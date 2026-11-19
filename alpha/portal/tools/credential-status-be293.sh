#!/usr/bin/env bash
# Read-only diagnosis of the BPN / Membership credential checklist state of one application on Alpha be293.
# Changes nothing: SELECTs only, inside a READ ONLY transaction with default_transaction_read_only=on;
# kubectl get/logs/exec. Prints no credentials; e-mail addresses in messages and logs are masked.
#
#   bash tools/credential-status-be293.sh [application-id]    # default: the reference application
#
#   C1 application, checklist process, process lock and version
#   C2 checklist entries IDENTITY_WALLET, BPNL_CREDENTIAL, MEMBERSHIP_CREDENTIAL (status, comment)
#   C3 every REQUEST_ / AWAIT_ / RETRIGGER_REQUEST_ credential step (status, stored message)
#   C4 verdict per credential, in particular the BE-293 mismatch: latest AWAIT step FAILED, entry still
#      IN_PROGRESS, RETRIGGER step TODO (the manual retrigger then answers 409 because it requires FAILED)
#   C5 processes-worker logs of the 3 newest Jobs, filtered to this application's credential lines
#
# Background: IdentityHubCredentialAwaitBusinessLogic (backend ad459ee7 / 274096a9) failed the await step
# without setting the checklist entry FAILED. Fixed on fix/BE-293-identityhub-await-checklist-failed; an
# application already in the mismatch state is not repaired by the fix (its await step is no longer active).
set -euo pipefail

