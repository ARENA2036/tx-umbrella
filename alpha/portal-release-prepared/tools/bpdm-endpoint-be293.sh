#!/usr/bin/env bash
# BPDM Gate/Pool base addresses of the BE-293 Portal on Alpha: verify the live endpoint, then fix be293 only.
#
#   bash tools/bpdm-endpoint-be293.sh            # DEFAULT, read-only: offline gates (R-BPDM), be293 live env,
#                                                # release26-09 Portal reference env, BPDM Ingress routes and images
#                                                # (kubectl get only), public BPDM OpenAPI (anonymous GET), verdict,
#                                                # server-side dry-run patch of the processes-worker
#   bash tools/bpdm-endpoint-be293.sh --execute  # after approval: typed confirmation, then patch ONLY the two plain
#                                                # BPDM env entries on cronjob/be293-portal-processes-worker (next run;
#                                                # no restart). Values come from the gated offline render.
#   bash tools/bpdm-endpoint-be293.sh --verify   # read-only: live BPDM env of all be293 workloads vs the render
#   bash tools/bpdm-endpoint-be293.sh --bpn-status  # read-only SQL: BPN checklist entries/steps and which
#                                                # applications are eligible for the manual BPN retrigger
#
# The backend (ad459ee7 BpdmService/BpnAccess) sends relative paths against "<base>/": e.g. PUT
# <APPLICATIONCHECKLIST__BPDM__BASEADDRESS>/input/business-partners. The administration-service,
# registration-service and portal frontend carry the same values; they change with the approved Helm recovery
# (patching them live restarts pods). The live OpenAPI check also compares the request/response fields the
# backend uses (tools/bpdm_openapi.rb): a Gate mismatch aborts; a Pool mismatch is reported (not BPN Creation).
# Never: PUT/POST to BPDM, apply/replace/delete, Secrets, Helm, any change in release26-09, retrigger of
# registrations, database writes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CTX="alpha"
NS="be293"
SHARED_NS="release26-09"
BPDM_HOST="https://business-partners.test.tractus-x.com"
WORKER="be293-portal-processes-worker"
GATE_ENV="APPLICATIONCHECKLIST__BPDM__BASEADDRESS"
POOL_ENV="APPLICATIONCHECKLIST__BPDM__BUSINESSPARTNERPOOLBASEADDRESS"
BPDM_ENVS=("$GATE_ENV" "$POOL_ENV" BPNACCESS__BASEADDRESS BPDM_GATE_API_URL BPDM_POOL_API_URL)
WORKLOADS=("cronjob/$WORKER" "deployment/be293-portal-administration-service" "deployment/be293-portal-registration-service" "deployment/be293-portal-portal")
DOC_PATHS=(/docs/api-docs /v3/api-docs)

MODE="plan"
case "${1:-}" in
  "") ;;
  --execute) MODE="execute" ;;
  --verify) MODE="verify" ;;
  --bpn-status) MODE="bpn-status" ;;
  *) echo "usage: bpdm-endpoint-be293.sh [--execute|--verify|--bpn-status]" >&2; exit 2 ;;
esac

unset KUBECONFIG
umask 077
die() { echo "ABORT: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/be293-bpdm.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
EP=(ruby "$HERE/tools/env_patch.rb")

# kubectl: be293 read-only verbs, patch only in the confirmed execute step; release26-09 get only.
MUTATE=0
k() {
  case "$1" in
    get|rollout) ;;
    patch) [[ "$MUTATE" == 1 || " $* " == *" --dry-run=server "* ]] || die "refused: kubectl patch outside the confirmed execute step" ;;
    *) die "refused: kubectl $1" ;;
  esac
  kubectl --kubeconfig "$KC" --context "$CTX" -n "$NS" --request-timeout=30s "$@"
}
kshared() {
  [[ "$1" == get ]] || die "refused: kubectl $1 in $SHARED_NS (read-only)"
  kubectl --kubeconfig "$KC" --context "$CTX" -n "$SHARED_NS" --request-timeout=30s "$@"
}

