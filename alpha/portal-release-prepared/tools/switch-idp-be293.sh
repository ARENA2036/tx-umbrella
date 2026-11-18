#!/usr/bin/env bash
# Guarded IdP switch of the be293-portal release: revision 5 (deployed) -> revision 6. The Portal moves from the shared
# centralidp/sharedidp to the be293 releases (centralidp-be293 / sharedidp-be293), BPDM keeps the SHARED CentralIDP token
# endpoint (decision G1-1, backend.processesworker.bpdm.tokenAddress of the patched chart), and new shared-IdP realms
# send mail to the smtp4dev sink (decision D5). Environment variables change; nothing else may.
#
#   bash tools/switch-idp-be293.sh             # DEFAULT: gates + read-only live checks + server-side dry run
#                                              # + rendered-vs-live comparison. Changes nothing.
#   bash tools/switch-idp-be293.sh --execute   # same, then a typed confirmation, a snapshot, ONE `helm upgrade --no-hooks`
#
# Safeguards (same as upgrade-be293.sh, scoped to this change):
#   - Chart: the PATCHED portal 2.6.0 package (alpha/portal-chart-2.6.0-patched/portal-2.6.0.tgz), pinned by sha256.
#     Same four values files in the same order, no --reuse-values. Post-renderer be293-idp-switch = be293-retention
#     unchanged + spec.suspend: true on the processes-worker CronJob, so the worker cannot write into the shared
#     release26-09 IdPs and Helm owns that field (the offline gates still run with be293-retention).
#   - The release must be at exactly revision 5 with status `deployed`.
#   - --no-hooks: no schema change. The operator admin user is seeded with fixed IDs in both new realms and the Portal
#     resolves users by preferred_username (= Portal identity id), so no seed data has to change. Hooks would re-run the
#     migration Jobs and BatchUpdateSeeder, which resets seed-keyed rows edited in the UI.
#   - Live effective values (helm get values) may differ from the four files ONLY at the reviewed IdP/SMTP keys, and
#     those keys must carry the reviewed target values.
#   - The Portal client secrets in Secret be293-portal-keycloak must equal the secrets seeded into the new realms
#     (compared in memory, verdicts only), and both new realms must publish the expected OIDC issuer.
#   - Drift is accepted only if listed in expected-drift.idp-switch.alpha.yaml AND on the reviewed objects; no Secret
#     key may change; every rendered image must equal the live image; BPDM must render the shared endpoint.
#   - Server-side apply without --force-conflicts; a field owned by another manager makes the upgrade fail.
#   - --execute snapshots live objects (no Secrets) and Helm history to .evidence/ before upgrading, and verifies
#     afterwards: revision, stored retention, suspended CronJobs, unchanged images, same PVC, same Ingress hosts,
#     IdP endpoints and the shared BPDM endpoint live.
#
# Never used: uninstall, rollback, install, --install, --force, --replace, --reset-values, --reuse-values,
# --take-ownership, --force-conflicts, --rollback-on-failure, --atomic, --cleanup-on-fail (deletes on failure).
# A failed upgrade leaves revision 6 `failed` and every object in place for read-only diagnosis.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
KC="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CTX="alpha"
NS="be293"
RELEASE="be293-portal"
FROM_REVISION=5
TO_REVISION=6
CHART="$REPO/alpha/portal-chart-2.6.0-patched/portal-2.6.0.tgz"
CHART_SHA256="b16d0d951adfc98f2014daec80c799b04e59fec38e4c5454e99228212ed7f760"
POST_RENDERER="be293-idp-switch"
RETENTION_RENDERER="be293-retention"
VALUES_FILES=("$HERE/values-be293-portal.yaml" "$HERE/values-be293-portal.alpha-release.yaml"
              "$HERE/values-be293-portal.alpha-retention.yaml" "$HERE/values-be293-portal.alpha-smtp4dev.yaml")
