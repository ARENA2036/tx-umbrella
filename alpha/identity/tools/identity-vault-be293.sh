#!/usr/bin/env bash
# Operator tool for the be293 identity Vault (release be293-identity-vault, Raft storage on a PVC).
#
#   bash tools/identity-vault-be293.sh --status              read-only: initialized / sealed
#   bash tools/identity-vault-be293.sh --init                once: 5 Shamir key shares, threshold 3
#   bash tools/identity-vault-be293.sh --unseal              after every Vault pod start
#   bash tools/identity-vault-be293.sh --configure           once: KV v2 mounts, policies, scoped tokens -> Secrets,
#                                                            BDRS aliases
#   bash tools/identity-vault-be293.sh --revoke-root         after --configure has been verified
#   bash tools/identity-vault-be293.sh --configure-edc       E2E test connectors (needs the root token, so before
#                                                            --revoke-root or after `vault operator generate-root`):
#                                                            KV mounts edc-fv1/edc-guc, policies, scoped tokens -> Secrets,
#                                                            aliases tokenSignerPrivateKey/-PublicKey, tokenEncryptionAesKey,
#                                                            edc-wallet-secret (copy of IdentityHub's <pid>-sts-client-secret)
#
# Every mode except --status asks for a typed confirmation. The Vault API is reached through
# `kubectl port-forward` to the Vault server POD, bound to 127.0.0.1 only. Not the Service: an uninitialised or sealed
# Vault never passes its readiness probe, so the Service has no endpoints exactly when --status/--init/--unseal are
# needed. --configure and --revoke-root use the pod too, for one code path. The init material (unseal keys and root token) is written to
# $BE293_VAULT_DIR (default ~/.be293-vault, mode 0700, outside the repository) and NEVER printed. Move the unseal keys
# to separate safe storage afterwards. Tokens for the applications are periodic, renewable, scoped to one KV mount each,
# and go straight from the Vault response file into a Kubernetes Secret (kubectl --from-file). Nothing overwrites an
# existing Secret or an existing BDRS alias (check-and-set 0).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CTX="alpha"
NS="be293"
# The single Vault server pod of release be293-identity-vault (ha.replicas: 1), found by its labels.
POD_SELECTOR="app.kubernetes.io/instance=be293-identity-vault,app.kubernetes.io/name=vault,component=server"
PORT="${BE293_VAULT_LOCAL_PORT:-18200}"
DIR="${BE293_VAULT_DIR:-$HOME/.be293-vault}"
INIT_FILE="$DIR/vault-init.json"
APPS=(issuerservice identityhub bdrs)

MODE="${1:-}"
case "$MODE" in --status|--init|--unseal|--configure|--revoke-root|--configure-edc) ;; *)
  echo "usage: identity-vault-be293.sh --status|--init|--unseal|--configure|--revoke-root|--configure-edc" >&2; exit 2 ;; esac
unset KUBECONFIG VAULT_TOKEN
umask 077