[[ -r "$KC" ]] || die "$KC not readable"
kubectl --kubeconfig "$KC" config get-contexts -o name | grep -qx "$CTX" || die "context $CTX not in $KC"

if [[ "$MODE" == "bpn-status" ]]; then
  K=(kubectl --kubeconfig "$KC" --context "$CTX" -n "$NS" --request-timeout=60s)
  # shellcheck source=lib/be293-db.sh
  source "$HERE/tools/lib/be293-db.sh"
  step "BPN checklist state (read-only SQL; e-mail addresses masked)"
  psql_ro <<'SQL'
BEGIN READ ONLY;
\echo '-- B1 BUSINESS_PARTNER_NUMBER checklist entries (latest 20)'
SELECT ca.id AS application_id, cas.label AS application_status, acs.label AS bpn_entry, ac.date_last_changed AS changed
FROM portal.company_applications ca
JOIN portal.company_application_statuses cas ON cas.id = ca.application_status_id
JOIN portal.application_checklist ac ON ac.application_id = ca.id
JOIN portal.application_checklist_types act ON act.id = ac.application_checklist_entry_type_id AND act.label = 'BUSINESS_PARTNER_NUMBER'
JOIN portal.application_checklist_statuses acs ON acs.id = ac.application_checklist_entry_status_id
ORDER BY ac.date_last_changed DESC NULLS LAST LIMIT 20;
\echo '-- B2 BPN process steps of those applications'
SELECT ca.id AS application_id, pst.label AS step, pss.label AS status, ps.date_last_changed AS changed,
       left(regexp_replace(coalesce(ps.message, ''), '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}', '<email>', 'g'), 300) AS message
FROM portal.company_applications ca
JOIN portal.process_steps ps ON ps.process_id = ca.checklist_process_id
JOIN portal.process_step_types pst ON pst.id = ps.process_step_type_id AND pst.label LIKE '%BUSINESS_PARTNER_NUMBER%'
JOIN portal.process_step_statuses pss ON pss.id = ps.process_step_status_id
ORDER BY ca.id, ps.date_created;
\echo '-- B3 eligible for POST .../registration/application/{id}/trigger-bpn?processTypeId=RETRIGGER_BUSINESS_PARTNER_NUMBER_PUSH'
SELECT ca.id AS application_id
FROM portal.company_applications ca
JOIN portal.application_checklist ac ON ac.application_id = ca.id
JOIN portal.application_checklist_types act ON act.id = ac.application_checklist_entry_type_id AND act.label = 'BUSINESS_PARTNER_NUMBER'
JOIN portal.application_checklist_statuses acs ON acs.id = ac.application_checklist_entry_status_id AND acs.label = 'FAILED'
WHERE EXISTS (SELECT 1 FROM portal.process_steps ps
              JOIN portal.process_step_types pst ON pst.id = ps.process_step_type_id AND pst.label = 'RETRIGGER_BUSINESS_PARTNER_NUMBER_PUSH'
              JOIN portal.process_step_statuses pss ON pss.id = ps.process_step_status_id AND pss.label = 'TODO'
              WHERE ps.process_id = ca.checklist_process_id);
ROLLBACK;
SQL
  echo; echo "Read-only. Retrigger only after the worker uses the verified addresses (--verify) and with separate approval."
  exit 0
fi

step "0 offline gates (incl. R-BPDM) and the reviewed values"
KUBECONFIG=/dev/null RENDER_OUT="$WORK/render.yaml" bash "$HERE/tools/render-release.sh" > "$WORK/render.log" 2>&1 \
  || { grep -E '^FAIL' "$WORK/render.log" | head -10 >&2; die "offline gates failed"; }
"${EP[@]}" values "$WORK/render.yaml" CronJob "$WORKER" "$GATE_ENV" "$POOL_ENV" > "$WORK/want.txt" || die "render lacks the worker BPDM env"
WANT_GATE="$(sed -n "s/^$GATE_ENV=//p" "$WORK/want.txt")"
WANT_POOL="$(sed -n "s/^$POOL_ENV=//p" "$WORK/want.txt")"
echo "OK   gates pass; reviewed values: gate $WANT_GATE · pool $WANT_POOL"

