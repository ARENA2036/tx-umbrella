#!/bin/sh
# Called as an init container; secret values never enter rendered YAML or logs.
set -eu
umask 077
trap 'rm -f /work/curl.conf /work/request.json /work/response.json' EXIT
TOKEN=$(cat /secrets/vault/token)
case "$TOKEN" in ''|*[!A-Za-z0-9._-]*) echo 'Invalid Vault token format' >&2; exit 1;; esac
printf 'header = "X-Vault-Token: %s"\n' "$TOKEN" > /work/curl.conf
unset TOKEN
put_once() {
  alias=$1
  file=$2
  [ -s "$file" ] || { echo 'Required secret file is empty' >&2; exit 1; }
  code=$(curl --config /work/curl.conf -sS --connect-timeout 5 --max-time 15 \
    -o /work/response.json -w '%{http_code}' "$VAULT_URL/v1/secret/data/$alias") || code=000
  case "$code" in
    200)
      # Refuse silent secret rotation on restart or upgrade.
      jq -e --rawfile expected "$file" '.data.data.content == $expected' /work/response.json >/dev/null 2>&1 \
        || { echo "Inconsistent existing Vault alias: $alias" >&2; exit 1; }
      ;;
    404)
      jq -n --rawfile value "$file" '{options:{cas:0},data:{content:$value}}' > /work/request.json
      code=$(curl --config /work/curl.conf -sS --connect-timeout 5 --max-time 15 \
        -o /work/response.json -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' --data-binary @/work/request.json \
        "$VAULT_URL/v1/secret/data/$alias") || code=000
      case "$code" in 2??) ;; *) echo "Vault write failed ($code)" >&2; exit 1;; esac
      ;;
    *) echo "Vault read failed ($code); require initialized, unsealed KV-v2 Vault" >&2; exit 1;;
  esac
  rm -f /work/request.json /work/response.json
}
put_once edc.datasource.didentry.user /secrets/database/username
put_once edc.datasource.didentry.password /secrets/database/password
put_once bdrs-management-api-key /secrets/management/api-key