KUBECONFIG_FILE="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CONTEXT=alpha
NS=be293
WORKER=be293-portal-processes-worker
APP="${1:-c5182556-2376-4afd-9131-15423e8e5e3e}"
K=(kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" -n "$NS")
MASK_EMAIL='s/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/<email>/g'

die() { echo "ABORT: $*" >&2; exit 1; }
# The id reaches SQL only as a psql variable (:'app'), but reject anything that is not a UUID up front.
[[ "$APP" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "usage: credential-status-be293.sh [application-uuid]" >&2; exit 2; }
[[ -r "$KUBECONFIG_FILE" ]] || die "kubeconfig $KUBECONFIG_FILE not readable"
kubectl --kubeconfig "$KUBECONFIG_FILE" config get-contexts -o name | grep -qx "$CONTEXT" || die "context $CONTEXT missing"

# shellcheck source=lib/be293-db.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/be293-db.sh"

echo "application $APP"
psql_ro -v app="$APP" <<'SQL'
BEGIN READ ONLY;

\echo '== C1 application and checklist process'
SELECT ca.id AS application_id, cas.label AS application_status, ca.checklist_process_id AS process_id,
       p.lock_expiry_date, coalesce(p.lock_expiry_date > now(), false) AS locked, p.version
FROM portal.company_applications ca
JOIN portal.company_application_statuses cas ON cas.id = ca.application_status_id
LEFT JOIN portal.processes p ON p.id = ca.checklist_process_id
WHERE ca.id = :'app'::uuid;

\echo '== C2 checklist entries'
SELECT act.label AS entry, acs.label AS status, ac.date_last_changed AS changed,
       left(regexp_replace(coalesce(ac.comment, ''), '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}', '<email>', 'g'), 200) AS comment
FROM portal.application_checklist ac
JOIN portal.application_checklist_types act ON act.id = ac.application_checklist_entry_type_id
JOIN portal.application_checklist_statuses acs ON acs.id = ac.application_checklist_entry_status_id
WHERE ac.application_id = :'app'::uuid
  AND act.label IN ('IDENTITY_WALLET', 'BPNL_CREDENTIAL', 'MEMBERSHIP_CREDENTIAL')
ORDER BY act.id;

\echo '== C3 credential process steps'
SELECT ps.date_created AS created, ps.date_last_changed AS changed, pst.label AS step, pss.label AS status,
       left(regexp_replace(coalesce(ps.message, ''), '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}', '<email>', 'g'), 300) AS message
FROM portal.company_applications ca
JOIN portal.process_steps ps ON ps.process_id = ca.checklist_process_id
JOIN portal.process_step_types pst ON pst.id = ps.process_step_type_id
JOIN portal.process_step_statuses pss ON pss.id = ps.process_step_status_id
WHERE ca.id = :'app'::uuid
  AND pst.label IN ('REQUEST_BPN_CREDENTIAL', 'AWAIT_BPN_CREDENTIAL_RESPONSE', 'RETRIGGER_REQUEST_BPN_CREDENTIAL',
                    'REQUEST_MEMBERSHIP_CREDENTIAL', 'AWAIT_MEMBERSHIP_CREDENTIAL_RESPONSE', 'RETRIGGER_REQUEST_MEMBERSHIP_CREDENTIAL')
ORDER BY ps.date_created;

\echo '== C4 verdict per credential'
WITH app AS (
  SELECT ca.id, ca.checklist_process_id AS pid, coalesce(p.lock_expiry_date > now(), false) AS locked
  FROM portal.company_applications ca
  LEFT JOIN portal.processes p ON p.id = ca.checklist_process_id
  WHERE ca.id = :'app'::uuid
), cred(entry, request, await, retrigger) AS (
  VALUES ('BPNL_CREDENTIAL', 'REQUEST_BPN_CREDENTIAL', 'AWAIT_BPN_CREDENTIAL_RESPONSE', 'RETRIGGER_REQUEST_BPN_CREDENTIAL'),
         ('MEMBERSHIP_CREDENTIAL', 'REQUEST_MEMBERSHIP_CREDENTIAL', 'AWAIT_MEMBERSHIP_CREDENTIAL_RESPONSE', 'RETRIGGER_REQUEST_MEMBERSHIP_CREDENTIAL')
), steps AS (
  SELECT ps.process_id, pst.label AS step, pss.label AS status, ps.date_created
  FROM portal.process_steps ps
  JOIN portal.process_step_types pst ON pst.id = ps.process_step_type_id
  JOIN portal.process_step_statuses pss ON pss.id = ps.process_step_status_id
  WHERE ps.process_id = (SELECT pid FROM app)
), s AS (
  SELECT c.entry, acs.label AS entry_status, app.locked,
         (SELECT st.status FROM steps st WHERE st.step = c.await ORDER BY st.date_created DESC LIMIT 1) AS last_await,
         EXISTS (SELECT 1 FROM steps st WHERE st.step = c.retrigger AND st.status = 'TODO') AS retrigger_todo,
         EXISTS (SELECT 1 FROM steps st WHERE st.step IN (c.request, c.await) AND st.status = 'TODO') AS active
  FROM cred c
  CROSS JOIN app
  LEFT JOIN portal.application_checklist_types act ON act.label = c.entry
  LEFT JOIN portal.application_checklist ac ON ac.application_id = app.id AND ac.application_checklist_entry_type_id = act.id
  LEFT JOIN portal.application_checklist_statuses acs ON acs.id = ac.application_checklist_entry_status_id
)
SELECT entry, entry_status, last_await, retrigger_todo, active, locked,
       CASE
         WHEN entry_status = 'IN_PROGRESS' AND last_await = 'FAILED' AND retrigger_todo AND NOT active AND NOT locked
           THEN 'MISMATCH: reconciliation candidate (see runbook section C)'
         WHEN entry_status = 'IN_PROGRESS' AND last_await = 'FAILED'
           THEN 'MISMATCH but not eligible (locked, active step or no retrigger step): investigate'
         WHEN entry_status = 'FAILED' AND retrigger_todo THEN 'RETRIGGERABLE: entry FAILED, retrigger step TODO'
         WHEN active THEN 'IN FLIGHT: request or await step TODO'
         WHEN entry_status = 'DONE' THEN 'DONE'
         WHEN entry_status = 'TO_DO' AND last_await IS NULL THEN 'NOT STARTED'
         ELSE 'OTHER: read C2/C3'
       END AS verdict
FROM s
ORDER BY entry;

ROLLBACK;
SQL

echo "== C5 processes-worker logs (3 newest Jobs, this application's credential lines, e-mails masked)"
# Jobs owned by the worker CronJob, newest last (bash 3.2 compatible: no mapfile).
jobs="$("${K[@]}" get jobs --sort-by=.metadata.creationTimestamp --no-headers \
  -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name | awk -v w="$WORKER" '$2 == w {print $1}' | tail -n 3)"
[[ -n "$jobs" ]] || echo "   (no Jobs of cronjob/$WORKER found)"
for j in $jobs; do
  echo "-- job/$j"
  "${K[@]}" logs "job/$j" --tail=5000 2>&1 \
    | grep -F "$APP" | grep -Ei 'credential' \
    | sed -E "$MASK_EMAIL" | tail -n 25 || echo "   (no matching lines)"
done
echo
echo "Read-only: nothing was changed. Reconciliation (runbook section C) needs separate approval."
