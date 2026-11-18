#!/usr/bin/env bash
# Create the generated Secrets of the own identity stack in be293 (secrets-contract.identity.yaml, class "generated").
#
#   bash tools/identity-secrets-be293.sh             # DEFAULT: read-only; lists what would be created, checks none exists
#   bash tools/identity-secrets-be293.sh --execute   # same checks, typed confirmation, then `kubectl create secret` per Secret
#   bash tools/identity-secrets-be293.sh --edc [--execute]   # the same for the E2E test connector Secrets only
#
# Values are random, generated on this machine into files in a private temporary directory (mode 0700, removed on exit)
# and passed to kubectl as --from-file paths, so no value is ever on a command line, on stdout or in Git.
# Never overwrites: if any target Secret already exists, nothing is created. Only `get` and `create secret` are allowed.
set -euo pipefail

KC="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CTX="alpha"
NS="be293"
CONFIRM_PHRASE="create the be293 identity secrets"

MODE="dry-run"
SET="identity"
for arg in "$@"; do
  case "$arg" in
    --execute) MODE="execute" ;;
    --edc) SET="edc"; CONFIRM_PHRASE="create the be293 edc secrets" ;;
    *) echo "usage: identity-secrets-be293.sh [--edc] [--execute]" >&2; exit 2 ;;
  esac
done
unset KUBECONFIG
umask 077

die() { echo "ABORT: $*" >&2; exit 1; }
k() {
  case "$1 ${2:-}" in
    "get "*|"create secret") ;;
    *) die "refused: kubectl $1 ${2:-}" ;;
  esac
  kubectl --kubeconfig "$KC" --context "$CTX" --request-timeout=20s "$@"
}

# name -> keys (generated unless noted)
SECRETS=(
  "be293-identity-postgresql:postgres-password"
  "be293-identity-db-users:ISSUERSERVICE_DB_PASSWORD,IDENTITYHUB_DB_PASSWORD,BDRS_DB_PASSWORD"
  "be293-issuerservice-superuser:api-key"
  "be293-identityhub-superuser:api-key"
  "be293-bdrs-management:api-key"
  "be293-portal-bdrs-be293:management-api-key"
  "be293-portal-identityhub-be293:identityhub-api-key,issuerservice-admin-api-key"
)
# E2E test connectors (--edc). The connectors' Vault tokens are created by identity-vault-be293.sh --configure-edc.
EDC_SECRETS=(
  "be293-edc-postgresql:postgres-password"
  "be293-edc-db-users:EDC_FV1_DB_PASSWORD,EDC_GUC_DB_PASSWORD"
  "be293-edc-fv1-auth:management-api-key,proxy-api-key"
  "be293-edc-guc-auth:management-api-key,proxy-api-key"
)
[[ "$SET" == "edc" ]] && SECRETS=("${EDC_SECRETS[@]}")

WORK="$(mktemp -d "${TMPDIR:-/tmp}/be293-identity-secrets.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[[ -r "$KC" ]] || die "$KC not readable"
kubectl --kubeconfig "$KC" config get-contexts -o name | grep -qx "$CTX" || die "context $CTX not in $KC"
present=()
for s in "${SECRETS[@]}"; do
  name="${s%%:*}"
  if [[ -n "$(k get secret "$name" -n "$NS" --ignore-not-found -o name)" ]]; then present+=("$name"); fi
  echo "plan  Secret $name  keys: ${s#*:}"
done
[[ ${#present[@]} -eq 0 ]] || die "already present, nothing created: ${present[*]}"
echo "OK   none of the ${#SECRETS[@]} Secrets exists yet"
if [[ "$MODE" != "execute" ]]; then echo; echo "DRY RUN COMPLETE: nothing created."; exit 0; fi

{ exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation; nothing created"
printf 'Type exactly "%s" to create them: ' "$CONFIRM_PHRASE" >&3
answer=""; read -r answer <&3 || true; exec 3>&-
[[ "$answer" == "$CONFIRM_PHRASE" ]] || die "confirmation did not match; nothing created"

# 32 random bytes, URL-safe base64 without padding (no shell-special characters).
random() { ruby -rsecurerandom -e 'print SecureRandom.urlsafe_base64(32, false)' > "$1"; }
# SuperUserSeedExtension format: base64(<participantId>).<random>
superuser_key() { ruby -rsecurerandom -rbase64 -e 'print Base64.strict_encode64("super-user") + "." + SecureRandom.urlsafe_base64(32, false)' > "$1"; }

random "$WORK/bdrs-mgmt"   # one BDRS management key, used by BDRS (via Vault) and the Portal
for s in "${SECRETS[@]}"; do
  name="${s%%:*}"; args=()
  IFS=',' read -r -a keys <<<"${s#*:}"
  for key in "${keys[@]}"; do
    f="$WORK/$name.$key"
    case "$name:$key" in
      be293-*-superuser:api-key) superuser_key "$f" ;;
      be293-bdrs-management:api-key|be293-portal-bdrs-be293:management-api-key) cp "$WORK/bdrs-mgmt" "$f" ;;
      be293-portal-identityhub-be293:*) printf 'pending-seed' > "$f" ;;   # placeholder until the seed job writes it
      *) random "$f" ;;
    esac
    args+=("--from-file=$key=$f")
  done
  k create secret generic "$name" -n "$NS" "${args[@]}" > /dev/null || die "creating $name failed"
  echo "OK   created Secret $name (${#keys[@]} key(s))"
done
if [[ "$SET" == "edc" ]]; then
  echo; echo "CREATED. Next: helm install be293-edc-postgresql, then identity-vault-be293.sh --configure-edc (see the deployment order)."
else
  echo; echo "CREATED. Next: helm install be293-identity-vault (see the deployment order)."
fi