VALUES_ARGS=(-f "${VALUES_FILES[0]}" -f "${VALUES_FILES[1]}" -f "${VALUES_FILES[2]}" -f "${VALUES_FILES[3]}")
EXPECTED_DRIFT="$HERE/expected-drift.idp-switch.alpha.yaml"
WORKER="$RELEASE-processes-worker"
MAINTENANCE="$RELEASE-portal-maintenance"
ADMIN="$RELEASE-administration-service"
CENTRAL="https://centralidp-be293.test.tractus-x.com"
SHARED="https://sharedidp-be293.test.tractus-x.com"
BPDM_TOKEN="https://centralidp.test.tractus-x.com/auth/realms/CX-Central/protocol/openid-connect/token"
SMTP_HOST="be293-smtp4dev.be293.svc.cluster.local"
# The only workloads whose environment changes, plus the Rancher annotation on both Ingresses.
ALLOWED_DRIFT_OBJECTS=("CronJob/$WORKER" "Deployment/$ADMIN" "Deployment/$RELEASE-marketplace-app-service"
                       "Deployment/$RELEASE-notification-service" "Deployment/$RELEASE-registration-service"
                       "Deployment/$RELEASE-services-service" "Deployment/$RELEASE-portal" "Deployment/$RELEASE-registration"
                       "Ingress/$RELEASE-backend" "Ingress/$RELEASE-frontend")
KEYCLOAK_WORKLOADS=("CronJob/$WORKER" "Deployment/$ADMIN" "Deployment/$RELEASE-marketplace-app-service"
                    "Deployment/$RELEASE-notification-service" "Deployment/$RELEASE-registration-service"
                    "Deployment/$RELEASE-services-service")
CONFIRM_PHRASE="switch $RELEASE on $CTX/$NS to the be293 IdPs as revision $TO_REVISION without hooks"

MODE="dry-run"
case "${1:-}" in
  "") ;;
  --execute) MODE="execute" ;;
  *) echo "usage: switch-idp-be293.sh [--execute]" >&2; exit 2 ;;
esac

unset KUBECONFIG HELM_KUBECONTEXT
export HELM_PLUGINS="$HERE/helm-plugins"
umask 077

die() { echo "ABORT: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

k() {
  case "$1" in get) ;; *) die "refused: kubectl $1 is not read-only" ;; esac
  kubectl --kubeconfig "$KC" --context "$CTX" --request-timeout=20s "$@"
}
# Helm: read-only subcommands, plus `upgrade` only with --no-hooks.
h() {
  case "$1" in
    get|history|status|list|plugin) ;;
    upgrade) [[ " $* " == *" --no-hooks "* ]] || die "refused: helm upgrade without --no-hooks" ;;
    *) die "refused: helm $1" ;;
  esac
  local a
  for a in "$@"; do
    case "$a" in
      --install|-i|--force|--replace|--reset-values|--reuse-values|--reset-then-reuse-values|--take-ownership|\
      --force-conflicts|--rollback-on-failure|--atomic|--cleanup-on-fail) die "refused: helm flag $a" ;;
    esac
  done
  helm --kubeconfig "$KC" --kube-context "$CTX" "$@"
}
# kind/name -> "container=image" lines of every container (Deployment, StatefulSet or CronJob), sorted.
images_of() {
  ruby -rjson -e 'd = JSON.parse($stdin.read)
    (d["items"] || [d]).each do |o|
      s = o.dig("spec","jobTemplate","spec","template","spec") || o.dig("spec","template","spec")
      s["containers"].each { |c| puts "#{o["kind"]}/#{o["metadata"]["name"]} #{c["name"]}=#{c["image"]}" }
    end' | sort
}
# Release JSON (dry run) on stdin -> the same "kind/name container=image" lines for the rendered workloads.
rendered_images() {
  ruby -rjson -ryaml -e 'YAML.load_stream(JSON.parse($stdin.read)["manifest"].to_s).compact.each do |d|
      s = d.dig("spec","jobTemplate","spec","template","spec") || d.dig("spec","template","spec")
      next unless %w[Deployment StatefulSet CronJob].include?(d["kind"]) && s
      s["containers"].each { |c| puts "#{d["kind"]}/#{d["metadata"]["name"]} #{c["name"]}=#{c["image"]}" }
    end' | sort
}
# Workload JSON (one object or a list) on stdin, kind/name and env name as args -> plain value of that env var.
env_value() {
  ruby -rjson -e 'kind, name, var = ARGV
    d = JSON.parse($stdin.read)
    o = (d["items"] || [d]).find { |x| x["kind"] == kind && x.dig("metadata","name") == name } or exit 1
    s = o.dig("spec","jobTemplate","spec","template","spec") || o.dig("spec","template","spec")
    e = s["containers"].flat_map { |c| c["env"] || [] }.find { |x| x["name"] == var } or exit 1
    print e["value"].to_s' "$@"
}
# Same on the dry-run manifest.
rendered_env() {
  ruby -rjson -ryaml -e 'kind, name, var = ARGV
    o = YAML.load_stream(JSON.parse($stdin.read)["manifest"].to_s).compact
            .find { |d| d["kind"] == kind && d.dig("metadata","name") == name } or exit 1
    s = o.dig("spec","jobTemplate","spec","template","spec") || o.dig("spec","template","spec")
    e = s["containers"].flat_map { |c| c["env"] || [] }.find { |x| x["name"] == var } or exit 1
    print e["value"].to_s' "$@"
}
# Ingress JSON (list) on stdin -> "name host" lines (rules and TLS), sorted.
ingress_hosts() {
  ruby -rjson -e 'JSON.parse($stdin.read)["items"].each do |i|
      n = i["metadata"]["name"]
      (i.dig("spec","rules") || []).each { |r| puts "#{n} rule #{r["host"]}" }
      (i.dig("spec","tls") || []).each { |t| (t["hosts"] || []).each { |x| puts "#{n} tls #{x} #{t["secretName"]}" } }
    end' | sort
}

