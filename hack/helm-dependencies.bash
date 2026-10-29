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
CONNECTOR_PATCH="./hack/patches/tractusx-connector-0.13.0-secret-refs.patch"

# Apply the local SecretRef extension only to the pinned Connector 0.13.0 package.
# This is intentionally version-specific: a package mismatch or changed upstream template fails closed.
patch_connector_package() {
  local package="$1" tmp
  [[ -f "$package" ]] || { echo "Missing $package" >&2; exit 1; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/connector-013-patch.XXXXXX")"
  if ! tar xzf "$package" -C "$tmp"; then
    rm -rf "$tmp"
    echo "Could not extract Connector package" >&2
    exit 1
  fi
  if patch -F 0 --dry-run --batch --forward -p1 -d "$tmp/tractusx-connector" < "$CONNECTOR_PATCH" >/dev/null 2>&1; then
    if ! patch -F 0 --batch --forward -p1 -d "$tmp/tractusx-connector" < "$CONNECTOR_PATCH" >/dev/null; then
      rm -rf "$tmp"
      echo "Could not apply Connector Secret-reference patch" >&2
      exit 1
    fi
    if ! find "$tmp/tractusx-connector" -exec touch -t 200001010000 {} +; then
      rm -rf "$tmp"
      echo "Could not normalize patched chart timestamps" >&2
      exit 1
    fi
    if ! helm package "$tmp/tractusx-connector" -d "$(dirname "$package")" >/dev/null; then
      rm -rf "$tmp"
      echo "Could not package patched Connector chart" >&2
      exit 1
    fi
    echo "   applied $(basename "$CONNECTOR_PATCH") to $(basename "$package")"
  elif ! patch -F 0 --dry-run --batch --reverse -p1 -d "$tmp/tractusx-connector" < "$CONNECTOR_PATCH" >/dev/null 2>&1; then
    rm -rf "$tmp"
    echo "Connector Secret-reference patch does not apply to $package; refusing to continue." >&2
    exit 1
  fi
  rm -rf "$tmp"
}

echo "🔄 Updating Helm repositories..."
helm repo update

echo "🔍 Updating dependencies for Helm charts under '$CHARTS_DIR'..."

# Update dependencies for all charts except tx-data-provider and umbrella
for chartdir in "$CHARTS_DIR"/*; do
  if [[ -d "$chartdir" && -f "$chartdir/Chart.yaml" && "$chartdir" != "$TX_DATA_PROVIDER_DIR" && "$chartdir" != "$UMBRELLA_DIR" ]]; then
    echo -e "\n📦 Updating dependencies for chart: $chartdir"
    helm dependency update "$chartdir" --skip-refresh
  fi
done

patch_connector_package "$CHARTS_DIR/dataspace-connector-bundle/charts/tractusx-connector-0.13.0.tgz"

# Update tx-data-provider and umbrella at the end
echo -e "\n📦 Updating dependencies for chart: $TX_DATA_PROVIDER_DIR"
helm dependency update "$TX_DATA_PROVIDER_DIR" --skip-refresh

echo -e "\n📦 Updating dependencies for chart: $UMBRELLA_DIR"
helm dependency update "$UMBRELLA_DIR" --skip-refresh

echo -e "\n✅ All charts up to date!"
