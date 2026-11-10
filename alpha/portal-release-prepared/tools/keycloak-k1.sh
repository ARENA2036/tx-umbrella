#!/usr/bin/env bash
# Blocker K1: allow the be293 Portal host on the SHARED CentralIDP clients in realm CX-Central, additively.
#
#   bash tools/keycloak-k1.sh             # DEFAULT: read-only; shows current values and the exact additions
#   bash tools/keycloak-k1.sh --execute   # Keycloak owner only, after approval: typed confirmation, backup, update
#
# Prerequisite (Keycloak owner, interactive; the password is prompted by kcadm, never passed here):
#   kcadm.sh config credentials --server https://centralidp.test.tractus-x.com/auth --realm master --user <admin>
#
# What the pinned frontends send (source of the exact image tags):
#   portal-frontend v2.6.0          keycloak-js init() without redirectUri -> current page URL (any path)
#   portal-frontend-registration v2.2.2  redirectUri = origin + /registration/load (or /registration/help)
# Additions (nothing is removed or reordered; release26-09 keeps every existing value):
#   Cl2-CX-Portal        redirectUris += https://portal-be293.test.tractus-x.com/*
#   Cl1-CX-Registration  redirectUris += https://portal-be293.test.tractus-x.com/registration/*
#   both                 webOrigins += https://portal-be293.test.tractus-x.com   (skipped if "+" is set: derived)
#                        post.logout.redirect.uris += same URI (only if an explicit list exists; "+"/unset untouched)
# Wildcards are host- and path-anchored; no bare "*" is ever added.
set -euo pipefail

KCADM="${KCADM:-kcadm.sh}"
REALM="CX-Central"
ORIGIN="https://portal-be293.test.tractus-x.com"
CHANGES=("Cl2-CX-Portal $ORIGIN/*" "Cl1-CX-Registration $ORIGIN/registration/*")
CONFIRM_PHRASE="add be293 redirect URIs in $REALM"
FIELDS="id,clientId,publicClient,redirectUris,webOrigins,attributes"

MODE="plan"
case "${1:-}" in
  "") ;;
  --execute) MODE="execute" ;;
  *) echo "usage: keycloak-k1.sh [--execute]" >&2; exit 2 ;;
esac
umask 077
die() { echo "ABORT: $*" >&2; exit 1; }

# Read one client (no secret: --fields excludes it). Prints the JSON object.
read_client() {
  local out
  out="$("$KCADM" get clients -r "$REALM" -q "clientId=$1" --fields "$FIELDS")" || die "cannot read client $1 (kcadm logged in?)"
  ruby -rjson -e 'a = JSON.parse(ARGV[0]); abort("expected exactly one client #{ARGV[1]}, got #{a.size}") unless a.size == 1 && a[0]["clientId"] == ARGV[1]; puts JSON.generate(a[0])' "$out" "$1" \
    || die "client lookup for $1 not unique"
}

# Prints: id, then the three new values (JSON array, JSON array, attribute string or empty = unchanged).
plan() {
  ruby -rjson -e '
    c = JSON.parse(ARGV[0]); add = ARGV[1]; origin = ARGV[2]
    abort("#{c["clientId"]} is not a public client; review before changing") unless c["publicClient"] == true
    ru = c["redirectUris"] || []; wo = c["webOrigins"] || []
    plo = (c["attributes"] || {})["post.logout.redirect.uris"].to_s
    nru = ru.include?(add) ? ru : ru + [add]
    nwo = (wo.include?("+") || wo.include?(origin)) ? wo : wo + [origin]
    list = plo.split("##")
    nplo = (plo.empty? || list.include?("+") || list.include?(add)) ? "" : (list + [add]).join("##")
    warn "  #{c["clientId"]} (id #{c["id"]})"
    warn "    redirectUris  current #{ru.inspect}"
    warn "                  add     #{(nru - ru).inspect}"
    warn "    webOrigins    current #{wo.inspect}; add #{(nwo - wo).inspect}#{wo.include?("+") ? " (\"+\" derives origins from redirectUris)" : ""}"
    warn "    post-logout   current #{plo.empty? ? "<unset>" : plo.inspect}; #{nplo.empty? ? "unchanged" : "add #{add}"}"
    puts c["id"], JSON.generate(nru), JSON.generate(nwo), nplo' "$1" "$2" "$ORIGIN"
}

echo "== K1 plan for realm $REALM (read-only)"
declare -a IDS NRU NWO NPLO NAMES
for entry in "${CHANGES[@]}"; do
  read -r client add <<<"$entry"
  cur="$(read_client "$client")"
  p="$(plan "$cur" "$add")" || die "plan failed for $client"
  IDS+=("$(sed -n 1p <<<"$p")"); NRU+=("$(sed -n 2p <<<"$p")"); NWO+=("$(sed -n 3p <<<"$p")"); NPLO+=("$(sed -n 4p <<<"$p")")
  NAMES+=("$client")
done

if [[ "$MODE" != "execute" ]]; then
  echo; echo "PLAN ONLY: nothing changed. The Keycloak owner re-runs with --execute after approval."
  exit 0
fi

{ exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation; nothing changed"
printf 'Type exactly "%s" to apply: ' "$CONFIRM_PHRASE" >&3
answer=""; read -r answer <&3 || true; exec 3>&-
[[ "$answer" == "$CONFIRM_PHRASE" ]] || die "confirmation did not match; nothing changed"

BACKUP="$(mktemp -d "${TMPDIR:-/tmp}/k1-backup.XXXXXX")"
for i in "${!IDS[@]}"; do
  read_client "${NAMES[$i]}" > "$BACKUP/${NAMES[$i]}.json"
done
echo "backup of the current values (no secrets): $BACKUP"

for i in "${!IDS[@]}"; do
  args=(update "clients/${IDS[$i]}" -r "$REALM" -s "redirectUris=${NRU[$i]}" -s "webOrigins=${NWO[$i]}")
  [[ -n "${NPLO[$i]}" ]] && args+=(-s "attributes.\"post.logout.redirect.uris\"=${NPLO[$i]}")
  "$KCADM" "${args[@]}" || die "update of ${NAMES[$i]} failed; restore values from $BACKUP if needed"
  after="$(read_client "${NAMES[$i]}")"
  ruby -rjson -e '
    b = JSON.parse(File.read(ARGV[0])); a = JSON.parse(ARGV[1]); add = ARGV[2]
    lost = ((b["redirectUris"] || []) - (a["redirectUris"] || [])) + ((b["webOrigins"] || []) - (a["webOrigins"] || []))
    abort("LOST existing values: #{lost.inspect}") unless lost.empty?
    abort("#{add} not present after update") unless (a["redirectUris"] || []).include?(add)
    puts "OK   #{a["clientId"]}: #{add} added, all existing values preserved"' \
    "$BACKUP/${NAMES[$i]}.json" "$after" "$(cut -d' ' -f2 <<<"${CHANGES[$i]}")" || die "verification failed for ${NAMES[$i]}"
done
echo; echo "DONE. Verify: bash tools/health-check-be293.sh (H6), then an interactive login (README)."