LOG="$(mktemp "${TMPDIR:-/tmp}/be293-idp.XXXXXX")"
CMP="$(mktemp "${TMPDIR:-/tmp}/be293-idp-cmp.XXXXXX")"
REL="$(mktemp "${TMPDIR:-/tmp}/be293-idp-rel.XXXXXX")"
trap 'rm -f "$LOG" "$CMP" "$REL"' EXIT

step "0 target and tooling"
[[ -r "$KC" ]] || die "$KC not readable"
kubectl --kubeconfig "$KC" config get-contexts -o name | grep -qx "$CTX" || die "context $CTX not in $KC"
[[ -f "$CHART" && "$(shasum -a 256 "$CHART" | cut -d' ' -f1)" == "$CHART_SHA256" ]] || die "patched chart checksum mismatch"
for p in "$POST_RENDERER" "$RETENTION_RENDERER"; do
  helm plugin list | grep -q "^${p}[[:space:]].*postrenderer/v1" || die "post-renderer $p missing in $HELM_PLUGINS"
done
echo "OK   kubeconfig $KC, context $CTX, namespace $NS, patched chart sha256 ok, post-renderers present (mode: $MODE)"

step "1 offline release gates on the patched chart (KUBECONFIG=/dev/null)"
KUBECONFIG=/dev/null PORTAL_CHART="$CHART" PORTAL_CHART_SHA256="$CHART_SHA256" bash "$HERE/tools/render-release.sh" > "$LOG" 2>&1 \
  || { tail -15 "$LOG" >&2; die "offline release gates failed"; }
echo "OK   render, Ingress, retention, smtp4dev (S9 = D5 shared-realm SMTP) and resolver gates pass"

step "2 release state: revision $FROM_REVISION deployed"
hist="$(h history "$RELEASE" -n "$NS" -o json)" || die "cannot read release history"
state="$(ruby -rjson -e 'r = JSON.parse(ARGV[0]).max_by { |x| x["revision"].to_i }; puts "#{r["revision"]} #{r["status"]}"' "$hist" 2>/dev/null)" \
  || die "release history unreadable"
[[ "$state" == "$FROM_REVISION deployed" ]] || die "latest release revision is '$state', expected '$FROM_REVISION deployed': nothing changed"
echo "OK   $RELEASE: revision $FROM_REVISION, deployed"

