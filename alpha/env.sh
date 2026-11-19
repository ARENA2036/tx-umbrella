# BE-293 Alpha shell environment. Source it (bash or zsh), from anywhere:
#
#   source <checkout>/alpha/env.sh        # in the tx-umbrella repository
#   source ~/alpha/env.sh                 # in the standalone export (alpha/tools/export-standalone.sh)
#
# It is the only setup the READMEs under alpha/ assume. Every path is derived from this file's own location, so the same
# file works in any checkout or export on any machine. Nothing here contacts a cluster.
#
# The same file serves both layouts; BE293_LAYOUT says which one was detected:
#   repo        (alpha/.. is the tx-umbrella checkout: it has .git and handoff/)
#     ROOT        the repo checkout (…/tx-umbrella)
#     WORKSPACE   the folder above it (…/BE293_ALPHA)
#     UMB         the Umbrella 3.17.0 chart in the repo (handoff/BE-293-umbrella-3.17.0/chart/umbrella)
#   standalone  (anything else, e.g. ~/alpha): no variable points outside this folder
#     ROOT        this folder
#     UMB         the Umbrella 3.17.0 Portal chart shipped with it ($CHARTS/umbrella-3.17.0)
# In both:
#   ALPHA         this directory
#   REL           Portal release package           (portal/)
#   IDENT         identity stack + EDC test package (identity/)
#   CHARTS        vendored charts                  (charts/); $CHARTS/umbrella-3.17.0/charts/portal-2.6.0.tgz is the
#                 Portal chart every Portal tool uses in either layout
#   HELM_PLUGINS  the Portal post-renderers         (portal/helm-plugins)
#   KUBECONFIG    ~/.kube/alpha.yaml; K() always adds --context alpha (credentials never live in this folder)
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
REL="$ALPHA/portal"
IDENT="$ALPHA/identity"
CHARTS="$ALPHA/charts"
HELM_PLUGINS="$REL/helm-plugins"
KUBECONFIG="$HOME/.kube/alpha.yaml"
if [ -e "$ALPHA/../.git" ] && [ -d "$ALPHA/../handoff" ]; then
  BE293_LAYOUT=repo
  ROOT="$(cd "$ALPHA/.." && pwd)"
  WORKSPACE="$(cd "$ROOT/.." && pwd)"
  UMB="$ROOT/handoff/BE-293-umbrella-3.17.0/chart/umbrella"
  export WORKSPACE
else
  BE293_LAYOUT=standalone
  ROOT="$ALPHA"
  UMB="$CHARTS/umbrella-3.17.0"
  unset WORKSPACE
fi
export BE293_LAYOUT ROOT UMB ALPHA REL IDENT CHARTS HELM_PLUGINS KUBECONFIG
unset _be293_env_file

# kubectl against Alpha, always with the explicit kubeconfig and context.
K() { kubectl --kubeconfig "$KUBECONFIG" --context alpha "$@"; }
