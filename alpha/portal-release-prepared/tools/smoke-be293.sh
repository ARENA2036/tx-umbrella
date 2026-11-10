#!/usr/bin/env bash
# READ-ONLY smoke test after the be293-portal recovery upgrade (revision 2). Changes nothing.
#
#   bash tools/smoke-be293.sh [--with-probe]
#
#   1. release: latest revision deployed
#   2. every be293-portal Deployment and the PostgreSQL StatefulSet fully ready
#   3. live images equal the reviewed pins (values-be293-portal.yaml / images.lock.yaml)
#   4. the reviewed configuration is live: BPDM /v6 and BPNAccess, in-cluster DID resolver on every workload that
#      sets it, shared-realm SMTP kept (office365:587), worker Portal mail still on smtp4dev
#   5. Rancher's field.cattle.io/publicEndpoints still on both Ingresses
#   6. public routes answer through the Ingress without a gateway error (no 502/503/504)
#   7. no startup exceptions in the last 15 minutes of the restarted Deployments (counts only)
#   8. DID resolver Ready; --with-probe also runs its in-pod resolution probe (kubectl exec, read-only)
# Exit 0 only if every check passes. kubectl verbs: get, logs (exec only with --with-probe, via did-resolver-be293.sh).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CTX="alpha"
NS="be293"
RELEASE="be293-portal"
FRONTEND="https://portal-be293.test.tractus-x.com"
BACKEND="https://portal-backend-be293.test.tractus-x.com"
RESOLVER="http://be293-did-resolver.be293.svc.cluster.local:8080/"
RESTARTED=(administration-service marketplace-app-service services-service registration-service portal)
PROBE=0
[[ "${1:-}" == "--with-probe" ]] && PROBE=1
[[ -z "${1:-}" || "$PROBE" == 1 ]] || { echo "usage: smoke-be293.sh [--with-probe]" >&2; exit 2; }

unset KUBECONFIG
fails=0
ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
step() { echo; echo "== $*"; }
k() {
  case "$1" in get|logs) ;; *) echo "refused: kubectl $1" >&2; exit 2 ;; esac
  kubectl --kubeconfig "$KC" --context "$CTX" -n "$NS" --request-timeout=30s "$@"
}
h() {
  case "$1" in status|history) ;; *) echo "refused: helm $1" >&2; exit 2 ;; esac
  helm --kubeconfig "$KC" --kube-context "$CTX" "$@"
}
envval() { # workload kind/name, variable -> value (plain env only; never a Secret)
  k get "$1" -o json | ruby -rjson -e 'd = JSON.parse($stdin.read)
    s = d.dig("spec","jobTemplate","spec","template","spec") || d.dig("spec","template","spec")
    e = s["containers"].flat_map { |c| c["env"] || [] }.find { |x| x["name"] == ARGV[0] }
    print(e.nil? ? "<unset>" : e["valueFrom"] ? "<ref:#{e.dig("valueFrom","secretKeyRef","name")}>" : e["value"].to_s)' "$2"
}
expect_env() { # kind/name var expected
  local v; v="$(envval "$1" "$2")"
  [[ "$v" == "$3" ]] && ok "$1 $2 = $3" || bad "$1 $2 = $v (expected $3)"
}

[[ -r "$KC" ]] || { echo "ABORT: $KC not readable" >&2; exit 2; }

step "1 release"
st="$(h status "$RELEASE" -n "$NS" -o json | ruby -rjson -e 'r = JSON.parse($stdin.read); puts "#{r["version"]} #{r.dig("info","status")}"')"
[[ "$st" == *" deployed" ]] && ok "$RELEASE revision ${st% *} deployed" || bad "release state '$st'"

step "2 readiness"
while read -r name want ready; do
  [[ "${ready:-0}" == "$want" && "$want" != "0" ]] && ok "deployment/$name $ready/$want ready" || bad "deployment/$name ${ready:-0}/$want ready"
done < <(k get deploy -l app.kubernetes.io/instance="$RELEASE" -o jsonpath='{range .items[*]}{.metadata.name} {.spec.replicas} {.status.readyReplicas}{"\n"}{end}')
pg="$(k get statefulset "$RELEASE-postgresql" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
[[ "$pg" == "1/1" ]] && ok "statefulset/$RELEASE-postgresql $pg" || bad "statefulset/$RELEASE-postgresql $pg"

step "3 images equal the reviewed pins"
pins="$(ruby -ryaml -e 'v = YAML.safe_load(File.read(ARGV[0])); b = v["backend"]
  { "administration-service" => %w[administration administrationservicetag], "registration-service" => %w[registration registrationservicetag],
    "marketplace-app-service" => %w[appmarketplace appmarketplaceservicetag], "services-service" => %w[services servicesservicetag],
    "notification-service" => %w[notification notificationservicetag] }.each { |w, (sec, key)|
    i = b.dig(sec, "image") or next; puts "#{w} #{i["name"]}:#{i[key]}" }' "$HERE/values-be293-portal.yaml" 2>/dev/null || true)"
if [[ -z "$pins" ]]; then
  bad "could not read image pins from values-be293-portal.yaml"