step "3 live effective values vs the four values files (key paths only, values never printed)"
h get values "$RELEASE" -n "$NS" -o json > "$LOG" || die "cannot read live release values"
ruby -rjson -ryaml -e '
  merge = ->(a, b) { a.is_a?(Hash) && b.is_a?(Hash) ? a.merge(b) { |_, x, y| merge.(x, y) } : b }
  flat = ->(h, p = nil) { h.is_a?(Hash) && !h.empty? ? h.flat_map { |k, v| flat.(v, [p, k].compact.join(".")) } : [[p, h]] }
  live_file, central, shared, bpdm, smtp, *files = ARGV
  live = flat.(JSON.parse(File.read(live_file)) || {}).to_h
  new = flat.(files.map { |f| YAML.safe_load(File.read(f)) || {} }.reduce { |a, b| merge.(a, b) }).to_h
  s = "backend.provisioning.sharedRealm.smtpServer"
  target = { "centralidp.address" => central, "sharedidpAddress" => shared, "backend.processesworker.bpdm.tokenAddress" => bpdm,
             "#{s}.host" => smtp, "#{s}.port" => "25", "#{s}.user" => "", "#{s}.from" => "noreply@be293.test",
             "#{s}.replyTo" => "noreply@be293.test", "#{s}.auth" => "false", "#{s}.startTls" => "false" }
  bad = target.reject { |k, v| new[k] == v }.keys.map { |k| "FAIL values file: #{k} is not the reviewed target" }
  changed = (live.keys | new.keys).reject { |k| live[k] == new[k] }
  bad += (changed - target.keys).map { |k| "FAIL live value differs from the values files outside the switch: #{k}" }
  bad << "FAIL live values already carry every target: nothing to switch" if (target.keys & changed).empty?
  (target.keys & changed).sort.each { |k| puts "CHANGE #{k}" }
  bad.each { |b| puts b }
  exit(bad.empty? ? 0 : 1)
' "$LOG" "$CENTRAL" "$SHARED" "$BPDM_TOKEN" "$SMTP_HOST" "${VALUES_FILES[@]}" \
  || die "live effective values differ outside the reviewed IdP/SMTP keys: nothing changed"
: > "$LOG"
echo "OK   live values = the four values files except the reviewed IdP/SMTP keys"

step "4 read-only live checks"
fails=0
pvc="data-$RELEASE-postgresql-0"
pvc_state="$(k get pvc "$pvc" -n "$NS" -o jsonpath='{.status.phase} {.metadata.uid}' 2>/dev/null || true)"
[[ "${pvc_state%% *}" == "Bound" ]] && echo "OK   PVC $pvc Bound" || { echo "FAIL PVC $pvc phase ${pvc_state%% *}"; fails=$((fails + 1)); }
for s in keycloak interfaces; do
  # Verdicts only (key names, byte lengths, NUL check); values never leave the checker.
  if out="$(k get secret "$RELEASE-$s" -n "$NS" -o json | ruby "$HERE/tools/check_secret_contract.rb" \
              --contract "$HERE/secrets-contract.yaml" --name "$RELEASE-$s" --mail-disabled)"; then
    echo "OK   Secret $RELEASE-$s matches the contract (no NUL bytes)"
  else
    fails=$((fails + 1))
  fi
  grep -E '^(FAIL|WARN)' <<<"$out" || true
done
# The Portal clients must authenticate against the NEW realms: compare in memory, print verdicts only.
if out="$(k get secret "$RELEASE-keycloak" be293-centralidp-seeding-service-accounts be293-sharedidp-seeding-master -n "$NS" -o json \
            | ruby -rjson -rbase64 -e '
                s = JSON.parse($stdin.read)["items"].to_h { |x| [x["metadata"]["name"], x["data"] || {}] }
                pairs = [["central-client-secret", "be293-centralidp-seeding-service-accounts", "sa-cl1-reg-2"],
                         ["shared-client-secret", "be293-sharedidp-seeding-master", "sa-provisioning"]]
                ok = pairs.map do |key, other, okey|
                  a = s.dig(ARGV[0], key); b = s.dig(other, okey)
                  v = a.nil? || b.nil? ? "MISSING" : Base64.decode64(a) == Base64.decode64(b) ? "MATCH" : "MISMATCH"
                  puts "#{v == "MATCH" ? "OK  " : "FAIL"} #{ARGV[0]}/#{key} vs #{other}/#{okey}: #{v}"
                  v == "MATCH"
                end
                exit(ok.all? ? 0 : 1)' "$RELEASE-keycloak")"; then
  echo "$out"