step "1 be293 live BPDM env (read-only)"
for w in "${WORKLOADS[@]}"; do
  k get "$w" -o json > "$WORK/live.json" || die "cannot read $w"
  "${EP[@]}" show "$WORK/live.json" "${BPDM_ENVS[@]}" | grep -v '=<unset>$' | sed "s|^|     $w |"
  if [[ "$w" == "cronjob/$WORKER" ]]; then cp "$WORK/live.json" "$WORK/worker.json"; fi
done

if [[ "$MODE" == "verify" ]]; then
  echo; echo "reviewed (render): gate $WANT_GATE · pool $WANT_POOL; workloads other than the worker change with Helm recovery"
  exit 0
fi

step "2 release26-09 Portal reference (read-only; plain BPDM env of its workloads)"
kshared get deployments,cronjobs -o json | ruby -rjson -e '
  names = ARGV
  JSON.parse($stdin.read)["items"].each do |d|
    pod = d.dig("spec", "jobTemplate", "spec", "template", "spec") || d.dig("spec", "template", "spec") || {}
    (pod["containers"] || []).flat_map { |c| c["env"] || [] }.each do |e|
      puts "     #{d["kind"]}/#{d["metadata"]["name"]} #{e["name"]}=#{e["value"]}" if names.include?(e["name"]) && e.key?("value")
    end
  end' "${BPDM_ENVS[@]}" | sort -u || echo "     (none readable)"

