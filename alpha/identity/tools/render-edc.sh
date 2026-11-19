#!/usr/bin/env bash
# Offline render + gates for the two hand-deployed E2E test connectors (never contacts a cluster: KUBECONFIG=/dev/null,
# throwaway Helm home).
#
#   bash tools/render-edc.sh            # offline mode: open <<PIN:…>> digests rendered with a dummy digest, reported as NOTE
#   bash tools/render-edc.sh --release  # release mode: additionally every image must already be pinned
#
# Steps: chart sha256 vs charts.lock.yaml; tractusx-connector package re-derived from its recorded patch;
# helm lint --strict and helm template for be293-edc-postgresql, be293-edc-fv1, be293-edc-guc; tools/validate_edc.rb
# (gates E1-E8) over the renders, networkpolicies-be293-edc.alpha.yaml, edc-datasource-be293.alpha.yaml and
# edc-e2e-provider-objects.alpha.json.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHARTS="$(cd "$HERE/.." && pwd)/charts/identity"
CONNECTOR="$CHARTS/tractusx-connector-0.13.0.tgz"
PATCH="$CHARTS/patches/tractusx-connector-0.13.0-secret-refs.patch"
PATCH_SHA256="9a7c876fe52453d3a953a7d7d29a7b71e51bc78b7e45ba02dc76af507117f75d"
MODE="offline"
case "${1:-}" in "") ;; --release) MODE="release" ;; *) echo "usage: render-edc.sh [--release]" >&2; exit 2 ;; esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/be293-edc-render.XXXXXX")"
trap '[[ "${KEEP_RENDER:-0}" == 1 ]] || rm -rf "$WORK"' EXIT
umask 077
export KUBECONFIG=/dev/null HELM_KUBECONTEXT=""
export HELM_CACHE_HOME="$WORK/helm/cache" HELM_CONFIG_HOME="$WORK/helm/config" HELM_DATA_HOME="$WORK/helm/data"
mkdir -p "$WORK/renders"

ruby -ryaml -e 'lock = YAML.safe_load(File.read(ARGV[0]))["charts"].select { |c| %w[tractusx-connector-0.13.0.tgz postgresql-16.0.0.tgz].include?(c["package"]) }
  bad = lock.reject { |c| f = File.join(ARGV[1], c["package"]); File.exist?(f) && `shasum -a 256 #{f}`.split.first == c["sha256"] }
  bad.each { |c| puts "FAIL chart #{c["package"]} missing or sha256 mismatch" }
  exit 1 unless bad.empty? && lock.size == 2
  puts "OK   connector and PostgreSQL chart packages match charts.lock.yaml"' "$HERE/charts.lock.yaml" "$CHARTS"
[[ "$(shasum -a 256 "$PATCH" | cut -d' ' -f1)" == "$PATCH_SHA256" ]] || { echo "FAIL connector patch sha256" >&2; exit 1; }
# The package must be exactly "pristine + patch": reversing the patch must succeed and leave no _secret-env.tpl behind.
mkdir -p "$WORK/chart" && tar -xzf "$CONNECTOR" -C "$WORK/chart"
(cd "$WORK/chart/tractusx-connector" && patch -R -p1 -s --dry-run < "$PATCH") || { echo "FAIL connector package is not pristine + patch" >&2; exit 1; }
echo "OK   connector package = tractusx-connector 0.13.0 + secret-refs patch (reverse-applies cleanly)"

pinfree() { # FILE -> offline copy with a dummy digest for open placeholders
  if [[ "$MODE" == "offline" ]]; then
    grep -o '<<PIN:[^>]*>>' "$1" | sed "s|^|NOTE $(basename "$1"): digest pending |" || true
    sed -E 's/<<PIN:[^>]+>>/sha256:0000000000000000000000000000000000000000000000000000000000000000/' "$1" > "$2"
  else cp "$1" "$2"; fi
}
pinfree "$HERE/values-be293-edc-common.yaml" "$WORK/common.yaml"
pinfree "$HERE/edc-datasource-be293.alpha.yaml" "$WORK/datasource.yaml"

helm lint --strict "$CHARTS/postgresql-16.0.0.tgz" --namespace be293 -f "$HERE/values-be293-edc-postgresql.yaml" > "$WORK/pg.lint" 2>&1 \
  || { cat "$WORK/pg.lint" >&2; echo "FAIL helm lint edc-postgresql" >&2; exit 1; }
helm template be293-edc-postgresql "$CHARTS/postgresql-16.0.0.tgz" --namespace be293 \
  -f "$HERE/values-be293-edc-postgresql.yaml" > "$WORK/renders/edc-postgresql.yaml"
echo "OK   edc-postgresql: helm lint --strict and helm template"
for c in fv1 guc; do
  helm lint --strict "$CONNECTOR" --namespace be293 -f "$WORK/common.yaml" -f "$HERE/values-be293-edc-$c.yaml" > "$WORK/$c.lint" 2>&1 \
    || { cat "$WORK/$c.lint" >&2; echo "FAIL helm lint edc-$c" >&2; exit 1; }
  helm template "be293-edc-$c" "$CONNECTOR" --namespace be293 -f "$WORK/common.yaml" -f "$HERE/values-be293-edc-$c.yaml" \
    > "$WORK/renders/edc-$c.yaml"
  echo "OK   edc-$c: helm lint --strict and helm template"
done

ruby "$HERE/tools/validate_edc.rb" --renders "$WORK/renders" --mode "$MODE" \
  --networkpolicies "$HERE/networkpolicies-be293-edc.alpha.yaml" --datasource "$WORK/datasource.yaml" \
  --objects "$HERE/edc-e2e-provider-objects.alpha.json"
