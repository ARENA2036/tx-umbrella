#!/usr/bin/env bash
# Guarded worker-only upgrade of the be293-portal release: revision 4 (deployed) -> revision 5, rolling out the
# processes-worker built from portal-backend e2451f876 (8ca2c1ecc credential-await checklist fix, 2cd5dd8a4 IdentityHub
# activation membership, and the BPDM Pool v6 cx-memberships field isCatenaXMember).
#
#   bash tools/upgrade-be293.sh             # DEFAULT: gates + read-only live checks + server-side dry run
#                                           # + rendered-vs-live comparison. Changes nothing.
#   bash tools/upgrade-be293.sh --execute   # same, then a typed confirmation, a snapshot, ONE `helm upgrade --no-hooks`
#
# Safeguards (adapted from recover-be293.sh):
#   - The release must be at exactly revision 4 with status `deployed`; anything else stops before the dry run.
#   - --no-hooks: this upgrade changes no schema (e2451f876 adds no migration). Hooks would re-run the migration
#     Jobs and BatchUpdateSeeder, which resets seed-keyed rows edited in the UI. No database change is wanted here.
#   - The rendered worker image must equal the reviewed pin below (values/lock and this script must agree).
#   - Step 4: no Secret key may change, every DRIFT item must be listed in expected-drift.alpha.yaml, AND drift is only
#     accepted on CronJob/be293-portal-processes-worker and the two Ingresses (Rancher annotation). Any drift on
#     another object (the seven other images, Services, ConfigMaps, ...) stops the run: this upgrade is worker-only.
#   - Server-side apply without --force-conflicts; a field owned by another manager makes the upgrade fail.
#   - --execute snapshots live objects (no Secrets) and Helm history to .evidence/ before upgrading, and verifies
#     afterwards that only the worker image changed.
#   - The worker is a CronJob: the new image is used from the next scheduled Job; a Job already running keeps its
#     image. Nothing is deleted or restarted by this script.
#
# Never used: uninstall, rollback, install, --install, --force, --replace, --reset-values, --reuse-values,
# --take-ownership, --force-conflicts, --rollback-on-failure, --atomic, --cleanup-on-fail (deletes on failure).
# A failed upgrade leaves revision 3 `failed` and every object in place for read-only diagnosis.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
KC="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CTX="alpha"
NS="be293"
RELEASE="be293-portal"
FROM_REVISION=4
TO_REVISION=5
CHART="$REPO/handoff/BE-293-umbrella-3.17.0/chart/umbrella/charts/portal-2.6.0.tgz"
CHART_SHA256="a17ab65070eeea3e719e2187213db23fc9226f6a8b2fc94ed771ec6835ad1e09"
POST_RENDERER="be293-retention"
VALUES_ARGS=(-f "$HERE/values-be293-portal.yaml" -f "$HERE/values-be293-portal.alpha-release.yaml"
             -f "$HERE/values-be293-portal.alpha-retention.yaml" -f "$HERE/values-be293-portal.alpha-smtp4dev.yaml")
WORKER="$RELEASE-processes-worker"
WORKER_IMAGE="harbor-hub-shared.arena.3ascloud.de/be293/portal-processes-worker:be293-e2451f87628c8ae56c131f136e5ad3e12703a1f6@sha256:0857101e376c52277f88ec081b2902e6883f530e6d27d914fc83d05d7e72d3a6"
ALLOWED_DRIFT_OBJECTS=("CronJob/$WORKER" "Ingress/$RELEASE-backend" "Ingress/$RELEASE-frontend")
CONFIRM_PHRASE="upgrade $RELEASE on $CTX/$NS to revision $TO_REVISION without hooks"

MODE="dry-run"
case "${1:-}" in
  "") ;;
  --execute) MODE="execute" ;;
  *) echo "usage: upgrade-be293.sh [--execute]" >&2; exit 2 ;;
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

LOG="$(mktemp "${TMPDIR:-/tmp}/be293-upgrade.XXXXXX")"
CMP="$(mktemp "${TMPDIR:-/tmp}/be293-upgrade-cmp.XXXXXX")"
REL="$(mktemp "${TMPDIR:-/tmp}/be293-upgrade-rel.XXXXXX")"
trap 'rm -f "$LOG" "$CMP" "$REL"' EXIT

