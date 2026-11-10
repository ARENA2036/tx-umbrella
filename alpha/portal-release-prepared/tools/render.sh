#!/usr/bin/env bash
# Offline lint + render + validation of the BE-293 Portal package. Never contacts a cluster:
# KUBECONFIG points at /dev/null, Helm state lives in a throwaway directory, no --validate,
# no dependency build. The render is written mode 0600 to a temp dir and removed on exit
# unless KEEP_RENDER=1.
#
# Usage: alpha/portal/tools/render.sh [offline|release]
set -euo pipefail

MODE="${1:-offline}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CHART="${PORTAL_CHART:-$REPO/handoff/BE-293-umbrella-3.17.0/chart/umbrella/charts/portal-2.6.0.tgz}"
# Matches handoff/BE-293-umbrella-3.17.0/ARTIFACT-MANIFEST.md.
EXPECTED_CHART_SHA256="${PORTAL_CHART_SHA256:-a17ab65070eeea3e719e2187213db23fc9226f6a8b2fc94ed771ec6835ad1e09}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/be293-portal-render.XXXXXX")"
cleanup() { [[ "${KEEP_RENDER:-0}" == "1" ]] || rm -rf "$WORK"; }
trap cleanup EXIT
umask 077

export KUBECONFIG=/dev/null HELM_KUBECONTEXT=""
export HELM_CACHE_HOME="$WORK/helm/cache" HELM_CONFIG_HOME="$WORK/helm/config" HELM_DATA_HOME="$WORK/helm/data"

actual_sha="$(shasum -a 256 "$CHART" | cut -d' ' -f1)"
if [[ "$actual_sha" != "$EXPECTED_CHART_SHA256" ]]; then
  echo "chart checksum mismatch: $actual_sha" >&2
  exit 2
fi
echo "chart $(basename "$CHART") sha256 $actual_sha"

ruby "$HERE/tools/check_package.rb" "$HERE"
helm lint --strict "$CHART" --namespace be293 -f "$HERE/values-be293-portal.yaml"
helm template be293-portal "$CHART" --namespace be293 \
  -f "$HERE/values-be293-portal.yaml" > "$WORK/render.yaml"

ruby "$HERE/tools/validate_render.rb" --mode "$MODE" \
  --render "$WORK/render.yaml" \
  --networkpolicies "$HERE/networkpolicies-be293-portal.yaml" \
  --values "$HERE/values-be293-portal.yaml" \
  --images-lock "$HERE/images.lock.yaml" \
  --service-map "$HERE/alpha-service-map.yaml" \
  --secrets-contract "$HERE/secrets-contract.yaml" \
  --expected-inventory "$HERE/expected-inventory.txt"
