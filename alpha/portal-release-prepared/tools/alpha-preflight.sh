#!/usr/bin/env bash
# READ-ONLY Alpha preflight for the be293-portal release. Run it on the operator workstation:
#
#   bash tools/alpha-preflight.sh 2>&1 | tee "$TMPDIR/be293-preflight.txt"
#
# Guarantees:
#   - every kubectl/helm call passes --kubeconfig ~/.kube/alpha.yaml and context `alpha` explicitly; the
#     ambient KUBECONFIG and current-context are never used (unset below)
#   - the kubectl wrapper refuses every verb except get / auth can-i / api-resources, and helm only runs
#     `list` and `status`; nothing is created, changed or deleted
#   - Secret VALUES are never printed: Secrets are piped straight into tools/check_secret_contract.rb, which
#     prints key names, byte lengths and format verdicts only
#
# Exit 0 = no FAIL. WARN / CHECK lines need a human decision and are listed in README-ALPHA-RELEASE.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CTX="alpha"
NS="be293"
RELEASE="be293-portal"
FRONT_HOST="portal-be293.test.tractus-x.com"
BACK_HOST="portal-backend-be293.test.tractus-x.com"
FAILS=0

unset KUBECONFIG HELM_KUBECONTEXT
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

k() {
  case "$1" in
    get|api-resources) ;;
    auth) [[ "${2:-}" == "can-i" ]] || { echo "refused: kubectl $*" >&2; return 99; } ;;
    *) echo "refused: kubectl $1 is not read-only" >&2; return 99 ;;
  esac
  kubectl --kubeconfig "$KC" --context "$CTX" --request-timeout=20s "$@"
}
h() {
  case "$1" in list|status) ;; *) echo "refused: helm $1 is not read-only" >&2; return 99 ;; esac
  helm --kubeconfig "$KC" --kube-context "$CTX" "$@"
}

echo "== P0 kubeconfig and context"
[[ -r "$KC" ]] || { echo "FAIL $KC not readable"; exit 1; }
if ! kubectl --kubeconfig "$KC" config get-contexts -o name | grep -qx "$CTX"; then
  echo "FAIL context $CTX not found in $KC"; exit 1
