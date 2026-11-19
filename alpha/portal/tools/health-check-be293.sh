#!/usr/bin/env bash
# Read-only external health check of the be293 Portal on Alpha: anonymous HTTPS GET/OPTIONS only, no
# credentials, no cluster access, nothing changed. Run from an operator machine (the hosts are public).
#
#   bash tools/health-check-be293.sh
#
#   H1 frontend: portal and registration apps answer 200 over verified TLS
#   H2 TLS: certificate valid for each host, issuer and days until expiry
#   H3 backend APIs: one [Authorize] endpoint per service answers 401 anonymously (routed, service up, auth
#      enforced); 200 = anonymous access (FAIL), 404/5xx = routing or service failure (FAIL)
#   H4 CORS: preflight from the portal origin is allowed, a foreign origin is not echoed
#   H5 OIDC: CX-Central discovery issuer matches the backends' VALIDISSUER
#   H6 login redirect (blocker K1): CentralIDP accepts the portal/registration redirect URIs for their clients
#      (200 login page = accepted; 400 "Invalid parameter: redirect_uri" = not registered)
# Exit: 0 no FAIL, 1 otherwise.
set -uo pipefail

FRONT="https://portal-be293.test.tractus-x.com"
BACK="https://portal-backend-be293.test.tractus-x.com"
IDP="https://centralidp.test.tractus-x.com/auth"
REALM="CX-Central"
ISSUER="$IDP/realms/$REALM"
# Anonymous probes; each route is [Authorize(Roles=...)] in the pinned backend (ad459ee7).
API_PROBES=(/api/administration/staticdata/usecases /api/registration/legalEntityAddress/BPNL000000000000
            /api/apps/active /api/services/active /api/notification/)
CURL=(curl -sS --proto =https --max-time 20 -o /dev/null)
FAILS=0

ok() { echo "OK   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
# curl prints 000 itself when the connection fails.
code() { local c; c="$("${CURL[@]}" -w '%{http_code}' "$@" 2>/dev/null)"; echo "${c:-000}"; }

echo "== H1 frontend"
for p in / /registration/; do
  c="$(code "$FRONT$p")"; [[ "$c" == 200 ]] && ok "GET $FRONT$p -> 200" || bad "GET $FRONT$p -> $c"
done

echo "== H2 TLS (curl verifies chain and host name; details from the served certificate)"
for host in "${FRONT#https://}" "${BACK#https://}"; do
  c="$(code "https://$host/")"
  [[ "$c" == 000 ]] && { bad "$host TLS handshake or verification failed"; continue; }
  cert="$(openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null)"
  end="$(sed -n 's/^notAfter=//p' <<<"$cert")"
  days=$(( ( $(date -j -f '%b %e %T %Y %Z' "$end" +%s 2>/dev/null || date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  issuer="$(sed -n 's/^issuer=//p' <<<"$cert")"
  [[ "$days" -ge 14 ]] && ok "$host verified; issuer: $issuer; expires in $days days" || bad "$host certificate expires in $days days"
done

echo "== H3 backend APIs (anonymous -> expect 401)"
for p in "${API_PROBES[@]}"; do
  c="$(code "$BACK$p")"
  case "$c" in
    401) ok "GET $p -> 401 (routed, auth enforced)" ;;
    403) ok "GET $p -> 403 (routed, auth enforced)" ;;
    200) bad "GET $p -> 200 WITHOUT a token (anonymous access)" ;;
    *) bad "GET $p -> $c (routing/service failure)" ;;
  esac
done

echo "== H4 CORS"
acao() { curl -sS --proto =https --max-time 20 -o /dev/null -D - -X OPTIONS -H "Origin: $1" \
           -H 'Access-Control-Request-Method: GET' "$BACK${API_PROBES[0]}" 2>/dev/null \
         | tr -d '\r' | sed -n 's/^[Aa]ccess-[Cc]ontrol-[Aa]llow-[Oo]rigin: //p'; }
a="$(acao "$FRONT")"; [[ "$a" == "$FRONT" ]] && ok "preflight from $FRONT allowed" || bad "preflight from $FRONT -> allow-origin '${a:-<none>}'"
a="$(acao "https://evil.example.invalid")"; [[ -z "$a" || "$a" == "$FRONT" ]] && ok "foreign origin not echoed" || bad "foreign origin echoed: '$a'"

echo "== H5 OIDC discovery"
iss="$(curl -sS --proto =https --max-time 20 "$ISSUER/.well-known/openid-configuration" 2>/dev/null | ruby -rjson -e 'puts JSON.parse($stdin.read)["issuer"]' 2>/dev/null)"
[[ "$iss" == "$ISSUER" ]] && ok "issuer $iss" || bad "issuer '${iss:-<unreachable>}' != $ISSUER"

echo "== H6 login redirect URIs (K1)"
# The URIs the pinned frontends actually send: portal v2.6.0 calls keycloak-js init() without redirectUri, so
# it sends the current page URL (any path); registration v2.2.2 sends origin + /registration/load (or /help).
for pair in "Cl2-CX-Portal $FRONT/" "Cl2-CX-Portal $FRONT/home" "Cl1-CX-Registration $FRONT/registration/load" \
            "Cl1-CX-Registration $FRONT/registration/help"; do
  read -r client redirect <<<"$pair"
  c="$(code -G "$ISSUER/protocol/openid-connect/auth" --data-urlencode "client_id=$client" \
         --data-urlencode "redirect_uri=$redirect" --data-urlencode 'response_type=code' --data-urlencode 'scope=openid')"
  case "$c" in
    200) ok "$client accepts redirect_uri $redirect" ;;
    400) bad "$client REJECTS redirect_uri $redirect (add it to the client's Valid Redirect URIs; blocker K1)" ;;
    *) bad "$client auth endpoint -> $c" ;;
  esac
done

echo; [[ "$FAILS" -eq 0 ]] && echo "HEALTH RESULT PASS" || echo "HEALTH RESULT FAIL ($FAILS)"
exit $(( FAILS > 0 ))