else
  echo "$out"; fails=$((fails + 1))
fi
for realm in "$CENTRAL/auth/realms/CX-Central" "$SHARED/auth/realms/CX-Operator"; do
  iss="$(curl -fsS --max-time 10 "$realm/.well-known/openid-configuration" 2>/dev/null \
           | ruby -rjson -e 'print JSON.parse($stdin.read)["issuer"].to_s' 2>/dev/null || true)"
  [[ "$iss" == "$realm" ]] && echo "OK   OIDC issuer $realm" || { echo "FAIL OIDC issuer of $realm is '${iss:-unreachable}'"; fails=$((fails + 1)); }
done
[[ -n "$(k get service be293-smtp4dev -n "$NS" --ignore-not-found -o name)" ]] && echo "OK   test mail sink Service be293-smtp4dev exists" \
  || { echo "FAIL Service be293-smtp4dev missing"; fails=$((fails + 1)); }
dns="$(k get networkpolicy -n "$NS" -o json | ruby -rjson -e '
  ok = JSON.parse($stdin.read)["items"].any? { |p| (p.dig("spec","egress") || []).any? { |r| (r["ports"] || []).any? { |x| x["port"].to_s == "8053" } } }
  puts(ok ? "yes" : "no")')"
[[ "$dns" == "yes" ]] && echo "OK   a be293 NetworkPolicy allows egress to DNS target port 8053" \
  || { echo "FAIL no be293 NetworkPolicy allows port 8053: cluster DNS would be blocked"; fails=$((fails + 1)); }
[[ "$(k get cronjob "$MAINTENANCE" -n "$NS" -o jsonpath='{.spec.suspend}')" == "true" ]] && echo "OK   live $MAINTENANCE suspended" \
  || { echo "FAIL live $MAINTENANCE not suspended"; fails=$((fails + 1)); }
# Suspended before the switch so no Job can write into the shared IdPs; the switch renders the same value.
[[ "$(k get cronjob "$WORKER" -n "$NS" -o jsonpath='{.spec.suspend}')" == "true" ]] && echo "OK   live $WORKER suspended" \
  || { echo "FAIL live $WORKER not suspended: suspend it before the switch"; fails=$((fails + 1)); }
[[ "$fails" -eq 0 ]] || die "$fails live check(s) failed: nothing changed"

UPGRADE_ARGS=(upgrade "$RELEASE" "$CHART" --namespace "$NS" "${VALUES_ARGS[@]}" --post-renderer "$POST_RENDERER" --no-hooks)

step "5 server-side dry run: release checks + rendered-vs-live comparison (in memory)"
h "${UPGRADE_ARGS[@]}" --dry-run=server -o json 2>"$LOG" > "$REL" \
  || { head -3 "$LOG" >&2; die "server-side dry run failed: nothing upgraded"; }
k get deployment,statefulset,cronjob -n "$NS" -o json | images_of > "$LOG" || die "cannot read live images"
img_diff="$(rendered_images < "$REL" | while read -r line; do grep -qxF "$line" "$LOG" || echo "${line%% *}"; done | sort -u)"
[[ -z "$img_diff" ]] || die "rendered image differs from live for: $(tr '\n' ' ' <<<"$img_diff")- nothing upgraded"
echo "OK   every rendered image equals the live image (pinned digests unchanged)"
for wl in "CronJob/$WORKER" "Deployment/$ADMIN"; do
  [[ "$(rendered_env "${wl%%/*}" "${wl#*/}" APPLICATIONCHECKLIST__BPDM__TOKENADDRESS < "$REL")" == "$BPDM_TOKEN" ]] \
    || die "$wl does not render the shared BPDM token endpoint: nothing upgraded"
