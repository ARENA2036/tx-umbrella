#!/usr/bin/env bash
# BE-293-only Keycloak IdP alias prefix (Provisioning:IdpPrefix) on Alpha be293, and the retrigger of the partner
# invitations that failed with "Identity Provider idpN already exists" (shared CentralIDP with release26-09).
#
#   bash tools/idp-prefix-be293.sh              # DEFAULT, read-only: offline gates (D10), live env, DB state,
#                                               # Keycloak alias probe (GET only), server-side dry-run patches
#   bash tools/idp-prefix-be293.sh --execute    # after approval: typed confirmation, then add ONE env entry
#                                               # PROVISIONING__IDPPREFIX to cronjob/processes-worker (next run,
#                                               # no restart) and deploy/administration-service (rolling update)
#   bash tools/idp-prefix-be293.sh --retrigger  # after approval: re-checks everything, then POSTs
#                                               # /api/administration/invitation/{processId}/retrigger-create-central-idp
#                                               # for exactly the eligible failed invitations (same company and
#                                               # application, nothing new created), with your Portal access token
#   bash tools/idp-prefix-be293.sh --verify     # read-only: live env, invitation steps, queued invitation mails
#
# The prefix value is single-sourced from the Helm post-renderer (Be293Retention::IDP_PREFIX), so the live patch
# and the later approved Helm recovery render the same entry (no server-side-apply conflict, no drift).
# Never: apply/replace/delete, Secrets, Helm, database writes, release26-09, Keycloak writes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CTX="alpha"
NS="be293"
WORKER="be293-portal-processes-worker"
ADMIN="be293-portal-administration-service"
ENV_NAME="PROVISIONING__IDPPREFIX"
BACKEND="https://portal-backend-be293.test.tractus-x.com"
ISSUER="https://centralidp.test.tractus-x.com/auth/realms/CX-Central"
CONTROL_ALIAS="idp2"            # exists in CX-Central (the reported collision): proves the probe sees aliases
EXPECT_INVITATIONS="${EXPECT_INVITATIONS:-2}"
PREFIX="$(ruby -r "$HERE/helm-plugins/be293-retention/post-render.rb" -e 'print Be293Retention::IDP_PREFIX')"

MODE="plan"
case "${1:-}" in
  "") ;;
  --execute) MODE="execute" ;;
  --retrigger) MODE="retrigger" ;;
  --verify) MODE="verify" ;;
  *) echo "usage: idp-prefix-be293.sh [--execute|--retrigger|--verify]" >&2; exit 2 ;;
esac

unset KUBECONFIG
umask 077
die() { echo "ABORT: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/be293-idp-prefix.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

K=(kubectl --kubeconfig "$KC" --context "$CTX" -n "$NS" --request-timeout=30s)
# kubectl: read-only verbs; patch only inside the confirmed execute step (MUTATE=1); exec only via psql_ro.
MUTATE=0
k() {
  case "$1" in
    get|rollout) ;;
    patch) [[ "$MUTATE" == 1 || " $* " == *" --dry-run=server "* ]] || die "refused: kubectl patch outside the confirmed execute step" ;;
    *) die "refused: kubectl $1" ;;
  esac
  "${K[@]}" "$@"
}
# shellcheck source=lib/be293-db.sh
source "$HERE/tools/lib/be293-db.sh"

[[ -r "$KC" ]] || die "$KC not readable"
kubectl --kubeconfig "$KC" config get-contexts -o name | grep -qx "$CTX" || die "context $CTX not in $KC"

# Writes <kind>.json and prints "container|current prefix values (comma-separated)" for the one container that
# renders the Provisioning section (PROVISIONING__CENTRALREALM).
inspect() {
  local kind="$1" name="$2"
  k get "$kind" "$name" -o json > "$WORK/$kind.json"
  ruby -rjson -e '
    d = JSON.parse(File.read(ARGV[0]))
    pod = d.dig("spec", "jobTemplate", "spec", "template", "spec") || d.dig("spec", "template", "spec")
    cs = pod["containers"].select { |c| (c["env"] || []).any? { |e| e["name"] == "PROVISIONING__CENTRALREALM" } }
    abort("#{ARGV[1]}: Provisioning env in #{cs.size} containers (expected 1)") unless cs.size == 1
    vals = cs[0]["env"].select { |e| e["name"].casecmp?(ARGV[2]) }.map { |e| e["value"] || "<valueFrom>" }
    print "#{cs[0]["name"]}|#{vals.join(",")}"' "$WORK/$kind.json" "$kind/$name" "$ENV_NAME"
}

