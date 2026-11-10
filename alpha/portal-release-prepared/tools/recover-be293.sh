#!/usr/bin/env bash
# Guarded recovery of the be293-portal release from status `failed` (revision 1, install timeout) to
# `deployed`, WITHOUT reinstalling and WITHOUT re-running the migration hooks.
#
#   bash tools/recover-be293.sh             # DEFAULT: gates + read-only live checks + server-side dry run
#                                           # + rendered-vs-live comparison. Changes nothing.
#   bash tools/recover-be293.sh --execute   # same, then a typed confirmation, then ONE `helm upgrade --no-hooks`
#
# Why `helm upgrade --no-hooks`:
#   - Helm upgrades a release whose only revision failed by taking that revision as the base; it is the
#     supported path. Never: uninstall/reinstall, rollback, or editing the sh.helm.release.v1 Secret.
#   - Both migrations already completed through the manual Jobs be293-portal-manual-*-migrations. With
#     --no-hooks, Helm creates no hook Job and deletes none (before-hook-creation is never triggered); the
#     hooks stay recorded in the release and run again on the next normal upgrade, where they are idempotent
#     (EF migrations already applied; BatchUpdateSeeder re-applies only the reviewed, hash-pinned rows, D7).
#   - Secrets: keycloak/interfaces/postgres are rendered from Helm `lookup` (existing data reused). Step 4
#     proves in memory that no Secret key would change; any change aborts (no key rotation, no reset).
#   - Drift: step 4 also requires every drifted field to be listed in expected-drift.alpha.yaml (reviewed); any
#     other drift aborts before the confirmation. --execute snapshots the live objects (no Secrets) to .evidence/
#     before upgrading, because no earlier successful revision exists to roll back to.
#   - Server-side apply (Helm 4 default) without --force-conflicts: if a field that kubectl manages would get
#     a different value, the upgrade fails instead of overwriting it. The manual hotfixes (ArenaAdminRoles env,
#     custodian sentinel) are rendered with identical values, so they become co-owned, not replaced.
#
# Never used: uninstall, rollback, install, --install, --force, --replace, --reset-values, --reuse-values,
# --take-ownership, --force-conflicts, --rollback-on-failure, --atomic, --cleanup-on-fail (deletes on failure).
# A failed upgrade leaves revision 2 `failed` and every object in place for read-only diagnosis.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
KC="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CTX="alpha"
NS="be293"
RELEASE="be293-portal"
CHART="$REPO/handoff/BE-293-umbrella-3.17.0/chart/umbrella/charts/portal-2.6.0.tgz"
CHART_SHA256="a17ab65070eeea3e719e2187213db23fc9226f6a8b2fc94ed771ec6835ad1e09"
POST_RENDERER="be293-retention"
VALUES_ARGS=(-f "$HERE/values-be293-portal.yaml" -f "$HERE/values-be293-portal.alpha-release.yaml"
             -f "$HERE/values-be293-portal.alpha-retention.yaml" -f "$HERE/values-be293-portal.alpha-smtp4dev.yaml")
CONFIRM_PHRASE="upgrade $RELEASE on $CTX/$NS without hooks"
MANUAL_JOBS=("$RELEASE-manual-portal-migrations" "$RELEASE-manual-provisioning-migrations")

MODE="dry-run"
case "${1:-}" in
  "") ;;
  --execute) MODE="execute" ;;
  *) echo "usage: recover-be293.sh [--execute]" >&2; exit 2 ;;
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

LOG="$(mktemp "${TMPDIR:-/tmp}/be293-recover.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

step "0 target and tooling"
[[ -r "$KC" ]] || die "$KC not readable"
kubectl --kubeconfig "$KC" config get-contexts -o name | grep -qx "$CTX" || die "context $CTX not in $KC"
[[ "$(shasum -a 256 "$CHART" | cut -d' ' -f1)" == "$CHART_SHA256" ]] || die "chart checksum mismatch"
helm plugin list | grep -q "^${POST_RENDERER}[[:space:]].*postrenderer/v1" || die "post-renderer $POST_RENDERER missing in $HELM_PLUGINS"
echo "OK   kubeconfig $KC, context $CTX, namespace $NS, chart sha256 ok, post-renderer present (mode: $MODE)"

step "1 offline release gates (KUBECONFIG=/dev/null)"
KUBECONFIG=/dev/null bash "$HERE/tools/render-release.sh" > "$LOG" 2>&1 \
  || { tail -15 "$LOG" >&2; die "offline release gates failed"; }
echo "OK   render, Ingress, retention (D1-D8) and ArenaAdminRoles (D9) gates pass"

step "2 release state: exactly one revision, status failed"
hist="$(h history "$RELEASE" -n "$NS" -o json)" || die "cannot read release history"
state="$(ruby -rjson -e 'r = JSON.parse(ARGV[0]); puts "#{r.size} #{r.map { |x| x["status"] }.join(",")}"' "$hist" 2>/dev/null)" \
  || die "release history unreadable"
[[ "$state" == "1 failed" ]] || die "release history is '$state', expected '1 failed': not the recovery case, nothing changed"
echo "OK   $RELEASE: 1 revision, failed"

step "3 read-only live checks"
fails=0
for j in "${MANUAL_JOBS[@]}"; do
  s="$(k get job "$j" -n "$NS" --ignore-not-found -o jsonpath='{.status.succeeded}')"
  [[ "$s" == "1" ]] && echo "OK   Job $j succeeded" || { echo "FAIL Job $j not succeeded (${s:-absent}): migrations unproven"; fails=$((fails + 1)); }
