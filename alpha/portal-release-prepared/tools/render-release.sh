#!/usr/bin/env bash
# Offline ALPHA RELEASE render + gates: base values + values-be293-portal.alpha-release.yaml +
# values-be293-portal.alpha-retention.yaml + values-be293-portal.alpha-smtp4dev.yaml, post-rendered by the release-local Helm plugin be293-retention,
# release-mode placeholder gate, approved Ingresses, release NetworkPolicies, inventory and the
# zero-automatic-data-deletion gate. Same isolation as tools/render.sh: never contacts a cluster
# (KUBECONFIG=/dev/null, throwaway Helm home, no --validate), renders written mode 0600 to a temp dir and
# removed on exit unless KEEP_RENDER=1.
#
# Usage: tools/render-release.sh   (RENDER_OUT=FILE also writes the gated render to FILE)
# Exit 0 only if lint, render, every validate_render.rb gate (release mode), every Ingress gate and every
# retention gate (D1-D10), every smtp4dev gate (S1-S9: test mail sink manifest + Portal mail target) and every
# did:web resolver gate (DR1-DR10: resolver manifest + Portal resolver target) pass.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CHART="${PORTAL_CHART:-$REPO/handoff/BE-293-umbrella-3.17.0/chart/umbrella/charts/portal-2.6.0.tgz}"
# Matches handoff/BE-293-umbrella-3.17.0/ARTIFACT-MANIFEST.md.
EXPECTED_CHART_SHA256="${PORTAL_CHART_SHA256:-a17ab65070eeea3e719e2187213db23fc9226f6a8b2fc94ed771ec6835ad1e09}"
BASE_VALUES="$HERE/values-be293-portal.yaml"
RELEASE_VALUES="$HERE/values-be293-portal.alpha-release.yaml"
RETENTION_VALUES="$HERE/values-be293-portal.alpha-retention.yaml"
MAIL_VALUES="$HERE/values-be293-portal.alpha-smtp4dev.yaml"
SMTP4DEV_MANIFEST="${SMTP4DEV_MANIFEST:-$HERE/smtp4dev-be293.alpha.yaml}"
DID_RESOLVER_MANIFEST="${DID_RESOLVER_MANIFEST:-$HERE/did-resolver-be293.alpha.yaml}"
POST_RENDERER="be293-retention"
VALUES_ARGS=(-f "$BASE_VALUES" -f "$RELEASE_VALUES" -f "$RETENTION_VALUES" -f "$MAIL_VALUES")

WORK="$(mktemp -d "${TMPDIR:-/tmp}/be293-portal-release.XXXXXX")"
cleanup() { [[ "${KEEP_RENDER:-0}" == "1" ]] || rm -rf "$WORK"; }
trap cleanup EXIT
umask 077

export KUBECONFIG=/dev/null HELM_KUBECONTEXT=""
export HELM_CACHE_HOME="$WORK/helm/cache" HELM_CONFIG_HOME="$WORK/helm/config" HELM_DATA_HOME="$WORK/helm/data"
# Release-local plugin directory: nothing is installed into the operator's Helm home.
export HELM_PLUGINS="$HERE/helm-plugins"

actual_sha="$(shasum -a 256 "$CHART" | cut -d' ' -f1)"
if [[ "$actual_sha" != "$EXPECTED_CHART_SHA256" ]]; then
  echo "chart checksum mismatch: $actual_sha" >&2
  exit 2
fi
echo "chart $(basename "$CHART") sha256 $actual_sha"

ruby "$HERE/tools/check_package.rb" "$HERE"
helm plugin list | grep -q "^${POST_RENDERER}[[:space:]].*postrenderer/v1" || { echo "post-renderer plugin $POST_RENDERER not found in $HELM_PLUGINS" >&2; exit 2; }
helm lint --strict "$CHART" --namespace be293 "${VALUES_ARGS[@]}"
# Plain render: baseline for the post-renderer diff (D8).
helm template be293-portal "$CHART" --namespace be293 "${VALUES_ARGS[@]}" > "$WORK/plain.yaml"
# Final render: exactly what `helm install --post-renderer be293-retention` applies and stores.
helm template be293-portal "$CHART" --namespace be293 "${VALUES_ARGS[@]}" \
  --post-renderer "$POST_RENDERER" > "$WORK/render.yaml"
# Deterministic D8 input: the post-renderer applied to the SAME plain render (offline renders regenerate
# chart-random Secret values on every run, so two Helm renders are not comparable field by field).
ruby "$HERE/helm-plugins/be293-retention/post-render.rb" < "$WORK/plain.yaml" > "$WORK/plain-post.yaml"

# Effective values (Helm semantics: maps deep-merge, lists and scalars replace) so the G7 credential gate
# covers the overlays as well.
ruby -ryaml -e '
  merge = ->(a, b) { a.is_a?(Hash) && b.is_a?(Hash) ? a.merge(b) { |_, x, y| merge.(x, y) } : b }
  out = ARGV.pop
  File.write(out, YAML.dump(ARGV.map { |f| YAML.safe_load(File.read(f)) }.reduce { |a, b| merge.(a, b) }))
' "$BASE_VALUES" "$RELEASE_VALUES" "$RETENTION_VALUES" "$MAIL_VALUES" "$WORK/values-effective.yaml"

ruby "$HERE/tools/validate_render.rb" --mode release --allow-ingress \
  --render "$WORK/render.yaml" \
  --networkpolicies "$HERE/networkpolicies-be293-portal.alpha-release.yaml" \
  --values "$WORK/values-effective.yaml" \
  --images-lock "$HERE/images.lock.yaml" \
  --service-map "$HERE/alpha-service-map.yaml" \
  --secrets-contract "$HERE/secrets-contract.yaml" \
  --expected-inventory "$HERE/expected-inventory.alpha-release.txt"

ruby "$HERE/tools/validate_ingress.rb" --render "$WORK/render.yaml"
ruby "$HERE/tools/validate_retention.rb" --render "$WORK/render.yaml"
ruby "$HERE/tools/validate_retention.rb" --render "$WORK/plain-post.yaml" --baseline "$WORK/plain.yaml" | sed 's/^RETENTION RESULT/RETENTION D8 RESULT/'
ruby "$HERE/tools/validate_smtp4dev.rb" --manifest "$SMTP4DEV_MANIFEST" --render "$WORK/render.yaml"
ruby "$HERE/tools/validate_did_resolver.rb" --manifest "$DID_RESOLVER_MANIFEST" --render "$WORK/render.yaml" \
  --networkpolicies "$HERE/networkpolicies-be293-portal.alpha-release.yaml"

# Optional: hand the fully gated render to a caller (e.g. as the single source of live env patch values). It holds
# only the offline render's own random Secret data (never live data); written mode 0600.
if [[ -n "${RENDER_OUT:-}" ]]; then install -m 0600 "$WORK/render.yaml" "$RENDER_OUT"; fi
