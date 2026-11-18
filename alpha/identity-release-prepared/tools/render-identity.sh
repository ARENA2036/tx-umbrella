#!/usr/bin/env bash
# Offline render + gates for the own identity stack (never contacts a cluster: KUBECONFIG=/dev/null, throwaway Helm home).
#
#   bash tools/render-identity.sh            # offline mode: open <<PIN:…>> digests are rendered with a dummy digest and
#                                            # reported as NOTE (charts, values, gates I1-I11 all checked)
#   bash tools/render-identity.sh --release  # release mode: additionally every image must already be pinned
#
# Steps: chart sha256 vs identity-charts.lock.yaml; shellcheck-free syntax check of the tools and the seed script;
# helm lint (strict, except the two official tractusx charts whose own Chart.yaml version "v0.4.1" is not strict SemVer);
# helm template per release; Portal render with and without values-be293-portal.alpha-identity.yaml (patched Portal chart,
# be293-idp-switch post-renderer, as tools/switch-idp-be293.sh uses); tools/validate_identity.rb.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALPHA="$(cd "$HERE/.." && pwd)"
CHARTS="$ALPHA/identity-charts"
PORTAL="$ALPHA/portal-release-prepared"
PORTAL_CHART="$ALPHA/portal-chart-2.6.0-patched/portal-2.6.0.tgz"
PORTAL_CHART_SHA256="b16d0d951adfc98f2014daec80c799b04e59fec38e4c5454e99228212ed7f760"
MODE="offline"
case "${1:-}" in "") ;; --release) MODE="release" ;; *) echo "usage: render-identity.sh [--release]" >&2; exit 2 ;; esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/be293-identity-render.XXXXXX")"
trap '[[ "${KEEP_RENDER:-0}" == 1 ]] || rm -rf "$WORK"' EXIT
umask 077
export KUBECONFIG=/dev/null HELM_KUBECONTEXT=""
export HELM_CACHE_HOME="$WORK/helm/cache" HELM_CONFIG_HOME="$WORK/helm/config" HELM_DATA_HOME="$WORK/helm/data"
export HELM_PLUGINS="$PORTAL/helm-plugins"
mkdir -p "$WORK/renders"

# release -> chart package (sha256 checked against the lock file)
RELEASES=("identity-vault:vault-0.29.1.tgz" "identity-postgresql:postgresql-16.0.0.tgz"
          "issuerservice:tractusx-issuerservice-v0.4.1.tgz" "identityhub:tractusx-identityhub-v0.4.1.tgz"
          "bdrs:bdrs-server-0.6.0.tgz")

ruby -ryaml -e 'lock = YAML.safe_load(File.read(ARGV[0]))["charts"]
  bad = lock.reject { |c| f = File.join(ARGV[1], c["package"]); File.exist?(f) && `shasum -a 256 #{f}`.split.first == c["sha256"] }
  bad.each { |c| puts "FAIL chart #{c["package"]} missing or sha256 mismatch" }
  puts "OK   #{lock.size} chart packages match identity-charts.lock.yaml" if bad.empty?
  exit(bad.empty? ? 0 : 1)' "$HERE/identity-charts.lock.yaml" "$CHARTS"
[[ "$(shasum -a 256 "$PORTAL_CHART" | cut -d' ' -f1)" == "$PORTAL_CHART_SHA256" ]] || { echo "FAIL patched Portal chart sha256" >&2; exit 1; }

for t in "$HERE"/tools/*.sh; do bash -n "$t"; done
ruby -ryaml -e 'print YAML.load_stream(File.read(ARGV[0])).compact.find { |d| d["kind"] == "ConfigMap" }["data"]["seed.sh"]' \
  "$HERE/identity-seed-be293.alpha.yaml" > "$WORK/seed.sh"
sh -n "$WORK/seed.sh"
echo "OK   tool and seed script syntax"

for r in "${RELEASES[@]}"; do
  name="${r%%:*}"; chart="$CHARTS/${r#*:}"; values="$HERE/values-be293-$name.yaml"
  if [[ "$MODE" == "offline" ]]; then
    sed -E 's/<<PIN:[^>]+>>/sha256:0000000000000000000000000000000000000000000000000000000000000000/' "$values" > "$WORK/$name.values.yaml"
    grep -o '<<PIN:[^>]*>>' "$values" | sed "s/^/NOTE $name: digest pending /" || true
  else
    cp "$values" "$WORK/$name.values.yaml"
  fi
  strict="--strict"; [[ "$name" == issuerservice || "$name" == identityhub ]] && strict=""
  helm lint $strict "$chart" --namespace be293 -f "$WORK/$name.values.yaml" > "$WORK/$name.lint" 2>&1 \
    || { cat "$WORK/$name.lint" >&2; echo "FAIL helm lint $name" >&2; exit 1; }
  helm template "be293-$name" "$chart" --namespace be293 -f "$WORK/$name.values.yaml" > "$WORK/renders/$name.yaml"
  echo "OK   $name: helm lint ${strict:-(non-strict: upstream chart version v0.4.1)} and helm template"
done

PV=(-f "$PORTAL/values-be293-portal.yaml" -f "$PORTAL/values-be293-portal.alpha-release.yaml"
    -f "$PORTAL/values-be293-portal.alpha-retention.yaml" -f "$PORTAL/values-be293-portal.alpha-smtp4dev.yaml")
helm template be293-portal "$PORTAL_CHART" --namespace be293 "${PV[@]}" --post-renderer be293-idp-switch > "$WORK/portal-before.yaml"
helm template be293-portal "$PORTAL_CHART" --namespace be293 "${PV[@]}" -f "$PORTAL/values-be293-portal.alpha-identity.yaml" \
  --post-renderer be293-idp-switch > "$WORK/portal-after.yaml"
echo "OK   Portal rendered with four and with five values files (identity overlay not applied anywhere)"

ruby "$HERE/tools/validate_identity.rb" --renders "$WORK/renders" --mode "$MODE" \
  --networkpolicies "$HERE/networkpolicies-be293-identity.alpha.yaml" \
  --seed "$HERE/identity-seed-be293.alpha.yaml" --seed-job "$HERE/identity-seed-job-be293.alpha.yaml" \
  --portal-before "$WORK/portal-before.yaml" --portal-after "$WORK/portal-after.yaml"