# Prints the value of one plain env entry of the worker container (from cronjob.json).
worker_env() {
  ruby -rjson -e '
    d = JSON.parse(File.read(ARGV[0]))
    c = d.dig("spec", "jobTemplate", "spec", "template", "spec", "containers").find { |x| x["name"] == ARGV[1] }
    e = (c["env"] || []).find { |x| x["name"] == ARGV[2] } or abort("worker env #{ARGV[2]} missing")
    print(e["value"] || (r = e.dig("valueFrom", "secretKeyRef")) && "secret:#{r["name"]}/#{r["key"]}")' "$WORK/cronjob.json" "$1" "$2"
}

check_live_prefix() { # $1 = required state: absent-or-set | set
  local wc wv ac av
  IFS='|' read -r wc wv <<<"$(inspect cronjob "$WORKER")"
  IFS='|' read -r ac av <<<"$(inspect deployment "$ADMIN")"
  WORKER_CONTAINER="$wc"; ADMIN_CONTAINER="$ac"
  echo "     cronjob/$WORKER    [$wc] $ENV_NAME=${wv:-<unset, backend default idp>}"
  echo "     deployment/$ADMIN [$ac] $ENV_NAME=${av:-<unset, backend default idp>}"
  for v in "$wv" "$av"; do
    [[ -z "$v" || "$v" == "$PREFIX" ]] || die "a different $ENV_NAME ('$v') is already set live: review before changing it"
    [[ "$1" != set || "$v" == "$PREFIX" ]] || die "$ENV_NAME is not live on both workloads yet (run --execute first)"
  done
  [[ "$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("spec", "suspend") == true' "$WORK/cronjob.json")" == false ]] \
    || die "cronjob/$WORKER is suspended: no invitation step would run"
}

# Read-only DB state. Rows: process_id|failed_central|retrigger_todo|other_todo|later_steps|no_idp_name|unlocked
db_state() {
  psql_ro -A -t -F '|' <<'SQL'
BEGIN READ ONLY;
SELECT 'SEQ', coalesce(max(sequence_id), 0) FROM provisioning.identity_provider_sequences;
SELECT ci.process_id,
       bool_or(pst.label = 'INVITATION_CREATE_CENTRAL_IDP' AND pss.label = 'FAILED'),
       bool_or(pst.label = 'RETRIGGER_INVITATION_CREATE_CENTRAL_IDP' AND pss.label = 'TODO'),
       count(*) FILTER (WHERE pss.label = 'TODO' AND pst.label <> 'RETRIGGER_INVITATION_CREATE_CENTRAL_IDP'),
       count(*) FILTER (WHERE pst.label NOT IN ('INVITATION_CREATE_CENTRAL_IDP', 'RETRIGGER_INVITATION_CREATE_CENTRAL_IDP')),
       ci.idp_name IS NULL,
       coalesce(p.lock_expiry_date < now(), true)
FROM portal.company_invitations ci
JOIN portal.processes p ON p.id = ci.process_id
JOIN portal.process_steps ps ON ps.process_id = ci.process_id
JOIN portal.process_step_types pst ON pst.id = ps.process_step_type_id
JOIN portal.process_step_statuses pss ON pss.id = ps.process_step_status_id
GROUP BY ci.process_id, ci.idp_name, p.lock_expiry_date
ORDER BY ci.process_id;
ROLLBACK;
SQL
}

load_db_state() {
  db_state > "$WORK/db.txt" || die "read-only database query failed"
  SEQ="$(sed -n 's/^SEQ|//p' "$WORK/db.txt")"
  [[ "$SEQ" =~ ^[0-9]+$ ]] || die "IdP sequence unreadable"
  ELIGIBLE="$(grep -E '^[0-9a-f-]{36}\|t\|t\|0\|0\|t\|t$' "$WORK/db.txt" | cut -d'|' -f1 || true)"
  echo "     provisioning IdP sequence: highest=$SEQ (next alias ${PREFIX}$((SEQ + 1)))"
  echo "     invitations (process_id | CENTRAL_IDP failed | retrigger TODO | other TODO | later steps | no idp_name | unlocked):"
  grep -E '^[0-9a-f-]{36}\|' "$WORK/db.txt" | sed 's/^/       /'
  N_ELIGIBLE="$(grep -c . <<<"$ELIGIBLE" || true)"
  echo "     eligible for retrigger-create-central-idp: $N_ELIGIBLE (expected $EXPECT_INVITATIONS)"
}

