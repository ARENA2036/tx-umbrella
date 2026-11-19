#!/usr/bin/env bash
# Guarded install of the be293-portal release on STACKIT Alpha (namespace be293 only).
#
#   bash tools/install-be293.sh             # DEFAULT: gates + read-only preflight + server-side dry run. Changes nothing.
#   bash tools/install-be293.sh --execute   # same gates, then a typed confirmation, then `helm install`
#
# Fail-closed sequence (any failure stops before the next step):
#   1. offline release gates (tools/render-release.sh): lint, release-mode render gates, Ingress gates,
#      retention gates D1-D8 with the be293-retention post-renderer
#   2. read-only Alpha preflight (tools/alpha-preflight.sh): 0 FAIL required (Secrets, no existing release,
#      no leftover PVC, no hook-named Jobs, issuer, ExternalDNS, hosts ...)
#   3. the release NetworkPolicies already exist in be293 (applied in a separate, approved step)
#   4. `helm install --dry-run=server` with all three values files and the post-renderer; the would-be release
#      manifest is verified IN MEMORY (maintenance CronJob suspended, keep on postgres/keycloak/interfaces);
#      it is never written to disk or printed, because server-side lookup puts real Secret data into it
#   5. --execute only: typed confirmation on /dev/tty, then `helm install` (never upgrade/replace)
#   6. --execute only: read-only verification of the STORED release manifest and the live objects
#
# Never used here: helm upgrade/uninstall/rollback, --replace, --take-ownership, --force-conflicts,
# --rollback-on-failure (uninstalls on failure), kubectl apply/create/delete/patch. A failed install is left
# in place for read-only diagnosis.
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
CONFIRM_PHRASE="install $RELEASE on $CTX/$NS"

MODE="dry-run"
case "${1:-}" in
  "") ;;
  --execute) MODE="execute" ;;
  *) echo "usage: install-be293.sh [--execute]" >&2; exit 2 ;;
esac

unset KUBECONFIG HELM_KUBECONTEXT
export HELM_PLUGINS="$HERE/helm-plugins"
umask 077

die() { echo "ABORT: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# Read-only kubectl; every call carries the Alpha kubeconfig and context explicitly.
k() {
  case "$1" in get) ;; *) die "refused: kubectl $1 is not read-only" ;; esac
  kubectl --kubeconfig "$KC" --context "$CTX" --request-timeout=20s "$@"
}
# Helm: only install (dry-run or the single confirmed real install), get manifest, plugin list.
h() {
  case "$1" in install|get|plugin) ;; *) die "refused: helm $1" ;; esac
  local a
  for a in "$@"; do
    case "$a" in
      --replace|--take-ownership|--force-conflicts|--rollback-on-failure|--atomic|--force) die "refused: helm flag $a" ;;
    esac
  done
  helm --kubeconfig "$KC" --kube-context "$CTX" "$@"
}

LOG="$(mktemp "${TMPDIR:-/tmp}/be293-install.XXXXXX")"
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
echo "OK   render, Ingress and retention gates (D1-D8) pass"

step "2 read-only Alpha preflight"
ALPHA_KUBECONFIG="$KC" bash "$HERE/tools/alpha-preflight.sh" || die "preflight reported FAIL"

step "3 release NetworkPolicies present in $NS"
for np in $(ruby -ryaml -e 'YAML.load_stream(File.read(ARGV[0])).compact.each { |d| puts d["metadata"]["name"] }' "$HERE/networkpolicies-be293-portal.alpha-release.yaml"); do
  out="$(k get networkpolicy "$np" -n "$NS" --ignore-not-found -o name)" || die "cannot read NetworkPolicy $np"
  [[ -n "$out" ]] || die "NetworkPolicy $np missing: apply networkpolicies-be293-portal.alpha-release.yaml first (separate approved step)"
done
echo "OK   all release NetworkPolicies exist"

INSTALL_ARGS=(install "$RELEASE" "$CHART" --namespace "$NS" "${VALUES_ARGS[@]}" --post-renderer "$POST_RENDERER")

step "4 server-side dry run (nothing persisted; manifest verified in memory)"
h "${INSTALL_ARGS[@]}" --dry-run=server -o json 2>"$LOG" | ruby "$HERE/tools/verify_release_retention.rb" --json \
  || { head -3 "$LOG" >&2; die "server-side dry run or retention check failed"; }

if [[ "$MODE" != "execute" ]]; then
  echo; echo "DRY RUN COMPLETE: all gates passed, nothing was installed. Re-run with --execute after approval."
  exit 0
fi

step "5 confirmation"
# Only an interactive terminal can confirm: stdin, pipes and env vars are never accepted.
{ exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation; nothing installed"
printf 'Type exactly "%s" to install: ' "$CONFIRM_PHRASE" >&3
answer=""
read -r answer <&3 || true
exec 3>&-
[[ "$answer" == "$CONFIRM_PHRASE" ]] || die "confirmation did not match; nothing installed"

step "6 helm install (no upgrade, no replace, no rollback-on-failure)"
h "${INSTALL_ARGS[@]}" --wait --wait-for-jobs --timeout 20m -o json > /dev/null \
  || die "helm install failed: release left in place for read-only diagnosis (see README-ALPHA-RELEASE.md)"

step "7 read-only verification of the stored release and live objects"
fails=0
{ h get manifest "$RELEASE" -n "$NS"; echo "---"; h get hooks "$RELEASE" -n "$NS"; } 2>"$LOG" \
  | ruby "$HERE/tools/verify_release_retention.rb" --yaml || fails=$((fails + 1))
[[ "$(k get cronjob "$RELEASE-portal-maintenance" -n "$NS" -o jsonpath='{.spec.suspend}')" == "true" ]] \
  && echo "OK   live CronJob $RELEASE-portal-maintenance suspended" || { echo "FAIL live maintenance CronJob not suspended"; fails=$((fails + 1)); }
for s in postgres keycloak interfaces; do
  v="$(k get secret "$RELEASE-$s" -n "$NS" -o jsonpath='{.metadata.annotations.helm\.sh/resource-policy}')"
  [[ "$v" == "keep" ]] && echo "OK   live Secret $RELEASE-$s keep" || { echo "FAIL live Secret $RELEASE-$s resource-policy=${v:-<none>}"; fails=$((fails + 1)); }
done
phase="$(k get pvc "data-$RELEASE-postgresql-0" -n "$NS" -o jsonpath='{.status.phase}')"
[[ "$phase" == "Bound" ]] && echo "OK   PVC data-$RELEASE-postgresql-0 Bound" || { echo "FAIL PVC phase ${phase:-<none>}"; fails=$((fails + 1)); }
k get jobs -n "$NS" -o custom-columns=NAME:.metadata.name,SUCCEEDED:.status.succeeded,FAILED:.status.failed
[[ "$fails" -eq 0 ]] || die "$fails post-install check(s) failed; nothing is changed automatically"
echo; echo "INSTALLED and verified. Next: back up be293-portal-postgres/-keycloak/-interfaces to the vault (README)."