else
  while read -r w img; do
    live="$(k get deploy "$RELEASE-$w" -o jsonpath='{.spec.template.spec.containers[0].image}')"
    [[ "$live" == "$img" ]] && ok "$w image pinned (${img##*@sha256:} ...)" || bad "$w image ${live##*/} != pinned ${img##*/}"
  done <<<"$pins"
fi

step "4 reviewed configuration is live"
for w in administration-service; do
  expect_env "deploy/$RELEASE-$w" APPLICATIONCHECKLIST__BPDM__BASEADDRESS "https://business-partners.test.tractus-x.com/gate/v6"
  expect_env "deploy/$RELEASE-$w" APPLICATIONCHECKLIST__BPDM__BUSINESSPARTNERPOOLBASEADDRESS "https://business-partners.test.tractus-x.com/pool/v6"
  expect_env "deploy/$RELEASE-$w" APPLICATIONCHECKLIST__IDENTITYHUB__UNIVERSALRESOLVERADDRESS "$RESOLVER"
  expect_env "deploy/$RELEASE-$w" APPLICATIONCHECKLIST__DIM__UNIVERSALRESOLVERADDRESS "$RESOLVER"
done
for w in administration-service registration-service; do
  expect_env "deploy/$RELEASE-$w" BPNACCESS__BASEADDRESS "https://business-partners.test.tractus-x.com/pool/v6"
done
for w in marketplace-app-service services-service; do
  expect_env "deploy/$RELEASE-$w" DIM__UNIVERSALRESOLVERADDRESS "$RESOLVER"
done
expect_env "deploy/$RELEASE-portal" BPDM_GATE_API_URL "https://business-partners.test.tractus-x.com/gate/v6"
expect_env "deploy/$RELEASE-portal" BPDM_POOL_API_URL "https://business-partners.test.tractus-x.com/pool/v6"
for wl in "deploy/$RELEASE-administration-service" "cronjob/$RELEASE-processes-worker"; do
  expect_env "$wl" PROVISIONING__SHAREDREALM__SMTPSERVER__HOST "smtp.office365.com"
  expect_env "$wl" PROVISIONING__SHAREDREALM__SMTPSERVER__PORT "587"
  expect_env "$wl" PROVISIONING__SHAREDREALM__SMTPSERVER__PASSWORD "<ref:$RELEASE-mailing>"
done
expect_env "cronjob/$RELEASE-processes-worker" MAILINGSERVICE__MAIL__SMTPHOST "be293-smtp4dev.be293.svc.cluster.local"
expect_env "cronjob/$RELEASE-processes-worker" APPLICATIONCHECKLIST__IDENTITYHUB__UNIVERSALRESOLVERADDRESS "$RESOLVER"

step "5 Rancher Ingress annotations kept"
for i in backend frontend; do
  a="$(k get ingress "$RELEASE-$i" -o jsonpath='{.metadata.annotations.field\.cattle\.io/publicEndpoints}')"
  [[ -n "$a" ]] && ok "ingress/$RELEASE-$i field.cattle.io/publicEndpoints present" || bad "ingress/$RELEASE-$i field.cattle.io/publicEndpoints missing"
done

step "6 public routes (no gateway error)"
for url in "$FRONTEND/" "$FRONTEND/registration/" "$BACKEND/api/administration/" "$BACKEND/api/registration/" \
           "$BACKEND/api/apps/" "$BACKEND/api/services/" "$BACKEND/api/notification/"; do
  code="$(curl -sS -o /dev/null --max-time 20 -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
  case "$code" in
    502|503|504|000) bad "$url -> $code" ;;
    *) ok "$url -> $code" ;;
  esac
done

step "7 startup errors (last 15 minutes, counts only)"
for w in "${RESTARTED[@]}"; do
  n="$(k logs "deploy/$RELEASE-$w" --all-containers --since=15m 2>/dev/null | grep -cE 'Unhandled exception|Application startup exception|crit:|fail: Microsoft.Extensions.Hosting' || true)"
  [[ "${n:-0}" == 0 ]] && ok "$w: no startup exceptions" || bad "$w: $n startup exception line(s) (read the pod logs)"
done

step "8 DID resolver"
r="$(k get deploy be293-did-resolver -o jsonpath='{.status.readyReplicas}/{.spec.replicas}')"
[[ "$r" == "1/1" ]] && ok "be293-did-resolver $r ready" || bad "be293-did-resolver $r"
ep="$(k get endpoints be293-did-resolver -o jsonpath='{.subsets[*].addresses[*].ip}')"
[[ -n "$ep" ]] && ok "service be293-did-resolver has a ready endpoint" || bad "service be293-did-resolver has no ready endpoint"
np="$(k get networkpolicy be293-did-resolver-ingress -o jsonpath='{.spec.ingress[0].from[0].podSelector}')"
[[ "$np" == "{}" ]] && ok "resolver ingress policy admits all be293 pods (worker and services)" || bad "resolver ingress policy source is '$np'"
if [[ "$PROBE" == 1 ]]; then
  ALPHA_KUBECONFIG="$KC" bash "$HERE/tools/did-resolver-be293.sh" --verify && ok "resolver probe" || bad "resolver probe"
fi

echo
[[ "$fails" == 0 ]] && { echo "SMOKE PASS"; exit 0; } || { echo "SMOKE FAIL ($fails)"; exit 1; }