fi
echo "context $CTX -> cluster $(kubectl --kubeconfig "$KC" config view -o jsonpath="{.contexts[?(@.name==\"$CTX\")].context.cluster}")"
k get --raw /version >/dev/null || { echo "FAIL Alpha API not reachable"; exit 1; }

umask 077
ERRF="$(mktemp "${TMPDIR:-/tmp}/be293-preflight-err.XXXXXX")"
trap 'rm -f "$ERRF" "$ERRF.p3"' EXIT
# Runs a read-only command, stdout into the named variable. A non-zero exit is ALWAYS a FAIL (never read as
# "absent" or "OK"); only the first stderr line is shown (kubectl/helm errors carry no Secret data).
#   capture VAR "description" cmd args...
capture() {
  local __var="$1" __desc="$2" __out __rc
  shift 2
  __out="$("$@" 2>"$ERRF")"; __rc=$?
  printf -v "$__var" '%s' "$__out"
  if [[ $__rc -ne 0 ]]; then fail "$__desc failed (exit $__rc): $(head -1 "$ERRF")"; return 1; fi
}

echo "== P1 namespace $NS and its current contents (names only)"
capture out "get namespace $NS" k get namespace "$NS" -o name && echo "$out"
capture out "list objects in $NS" k get deploy,sts,job,cronjob,svc,ingress,configmap,secret,pvc,networkpolicy -n "$NS" -o name && echo "${out:-<none>}"
# Helm 4 `list` has no -a/--all; the status flags together cover every release state.
HELM_ALL_STATES=(--deployed --failed --pending --superseded --uninstalled --uninstalling)
if capture out "helm list in $NS" h list -n "$NS" "${HELM_ALL_STATES[@]}" --filter "^${RELEASE}\$" -q; then
  if [[ -n "$out" ]]; then fail "Helm release $RELEASE already exists in $NS (no upgrade allowed)"; else echo "OK   Helm release $RELEASE not present in any state"; fi
fi
capture out "helm list all releases in $NS" h list -n "$NS" "${HELM_ALL_STATES[@]}" && echo "$out"
# Rights helm install + kubectl apply of the NetworkPolicies need in be293.
for r in secrets configmaps services deployments.apps statefulsets.apps jobs.batch cronjobs.batch \
         persistentvolumeclaims ingresses.networking.k8s.io networkpolicies.networking.k8s.io; do
  for verb in get create patch; do
    ans="$(k auth can-i "$verb" "$r" -n "$NS" 2>"$ERRF")"
    [[ "$ans" == "yes" ]] || fail "can-i $verb $r in $NS: ${ans:-$(head -1 "$ERRF")}"
  done
done
echo "rights check done (FAIL lines above, if any)"

echo "== P1b fresh-install data safety (PVC, hook Jobs, StorageClass)"
# A leftover PostgreSQL PVC would be silently reused: Bitnami skips initdb on a non-empty data dir, so new
# chart-generated passwords would not match and old data would be adopted. Fresh install requires none.
PG_PVC="data-${RELEASE}-postgresql-0"
if capture out "read PVC $PG_PVC" k get pvc "$PG_PVC" -n "$NS" --ignore-not-found -o name; then
  if [[ -n "$out" ]]; then fail "PVC $PG_PVC already exists: fresh install would reuse its data with new credentials; owner decision required (never delete it)"; else echo "OK   PVC $PG_PVC absent (fresh database)"; fi
fi
# The migration hooks have no hook-delete-policy, so Helm's default before-hook-creation DELETES any existing
# Job of the same name before creating the hook. None may exist before install.
for j in "${RELEASE}-portal-migrations" "${RELEASE}-provisioning-migrations"; do
  if capture out "read Job $j" k get job "$j" -n "$NS" --ignore-not-found -o name; then
    if [[ -n "$out" ]]; then fail "Job $j exists: Helm would delete it (before-hook-creation)"; else echo "OK   Job $j absent"; fi
  fi
done
# The PostgreSQL volume claim has no storageClassName, so the cluster default class applies.
if capture out "list StorageClasses" k get storageclass -o jsonpath='{range .items[*]}{.metadata.name} reclaim={.reclaimPolicy} binding={.volumeBindingMode} expand={.allowVolumeExpansion} default={.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}'; then
  echo "$out"
  defaults="$(grep -c 'default=true' <<<"$out" || true)"
  [[ "$defaults" == "1" ]] || fail "expected exactly one default StorageClass, found $defaults (PVC would stay Pending or be ambiguous)"
  grep 'default=true' <<<"$out" | grep -q 'reclaim=Delete' && echo "WARN default StorageClass reclaimPolicy=Delete: deleting the PVC destroys the database volume"
fi

echo "== P2 Secrets vs secrets-contract.yaml (values never printed)"
for name in $(ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))["secrets"].each { |s| puts s["name"] }' "$HERE/secrets-contract.yaml"); do
  # --ignore-not-found: NotFound -> exit 0 + empty output (absent); any other error -> non-zero -> FAIL.
  if capture json "read Secret $name" k get secret "$name" -n "$NS" --ignore-not-found -o json; then
    printf '%s' "$json" | ruby "$HERE/tools/check_secret_contract.rb" --contract "$HERE/secrets-contract.yaml" --name "$name" --mail-disabled || FAILS=$((FAILS + 1))
  fi
  json=""
done
for t in be293-portal-frontend-tls be293-portal-backend-tls; do
  if capture out "read TLS Secret $t" k get secret "$t" -n "$NS" --ignore-not-found -o name; then
    if [[ -n "$out" ]]; then echo "WARN TLS Secret $t already exists; cert-manager will manage it"; else echo "OK   TLS Secret $t absent; cert-manager creates it"; fi
  fi
done

echo "== P3 cert-manager ClusterIssuer letsencrypt-prod (status and solver kinds only)"
if capture out "get ClusterIssuer letsencrypt-prod" k get clusterissuer letsencrypt-prod -o json; then
  printf '%s' "$out" | ruby -rjson -e '
    ci = JSON.parse($stdin.read)
    ready = (ci.dig("status","conditions") || []).find { |c| c["type"] == "Ready" }
    puts(ready && ready["status"] == "True" ? "OK   letsencrypt-prod Ready" : "FAIL letsencrypt-prod not Ready (#{ready && ready["reason"]})")
    solvers = ci.dig("spec","acme","solvers") || []
    puts "FAIL letsencrypt-prod has no ACME solvers" if solvers.empty?
    solvers.each_with_index do |s, i|
      kind = (s.keys - ["selector"]).join(",")
      detail = s["http01"] ? "ingressClass=#{s.dig("http01","ingress","ingressClassName") || s.dig("http01","ingress","class")}" : "provider=#{(s["dns01"] || {}).keys.join(",")}"
      puts "info solver[#{i}] #{kind} #{detail} selector=#{(s["selector"] || {}).to_json}"
    end' > "$ERRF.p3" 2>&1 || echo "FAIL could not parse ClusterIssuer" >> "$ERRF.p3"
  cat "$ERRF.p3"; FAILS=$((FAILS + $(grep -c '^FAIL' "$ERRF.p3"))); rm -f "$ERRF.p3"
fi

echo "== P4 IngressClass, ingress-nginx controller pods and ports"
capture out "get ingressclass nginx" k get ingressclass nginx -o jsonpath='{.metadata.name} controller={.spec.controller}{"\n"}' && echo "$out"
capture out "get ingress-nginx pods" k get pods -n ingress-nginx -o custom-columns=NAME:.metadata.name,LABELS:.metadata.labels,PORTS:.spec.containers[*].ports[*].containerPort && echo "$out"
capture out "get ingress-nginx services" k get svc -n ingress-nginx -o wide && echo "$out"

echo "== P5 ExternalDNS (deployment, args only; credentials live in env/Secrets and are not printed)"
if capture out "list deployments (all namespaces)" k get deploy -A -o json; then
  edns="$(printf '%s' "$out" | ruby -rjson -e '
    hits = JSON.parse($stdin.read)["items"].select { |d| d.dig("spec","template","spec","containers").any? { |c| c["image"].to_s.include?("external-dns") } }
    puts "FAIL no ExternalDNS deployment found: DNS records will NOT be created automatically" if hits.empty?
    hits.each do |d|
      c = d.dig("spec","template","spec","containers").find { |x| x["image"].to_s.include?("external-dns") }
      ready = d.dig("status","readyReplicas").to_i
      puts "#{ready > 0 ? "OK  " : "FAIL"} #{d["metadata"]["namespace"]}/#{d["metadata"]["name"]} ready=#{ready}/#{d.dig("spec","replicas")} image=#{c["image"]}"
      (c["args"] || []).each { |a| puts "  arg #{a}" if a.match?(/\A--(source|domain-filter|exclude-domains|annotation-filter|label-filter|namespace|policy|registry|txt-owner-id|txt-prefix|provider|ingress-class|zone-id-filter)/) }
    end' 2>&1 || echo "FAIL could not parse deployments")"
  echo "$edns"; FAILS=$((FAILS + $(grep -c '^FAIL' <<<"$edns")))
fi

echo "== P6 host conflicts and current DNS"
if capture out "list ingresses (all namespaces)" k get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.rules[*].host}{"\n"}{end}'; then
  hits="$(grep -E "(^| )($FRONT_HOST|$BACK_HOST)( |$)" <<<"$out" || true)"
  if [[ -n "$hits" ]]; then echo "$hits"; fail "an Ingress already claims a be293 host"; else echo "OK   no Ingress claims $FRONT_HOST / $BACK_HOST"; fi
