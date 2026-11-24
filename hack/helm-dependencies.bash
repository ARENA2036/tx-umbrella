#!/bin/bash
set -euo pipefail

# Check if any repositories is present
if ! helm repo list ; then
  echo "Need to add repos"
  helm repo add tractusx https://eclipse-tractusx.github.io/charts/dev
  helm repo add hashicorp https://helm.releases.hashicorp.com
  helm repo add runix https://helm.runix.net
  helm repo add bitnami https://charts.bitnami.com/bitnami
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
  helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo add grafana https://grafana.github.io/helm-charts
  helm repo add cert-manager https://charts.jetstack.io
else
  echo "Checking and adding missing repositories..."
  
  # Check for each required repository and add if missing
  if ! helm repo list | grep -q "^tractusx[[:space:]]"; then
    echo "Adding tractusx repository..."
    helm repo add tractusx https://eclipse-tractusx.github.io/charts/dev
  fi

  if ! helm repo list | grep -q "^hashicorp[[:space:]]"; then
    echo "Adding hashicorp repository..."
    helm repo add hashicorp https://helm.releases.hashicorp.com
  fi

  if ! helm repo list | grep -q "^runix[[:space:]]"; then
    echo "Adding runix repository..."
    helm repo add runix https://helm.runix.net
  fi

  if ! helm repo list | grep -q "^bitnami[[:space:]]"; then
    echo "Adding bitnami repository..."
    helm repo add bitnami https://charts.bitnami.com/bitnami
  fi
  
  if ! helm repo list | grep -q "^open-telemetry[[:space:]]"; then
    echo "Adding open-telemetry repository..."
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
  fi
  
  if ! helm repo list | grep -q "^jaegertracing[[:space:]]"; then
    echo "Adding jaegertracing repository..."
    helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
  fi
  
  if ! helm repo list | grep -q "^prometheus-community[[:space:]]"; then
    echo "Adding prometheus-community repository..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  fi
  
  if ! helm repo list | grep -q "^grafana[[:space:]]"; then
    echo "Adding grafana repository..."
    helm repo add grafana https://grafana.github.io/helm-charts
  fi
  
  if ! helm repo list | grep -q "^cert-manager[[:space:]]"; then
    echo "Adding cert-manager repository..."
    helm repo add cert-manager https://charts.jetstack.io
  fi
fi

CHARTS_DIR="./charts"
TX_DATA_PROVIDER_DIR="$CHARTS_DIR/tx-data-provider"
UMBRELLA_DIR="$CHARTS_DIR/umbrella"
ALPHA_DIR="$CHARTS_DIR/alpha"
PATCHES_DIR="./hack/patches"

# Apply a local patch to a pinned, downloaded chart package and repackage it in place.
# Version-specific and fail-closed: a different chart, version or changed upstream template stops the script.
# An already patched package is left unchanged.
patch_package() {
  local package="$1" chart="$2" version="$3" patch_file="$4" chart_yaml tmp
  [[ -f "$package" ]] || { echo "Missing $package" >&2; exit 1; }
  [[ -f "$patch_file" ]] || { echo "Missing $patch_file" >&2; exit 1; }
  chart_yaml="$(tar xOf "$package" "$chart/Chart.yaml" 2>/dev/null)" || {
    echo "Could not read $chart chart metadata from $package" >&2
    exit 1
  }
  grep -q "^name: $chart\$" <<<"$chart_yaml" || { echo "Unexpected chart in $package" >&2; exit 1; }
  grep -q "^version: $version\$" <<<"$chart_yaml" || {
    echo "$(basename "$patch_file") requires $chart $version" >&2
    exit 1
  }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/chart-patch.XXXXXX")"
  if ! tar xzf "$package" -C "$tmp"; then
    rm -rf "$tmp"
    echo "Could not extract $package" >&2
    exit 1
  fi
  if patch -F 0 --dry-run --batch --forward -p1 -d "$tmp/$chart" < "$patch_file" >/dev/null 2>&1; then
    if ! patch -F 0 --batch --forward -p1 -d "$tmp/$chart" < "$patch_file" >/dev/null \
      || ! find "$tmp/$chart" -exec touch -t 200001010000 {} + \
      || ! helm package "$tmp/$chart" -d "$(dirname "$package")" >/dev/null; then
      rm -rf "$tmp"
      echo "Could not apply $(basename "$patch_file") to $package" >&2
      exit 1
    fi
    echo "   applied $(basename "$patch_file") to $(basename "$package")"
  elif ! patch -F 0 --dry-run --batch --reverse -p1 -d "$tmp/$chart" < "$patch_file" >/dev/null 2>&1; then
    rm -rf "$tmp"
    echo "$(basename "$patch_file") does not apply to $package; refusing to continue." >&2
    exit 1
  fi
  rm -rf "$tmp"
}

echo "🔄 Updating Helm repositories..."
helm repo update

echo "🔍 Updating dependencies for Helm charts under '$CHARTS_DIR'..."

# Update dependencies for all charts except tx-data-provider, umbrella and alpha
for chartdir in "$CHARTS_DIR"/*; do
  if [[ -d "$chartdir" && -f "$chartdir/Chart.yaml" && "$chartdir" != "$TX_DATA_PROVIDER_DIR" && "$chartdir" != "$UMBRELLA_DIR" && "$chartdir" != "$ALPHA_DIR" ]]; then
    echo -e "\n📦 Updating dependencies for chart: $chartdir"
    helm dependency update "$chartdir" --skip-refresh
  fi
done

patch_package "$CHARTS_DIR/dataspace-connector-bundle/charts/tractusx-connector-0.13.0.tgz" \
  tractusx-connector 0.13.0 "$PATCHES_DIR/tractusx-connector-0.13.0-secret-refs.patch"
patch_package "$CHARTS_DIR/identity-and-trust-bundle/charts/ssi-dim-wallet-stub-0.1.14.tgz" \
  ssi-dim-wallet-stub 0.1.14 "$PATCHES_DIR/ssi-dim-wallet-stub-0.1.14-ingress-annotations.patch"

# Update tx-data-provider and umbrella at the end
echo -e "\n📦 Updating dependencies for chart: $TX_DATA_PROVIDER_DIR"
helm dependency update "$TX_DATA_PROVIDER_DIR" --skip-refresh

echo -e "\n📦 Updating dependencies for chart: $UMBRELLA_DIR"
helm dependency update "$UMBRELLA_DIR" --skip-refresh

patch_package "$UMBRELLA_DIR/charts/portal-2.6.0.tgz" \
  portal 2.6.0 "$PATCHES_DIR/portal-2.6.0-identityhub-secret-refs.patch"

# The alpha chart vendors portal and bdrs-server in charts/ (no repository); helm keeps them.
echo -e "\n📦 Updating dependencies for chart: $ALPHA_DIR"
helm dependency update "$ALPHA_DIR" --skip-refresh
patch_package "$ALPHA_DIR/charts/tractusx-connector-0.13.0.tgz" \
  tractusx-connector 0.13.0 "$PATCHES_DIR/tractusx-connector-0.13.0-secret-refs.patch"
  
patch_package "$ALPHA_DIR/charts/centralidp-4.2.1.tgz" \
  centralidp 4.2.1 "$PATCHES_DIR/idp-4.2.1-postgresql-selector.patch"

patch_package "$ALPHA_DIR/charts/sharedidp-4.2.1.tgz" \
  sharedidp 4.2.1 "$PATCHES_DIR/idp-4.2.1-postgresql-selector.patch"
echo -e "\n✅ All charts up to date!"
