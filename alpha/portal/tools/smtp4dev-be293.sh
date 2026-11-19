#!/usr/bin/env bash
# smtp4dev test mail sink for the BE-293 Portal on Alpha (namespace be293 only).
#
#   bash tools/smtp4dev-be293.sh --pin       # resolve the rnwood/smtp4dev:3.15.0 index digest (anonymous registry
#                                            # read) and write it into smtp4dev-be293.alpha.yaml. No cluster access.
#   bash tools/smtp4dev-be293.sh             # DEFAULT: offline gates + read-only live checks + server-side dry runs
#   bash tools/smtp4dev-be293.sh --execute   # after approval: typed confirmation, then
#                                            #   1. kubectl create the sink (PVC, Deployment, Service, NetworkPolicy)
#                                            #   2. patch ONLY MAILINGSERVICE__MAIL__SMTPHOST/SMTPPORT/SMTPUSER on the
#                                            #      processes-worker CronJob (next run uses the sink; no restart)
#                                            #   3. one SMTP probe Job, then read-only check that smtp4dev captured it
#   bash tools/smtp4dev-be293.sh --verify    # read-only: sink Ready, worker env, captured messages (port-forward)
#
# Never: apply/replace/delete, Secrets, Helm, release26-09, Keycloak, PostgreSQL. `create` fails if an object
# already exists, so nothing is overwritten. The administration-service shared-realm SMTP settings are NOT
# patched live (that would restart it); they take effect with the approved Helm recovery (values overlay).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CTX="alpha"
NS="be293"
MANIFEST="${SMTP4DEV_MANIFEST:-$HERE/smtp4dev-be293.alpha.yaml}"
OVERLAY="$HERE/values-be293-portal.alpha-smtp4dev.yaml"
NAME="be293-smtp4dev"
WORKER="be293-portal-processes-worker"
CONFIRM_PHRASE="deploy smtp4dev in $CTX/$NS"
UI_LOCAL_PORT=8085

MODE="plan"
case "${1:-}" in
  "") ;;
  --pin) MODE="pin" ;;
  --execute) MODE="execute" ;;
  --verify) MODE="verify" ;;
  *) echo "usage: smtp4dev-be293.sh [--pin|--execute|--verify]" >&2; exit 2 ;;
esac

unset KUBECONFIG
umask 077
die() { echo "ABORT: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# kubectl: read-only verbs always; create/patch only in execute mode after the confirmation (MUTATE=1).
MUTATE=0
k() {
  case "$1" in
    get|wait|rollout|port-forward|auth) ;;
    create|patch) [[ "$MUTATE" == 1 ]] || die "refused: kubectl $1 outside the confirmed execute step" ;;
    *) die "refused: kubectl $1" ;;
  esac
  kubectl --kubeconfig "$KC" --context "$CTX" --request-timeout=30s "$@"
}

if [[ "$MODE" == "pin" ]]; then
  step "pin rnwood/smtp4dev:3.15.0 (anonymous Docker Hub read)"
  token="$(curl -fsS --proto =https --max-time 20 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:rnwood/smtp4dev:pull" \
           | ruby -rjson -e 'print JSON.parse($stdin.read).fetch("token")')" || die "registry token request failed"
  hdr="$(mktemp "${TMPDIR:-/tmp}/smtp4dev-pin.XXXXXX")"; trap 'rm -f "$hdr"' EXIT
  accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json'
  index="$(curl -fsS --proto =https --max-time 20 -H "Authorization: Bearer $token" -H "Accept: $accept" \
           -D "$hdr" https://registry-1.docker.io/v2/rnwood/smtp4dev/manifests/3.15.0)" \
    || die "manifest request failed"
  digest="$(tr -d '\r' < "$hdr" | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: //p')"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "no valid digest in registry response"
  # Integrity: the served index must hash to the digest, and contain linux/amd64.
  [[ "sha256:$(printf '%s' "$index" | shasum -a 256 | cut -d' ' -f1)" == "$digest" ]] || die "index content does not match its digest"
  ruby -rjson -e 'm = JSON.parse(ARGV[0])["manifests"] || []; exit(m.any? { |x| x.dig("platform","os") == "linux" && x.dig("platform","architecture") == "amd64" } ? 0 : 1)' "$index" \
    || die "index has no linux/amd64 image"
  ruby -e 'f, d = ARGV; s = File.read(f)
    n = s.sub!(/(rnwood\/smtp4dev:3\.15\.0@)sha256:(<<PIN:[A-Z0-9_.]+>>|\h{64})/) { "#{$1}#{d}" }
    abort("image line not found") unless n; File.write(f, s)' "$MANIFEST" "$digest"
  echo "OK   rnwood/smtp4dev:3.15.0 -> $digest (linux/amd64 present) written to $(basename "$MANIFEST")"
  echo "     Cross-check once at https://hub.docker.com/layers/rnwood/smtp4dev/3.15.0 before approving."
  exit 0