step "0 target and tooling"
[[ -r "$KC" ]] || die "$KC not readable"
kubectl --kubeconfig "$KC" config get-contexts -o name | grep -qx "$CTX" || die "context $CTX not in $KC"
[[ "$(shasum -a 256 "$CHART" | cut -d' ' -f1)" == "$CHART_SHA256" ]] || die "chart checksum mismatch"
helm plugin list | grep -q "^${POST_RENDERER}[[:space:]].*postrenderer/v1" || die "post-renderer $POST_RENDERER missing in $HELM_PLUGINS"
echo "OK   kubeconfig $KC, context $CTX, namespace $NS, chart sha256 ok, post-renderer present (mode: $MODE)"

step "1 offline release gates (KUBECONFIG=/dev/null)"
KUBECONFIG=/dev/null bash "$HERE/tools/render-release.sh" > "$LOG" 2>&1 \
  || { tail -15 "$LOG" >&2; die "offline release gates failed"; }
echo "OK   render (values = images.lock), Ingress, retention (D1-D8) and ArenaAdminRoles (D9) gates pass"

step "2 release state: revision $FROM_REVISION deployed"
hist="$(h history "$RELEASE" -n "$NS" -o json)" || die "cannot read release history"
state="$(ruby -rjson -e 'r = JSON.parse(ARGV[0]).max_by { |x| x["revision"].to_i }; puts "#{r["revision"]} #{r["status"]}"' "$hist" 2>/dev/null)" \
  || die "release history unreadable"
[[ "$state" == "$FROM_REVISION deployed" ]] || die "latest release revision is '$state', expected '$FROM_REVISION deployed': nothing changed"
echo "OK   $RELEASE: revision $FROM_REVISION, deployed"

step "3 read-only live checks"
fails=0
phase="$(k get pvc "data-$RELEASE-postgresql-0" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "$phase" == "Bound" ]] && echo "OK   PVC data-$RELEASE-postgresql-0 Bound" || { echo "FAIL PVC phase ${phase:-absent}"; fails=$((fails + 1)); }
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
[[ -n "$(k get service be293-smtp4dev -n "$NS" --ignore-not-found -o name)" ]] && echo "OK   test mail sink Service be293-smtp4dev exists" \
  || { echo "FAIL Service be293-smtp4dev missing"; fails=$((fails + 1)); }
dns="$(k get networkpolicy -n "$NS" -o json | ruby -rjson -e '
  ok = JSON.parse($stdin.read)["items"].any? { |p| (p.dig("spec","egress") || []).any? { |r| (r["ports"] || []).any? { |x| x["port"].to_s == "8053" } } }
  puts(ok ? "yes" : "no")')"
[[ "$dns" == "yes" ]] && echo "OK   a be293 NetworkPolicy allows egress to DNS target port 8053" \
  || { echo "FAIL no be293 NetworkPolicy allows port 8053: cluster DNS would be blocked"; fails=$((fails + 1)); }
[[ "$fails" -eq 0 ]] || die "$fails live check(s) failed"
active="$(k get cronjob "$WORKER" -n "$NS" -o jsonpath='{.status.active[*].name}' 2>/dev/null || true)"
[[ -z "$active" ]] && echo "OK   no $WORKER Job running" \
  || echo "WARN $WORKER Job running ($active): it finishes with the old image; the next scheduled Job uses the new one"

UPGRADE_ARGS=(upgrade "$RELEASE" "$CHART" --namespace "$NS" "${VALUES_ARGS[@]}" --post-renderer "$POST_RENDERER" --no-hooks)

step "4 server-side dry run: release checks + rendered-vs-live comparison (in memory)"
h "${UPGRADE_ARGS[@]}" --dry-run=server -o json 2>"$LOG" > "$REL" \
  || { head -3 "$LOG" >&2; die "server-side dry run failed: nothing upgraded"; }
rendered_worker="$(ruby -rjson -ryaml -e 'm = JSON.parse(File.read(ARGV[0]))["manifest"].to_s
  YAML.load_stream(m).compact.each do |d|
    next unless d["kind"] == "CronJob" && d.dig("metadata","name") == ARGV[1]
    puts d.dig("spec","jobTemplate","spec","template","spec","containers").map { |c| c["image"] }.uniq
  end' "$REL" "$WORKER")"
[[ "$rendered_worker" == "$WORKER_IMAGE" ]] \
  || die "rendered $WORKER image '${rendered_worker:-none}' is not the reviewed pin: nothing upgraded"
echo "OK   rendered $WORKER image is the reviewed pin (be293-e2451f876...@sha256:0857101e...)"
ruby "$HERE/tools/compare_release_live.rb" --kubeconfig "$KC" --context "$CTX" --expected "$HERE/expected-drift.alpha.yaml" \
  < "$REL" | tee "$CMP" \
  || die "a release check failed, a Secret key would change, or unreviewed drift: nothing upgraded"