done
for wl in "${KEYCLOAK_WORKLOADS[@]}"; do
  [[ "$(rendered_env "${wl%%/*}" "${wl#*/}" KEYCLOAK__CENTRAL__CONNECTIONSTRING < "$REL")" == "$CENTRAL" && \
     "$(rendered_env "${wl%%/*}" "${wl#*/}" KEYCLOAK__SHARED__CONNECTIONSTRING < "$REL")" == "$SHARED" ]] \
    || die "$wl does not render the be293 IdP connection strings: nothing upgraded"
done
echo "OK   rendered: BPDM on the shared CentralIDP, Keycloak connections on centralidp-be293/sharedidp-be293"
suspended="$(ruby -rjson -ryaml -e 'YAML.load_stream(JSON.parse($stdin.read)["manifest"].to_s).compact
    .select { |d| d["kind"] == "CronJob" && d.dig("spec","suspend") == true }.each { |d| puts d["metadata"]["name"] }' < "$REL" | sort | tr '\n' ' ')"
[[ "$suspended" == "$MAINTENANCE $WORKER " ]] || die "rendered suspended CronJobs are '$suspended', expected '$MAINTENANCE $WORKER': nothing upgraded"
echo "OK   rendered: $MAINTENANCE and $WORKER suspended"
ruby "$HERE/tools/compare_release_live.rb" --kubeconfig "$KC" --context "$CTX" --expected "$EXPECTED_DRIFT" \
  < "$REL" | tee "$CMP" \
  || die "a release check failed, a Secret key would change, or unreviewed drift: nothing upgraded"
off_scope="$({ grep -E '^DRIFT ' "$CMP" || true; } | sed -E 's/^DRIFT ([^:]+):.*/\1/' | sort -u | while read -r obj; do
  ok=0; for a in "${ALLOWED_DRIFT_OBJECTS[@]}"; do [[ "$obj" == "$a" ]] && ok=1; done
  [[ "$ok" == 1 ]] || echo "$obj"
done)"
[[ -z "$off_scope" ]] || die "drift outside the IdP-switch scope: $(tr '\n' ' ' <<<"$off_scope")- nothing upgraded"
grep -qE "^DRIFT Deployment/$ADMIN: .*env KEYCLOAK__CENTRAL__CONNECTIONSTRING: value differs" "$CMP" \
  || die "no KEYCLOAK__CENTRAL__CONNECTIONSTRING drift on $ADMIN: live is already switched or the comparison changed"
echo "OK   drift limited to IdP/SMTP environment variables of the reviewed workloads and Rancher Ingress annotations"

if [[ "$MODE" != "execute" ]]; then
  echo; echo "DRY RUN COMPLETE: nothing changed. Review the DRIFT lines above, then re-run with --execute after approval."
  exit 0
fi

