#!/bin/sh
# Identity seed: issuer participant, attestations and credential definitions on the IssuerService, the Portal
# participant on IdentityHub, the scoped Portal keys and rotation of both super-user keys. Idempotent; every run
# regenerates the Portal keys and rotates the super-user keys again.
# Keys never pass through argv, stdout or the log: they are read from mounted Secret files, sent as curl header/body
# files in a memory emptyDir and written to Secrets through the Kubernetes API. Only step names and HTTP codes are
# printed.
# Never `set -x`: header and body files hold keys.
set -eu
umask 077

# Settings come from the Job environment (templates/identity-seed.yaml).
: "${NS:?}" "${IS_URL:?}" "${IH_URL:?}" "${ISSUER_ID:?}" "${ISSUER_DID:?}" "${ISSUANCE_URL:?}" "${PORTAL_ID:?}"
: "${PORTAL_DID:?}" "${SCHEMA_BASE:?}" "${BPN_DEFINITION_ID:?}" "${MEMBERSHIP_DEFINITION_ID:?}" "${PORTAL_SECRET:?}"
: "${IS_SUPERUSER_SECRET:?}" "${IH_SUPERUSER_SECRET:?}"
IS_IDENTITY="$IS_URL:8087/api/identity"
IS_ADMIN="$IS_URL:8086/api/admin"
IS_READY="$IS_URL:8081/api/check/readiness"
IH_IDENTITY="$IH_URL:8082/api/identity"
IH_READY="$IH_URL:8081/api/check/readiness"
SUPER_ID="super-user"
W=/work
SA=/var/run/secrets/kubernetes.io/serviceaccount
K8S="https://kubernetes.default.svc/api/v1/namespaces/${NS}/secrets"

die() { echo "[seed] FATAL: $*" >&2; exit 1; }
step() { echo "[seed] $*"; }

# header file "x-api-key: <key>" from a key file (printf is a shell builtin: the key never reaches an argv)
key_header() { printf 'x-api-key: %s\n' "$(tr -d '\r\n' < "$1")" > "$2"; }
printf 'Authorization: Bearer %s\n' "$(cat "$SA/token")" > "$W/k8s.hdr"

# call METHOD URL HEADERFILE [BODYFILE] -> prints the HTTP code; response body in $W/resp (never printed)
call() {
  if [ -n "${4:-}" ]; then
    curl -sS --connect-timeout 10 --max-time 60 -o "$W/resp" -w '%{http_code}' -X "$1" -H @"$3" \
      -H 'Content-Type: application/json' --data-binary @"$4" "$2" || echo 000
  else
    curl -sS --connect-timeout 10 --max-time 60 -o "$W/resp" -w '%{http_code}' -X "$1" -H @"$3" "$2" || echo 000
  fi
}
# idempotent create: 2xx or 409
ensure() {
  code=$(call POST "$1" "$2" "${3:-}")
  case "$code" in 2??) step "$4: created ($code)";; 409) step "$4: exists (409)";; *) die "$4 failed ($code)";; esac
}
wait_ready() {
  i=0
  until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" || true)" = 200 ]; do
    i=$((i + 1)); [ "$i" -le 90 ] || die "$2 not ready"; sleep 5
  done
  step "$2 ready"
}
# regenerate PARTICIPANT on API with HEADERFILE -> new key in OUTFILE (no newline, never printed)
regenerate() {
  code=$(call POST "$1/v1alpha/participants/$2/token" "$3")
  case "$code" in 2??) ;; *) die "token regeneration for $2 failed ($code)";; esac
  if jq -e 'type == "string"' "$W/resp" >/dev/null 2>&1; then jq -j . "$W/resp" > "$4"; else tr -d '\r\n' < "$W/resp" > "$4"; fi
  [ -s "$4" ] || die "token regeneration for $2 returned no key"
  : > "$W/resp"
}
# patch_secret NAME KEY VALUEFILE (merge patch through the API; value only inside the request body file)
patch_secret() {
  jq -n --rawfile v "$3" --arg k "$2" '{stringData: {($k): $v}}' > "$W/patch.json"
  code=$(curl -sS --connect-timeout 10 --max-time 30 -o /dev/null -w '%{http_code}' --cacert "$SA/ca.crt" \
    -H @"$W/k8s.hdr" -H 'Content-Type: application/merge-patch+json' -X PATCH \
    --data-binary @"$W/patch.json" "$K8S/$1" || echo 000)
  : > "$W/patch.json"
  case "$code" in 2??) step "Secret $1/$2 updated";; *) die "Secret $1/$2 update failed ($code)";; esac
}
# expect CODE API HEADERFILE LABEL: an authenticated read must return CODE
expect() {
  code=$(call GET "$2/v1alpha/participants?offset=0&limit=1" "$3")
  [ "$code" = "$1" ] || die "$4: expected $1, got $code"
  step "$4: $code"
}
participant_body() { # ID DID ROLE ACTIVE SERVICE_TYPE SERVICE_URL
  jq -n --arg id "$1" --arg did "$2" --arg role "$3" --argjson active "$4" --arg st "$5" --arg su "$6" '{
    active: $active, participantContextId: $id, did: $did,
    roles: (if $role == "" then [] else [$role] end),
    key: {keyId: ($did + "#key-1"), type: "JsonWebKey2020", privateKeyAlias: ($id + "-key-1"),
          keyGeneratorParams: {algorithm: "EC", curve: "secp256r1"}},
    serviceEndpoints: (if $st == "" then [] else [{id: ($did + "#" + $st), type: $st, serviceEndpoint: $su}] end)}'
}
definition_body() { # ID TYPE SCHEMA WITH_BPN
  jq -n --arg id "$1" --arg type "$2" --arg schema "$3" --argjson bpn "$4" '{
    id: $id, credentialType: $type, format: "VC1_0_JWT",
    attestations: ["holders-database-attestation"], jsonSchema: "{}", jsonSchemaUrl: $schema,
    mappings: ([{input: "did", output: "credentialSubject.id", required: true},
                {input: "holder_id", output: "credentialSubject.holderIdentifier", required: true}]
               + (if $bpn then [{input: "holder_id", output: "credentialSubject.bpn", required: true}] else [] end)),
    validity: 31536000}'
}