fi

LOG="$(mktemp "${TMPDIR:-/tmp}/be293-smtp4dev.XXXXXX")"
PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null; rm -f "$LOG"; }
trap cleanup EXIT

# Reads smtp4dev's message list through a temporary localhost port-forward; prints the subjects only.
captured_subjects() {
  local port=$(( 20000 + RANDOM % 20000 ))
  k port-forward "deploy/$NAME" -n "$NS" "$port:8080" >/dev/null 2>&1 & PF_PID=$!
  local i
  for i in $(seq 1 20); do curl -fsS --max-time 2 "http://127.0.0.1:$port/" -o /dev/null 2>/dev/null && break; sleep 0.5; done
  curl -fsS --max-time 10 "http://127.0.0.1:$port/api/messages?page=1&pageSize=50" 2>/dev/null \
    | ruby -rjson -e 'j = JSON.parse($stdin.read); list = j.is_a?(Array) ? j : (j["results"] || []); list.each { |m| puts m["subject"] }' \
    || echo "<api unreadable>"
  kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null || true; PF_PID=""
}

worker_env() {
  k get cronjob "$WORKER" -n "$NS" -o json | ruby -rjson -e '
    c = JSON.parse($stdin.read).dig("spec","jobTemplate","spec","template","spec","containers").first
    (c["env"] || []).each { |e| puts "#{e["name"]}=#{e["value"]}" if e["name"] =~ /\AMAILINGSERVICE__MAIL__(SMTPHOST|SMTPPORT|SMTPUSER)\z/ }'
}

if [[ "$MODE" == "verify" ]]; then
  step "verify (read-only)"
  k rollout status "deploy/$NAME" -n "$NS" --timeout=60s
  k get svc "$NAME" -n "$NS" -o jsonpath='{.spec.type} {.spec.clusterIP} ports={.spec.ports[*].port}{"\n"}'
  worker_env
  echo "captured subjects:"; captured_subjects | sed 's/^/  /'
  echo; echo "UI: kubectl --kubeconfig $KC --context $CTX -n $NS port-forward deploy/$NAME $UI_LOCAL_PORT:8080  -> http://localhost:$UI_LOCAL_PORT"
  exit 0
fi

step "0 target and offline gates"
[[ -r "$KC" ]] || die "$KC not readable"
kubectl --kubeconfig "$KC" config get-contexts -o name | grep -qx "$CTX" || die "context $CTX not in $KC"
KUBECONFIG=/dev/null SMTP4DEV_MANIFEST="$MANIFEST" bash "$HERE/tools/render-release.sh" > "$LOG" 2>&1 \
  || { grep -E '^FAIL' "$LOG" | head -10 >&2; die "offline gates failed (pin the image first: --pin)"; }
echo "OK   release gates + smtp4dev gates S1-S9 pass (manifest and Portal mail render)"
IMAGE="$(ruby -ryaml -e 'd = YAML.load_stream(File.read(ARGV[0])).compact.find { |x| x["kind"] == "Deployment" }; print d["spec"]["template"]["spec"]["containers"][0]["image"]' "$MANIFEST")"
HOST="$(ruby -ryaml -e 'print YAML.safe_load(File.read(ARGV[0])).dig("backend","mailing","host")' "$OVERLAY")"
PORT="$(ruby -ryaml -e 'print YAML.safe_load(File.read(ARGV[0])).dig("backend","mailing","port")' "$OVERLAY")"
USER_NAME="$(ruby -ryaml -e 'print YAML.safe_load(File.read(ARGV[0])).dig("backend","mailing","user")' "$OVERLAY")"

step "1 read-only live checks"
for obj in "pvc/$NAME-data" "deployment/$NAME" "service/$NAME" "networkpolicy/$NAME-smtp-ingress"; do
  [[ -z "$(k get "$obj" -n "$NS" --ignore-not-found -o name)" ]] || die "$obj already exists: nothing is overwritten (use --verify)"
done
echo "OK   no smtp4dev object exists yet"
[[ "$(k get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' | grep -c '^true$')" == 1 ]] \
  || die "expected exactly one default StorageClass for the mailbox PVC"
echo "OK   one default StorageClass"
echo "current processes-worker mail target (non-secret):"; worker_env | sed 's/^/  /'
container="$(k get cronjob "$WORKER" -n "$NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].name}')"
[[ "$container" == "$WORKER" ]] || die "unexpected worker container name '$container'"
PATCH="$(ruby -rjson -e 'n, h, p, u = ARGV
  puts JSON.generate("spec" => { "jobTemplate" => { "spec" => { "template" => { "spec" => { "containers" => [
    { "name" => n, "env" => [{ "name" => "MAILINGSERVICE__MAIL__SMTPHOST", "value" => h },
                             { "name" => "MAILINGSERVICE__MAIL__SMTPPORT", "value" => p },
                             { "name" => "MAILINGSERVICE__MAIL__SMTPUSER", "value" => u }] }] } } } } })' \
  "$container" "$HOST" "$PORT" "$USER_NAME")"