done
for j in "$RELEASE-portal-migrations" "$RELEASE-provisioning-migrations"; do
  [[ -z "$(k get job "$j" -n "$NS" --ignore-not-found -o name)" ]] && echo "OK   no hook Job $j (nothing for a later hook run to replace)" \
    || echo "WARN hook Job $j exists: --no-hooks leaves it alone; a later normal upgrade would delete and re-create it (before-hook-creation)"
done
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
# The release values (alpha-smtp4dev overlay) point Portal mail at the test sink; it must exist first.
[[ -n "$(k get service be293-smtp4dev -n "$NS" --ignore-not-found -o name)" ]] && echo "OK   test mail sink Service be293-smtp4dev exists" \
  || { echo "FAIL Service be293-smtp4dev missing: deploy it first (tools/smtp4dev-be293.sh)"; fails=$((fails + 1)); }
dns="$(k get networkpolicy -n "$NS" -o json | ruby -rjson -e '
  ok = JSON.parse($stdin.read)["items"].any? { |p| (p.dig("spec","egress") || []).any? { |r| (r["ports"] || []).any? { |x| x["port"].to_s == "8053" } } }
  puts(ok ? "yes" : "no")')"
[[ "$dns" == "yes" ]] && echo "OK   a be293 NetworkPolicy allows egress to DNS target port 8053" \
  || { echo "FAIL no be293 NetworkPolicy allows port 8053: cluster DNS would be blocked"; fails=$((fails + 1)); }
[[ "$fails" -eq 0 ]] || die "$fails live check(s) failed"

UPGRADE_ARGS=(upgrade "$RELEASE" "$CHART" --namespace "$NS" "${VALUES_ARGS[@]}" --post-renderer "$POST_RENDERER" --no-hooks)

step "4 server-side dry run: release checks + rendered-vs-live comparison (in memory)"
# --expected: every DRIFT item must be one of the reviewed items in expected-drift.alpha.yaml; anything else (and
# any FAIL) stops here, before the confirmation, so --execute can never upgrade over unreviewed drift.
h "${UPGRADE_ARGS[@]}" --dry-run=server -o json 2>"$LOG" \
  | ruby "$HERE/tools/compare_release_live.rb" --kubeconfig "$KC" --context "$CTX" --expected "$HERE/expected-drift.alpha.yaml" \
  || { head -3 "$LOG" >&2; die "dry run failed, a release check failed, a Secret key would change, or unreviewed drift: nothing upgraded"; }

if [[ "$MODE" != "execute" ]]; then
  echo; echo "DRY RUN COMPLETE: nothing changed. Review DRIFT lines above, then re-run with --execute after approval."
  exit 0
fi

step "5 confirmation"
{ exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation; nothing upgraded"
printf 'Type exactly "%s" to upgrade: ' "$CONFIRM_PHRASE" >&3
answer=""
read -r answer <&3 || true
exec 3>&-
[[ "$answer" == "$CONFIRM_PHRASE" ]] || die "confirmation did not match; nothing upgraded"

step "6 pre-upgrade snapshot (read-only; there is no earlier successful revision to roll back to)"
# Workload, Service, Ingress and ConfigMap specs plus ReplicaSet revisions: the reference for `kubectl rollout undo`
# or a manual restore. Secrets are deliberately not captured.
SNAP="$HERE/.evidence/pre-revision-2-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$SNAP"
k get deployment,statefulset,cronjob,service,ingress,configmap -n "$NS" -o yaml > "$SNAP/objects.yaml" \
  || die "snapshot failed: nothing upgraded"
k get replicaset -n "$NS" -o custom-columns='NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name,REVISION:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,READY:.status.readyReplicas' \
  > "$SNAP/replicasets.txt" || die "snapshot failed: nothing upgraded"
h history "$RELEASE" -n "$NS" -o json > "$SNAP/helm-history.json" || die "snapshot failed: nothing upgraded"
echo "OK   snapshot in ${SNAP#$HERE/} (keep out of Git)"

step "7 helm upgrade --no-hooks (server-side apply, no forced conflicts, no rollback/cleanup on failure)"
h "${UPGRADE_ARGS[@]}" --wait --timeout 15m -o json > /dev/null \
  || die "helm upgrade failed: revision 2 left in place for read-only diagnosis; nothing deleted (snapshot: ${SNAP#$HERE/})"

step "8 read-only verification"
st="$(h status "$RELEASE" -n "$NS" -o json | ruby -rjson -e 'r = JSON.parse($stdin.read); puts "#{r["version"]} #{r.dig("info","status")}"')"
[[ "$st" == "2 deployed" ]] && echo "OK   $RELEASE revision 2 deployed" || die "release state '$st', expected '2 deployed'"
{ h get manifest "$RELEASE" -n "$NS"; echo "---"; h get hooks "$RELEASE" -n "$NS"; } 2>"$LOG" \
  | ruby "$HERE/tools/verify_release_retention.rb" --yaml || die "stored release manifest check failed"
[[ "$(k get cronjob "$RELEASE-portal-maintenance" -n "$NS" -o jsonpath='{.spec.suspend}')" == "true" ]] \
  || die "live maintenance CronJob not suspended"
k get deploy -n "$NS" -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,WANTED:.spec.replicas
echo; echo "RECOVERED: $RELEASE is deployed. Next upgrades run the migration hooks normally (idempotent)."
