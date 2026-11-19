# BE-293 Alpha shell environment. Source it (bash or zsh), from anywhere:
#
#   source <checkout>/alpha/env.sh
#
# It is the only setup the READMEs under alpha/ assume. Every path is derived from this file's own location, so the same
# file works in any checkout on any machine. Nothing here contacts a cluster.
#
#   ROOT          the repo checkout (…/tx-umbrella)
#   WORKSPACE     the folder above it (…/BE293_ALPHA)
#   UMB           the tx-umbrella checkout
#   ALPHA         this directory
#   REL           Portal release package           (alpha/portal)
#   IDENT         identity stack + EDC test package (alpha/identity)
#   CHARTS        vendored charts                  (alpha/charts)
#   HELM_PLUGINS  the Portal post-renderers         (alpha/portal/helm-plugins)
#   KUBECONFIG    ~/.kube/alpha.yaml; K() always adds --context alpha
#
# The package tools keep their own guards: they unset KUBECONFIG and pass the Alpha kubeconfig and context explicitly,
# and the offline render gates run with KUBECONFIG=/dev/null and their own HELM_PLUGINS.

if [ -n "${BASH_VERSION:-}" ]; then
  _be293_env_file="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  eval '_be293_env_file="${(%):-%x}"'
else
  echo "alpha/env.sh: source it from bash or zsh" >&2
  return 1 2>/dev/null || exit 1
fi

ALPHA="$(cd "$(dirname "$_be293_env_file")" && pwd)"
ROOT="$(cd "$ALPHA/.." && pwd)"
WORKSPACE="$(cd "$ROOT/.." && pwd)"
UMB="$ROOT/handoff/BE-293-umbrella-3.17.0/chart/umbrella"
REL="$ALPHA/portal"
IDENT="$ALPHA/identity"
CHARTS="$ALPHA/charts"
HELM_PLUGINS="$REL/helm-plugins"
KUBECONFIG="$HOME/.kube/alpha.yaml"
export ROOT WORKSPACE UMB ALPHA REL IDENT CHARTS HELM_PLUGINS KUBECONFIG
unset _be293_env_file

# kubectl against Alpha, always with the explicit kubeconfig and context.
K() { kubectl --kubeconfig "$KUBECONFIG" --context alpha "$@"; }