die() { echo "ABORT: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
k() {
  case "$1 ${2:-}" in
    "get "*|"port-forward "*|"create secret") ;;
    *) die "refused: kubectl $1 ${2:-}" ;;
  esac
  kubectl --kubeconfig "$KC" --context "$CTX" --request-timeout=20s "$@"
}
confirm() {
  { exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation; nothing changed"
  printf 'Type exactly "%s": ' "$1" >&3
  local answer=""; read -r answer <&3 || true; exec 3>&-
  [[ "$answer" == "$1" ]] || die "confirmation did not match; nothing changed"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/be293-vault.XXXXXX")"
PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

[[ -r "$KC" ]] || die "$KC not readable"
pods="$(k get pods -n "$NS" -l "$POD_SELECTOR" -o jsonpath='{.items[*].metadata.name}')" \
  || die "cannot list Vault pods in $NS"
read -r -a pod_list <<<"$pods"
[[ ${#pod_list[@]} -gt 0 ]] || die "no Vault server pod found in $NS (selector $POD_SELECTOR): is release be293-identity-vault installed?"
[[ ${#pod_list[@]} -eq 1 ]] || die "expected exactly one Vault server pod in $NS, found ${#pod_list[@]}: $pods"
POD="${pod_list[0]}"
k port-forward -n "$NS" --address 127.0.0.1 "pod/$POD" "$PORT:8200" > "$WORK/pf.log" 2>&1 &
PF_PID=$!
VAULT="http://127.0.0.1:$PORT"
reachable=""
for _ in $(seq 1 30); do curl -s -o /dev/null --max-time 2 "$VAULT/v1/sys/health" && { reachable=1; break; }; sleep 1; done
[[ -n "$reachable" ]] || die "Vault pod $POD not reachable through the port-forward on 127.0.0.1:$PORT ($(tail -1 "$WORK/pf.log" 2>/dev/null))"
echo "OK   port-forward to pod/$POD on 127.0.0.1:$PORT"

# api METHOD PATH [BODYFILE] -> HTTP code; response in $WORK/resp (never printed). Token header from $WORK/token.hdr.
# hdr may be empty (unauthenticated calls): ${hdr[@]+...} keeps `set -u` happy on macOS bash 3.2.
api() {
  local hdr=()
  [[ -s "$WORK/token.hdr" ]] && hdr=(-H "@$WORK/token.hdr")
  if [[ -n "${3:-}" ]]; then
    curl -sS --max-time 20 -o "$WORK/resp" -w '%{http_code}' -X "$1" ${hdr[@]+"${hdr[@]}"} -H 'Content-Type: application/json' \
      --data-binary "@$3" "$VAULT$2" || echo 000
  else
    curl -sS --max-time 20 -o "$WORK/resp" -w '%{http_code}' -X "$1" ${hdr[@]+"${hdr[@]}"} "$VAULT$2" || echo 000
  fi
}
root_header() {
  [[ -r "$INIT_FILE" ]] || die "$INIT_FILE not found (run --init first)"
  ruby -rjson -e 'exit(JSON.parse(File.read(ARGV[0])).key?("root_token") ? 0 : 1)' "$INIT_FILE" \
    || die "no root token in $INIT_FILE (revoked by --revoke-root): regenerate one with the unseal keys (vault operator generate-root)"
  ruby -rjson -e 'printf("X-Vault-Token: %s\n", JSON.parse(File.read(ARGV[0])).fetch("root_token"))' "$INIT_FILE" > "$WORK/token.hdr"
}

# --- E2E test connectors (--configure-edc) ---
# Two tokens are in play: the ROOT header (mounts, policies, token minting, reading IdentityHub's STS secret) and the
# connector's own scoped token (every alias write, so the connector policy is exercised exactly as the connector will use
# it). api() always sends $WORK/token.hdr; use_header swaps which one that is. Values live only in $WORK files.
EDC_CONNECTORS=("edc-fv1:bpnl000000000fv1" "edc-guc:bpnl000000000guc")
use_header() { cp "$WORK/$1.hdr" "$WORK/token.hdr"; }
edc_policy_body() { # MOUNT -> JSON body for PUT sys/policies/acl/be293-MOUNT
  ruby -rjson -e 'm = ARGV[0]; print JSON.generate("policy" => [
    %(path "#{m}/data/*" { capabilities = ["create", "read", "update"] }),
    %(path "#{m}/metadata/transfer-process-*" { capabilities = ["delete"] }),
    %(path "#{m}/metadata/edr--*" { capabilities = ["delete"] })].join("\n"))' "$1"
}
# alias_exists MOUNT ALIAS (connector header active) -> 0 exists, 1 missing; anything else aborts
alias_exists() {
  local code; code="$(api GET "/v1/$1/data/$2")"; : > "$WORK/resp"
  case "$code" in 200) return 0;; 404) return 1;; *) die "reading $1/$2 failed ($code)";; esac
}
# write_alias MOUNT ALIAS VALUEFILE (connector header active): KV v2 create-only (cas 0); the value file is wiped after.
write_alias() {
  local code
  ruby -rjson -e 'print JSON.generate("options" => {"cas" => 0}, "data" => {"content" => File.read(ARGV[0])})' "$3" > "$WORK/body"
  code="$(api POST "/v1/$1/data/$2" "$WORK/body")"; : > "$WORK/body"; : > "$3"; : > "$WORK/resp"
  case "$code" in 200) echo "OK   $1/$2 written";; 400) echo "OK   $1/$2 exists (not overwritten)";; *) die "writing $1/$2 failed ($code)";; esac
}
# edc_token MOUNT: the connector's periodic token, minted once and stored in Secret be293-MOUNT-vault-token BEFORE it is
# used; a re-run reads it back from the Secret. Result: $WORK/MOUNT.hdr.
edc_token() {
  local secret="be293-$1-vault-token"
  if [[ -n "$(k get secret "$secret" -n "$NS" --ignore-not-found -o name)" ]]; then
    k get secret "$secret" -n "$NS" -o jsonpath='{.data.token}' | base64 -d > "$WORK/$1.token" || die "cannot read $secret"
    echo "OK   Secret $secret exists: token reused"
  else
    use_header root
    ruby -rjson -e 'print JSON.generate("policies" => ["be293-#{ARGV[0]}"], "period" => "768h", "renewable" => true,
                                        "no_parent" => true, "display_name" => "be293-#{ARGV[0]}")' "$1" > "$WORK/body"
    [[ "$(api POST /v1/auth/token/create-orphan "$WORK/body")" == 200 ]] || die "token for $1 failed"
    ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("auth", "client_token")' "$WORK/resp" > "$WORK/$1.token"; : > "$WORK/resp"
    [[ -s "$WORK/$1.token" ]] || die "no token for $1"
    k create secret generic "$secret" -n "$NS" --from-file="token=$WORK/$1.token" > /dev/null || die "Secret $secret failed"
    echo "OK   Secret $secret (periodic 768h, policy be293-$1)"
  fi
  [[ -s "$WORK/$1.token" ]] || die "empty token for $1"
  printf 'X-Vault-Token: %s\n' "$(cat "$WORK/$1.token")" > "$WORK/$1.hdr"; : > "$WORK/$1.token"
}
# copy_sts_secret MOUNT PID: IdentityHub's <PID>-sts-client-secret -> MOUNT/edc-wallet-secret. Read with the root header
# into $WORK/resp, the value goes straight into the request body file, written with the connector header (cas 0), then
# read back with the connector header and compared by SHA-256 inside ruby. Only "match"/"MISMATCH" is ever printed.
copy_sts_secret() {
  local code src="identityhub/data/$2-sts-client-secret"
  use_header "$1"
  if alias_exists "$1" edc-wallet-secret; then echo "OK   $1/edc-wallet-secret exists (not overwritten)"; else
    use_header root
    code="$(api GET "/v1/$src")"
    [[ "$code" == 200 ]] || { : > "$WORK/resp"; die "reading $src failed ($code): is $2 an IdentityHub participant with an STS account?"; }
    ruby -rjson -e 'v = JSON.parse(File.read(ARGV[0])).dig("data", "data", "content").to_s; exit 1 if v.empty?; print v' \
      "$WORK/resp" > "$WORK/sts.value" || { : > "$WORK/resp"; die "$src has no content"; }
    : > "$WORK/resp"
    use_header "$1"
    write_alias "$1" edc-wallet-secret "$WORK/sts.value"
  fi
  # verify: IdentityHub's value and the connector's copy are identical (digests only, never values)
  use_header root
  [[ "$(api GET "/v1/$src")" == 200 ]] || die "re-reading $src failed"; mv "$WORK/resp" "$WORK/src.json"
  use_header "$1"
  [[ "$(api GET "/v1/$1/data/edc-wallet-secret")" == 200 ]] || die "reading back $1/edc-wallet-secret failed"
  ruby -rjson -rdigest -e 'a, b = ARGV.map { |f| Digest::SHA256.hexdigest(JSON.parse(File.read(f)).dig("data", "data", "content").to_s) }
    puts(a == b ? "OK   edc-wallet-secret matches IdentityHub (SHA-256 compared, value not shown)" : "MISMATCH"); exit(a == b ? 0 : 1)' \
    "$WORK/src.json" "$WORK/resp" || { : > "$WORK/src.json"; : > "$WORK/resp"; die "$1/edc-wallet-secret differs from $src"; }
  : > "$WORK/src.json"; : > "$WORK/resp"
}
# edc_keys MOUNT (connector header active): RSA-2048 PKCS#8 token-signer pair and a 256-bit AES key (base64), generated
# into files by openssl (never on stdout or argv). A half-present signer pair aborts instead of being repaired.
edc_keys() {
  local priv=0 pub=0
  alias_exists "$1" tokenSignerPrivateKey && priv=1
  alias_exists "$1" tokenSignerPublicKey && pub=1
  if [[ $priv -eq 1 && $pub -eq 1 ]]; then echo "OK   $1 token-signer pair exists (not overwritten)"
  elif [[ $priv -ne $pub ]]; then die "$1 has only one half of the token-signer pair: fix by hand, nothing written"
  else
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$WORK/signer.key" 2>/dev/null || die "key generation failed"
    openssl pkey -in "$WORK/signer.key" -pubout -out "$WORK/signer.pub" 2>/dev/null || die "public key derivation failed"
    write_alias "$1" tokenSignerPrivateKey "$WORK/signer.key"
    write_alias "$1" tokenSignerPublicKey "$WORK/signer.pub"
  fi
  if alias_exists "$1" tokenEncryptionAesKey; then echo "OK   $1/tokenEncryptionAesKey exists (not overwritten)"; else
    openssl rand -base64 32 | tr -d '\n' > "$WORK/aes.key"
    [[ -s "$WORK/aes.key" ]] || die "AES key generation failed"
    write_alias "$1" tokenEncryptionAesKey "$WORK/aes.key"
  fi
}
# --- end E2E test connectors ---
status() {
  [[ "$(api GET /v1/sys/seal-status)" == 200 ]] || die "Vault not reachable through the port-forward"
  ruby -rjson -e 'r = JSON.parse(File.read(ARGV[0])); puts "initialized=#{r["initialized"]} sealed=#{r["sealed"]} progress=#{r["progress"]}/#{r["t"]} storage=#{r["storage_type"]}"' "$WORK/resp"
}

