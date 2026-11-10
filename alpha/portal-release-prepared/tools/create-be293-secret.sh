#!/usr/bin/env bash
# Creates ONE contract Secret in be293 on Alpha. Owner credentials are typed/pasted at a silent /dev/tty prompt;
# Portal encryption keys are generated. Values never touch disk, argv, env, shell history or the terminal.
#
#   bash tools/create-be293-secret.sh be293-portal-bdrs              # DRY RUN: build + contract check, no cluster
#   bash tools/create-be293-secret.sh be293-portal-bdrs --execute    # kubectl create (never overwrites)
#
# Uses `kubectl create`, not apply: an existing Secret makes it fail with AlreadyExists, so nothing is replaced.
# Run only after the owner has issued or authorized the credential (README-ALPHA-RELEASE.md, S1).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
NAME="${1:?usage: create-be293-secret.sh SECRET_NAME [--execute]}"
MODE="${2:-dry-run}"
CONTRACT="$HERE/secrets-contract.yaml"
unset KUBECONFIG

case "$MODE" in
  dry-run)
    ruby "$HERE/tools/build_secret_manifest.rb" --contract "$CONTRACT" --name "$NAME" \
      | ruby "$HERE/tools/check_secret_contract.rb" --contract "$CONTRACT" --name "$NAME" --mail-disabled
    echo "dry run only: nothing was sent to a cluster"
    ;;
  --execute)
    [[ -r "$KC" ]] || { echo "$KC not readable" >&2; exit 1; }
    ruby "$HERE/tools/build_secret_manifest.rb" --contract "$CONTRACT" --name "$NAME" \
      | kubectl --kubeconfig "$KC" --context alpha --request-timeout=20s -n be293 create -f - -o name
    ;;
  *) echo "unknown mode $MODE (use --execute)" >&2; exit 2 ;;
esac