step "2 server-side dry runs (nothing persisted)"
MUTATE=1
k create --dry-run=server -f "$MANIFEST" -o name | sed 's/^/  would create /'
after="$(k patch cronjob "$WORKER" -n "$NS" --type=strategic -p "$PATCH" --dry-run=server -o json | ruby -rjson -e '
  c = JSON.parse($stdin.read).dig("spec","jobTemplate","spec","template","spec","containers").first
  puts (c["env"] || []).select { |e| e["name"].start_with?("MAILINGSERVICE__MAIL__SMTP") }.map { |e| e["valueFrom"] ? "#{e["name"]}=<secretRef>" : "#{e["name"]}=#{e["value"]}" }')"
MUTATE=0
echo "$after" | sed 's/^/  worker env after patch: /'
grep -qx "MAILINGSERVICE__MAIL__SMTPHOST=$HOST" <<<"$after" || die "dry-run patch did not set the sink host"
grep -qx 'MAILINGSERVICE__MAIL__SMTPPASSWORD=<secretRef>' <<<"$after" || die "dry-run patch changed the password reference"

if [[ "$MODE" != "execute" ]]; then
  echo; echo "DRY RUN COMPLETE: nothing changed. Re-run with --execute after approval."
  exit 0
fi

step "3 confirmation"
{ exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation; nothing changed"
printf 'Type exactly "%s": ' "$CONFIRM_PHRASE" >&3
answer=""; read -r answer <&3 || true; exec 3>&-
[[ "$answer" == "$CONFIRM_PHRASE" ]] || die "confirmation did not match; nothing changed"

step "4 create the sink and point the worker at it"
MUTATE=1
k create -f "$MANIFEST" -o name
MUTATE=0
k rollout status "deploy/$NAME" -n "$NS" --timeout=300s || die "smtp4dev not Ready; worker NOT patched (objects left for read-only diagnosis)"
MUTATE=1
k patch cronjob "$WORKER" -n "$NS" --type=strategic -p "$PATCH" -o name
MUTATE=0

step "5 SMTP probe (one Job from a be293 pod through the ClusterIP Service)"
token="be293-smtp4dev-probe-$(date +%Y%m%d%H%M%S)"
probe="$(ruby -rjson -e 'name, image, host, port = ARGV
  sc = { "allowPrivilegeEscalation" => false, "readOnlyRootFilesystem" => true, "capabilities" => { "drop" => ["ALL"] } }
  script = %(printf "From: probe@portal-be293.test\\r\\nTo: probe@example.invalid\\r\\nSubject: #{name}\\r\\n\\r\\nBE-293 smtp4dev probe\\r\\n" | ) +
           %(curl -fsS --max-time 20 smtp://#{host}:#{port} --mail-from probe@portal-be293.test --mail-rcpt probe@example.invalid -T -)
  puts JSON.generate("apiVersion" => "batch/v1", "kind" => "Job",
    "metadata" => { "name" => name, "namespace" => "be293", "labels" => { "app.kubernetes.io/part-of" => "be293-portal", "app.kubernetes.io/component" => "smtp4dev-probe" } },
    "spec" => { "backoffLimit" => 0, "activeDeadlineSeconds" => 120, "template" => { "spec" => {
      "restartPolicy" => "Never", "automountServiceAccountToken" => false,
      "securityContext" => { "runAsNonRoot" => true, "runAsUser" => 1654, "runAsGroup" => 1654, "seccompProfile" => { "type" => "RuntimeDefault" } },
      "containers" => [{ "name" => "probe", "image" => image, "command" => ["/bin/sh", "-c", script], "securityContext" => sc,
                         "resources" => { "requests" => { "cpu" => "10m", "memory" => "32Mi" }, "limits" => { "memory" => "64Mi" } } }] } } })' \
  "$token" "$IMAGE" "$HOST" "$PORT")"
MUTATE=1
k create -f - -o name <<<"$probe"
MUTATE=0
k wait --for=condition=complete "job/$token" -n "$NS" --timeout=150s || die "probe Job did not complete: SMTP path broken (Job kept for diagnosis)"
subjects="$(captured_subjects)"
grep -qx "$token" <<<"$subjects" && echo "OK   smtp4dev captured the probe message '$token'" || die "probe sent but not found in smtp4dev"

echo; echo "DONE. Worker env:"; worker_env | sed 's/^/  /'
echo "UI: kubectl --kubeconfig $KC --context $CTX -n $NS port-forward deploy/$NAME $UI_LOCAL_PORT:8080  -> http://localhost:$UI_LOCAL_PORT"