case "$MODE" in
  --status)
    step "status (read-only)"; status ;;

  --init)
    step "init: 5 key shares, threshold 3; material to $INIT_FILE (never printed)"
    [[ -e "$INIT_FILE" ]] && die "$INIT_FILE exists: Vault was initialised already; nothing changed"
    confirm "initialize the be293 identity vault"
    mkdir -p "$DIR"; chmod 700 "$DIR"
    printf '{"secret_shares":5,"secret_threshold":3}' > "$WORK/body"
    code="$(api PUT /v1/sys/init "$WORK/body")"
    [[ "$code" == 200 ]] || die "init failed ($code)"
    mv "$WORK/resp" "$INIT_FILE"; chmod 600 "$INIT_FILE"
    echo "OK   initialised. Unseal keys and root token are in $INIT_FILE. Copy the unseal keys to separate safe storage." ;;

  --unseal)
    step "unseal from $INIT_FILE"
    [[ -r "$INIT_FILE" ]] || die "$INIT_FILE not found"
    confirm "unseal the be293 identity vault"
    for i in 0 1 2; do
      ruby -rjson -e 'print JSON.generate("key" => JSON.parse(File.read(ARGV[0])).fetch("keys_base64")[ARGV[1].to_i])' "$INIT_FILE" "$i" > "$WORK/body"
      code="$(api PUT /v1/sys/unseal "$WORK/body")"; : > "$WORK/body"
      [[ "$code" == 200 ]] || die "unseal step $((i + 1)) failed ($code)"
    done
    status ;;

  --configure)
    step "configure: KV v2 mounts, policies, scoped tokens, BDRS aliases"
    confirm "configure the be293 identity vault"
    root_header
    for app in "${APPS[@]}"; do
      [[ -z "$(k get secret "be293-$app-vault-token" -n "$NS" --ignore-not-found -o name)" ]] \
        || die "Secret be293-$app-vault-token exists: nothing changed"
    done
    for app in "${APPS[@]}"; do
      printf '{"type":"kv","options":{"version":"2"}}' > "$WORK/body"
      code="$(api POST "/v1/sys/mounts/$app" "$WORK/body")"
      case "$code" in 2??) echo "OK   KV v2 mount $app";; 400) echo "OK   KV v2 mount $app exists";; *) die "mount $app failed ($code)";; esac
      ruby -rjson -e 'print JSON.generate("policy" => %(path "#{ARGV[0]}/*" { capabilities = ["create", "read", "update", "patch", "delete", "list"] }))' "$app" > "$WORK/body"
      [[ "$(api PUT "/v1/sys/policies/acl/be293-$app" "$WORK/body")" == 204 ]] || die "policy be293-$app failed"
      echo "OK   policy be293-$app (only $app/*)"
      ruby -rjson -e 'print JSON.generate("policies" => ["be293-#{ARGV[0]}"], "period" => "768h", "renewable" => true,
                                          "no_parent" => true, "display_name" => "be293-#{ARGV[0]}")' "$app" > "$WORK/body"
      [[ "$(api POST /v1/auth/token/create-orphan "$WORK/body")" == 200 ]] || die "token for $app failed"
      ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("auth", "client_token")' "$WORK/resp" > "$WORK/app.token"; : > "$WORK/resp"
      [[ -s "$WORK/app.token" ]] || die "no token for $app"
      k create secret generic "be293-$app-vault-token" -n "$NS" --from-file="token=$WORK/app.token" > /dev/null \
        || die "Secret be293-$app-vault-token failed"
      : > "$WORK/app.token"
      echo "OK   Secret be293-$app-vault-token (periodic 768h, policy be293-$app)"
    done
    # BDRS reads its DB credentials and management key from Vault (bdrs mount), written once (cas 0).
    k get secret be293-identity-db-users -n "$NS" -o jsonpath='{.data.BDRS_DB_PASSWORD}' | base64 -d > "$WORK/bdrs-db" \
      || die "cannot read be293-identity-db-users"
    k get secret be293-bdrs-management -n "$NS" -o jsonpath='{.data.api-key}' | base64 -d > "$WORK/bdrs-mgmt" \
      || die "cannot read be293-bdrs-management"
    printf 'bdrs' > "$WORK/bdrs-user"
    for pair in "edc.datasource.didentry.user:bdrs-user" "edc.datasource.didentry.password:bdrs-db" "mgmt-api-key:bdrs-mgmt"; do
      alias="${pair%%:*}"; file="$WORK/${pair#*:}"
      [[ -s "$file" ]] || die "empty value for $alias"
      ruby -rjson -e 'print JSON.generate("options" => {"cas" => 0}, "data" => {"content" => File.read(ARGV[0])})' "$file" > "$WORK/body"
      code="$(api POST "/v1/bdrs/data/$alias" "$WORK/body")"; : > "$WORK/body"
      case "$code" in 200) echo "OK   BDRS alias $alias";; 400) echo "OK   BDRS alias $alias exists (not overwritten)";; *) die "alias $alias failed ($code)";; esac
      : > "$file"
    done ;;

  --revoke-root)
    step "revoke the root token (regenerate later only with the unseal keys: vault operator generate-root)"
    confirm "revoke the be293 identity vault root token"
    root_header
    [[ "$(api POST /v1/auth/token/revoke-self)" == 204 ]] || die "root token revocation failed"
    ruby -rjson -e 'd = JSON.parse(File.read(ARGV[0])); d.delete("root_token"); File.write(ARGV[0], JSON.generate(d))' "$INIT_FILE"
    echo "OK   root token revoked and removed from $INIT_FILE" ;;

  --configure-edc)
    step "configure-edc: KV v2 mounts, policies, scoped tokens and aliases for the E2E test connectors"
    confirm "configure the be293 edc test connectors"
    root_header; cp "$WORK/token.hdr" "$WORK/root.hdr"
    for pair in "${EDC_CONNECTORS[@]}"; do
      mount="${pair%%:*}"; pid="${pair#*:}"
      use_header root
      printf '{"type":"kv","options":{"version":"2"}}' > "$WORK/body"
      code="$(api POST "/v1/sys/mounts/$mount" "$WORK/body")"
      case "$code" in 2??) echo "OK   KV v2 mount $mount";; 400) echo "OK   KV v2 mount $mount exists";; *) die "mount $mount failed ($code)";; esac
      edc_policy_body "$mount" > "$WORK/body"
      [[ "$(api PUT "/v1/sys/policies/acl/be293-$mount" "$WORK/body")" == 204 ]] || die "policy be293-$mount failed"
      echo "OK   policy be293-$mount (create/read/update on $mount/data/*; delete only transfer-process-*/edr--* metadata)"
      edc_token "$mount"
      use_header "$mount"
      edc_keys "$mount"
      copy_sts_secret "$mount" "$pid"
      : > "$WORK/$mount.hdr"
    done
    : > "$WORK/root.hdr" ;;
esac