keycloak_probe() {
  local cref sref upto=$((SEQ + 20))
  cref="$(worker_env "$WORKER_CONTAINER" KEYCLOAK__CENTRAL__CLIENTSECRET)"
  sref="$(worker_env "$WORKER_CONTAINER" KEYCLOAK__SHARED__CLIENTSECRET)"
  [[ "$cref" == secret:*/* && "$sref" == secret:*/* && "${cref%/*}" == "${sref%/*}" ]] || die "worker Keycloak secrets are not refs to one Secret"
  # The Secret JSON goes straight into the checker's stdin; it is never printed or stored.
  if ! k get secret "$(cut -d/ -f1 <<<"${cref#secret:}")" -o json | ruby "$HERE/tools/keycloak_alias_check.rb" \
    --central-url "$(worker_env "$WORKER_CONTAINER" KEYCLOAK__CENTRAL__CONNECTIONSTRING)" \
    --central-auth-realm "$(worker_env "$WORKER_CONTAINER" KEYCLOAK__CENTRAL__AUTHREALM)" \
    --central-client "$(worker_env "$WORKER_CONTAINER" KEYCLOAK__CENTRAL__CLIENTID)" \
    --shared-url "$(worker_env "$WORKER_CONTAINER" KEYCLOAK__SHARED__CONNECTIONSTRING)" \
    --shared-auth-realm "$(worker_env "$WORKER_CONTAINER" KEYCLOAK__SHARED__AUTHREALM)" \
    --shared-client "$(worker_env "$WORKER_CONTAINER" KEYCLOAK__SHARED__CLIENTID)" \
    --central-realm "$(worker_env "$WORKER_CONTAINER" PROVISIONING__CENTRALREALM)" \
    --sa-prefix "$(worker_env "$WORKER_CONTAINER" PROVISIONING__SERVICEACCOUNTCLIENTPREFIX)" \
    --central-key "${cref##*/}" --shared-key "${sref##*/}" \
    --prefix "$PREFIX" --to "$upto" --control-alias "$CONTROL_ALIAS" | sed 's/^/     /'; then
    die "Keycloak alias probe did not prove ${PREFIX}1..$upto unused"
  fi
}

# Strategic merge patch adding the one env entry to the named container ($1) of a cronjob or deployment ($2).
patch_json() {
  case "$2" in
    cronjob) ruby -rjson -e 'puts JSON.generate("spec" => { "jobTemplate" => { "spec" => { "template" => { "spec" => { "containers" => [
               { "name" => ARGV[0], "env" => [{ "name" => ARGV[1], "value" => ARGV[2] }] }] } } } } })' "$1" "$ENV_NAME" "$PREFIX" ;;
    deployment) ruby -rjson -e 'puts JSON.generate("spec" => { "template" => { "spec" => { "containers" => [
               { "name" => ARGV[0], "env" => [{ "name" => ARGV[1], "value" => ARGV[2] }] }] } } })' "$1" "$ENV_NAME" "$PREFIX" ;;
  esac
}

# The dry-run result must equal the live spec plus exactly this one env entry.
assert_only_prefix_added() { # $1 kind, $2 dry-run json file
  ruby -rjson -e '
    live, after = ARGV[0..1].map { |f| JSON.parse(File.read(f))["spec"] }
    name, value = ARGV[2..3]
    pods = ->(s) { (s.dig("jobTemplate", "spec", "template", "spec") || s.dig("template", "spec"))["containers"] }
    added = pods.(after).flat_map { |c| (c["env"] || []).select { |e| e["name"] == name } }
    abort("dry run: #{name} entries #{added.inspect} != one plain #{value.inspect}") unless added == [{ "name" => name, "value" => value }]
    pods.(after).each { |c| c["env"]&.reject! { |e| e["name"] == name } }
    pods.(live).each { |c| c["env"]&.reject! { |e| e["name"] == name } }
    abort("dry run changes more than #{name}") unless live == after' "$WORK/$1.json" "$2" "$ENV_NAME" "$PREFIX"
}