key_header /keys/issuerservice/api-key "$W/is-super.hdr"
key_header /keys/identityhub/api-key "$W/ih-super.hdr"
wait_ready "$IS_READY" IssuerService
wait_ready "$IH_READY" IdentityHub
expect 200 "$IS_IDENTITY" "$W/is-super.hdr" "IssuerService super-user key accepted"
expect 200 "$IH_IDENTITY" "$W/ih-super.hdr" "IdentityHub super-user key accepted"

# 1. issuer participant context (owner-scoped: no admin role)
participant_body "$ISSUER_ID" "$ISSUER_DID" "" true IssuerService "$ISSUANCE_URL" > "$W/body.json"
ensure "$IS_IDENTITY/v1alpha/participants" "$W/is-super.hdr" "$W/body.json" "issuer participant context"
ensure "$IS_IDENTITY/v1alpha/participants/$ISSUER_ID/state?isActive=true" "$W/is-super.hdr" "" "issuer activation"

# 2. attestations
jq -n '{id: "holders-database-attestation", attestationType: "database",
        configuration: {dataSourceName: "holder", tableName: "holders"}}' > "$W/body.json"
ensure "$IS_ADMIN/v1alpha/participants/$ISSUER_ID/attestations" "$W/is-super.hdr" "$W/body.json" "database attestation"
jq -n '{id: "holder-properties-attestation", attestationType: "holder", configuration: {}}' > "$W/body.json"
ensure "$IS_ADMIN/v1alpha/participants/$ISSUER_ID/attestations" "$W/is-super.hdr" "$W/body.json" "holder attestation"

# 3. credential definitions (ids as configured in the Portal values)
definition_body "$BPN_DEFINITION_ID" BpnCredential "$SCHEMA_BASE/bpn.credential.schema.json" true > "$W/body.json"
ensure "$IS_ADMIN/v1alpha/participants/$ISSUER_ID/credentialdefinitions" "$W/is-super.hdr" "$W/body.json" "BpnCredential definition"
definition_body "$MEMBERSHIP_DEFINITION_ID" MembershipCredential "$SCHEMA_BASE/membership.credential.schema.json" false > "$W/body.json"
ensure "$IS_ADMIN/v1alpha/participants/$ISSUER_ID/credentialdefinitions" "$W/is-super.hdr" "$W/body.json" "MembershipCredential definition"

# 4. Portal participant on IdentityHub: role "admin" (ParticipantPrincipal.ROLE_ADMIN, EDC 0.17.0). Never rename it
#    once it exists: that would orphan the participant and its DID.
participant_body "$PORTAL_ID" "$PORTAL_DID" admin true "" "" > "$W/body.json"
ensure "$IH_IDENTITY/v1alpha/participants" "$W/ih-super.hdr" "$W/body.json" "Portal participant"
# a 409 above leaves an existing participant untouched: set role and state explicitly (both idempotent)
jq -n '["admin"]' > "$W/body.json"
code=$(call PUT "$IH_IDENTITY/v1alpha/participants/$PORTAL_ID/roles" "$W/ih-super.hdr" "$W/body.json")
case "$code" in 2??) step "Portal participant role admin ($code)";; *) die "Portal participant role update failed ($code)";; esac
ensure "$IH_IDENTITY/v1alpha/participants/$PORTAL_ID/state?isActive=true" "$W/ih-super.hdr" "" "Portal participant activation"

# 5. scoped Portal keys (regenerated on every run, so a re-run always leaves known keys)
regenerate "$IS_IDENTITY" "$ISSUER_ID" "$W/is-super.hdr" "$W/issuer.key"
patch_secret "$PORTAL_SECRET" issuerservice-admin-api-key "$W/issuer.key"
regenerate "$IH_IDENTITY" "$PORTAL_ID" "$W/ih-super.hdr" "$W/portal.key"
patch_secret "$PORTAL_SECRET" identityhub-api-key "$W/portal.key"
key_header "$W/issuer.key" "$W/issuer.hdr"; key_header "$W/portal.key" "$W/portal.hdr"
: > "$W/issuer.key"; : > "$W/portal.key"
expect 200 "$IH_IDENTITY" "$W/portal.hdr" "Portal participant key accepted"

# 6. rotate both super-user keys; the logged bootstrap key stops working
for app in issuerservice identityhub; do
  case "$app" in
    issuerservice) api="$IS_IDENTITY"; secret="$IS_SUPERUSER_SECRET"; cp "$W/is-super.hdr" "$W/old.hdr" ;;
    identityhub)   api="$IH_IDENTITY"; secret="$IH_SUPERUSER_SECRET"; cp "$W/ih-super.hdr" "$W/old.hdr" ;;
  esac
  regenerate "$api" "$SUPER_ID" "$W/old.hdr" "$W/new.key"
  patch_secret "$secret" api-key "$W/new.key"
  key_header "$W/new.key" "$W/new.hdr"; : > "$W/new.key"
  expect 401 "$api" "$W/old.hdr" "$app previous super-user key rejected"
  expect 200 "$api" "$W/new.hdr" "$app rotated super-user key accepted"
  : > "$W/old.hdr"; : > "$W/new.hdr"
done
rm -f "$W"/*.hdr "$W"/*.key "$W"/resp "$W"/body.json
step "done"
