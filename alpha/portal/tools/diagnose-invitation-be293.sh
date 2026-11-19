#!/usr/bin/env bash
# Read-only diagnosis of "Invite a New Partner" (process type INVITATION) on Alpha be293. Changes nothing:
# SELECTs only, inside a READ ONLY transaction with default_transaction_read_only=on; kubectl get/logs/exec.
# Prints no credentials and no personal data (no names; e-mail addresses in messages and logs are masked).
#
#   bash tools/diagnose-invitation-be293.sh
#
#   I1 latest invitations: application status, idp alias reserved, Keycloak SA created (yes/no only)
#   I2 every process step of the latest invitation with status and stored error message
#   I3 process lock and the invitation step/status histogram (all invitations)
#   I4 provisioning IdP name sequence (the next central IdP alias is "idp<sequence>")
#   I5 mails queued: invitation templates vs Add User templates, by mailing status
#   I6 processes-worker logs of the 3 newest Jobs, filtered to invitation/Keycloak errors
#
# Source (pinned backend ad459ee7): the invitation e-mails are only queued at the END of the last step
# INVITATION_CREATE_USER (src/processes/Invitation.Executor/InvitationProcessService.cs). Any earlier step that
# is FAILED or stuck in TODO means no mail is ever created; the worker Job still completes successfully.
set -euo pipefail

KUBECONFIG_FILE="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CONTEXT=alpha
NS=be293
WORKER=be293-portal-processes-worker
K=(kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$CONTEXT" -n "$NS")
MASK_EMAIL='s/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/<email>/g'

die() { echo "ABORT: $*" >&2; exit 1; }
[[ -r "$KUBECONFIG_FILE" ]] || die "kubeconfig $KUBECONFIG_FILE not readable"
kubectl --kubeconfig "$KUBECONFIG_FILE" config get-contexts -o name | grep -qx "$CONTEXT" || die "context $CONTEXT missing"

# shellcheck source=lib/be293-db.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/be293-db.sh"

psql_ro <<'SQL'
BEGIN READ ONLY;

\echo '== I1 latest invitations'
SELECT ca.date_created AS created, ci.id AS invitation_id, ci.process_id, cas.label AS application_status,
       ci.idp_name, ci.client_id IS NOT NULL AS sa_client_created, ci.service_account_user_id IS NOT NULL AS sa_user_created
FROM portal.company_invitations ci
JOIN portal.company_applications ca ON ca.id = ci.application_id
JOIN portal.company_application_statuses cas ON cas.id = ca.application_status_id
ORDER BY ca.date_created DESC LIMIT 5;

\echo '== I2 process steps of the latest invitation (oldest first)'
WITH inv AS (
  SELECT ci.process_id FROM portal.company_invitations ci
  JOIN portal.company_applications ca ON ca.id = ci.application_id
  ORDER BY ca.date_created DESC LIMIT 1)
SELECT ps.date_created AS created, ps.date_last_changed AS changed, pst.label AS step, pss.label AS status,
       left(regexp_replace(coalesce(ps.message, ''), '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}', '<email>', 'g'), 600) AS message
FROM portal.process_steps ps
JOIN inv ON ps.process_id = inv.process_id
JOIN portal.process_step_types pst ON pst.id = ps.process_step_type_id
JOIN portal.process_step_statuses pss ON pss.id = ps.process_step_status_id
ORDER BY ps.date_created, ps.process_step_type_id;

\echo '== I3 lock of the latest invitation process, and step/status histogram over all invitations'
SELECT p.id AS process_id, p.lock_expiry_date, p.version
FROM portal.processes p
WHERE p.id = (SELECT ci.process_id FROM portal.company_invitations ci
              JOIN portal.company_applications ca ON ca.id = ci.application_id
              ORDER BY ca.date_created DESC LIMIT 1);
SELECT pst.label AS step, pss.label AS status, count(*)
FROM portal.process_steps ps
JOIN portal.processes p ON p.id = ps.process_id
JOIN portal.process_types pt ON pt.id = p.process_type_id AND pt.label = 'INVITATION'
JOIN portal.process_step_types pst ON pst.id = ps.process_step_type_id
JOIN portal.process_step_statuses pss ON pss.id = ps.process_step_status_id
GROUP BY 1, 2 ORDER BY 1, 2;

\echo '== I4 provisioning IdP name sequence (next central IdP alias = idp<n>)'
SELECT count(*) AS reserved, max(sequence_id) AS highest FROM provisioning.identity_provider_sequences;
SELECT iip.iam_idp_alias AS idp_aliases_known_to_be293 FROM portal.iam_identity_providers iip ORDER BY 1;

\echo '== I5 queued mails by template and status (invitation: RegistrationTemplate/PasswordForRegistrationTemplate)'
SELECT mi.template, ms.label AS mailing_status, count(*)
FROM portal.mailing_informations mi
JOIN portal.mailing_statuses ms ON ms.id = mi.mailing_status_id
GROUP BY 1, 2 ORDER BY 1, 2;

ROLLBACK;
SQL

echo "== I6 processes-worker logs (3 newest Jobs, invitation/Keycloak errors, e-mails masked)"
# Jobs owned by the worker CronJob, newest last (bash 3.2 compatible: no mapfile).
jobs="$("${K[@]}" get jobs --sort-by=.metadata.creationTimestamp --no-headers \
  -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name | awk -v w="$WORKER" '$2 == w {print $1}' | tail -n 3)"
[[ -n "$jobs" ]] || echo "   (no Jobs of cronjob/$WORKER found)"
for j in $jobs; do
  echo "-- job/$j"
  "${K[@]}" logs "job/$j" --tail=2000 2>&1 \
    | grep -Ei 'invitation|INVITATION_|identity-provider|centralidp|sharedidp|status code (4|5)[0-9]{2}|Conflict|Unauthorized|Forbidden|ConfigurationException|exception' \
    | sed -E "$MASK_EMAIL" | tail -n 25 || echo "   (no matching lines)"
done