# Worker-only: drift is accepted on the allowed objects only, and the worker image drift must be present.
off_scope="$({ grep -E '^DRIFT ' "$CMP" || true; } | sed -E 's/^DRIFT ([^:]+):.*/\1/' | sort -u | while read -r obj; do
  ok=0; for a in "${ALLOWED_DRIFT_OBJECTS[@]}"; do [[ "$obj" == "$a" ]] && ok=1; done
  [[ "$ok" == 1 ]] || echo "$obj"
done)"
[[ -z "$off_scope" ]] || die "drift outside the worker-only scope: $(tr '\n' ' ' <<<"$off_scope")- nothing upgraded"
grep -qE "^DRIFT CronJob/$WORKER: .*container $WORKER image" "$CMP" \
  || die "no $WORKER image drift: live already runs the pin or the comparison changed; nothing to upgrade"
echo "OK   drift limited to $WORKER image and Rancher Ingress annotations"

if [[ "$MODE" != "execute" ]]; then
  echo; echo "DRY RUN COMPLETE: nothing changed. Review the DRIFT lines above, then re-run with --execute after approval."
  exit 0
fi

step "5 confirmation"
{ exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation; nothing upgraded"
printf 'Type exactly "%s" to upgrade: ' "$CONFIRM_PHRASE" >&3
answer=""
read -r answer <&3 || true
exec 3>&-
[[ "$answer" == "$CONFIRM_PHRASE" ]] || die "confirmation did not match; nothing upgraded"

step "6 pre-upgrade snapshot (read-only; Secrets are not captured)"
SNAP="$HERE/.evidence/pre-revision-$TO_REVISION-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$SNAP"
k get deployment,statefulset,cronjob,service,ingress,configmap -n "$NS" -o yaml > "$SNAP/objects.yaml" \
  || die "snapshot failed: nothing upgraded"
k get replicaset -n "$NS" -o custom-columns='NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name,REVISION:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,READY:.status.readyReplicas' \
  > "$SNAP/replicasets.txt" || die "snapshot failed: nothing upgraded"
h history "$RELEASE" -n "$NS" -o json > "$SNAP/helm-history.json" || die "snapshot failed: nothing upgraded"
k get deployment,statefulset,cronjob -n "$NS" -o json | images_of > "$SNAP/images-before.txt" \
  || die "snapshot failed: nothing upgraded"
echo "OK   snapshot in ${SNAP#$HERE/} (keep out of Git)"

step "7 helm upgrade --no-hooks (server-side apply, no forced conflicts, no rollback/cleanup on failure)"
h "${UPGRADE_ARGS[@]}" --wait --timeout 15m -o json > /dev/null \
  || die "helm upgrade failed: revision $TO_REVISION left in place for read-only diagnosis; nothing deleted (snapshot: ${SNAP#$HERE/})"

step "8 read-only verification"
st="$(h status "$RELEASE" -n "$NS" -o json | ruby -rjson -e 'r = JSON.parse($stdin.read); puts "#{r["version"]} #{r.dig("info","status")}"')"
[[ "$st" == "$TO_REVISION deployed" ]] && echo "OK   $RELEASE revision $TO_REVISION deployed" || die "release state '$st', expected '$TO_REVISION deployed'"
{ h get manifest "$RELEASE" -n "$NS"; echo "---"; h get hooks "$RELEASE" -n "$NS"; } 2>"$LOG" \
  | ruby "$HERE/tools/verify_release_retention.rb" --yaml || die "stored release manifest check failed"
[[ "$(k get cronjob "$RELEASE-portal-maintenance" -n "$NS" -o jsonpath='{.spec.suspend}')" == "true" ]] \
  || die "live maintenance CronJob not suspended"
k get deployment,statefulset,cronjob -n "$NS" -o json | images_of > "$SNAP/images-after.txt" || die "cannot read live images"
changed="$(diff "$SNAP/images-before.txt" "$SNAP/images-after.txt" | grep -E '^>' | sed 's/^> //' || true)"
[[ "$changed" == "CronJob/$WORKER $WORKER=$WORKER_IMAGE" ]] \
  || die "unexpected image change set after upgrade (see ${SNAP#$HERE/}/images-*.txt): ${changed:-none}"
echo "OK   only $WORKER changed image; every other workload image is unchanged"
echo; echo "UPGRADED: $RELEASE revision $TO_REVISION deployed. Next: bash tools/smoke-be293.sh, then tools/credential-status-be293.sh."