if [[ "$MODE" == "verify" ]]; then
  step "verify (read-only)"
  check_live_prefix absent-or-set
  k rollout status "deployment/$ADMIN" --timeout=10s | sed 's/^/     /'
  psql_ro <<'SQL'
BEGIN READ ONLY;
\echo '     invitation steps (newest invitations first)'
SELECT ci.process_id, ci.idp_name, pst.label AS step, pss.label AS status, ps.date_last_changed AS changed,
       left(regexp_replace(coalesce(ps.message, ''), '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}', '<email>', 'g'), 200) AS message
FROM portal.company_invitations ci
JOIN portal.company_applications ca ON ca.id = ci.application_id
JOIN portal.process_steps ps ON ps.process_id = ci.process_id
JOIN portal.process_step_types pst ON pst.id = ps.process_step_type_id
JOIN portal.process_step_statuses pss ON pss.id = ps.process_step_status_id
ORDER BY ca.date_created DESC, ps.date_created;
\echo '     invitation mails'
SELECT mi.template, ms.label AS status, count(*) FROM portal.mailing_informations mi
JOIN portal.mailing_statuses ms ON ms.id = mi.mailing_status_id
WHERE mi.template IN ('RegistrationTemplate', 'PasswordForRegistrationTemplate') GROUP BY 1, 2 ORDER BY 1, 2;
ROLLBACK;
SQL
  exit 0
fi

step "0 offline gates (release render incl. D10 IdP prefix)"
KUBECONFIG=/dev/null bash "$HERE/tools/render-release.sh" > "$WORK/render.log" 2>&1 \
  || { grep -E '^FAIL' "$WORK/render.log" | head -10 >&2; die "offline gates failed"; }
grep -q '^RETENTION RESULT PASS' "$WORK/render.log" || die "retention gates did not report PASS"
echo "OK   release render passes all gates; prefix '$PREFIX' rendered on $WORKER and $ADMIN only"

step "1 live workloads (read-only)"
check_live_prefix "$([[ "$MODE" == retrigger ]] && echo set || echo absent-or-set)"
k rollout status "deployment/$ADMIN" --timeout=10s >/dev/null || die "deployment/$ADMIN is not fully rolled out"
echo "OK   $ADMIN rolled out; worker CronJob active"

step "2 database (read-only transaction)"
load_db_state

step "3 shared Keycloak alias probe (read-only GETs with the worker's own service accounts)"
keycloak_probe