fi
for host in "$FRONT_HOST" "$BACK_HOST" centralidp.test.tractus-x.com; do echo "info dns $host -> $(dig +short "$host" A | tr '\n' ' ')"; done

echo "== P7 CNI (FQDN egress capability) and release26-09 ingress-side policies (names only)"
capture out "get kube-system daemonsets" k get ds -n kube-system -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image && echo "$out"
capture out "api-resources" k api-resources -o name && grep -E 'cilium\.io|projectcalico\.org' <<<"$out" | grep -i -E 'networkpolic|networkset' | head -8
capture out "get release26-09 networkpolicies" k get networkpolicy -n release26-09 -o name && echo "${out:-<none>}"

echo "== P8 resolver and SMTP endpoints the EXISTING Alpha services use (non-secret env values only)"
if capture out "get release26-09 deployments/cronjobs" k get deploy,cronjob -n release26-09 -o json; then
  printf '%s' "$out" | ruby -rjson -e '
    JSON.parse($stdin.read)["items"].each do |o|
      spec = o.dig("spec","template","spec") || o.dig("spec","jobTemplate","spec","template","spec") || {}
      (spec["containers"] || []).each do |c|
        (c["env"] || []).each do |e|
          next unless e["name"].to_s.match?(/UNIVERSALRESOLVER|SMTPHOST|SMTPPORT|MAIL__HOST|MAIL__PORT|SMTP__HOST|SMTP__PORT/i) && e.key?("value")
          puts "info #{o["kind"]}/#{o["metadata"]["name"]} #{e["name"]}=#{e["value"]}"
        end
      end
    end' | sort -u
fi
out=""
echo
if [[ "$FAILS" -eq 0 ]]; then echo "PREFLIGHT: no FAIL (review WARN/CHECK lines)"; else echo "PREFLIGHT: $FAILS FAIL"; fi
exit $(( FAILS > 0 ))
