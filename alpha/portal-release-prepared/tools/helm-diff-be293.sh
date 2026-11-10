#!/usr/bin/env bash
# READ-ONLY Helm diff of the be293-portal release against LIVE Alpha. Works in any release state; never upgrades.
#
#   bash tools/helm-diff-be293.sh
#
#   0. target, chart checksum, post-renderer
#   1. offline release gates (tools/render-release.sh)
#   2. release history and the image every backend workload runs NOW (live)
#   3. `helm upgrade --dry-run=server --no-hooks` with exactly the values/post-renderer the install/recover scripts
#      use, compared in memory with the live objects (tools/compare_release_live.rb): per-container image, env
#      (names; values only for plain env), replicas, CronJob schedule/suspend, Secret keys (hashes in memory,
#      never printed), ConfigMaps, Services, Ingresses, objects an upgrade would create
#   4. the separately managed DID resolver: ownership + kubectl diff (tools/did-resolver-be293.sh --diff)
#
# kubectl verbs used: get, diff (server-side dry run). helm verbs: history, upgrade --dry-run=server.
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

unset KUBECONFIG
umask 077
export HELM_PLUGINS="$HERE/helm-plugins"
die() { echo "ABORT: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
k() {
  case "$1" in get|diff) ;; *) die "refused: kubectl $1" ;; esac
  kubectl --kubeconfig "$KC" --context "$CTX" -n "$NS" --request-timeout=30s "$@"
}
h() {
  case "$1" in
    history) ;;
    upgrade) [[ " $* " == *" --dry-run=server "* && " $* " == *" --no-hooks "* ]] || die "refused: helm upgrade without --dry-run=server --no-hooks" ;;
    *) die "refused: helm $1" ;;
  esac
  helm --kubeconfig "$KC" --kube-context "$CTX" "$@"
}
LOG="$(mktemp "${TMPDIR:-/tmp}/be293-helm-diff.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

step "0 target and tooling"
[[ -r "$KC" ]] || die "$KC not readable"
kubectl --kubeconfig "$KC" config get-contexts -o name | grep -qx "$CTX" || die "context $CTX not in $KC"
[[ "$(shasum -a 256 "$CHART" | cut -d' ' -f1)" == "$CHART_SHA256" ]] || die "chart checksum mismatch"
helm plugin list | grep -q "^${POST_RENDERER}[[:space:]].*postrenderer/v1" || die "post-renderer $POST_RENDERER missing in $HELM_PLUGINS"
echo "OK   $CTX/$NS, chart sha256 ok, post-renderer present"

step "1 offline release gates"
KUBECONFIG=/dev/null bash "$HERE/tools/render-release.sh" > "$LOG" 2>&1 || { grep -E '^FAIL' "$LOG" | head -10 >&2; die "offline gates failed"; }
grep -E 'RESULT|PACKAGE' "$LOG" | sed 's/^/  /'

step "2 release state and live backend images"
h history "$RELEASE" -n "$NS" -o json | ruby -rjson -e 'JSON.parse($stdin.read).each { |r| puts "  rev #{r["revision"]} #{r["status"]} #{r["updated"]} #{r["description"]}" }'
for w in deployment/$RELEASE-administration-service deployment/$RELEASE-registration-service deployment/$RELEASE-marketplace-app-service \
         deployment/$RELEASE-services-service deployment/$RELEASE-notification-service cronjob/$RELEASE-portal-maintenance \
         cronjob/$RELEASE-processes-worker deployment/$RELEASE-portal; do
  img="$(k get "$w" --ignore-not-found -o jsonpath='{.spec.template.spec.containers[*].image}{.spec.jobTemplate.spec.template.spec.containers[*].image}')"
  echo "  $w: ${img:-<absent>}"
done

step "3 server-side dry run vs live (in memory; values never printed)"
rc=0
h upgrade "$RELEASE" "$CHART" --namespace "$NS" "${VALUES_ARGS[@]}" --post-renderer "$POST_RENDERER" --no-hooks --dry-run=server -o json 2>"$LOG" \
  | ruby "$HERE/tools/compare_release_live.rb" --kubeconfig "$KC" --context "$CTX" --expected "$HERE/expected-drift.alpha.yaml" || rc=$?
[[ "$rc" == 0 ]] || { head -3 "$LOG" >&2; echo "STOP: dry run failed, a release check failed, or a Secret key would change (rc=$rc)"; }

step "4 DID resolver (separately managed)"
ALPHA_KUBECONFIG="$KC" bash "$HERE/tools/did-resolver-be293.sh" --diff || rc=1

echo
[[ "$rc" == 0 ]] && echo "READ-ONLY DIFF COMPLETE: nothing changed. Review every DRIFT line before any approved upgrade." \
  || { echo "READ-ONLY DIFF COMPLETE WITH STOP CONDITIONS: nothing changed; do not upgrade."; exit 1; }