step "3 BPDM Ingress routes and images in $SHARED_NS (read-only)"
kshared get ingress -o json | ruby -rjson -e '
  host = ARGV[0].sub(%r{\Ahttps://}, "")
  JSON.parse($stdin.read)["items"].each do |i|
    a = i.dig("metadata", "annotations") || {}
    (i.dig("spec", "rules") || []).select { |r| r["host"] == host }.each do |r|
      (r.dig("http", "paths") || []).each do |p|
        svc = p.dig("backend", "service")
        puts "     ingress/#{i["metadata"]["name"]} #{p["path"]} (#{p["pathType"]}) -> #{svc["name"]}:#{svc.dig("port", "number") || svc.dig("port", "name")}" \
             " rewrite-target=#{a["nginx.ingress.kubernetes.io/rewrite-target"].inspect} x-forwarded-prefix=#{a["nginx.ingress.kubernetes.io/x-forwarded-prefix"].inspect}"
      end
    end
  end' "$BPDM_HOST"
kshared get deployments -o json | ruby -rjson -e '
  JSON.parse($stdin.read)["items"].select { |d| d["metadata"]["name"].include?("bpdm") }.each do |d|
    d.dig("spec", "template", "spec", "containers").each { |c| puts "     deployment/#{d["metadata"]["name"]} image #{c["image"]}" }
  end'

step "4 live BPDM OpenAPI (anonymous GET over verified TLS)"
for api in gate pool; do
  got=""
  for p in "${DOC_PATHS[@]}"; do
    code="$(curl -sS --proto '=https' --max-time 20 -o "$WORK/$api.json" -w '%{http_code}' "$BPDM_HOST/$api$p" 2>/dev/null)" || code=000
    echo "     GET $BPDM_HOST/$api$p -> $code"
    if [[ "$code" == 200 ]] && ruby "$HERE/tools/bpdm_openapi.rb" --api "$api" < "$WORK/$api.json" > "$WORK/$api.verdict"; then got=1; break; fi
    if [[ -s "$WORK/$api.verdict" ]]; then sed 's/^/     /' "$WORK/$api.verdict"; fi
    if grep -q '(blocks BPN Creation)' "$WORK/$api.verdict" 2>/dev/null; then
      die "the live $api API does not accept/return the fields the pinned backend uses for BPN Creation (see SCHEMA MISMATCH)"
    fi
  done
  [[ -n "$got" ]] || die "could not verify the live $api API from its OpenAPI document"
  sed 's/^/     /' "$WORK/$api.verdict"
done
gate_prefix="$(sed -n 's/^OK gate prefix=\([^ ]*\).*/\1/p' "$WORK/gate.verdict")"
pool_prefix="$(sed -n 's/^OK pool prefix=\([^ ]*\).*/\1/p' "$WORK/pool.verdict")"
[[ "$gate_prefix" == "<none>" ]] && gate_prefix=""
[[ "$pool_prefix" == "<none>" ]] && pool_prefix=""
VERIFIED_GATE="$BPDM_HOST/gate$gate_prefix"
VERIFIED_POOL="$BPDM_HOST/pool$pool_prefix"

step "5 verdict"
echo "     verified gate base: $VERIFIED_GATE   (PUT $VERIFIED_GATE/input/business-partners)"
echo "     verified pool base: $VERIFIED_POOL   (PUT $VERIFIED_POOL/cx-memberships, GET $VERIFIED_POOL/legal-entities/{bpn})"
LIVE_GATE="$("${EP[@]}" show "$WORK/worker.json" "$GATE_ENV" | sed "s/^$GATE_ENV=//")"
LIVE_POOL="$("${EP[@]}" show "$WORK/worker.json" "$POOL_ENV" | sed "s/^$POOL_ENV=//")"
echo "     worker now:         gate $LIVE_GATE · pool $LIVE_POOL"
[[ "$WANT_GATE" == "$VERIFIED_GATE" && "$WANT_POOL" == "$VERIFIED_POOL" ]] \
  || die "reviewed values ($WANT_GATE, $WANT_POOL) differ from the live BPDM API: set bpdm.portalGateApiPath=/gate$gate_prefix and bpdm.poolApiPath=/pool$pool_prefix in values-be293-portal.yaml"
echo "OK   reviewed values match the live BPDM API (host correct; path needs the API version after /gate and /pool)"
if grep -q '^SCHEMA MISMATCH' "$WORK/pool.verdict"; then
  echo "WARN pool schema differs from the pinned backend (not used by BPN Creation; a backend code fix, not configuration):"
  grep '^SCHEMA MISMATCH' "$WORK/pool.verdict" | sed 's/^/       /'
fi
if [[ "$LIVE_GATE" == "$WANT_GATE" && "$LIVE_POOL" == "$WANT_POOL" ]]; then
  echo; echo "NOTHING TO PATCH: the worker already uses the verified addresses."
  exit 0
fi

step "6 server-side dry run (nothing persisted)"
CONTAINER="$("${EP[@]}" container "$WORK/worker.json" "$GATE_ENV")" || die "worker container not found"
PAIRS=("$GATE_ENV=$WANT_GATE" "$POOL_ENV=$WANT_POOL")
"${EP[@]}" patch CronJob "$CONTAINER" "${PAIRS[@]}" > "$WORK/worker.patch"
k patch cronjob "$WORKER" --type=strategic -p "$(cat "$WORK/worker.patch")" --dry-run=server -o json > "$WORK/worker.after.json"
"${EP[@]}" assert "$WORK/worker.json" "$WORK/worker.after.json" "${PAIRS[@]}" || die "dry run rejected"
echo "OK   cronjob/$WORKER: only $GATE_ENV and $POOL_ENV change (next scheduled Job; no restart)"
echo "     patch: $(cat "$WORK/worker.patch")"

if [[ "$MODE" != "execute" ]]; then
  echo; echo "DRY RUN COMPLETE: nothing changed. Re-run with --execute after approval."
  exit 0
fi

step "7 confirmation"
phrase="set BPDM addresses on $WORKER in $CTX/$NS"
{ exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation; nothing changed"
printf 'Type exactly "%s": ' "$phrase" >&3
answer=""; read -r answer <&3 || true; exec 3>&-
[[ "$answer" == "$phrase" ]] || die "confirmation did not match; nothing changed"

step "8 apply"
MUTATE=1
k patch cronjob "$WORKER" --type=strategic -p "$(cat "$WORK/worker.patch")" -o name
MUTATE=0
k get cronjob "$WORKER" -o json > "$WORK/worker.json"
"${EP[@]}" show "$WORK/worker.json" "$GATE_ENV" "$POOL_ENV" | sed 's/^/     /'
echo; echo "DONE. The failed BPN step is NOT retriggered by this script (separate approval; see --bpn-status)."