if [[ "$MODE" == "retrigger" ]]; then
  step "4 retrigger preconditions"
  [[ "$N_ELIGIBLE" == "$EXPECT_INVITATIONS" ]] || die "eligible invitations $N_ELIGIBLE != expected $EXPECT_INVITATIONS (EXPECT_INVITATIONS=...)"
  # A worker Job created before the prefix patch still runs with the default "idp" and must not pick up a step.
  stale="$(k get jobs -o json | ruby -rjson -e '
    w, n = ARGV
    JSON.parse($stdin.read)["items"].each do |j|
      next unless (j.dig("metadata", "ownerReferences") || []).any? { |o| o["kind"] == "CronJob" && o["name"] == w }
      next unless j.dig("status", "active").to_i.positive?
      env = j.dig("spec", "template", "spec", "containers").flat_map { |c| c["env"] || [] }
      puts j["metadata"]["name"] unless env.any? { |e| e["name"] == n && e["value"] == ARGV[2] }
    end' "$WORKER" "$ENV_NAME" "$PREFIX")"
  [[ -z "$stale" ]] || die "worker Job(s) without the prefix still running: $stale (wait for them to finish)"
  echo "OK   $N_ELIGIBLE eligible invitations; no running worker Job without the prefix"
  echo "     next aliases: ${PREFIX}$((SEQ + 1)) .. ${PREFIX}$((SEQ + N_ELIGIBLE)) (each retry consumes one sequence number)"

  step "5 confirmation and Portal access token"
  phrase="retrigger $N_ELIGIBLE failed be293 invitations"
  { exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation; nothing changed"
  printf 'Type exactly "%s": ' "$phrase" >&3
  answer=""; read -r answer <&3 || true
  [[ "$answer" == "$phrase" ]] || die "confirmation did not match; nothing changed"
  printf 'Paste the Portal access token of a CX Admin with invite_new_partner (input hidden): ' >&3
  token=""; read -rs token <&3 || true; printf '\n' >&3; exec 3>&-
  printf '%s' "$token" | ruby -rjson -rbase64 -e '
    t = $stdin.read.strip; iss, now = ARGV[0], Time.now.to_i
    parts = t.split(".")
    abort("token is not a JWT") unless parts.size == 3
    p = JSON.parse(Base64.urlsafe_decode64(parts[1] + "=" * (-parts[1].size % 4)))
    abort("token issuer #{p["iss"]} != #{iss}") unless p["iss"] == iss
    abort("token expires in #{p["exp"].to_i - now}s (need > 120s)") unless p["exp"].to_i - now > 120
    roles = (p["resource_access"] || {}).values.flat_map { |v| v["roles"] || [] }
    abort("token lacks role invite_new_partner") unless roles.include?("invite_new_partner")
    puts "OK   token: issuer CX-Central, role invite_new_partner, valid for #{p["exp"].to_i - now}s"' "$ISSUER" \
    || die "token rejected; nothing changed"

  step "6 retrigger (Portal API, one call per invitation)"
  for pid in $ELIGIBLE; do
    code="$(printf 'url = "%s/api/administration/invitation/%s/retrigger-create-central-idp"\nrequest = "POST"\nheader = "Authorization: Bearer %s"\nheader = "Content-Length: 0"\n' \
              "$BACKEND" "$pid" "$token" | curl -sS --proto =https --max-time 30 -o "$WORK/resp" -w '%{http_code}' --config -)" || code=000
    [[ "$code" == 204 ]] || { token=""; die "retrigger $pid -> HTTP $code (stopped; earlier calls stay done)"; }
    echo "OK   $pid -> 204 (RETRIGGER step DONE, INVITATION_CREATE_CENTRAL_IDP scheduled)"
  done
  token=""
  echo; echo "DONE. The worker runs every 5 minutes. Then: bash tools/idp-prefix-be293.sh --verify"
  echo "     expect all 10 INVITATION_* steps DONE, idp_name ${PREFIX}<n>, RegistrationTemplate + PasswordForRegistrationTemplate SENT,"
  echo "     and both mails per invitation in smtp4dev (port-forward deploy/be293-smtp4dev 8085:8080 -> http://localhost:8085)."
  exit 0
fi

step "4 server-side dry runs (nothing persisted)"
patch_json "$WORKER_CONTAINER" cronjob > "$WORK/worker.patch"
patch_json "$ADMIN_CONTAINER" deployment > "$WORK/admin.patch"
k patch cronjob "$WORKER" --type=strategic -p "$(cat "$WORK/worker.patch")" --dry-run=server -o json > "$WORK/cronjob.after.json"
k patch deployment "$ADMIN" --type=strategic -p "$(cat "$WORK/admin.patch")" --dry-run=server -o json > "$WORK/deployment.after.json"
assert_only_prefix_added cronjob "$WORK/cronjob.after.json"
assert_only_prefix_added deployment "$WORK/deployment.after.json"
echo "OK   cronjob/$WORKER: only $ENV_NAME=$PREFIX added (applies to the next scheduled Job; no restart)"
echo "OK   deployment/$ADMIN: only $ENV_NAME=$PREFIX added (rolling update of its pods)"
echo "     patch cronjob:    $(cat "$WORK/worker.patch")"
echo "     patch deployment: $(cat "$WORK/admin.patch")"

if [[ "$MODE" != "execute" ]]; then
  echo; echo "DRY RUN COMPLETE: nothing changed. Re-run with --execute after approval; --retrigger is a separate approval."
  exit 0
fi

step "5 confirmation"
phrase="set IdP prefix $PREFIX in $CTX/$NS"
{ exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation; nothing changed"
printf 'Type exactly "%s": ' "$phrase" >&3
answer=""; read -r answer <&3 || true; exec 3>&-
[[ "$answer" == "$phrase" ]] || die "confirmation did not match; nothing changed"

step "6 apply"
MUTATE=1
k patch cronjob "$WORKER" --type=strategic -p "$(cat "$WORK/worker.patch")" -o name
k patch deployment "$ADMIN" --type=strategic -p "$(cat "$WORK/admin.patch")" -o name
MUTATE=0
k rollout status "deployment/$ADMIN" --timeout=600s || die "deployment/$ADMIN rollout not complete (inspect; do not retrigger)"
check_live_prefix set
echo; echo "DONE. Next (separate approval): bash tools/idp-prefix-be293.sh --retrigger"