step "6 confirmation"
{ exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation; nothing upgraded"
printf 'Type exactly "%s" to upgrade: ' "$CONFIRM_PHRASE" >&3
answer=""
read -r answer <&3 || true
exec 3>&-
[[ "$answer" == "$CONFIRM_PHRASE" ]] || die "confirmation did not match; nothing upgraded"

step "7 pre-upgrade snapshot (read-only; Secrets are not captured)"
SNAP="$HERE/.evidence/pre-revision-$TO_REVISION-idp-switch-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$SNAP"
k get deployment,statefulset,cronjob,service,ingress,configmap -n "$NS" -o yaml > "$SNAP/objects.yaml" \
  || die "snapshot failed: nothing upgraded"
k get replicaset -n "$NS" -o custom-columns='NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name,REVISION:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,READY:.status.readyReplicas' \
  > "$SNAP/replicasets.txt" || die "snapshot failed: nothing upgraded"
h history "$RELEASE" -n "$NS" -o json > "$SNAP/helm-history.json" || die "snapshot failed: nothing upgraded"
k get deployment,statefulset,cronjob -n "$NS" -o json | images_of > "$SNAP/images-before.txt" \
  || die "snapshot failed: nothing upgraded"
k get ingress -n "$NS" -o json | ingress_hosts > "$SNAP/ingress-hosts-before.txt" || die "snapshot failed: nothing upgraded"
echo "${pvc_state#* }" > "$SNAP/pvc-uid.txt"
echo "OK   snapshot in ${SNAP#$HERE/} (keep out of Git)"

step "8 helm upgrade --no-hooks (server-side apply, no forced conflicts, no rollback/cleanup on failure)"
h "${UPGRADE_ARGS[@]}" --wait --timeout 15m -o json > /dev/null \
  || die "helm upgrade failed: revision $TO_REVISION left in place for read-only diagnosis; nothing deleted (snapshot: ${SNAP#$HERE/})"

step "9 read-only verification"
st="$(h status "$RELEASE" -n "$NS" -o json | ruby -rjson -e 'r = JSON.parse($stdin.read); puts "#{r["version"]} #{r.dig("info","status")}"')"
[[ "$st" == "$TO_REVISION deployed" ]] && echo "OK   $RELEASE revision $TO_REVISION deployed" || die "release state '$st', expected '$TO_REVISION deployed'"
{ h get manifest "$RELEASE" -n "$NS"; echo "---"; h get hooks "$RELEASE" -n "$NS"; } 2>"$LOG" \
  | ruby "$HERE/tools/verify_release_retention.rb" --yaml || die "stored release manifest check failed"
[[ "$(k get cronjob "$MAINTENANCE" -n "$NS" -o jsonpath='{.spec.suspend}')" == "true" ]] || die "live $MAINTENANCE not suspended"
[[ "$(k get cronjob "$WORKER" -n "$NS" -o jsonpath='{.spec.suspend}')" == "true" ]] || die "live $WORKER no longer suspended"
echo "OK   $MAINTENANCE and $WORKER still suspended"
k get deployment,statefulset,cronjob -n "$NS" -o json | images_of > "$SNAP/images-after.txt" || die "cannot read live images"
diff -q "$SNAP/images-before.txt" "$SNAP/images-after.txt" > /dev/null \
  || die "workload images changed (see ${SNAP#$HERE/}/images-*.txt)"
echo "OK   every workload image unchanged"
[[ "$(k get pvc "$pvc" -n "$NS" -o jsonpath='{.status.phase} {.metadata.uid}')" == "$pvc_state" ]] \
  || die "PVC $pvc changed phase or identity"
echo "OK   PVC $pvc Bound, same UID"
k get ingress -n "$NS" -o json | ingress_hosts > "$SNAP/ingress-hosts-after.txt" || die "cannot read live Ingresses"
diff -q "$SNAP/ingress-hosts-before.txt" "$SNAP/ingress-hosts-after.txt" > /dev/null || die "Ingress hosts or TLS Secrets changed"
echo "OK   Ingress hosts and TLS Secrets unchanged"
live_wl="$(k get deployment,cronjob -n "$NS" -o json)" || die "cannot read live workloads"
for wl in "CronJob/$WORKER" "Deployment/$ADMIN"; do
  [[ "$(env_value "${wl%%/*}" "${wl#*/}" APPLICATIONCHECKLIST__BPDM__TOKENADDRESS <<<"$live_wl")" == "$BPDM_TOKEN" ]] \
    || die "$wl live BPDM token endpoint is not the shared CentralIDP"
done
for wl in "${KEYCLOAK_WORKLOADS[@]}"; do
  [[ "$(env_value "${wl%%/*}" "${wl#*/}" KEYCLOAK__CENTRAL__CONNECTIONSTRING <<<"$live_wl")" == "$CENTRAL" ]] \
    || die "$wl live KEYCLOAK__CENTRAL__CONNECTIONSTRING is not $CENTRAL"
done
echo "OK   live: Keycloak connections on centralidp-be293/sharedidp-be293, BPDM on the shared CentralIDP"
echo; echo "SWITCHED: $RELEASE revision $TO_REVISION deployed. Next: log in as the CX-Operator admin. Note: tools/smoke-be293.sh still expects the pre-D5 shared-realm SMTP."
