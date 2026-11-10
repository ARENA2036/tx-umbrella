#!/usr/bin/env bash
# Self-hosted did:web resolver for the BE-293 Portal on Alpha (namespace be293 only).
#
#   bash tools/did-resolver-be293.sh --pin       # resolve the driver and gateway digests (anonymous registry read;
#                                                # index or single-platform manifest, linux/amd64 proven from the
#                                                # image config) and write them into did-resolver-be293.alpha.yaml.
#                                                # No cluster.
#   bash tools/did-resolver-be293.sh             # DEFAULT: offline gates + read-only live checks + server-side dry runs
#   bash tools/did-resolver-be293.sh --execute   # after approval: typed confirmation, then
#                                                #   1. kubectl create the resolver (ConfigMap, Deployment, Service,
#                                                #      2 NetworkPolicies)
#                                                #   2. in-cluster probe through the Service with the Portal's exact
#                                                #      request form; stops here unless the existing DID resolves
#                                                #   3. patch ONLY the two *__UNIVERSALRESOLVERADDRESS env vars of the
#                                                #      processes-worker CronJob (next run uses it; no restart)
#   bash tools/did-resolver-be293.sh --verify    # read-only: resolver Ready, probe, worker env
#   bash tools/did-resolver-be293.sh --diff      # read-only: `kubectl diff` of the manifest against the live objects
#                                                # (server-side dry run) and their ownership (must not be Helm)
#
# Lifecycle: the resolver is a separately managed, declarative manifest, deliberately NOT part of the be293-portal
# Helm release (gate DR11 fails if the release ever renders an object of the same kind and name). Helm upgrades,
# rollbacks and uninstalls of be293-portal therefore never touch it. Changes = edit the manifest, gates, --diff,
# then an approved apply of exactly that diff.
#
# Never: apply/replace/delete, Secrets, Helm, release26-09, Keycloak, PostgreSQL, the wallet. `create` fails if an
# object already exists, so nothing is overwritten. The DID validation step itself is NOT retriggered here
# (tools/did-validate-retrigger-be293.sh, separate approval).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KC="${ALPHA_KUBECONFIG:-$HOME/.kube/alpha.yaml}"
CTX="alpha"
NS="be293"
MANIFEST="${DID_RESOLVER_MANIFEST:-$HERE/did-resolver-be293.alpha.yaml}"
NAME="be293-did-resolver"
URL="http://$NAME.$NS.svc.cluster.local:8080/"
WORKER="be293-portal-processes-worker"
RESOLVER_ENVS=(APPLICATIONCHECKLIST__IDENTITYHUB__UNIVERSALRESOLVERADDRESS APPLICATIONCHECKLIST__DIM__UNIVERSALRESOLVERADDRESS)
DID="did:web:identity-hub-01.test.tractus-x.com:BPNL000000000342"
DID_HOST="identity-hub-01.test.tractus-x.com"
CONFIRM_PHRASE="deploy did resolver in $CTX/$NS"
# repository  tag  placeholder-key
IMAGES=("uport/uni-resolver-driver-did-uport 5.0.8" "nginxinc/nginx-unprivileged 1.28.0-alpine")

MODE="plan"
case "${1:-}" in
  "") ;;
  --pin) MODE="pin" ;;
  --execute) MODE="execute" ;;
  --verify) MODE="verify" ;;
  --diff) MODE="diff" ;;
  *) echo "usage: did-resolver-be293.sh [--pin|--execute|--verify|--diff]" >&2; exit 2 ;;
esac

unset KUBECONFIG
umask 077
die() { echo "ABORT: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# kubectl: read-only verbs always; exec only for the fixed probe; create/patch only after the confirmation (MUTATE=1).
MUTATE=0
k() {
  case "$1" in
    get|wait|rollout|exec|diff) ;;
    create|patch) [[ "$MUTATE" == 1 || " $* " == *" --dry-run=server "* ]] || die "refused: kubectl $1 outside the confirmed execute step" ;;
    *) die "refused: kubectl $1" ;;
  esac
  kubectl --kubeconfig "$KC" --context "$CTX" -n "$NS" --request-timeout=30s "$@"
}

if [[ "$MODE" == "pin" ]]; then
  # Accepts a multi-platform index (OCI index / Docker manifest list) or a single-platform manifest (OCI / Docker
  # schema 2). Either way the linux/amd64 image is proven from content-addressed bytes: every fetched document must
  # hash to the digest it was requested by (or the registry's Docker-Content-Digest), and OS/architecture are read
  # from the image CONFIG blob, not from tags or index annotations alone. The pinned digest is the top-level one.
  INDEX_TYPES="application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json"
  IMAGE_TYPES="application/vnd.oci.image.manifest.v1+json application/vnd.docker.distribution.manifest.v2+json"
  ACCEPT="$(tr ' ' ',' <<<"$INDEX_TYPES $IMAGE_TYPES")"
  PIN_WORK="$(mktemp -d "${TMPDIR:-/tmp}/did-resolver-pin.XXXXXX")"; trap 'rm -rf "$PIN_WORK"' EXIT

  # reg_get PATH OUT: registry GET (blobs may redirect to the CDN, https only; curl never forwards the token to
  # another host). Body -> OUT (exact bytes), headers -> OUT.hdr.
  reg_get() {
    curl -fsS --proto =https --proto-redir =https -L --max-time 30 -H "Authorization: Bearer $token" -H "Accept: $ACCEPT" \
      -D "$2.hdr" -o "$2" "https://registry-1.docker.io/v2/$repo/$1"
  }
  header() { tr -d '\r' < "$1.hdr" | awk -v k="$(tr 'A-Z' 'a-z' <<<"$2")" -F': ' 'tolower($1) == k { v = $2 } END { print v }'; }
  sha_of() { echo "sha256:$(shasum -a 256 "$1" | cut -d' ' -f1)"; }
  in_list() { [[ " $2 " == *" $1 "* ]]; }
  # Reads one fetched document; prints the next digest to follow or dies on anything unexpected.
  inspect_doc() {
    ruby -rjson -e '
      kind, file, type = ARGV
      j = (JSON.parse(File.read(file)) rescue abort("#{kind}: not JSON"))
      abort("#{kind}: not a JSON object") unless j.is_a?(Hash)
      abort("#{kind}: body mediaType #{j["mediaType"]} != Content-Type #{type}") if j["mediaType"] && j["mediaType"] != type
      dig = ->(d) { d.is_a?(String) && d.match?(/\Asha256:\h{64}\z/) }
      case kind
      when "index"
        m = (j["manifests"] || []).select { |x| x.dig("platform", "os") == "linux" && x.dig("platform", "architecture") == "amd64" }
        abort("index: no linux/amd64 manifest") if m.empty?
        abort("index: #{m.size} linux/amd64 manifests (ambiguous)") if m.size > 1
        abort("index: linux/amd64 entry has an invalid digest") unless dig.(m[0]["digest"])
        print m[0]["digest"]
      when "manifest"
        abort("manifest: schemaVersion #{j["schemaVersion"].inspect} != 2") unless j["schemaVersion"] == 2
        c = j["config"] || {}
        ok = %w[application/vnd.oci.image.config.v1+json application/vnd.docker.container.image.v1+json]
        abort("manifest: unexpected config mediaType #{c["mediaType"].inspect}") unless ok.include?(c["mediaType"])
        abort("manifest: config has an invalid digest") unless dig.(c["digest"])
        abort("manifest: no layers") if (j["layers"] || []).empty?
        print c["digest"]
      when "config"
        os, arch = j["os"], j["architecture"]
        abort("config: missing os/architecture") if os.to_s.empty? || arch.to_s.empty?
        abort("config: image is #{os}/#{arch}, need linux/amd64") unless os == "linux" && arch == "amd64"
        print "#{os}/#{arch}"
      end' "$@"
  }

  for entry in "${IMAGES[@]}"; do
    read -r repo tag <<<"$entry"
    step "pin $repo:$tag (anonymous Docker Hub read)"
    token="$(curl -fsS --proto =https --max-time 20 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" \
             | ruby -rjson -e 'print JSON.parse($stdin.read).fetch("token")')" || die "registry token request failed for $repo"
    d="$PIN_WORK/${repo//\//_}"; mkdir -p "$d"
    reg_get "manifests/$tag" "$d/top" || die "manifest request failed for $repo:$tag (does the tag exist?)"
    digest="$(header "$d/top" Docker-Content-Digest)"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "no valid Docker-Content-Digest for $repo:$tag"
    [[ "$(sha_of "$d/top")" == "$digest" ]] || die "$repo:$tag content does not match its digest"
    type="$(header "$d/top" Content-Type)"; type="${type%%;*}"
    if in_list "$type" "$INDEX_TYPES"; then
      kind="multi-platform index"
      child="$(inspect_doc index "$d/top" "$type")" || die "$repo:$tag rejected"
      reg_get "manifests/$child" "$d/image" || die "linux/amd64 manifest request failed for $repo:$tag"
      [[ "$(sha_of "$d/image")" == "$child" ]] || die "$repo:$tag linux/amd64 manifest does not match its digest"
      itype="$(header "$d/image" Content-Type)"; itype="${itype%%;*}"
      in_list "$itype" "$IMAGE_TYPES" || die "$repo:$tag linux/amd64 entry is $itype, not an image manifest"
    elif in_list "$type" "$IMAGE_TYPES"; then
      kind="single-platform manifest"
      cp "$d/top" "$d/image"; itype="$type"
    else
      die "$repo:$tag has unexpected manifest type '${type:-<none>}'"
    fi
    config="$(inspect_doc manifest "$d/image" "$itype")" || die "$repo:$tag rejected"
    reg_get "blobs/$config" "$d/config" || die "config blob request failed for $repo:$tag"
    [[ "$(sha_of "$d/config")" == "$config" ]] || die "$repo:$tag config blob does not match its digest"
    platform="$(inspect_doc config "$d/config" "")" || die "$repo:$tag rejected: not verified as linux/amd64"
    ruby -e 'f, ref, d = ARGV; s = File.read(f)
      n = s.sub!(/(#{Regexp.escape(ref)}@)sha256:(<<PIN:[A-Z0-9_.]+>>|\h{64})/) { "#{$1}#{d}" }
      abort("image line for #{ref} not found") unless n; File.write(f, s)' "$MANIFEST" "docker.io/$repo:$tag" "$digest"
    echo "OK   $repo:$tag -> $digest ($kind; image config $config is $platform)"
  done
  echo "Written to $(basename "$MANIFEST"). Cross-check once on hub.docker.com before approving."
  exit 0
fi

LOG="$(mktemp "${TMPDIR:-/tmp}/be293-did-resolver.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

worker_env() {
  k get cronjob "$WORKER" -o json | ruby -rjson -e '
    c = JSON.parse($stdin.read).dig("spec","jobTemplate","spec","template","spec","containers").first
    (c["env"] || []).each { |e| puts "#{e["name"]}=#{e["value"]}" if e["name"].end_with?("__UNIVERSALRESOLVERADDRESS") }'
}

# Resolves a DID through the Service exactly as the Portal does: GET {base}1.0/identifiers/{EscapeDataString(did)}
# (encodeURIComponent encodes ":" the same way). Runs inside the resolver pod (be293 source, so the Service and
# the ingress NetworkPolicy are on the path). Prints "<http status> <did document id|-> <resolution error|->".
probe() {
  k exec "deploy/$NAME" -c driver -- node -e '
    const [base, did] = process.argv.slice(-2);
    fetch(base + "1.0/identifiers/" + encodeURIComponent(did), { signal: AbortSignal.timeout(25000) })
      .then(async (r) => {
        let j = {}; try { j = JSON.parse(await r.text()) } catch (e) {}
        console.log([r.status, (j.didDocument && j.didDocument.id) || "-", (j.didResolutionMetadata && j.didResolutionMetadata.error) || "-"].join(" "));
      })
      .catch((e) => { console.log("000 - " + (e.cause && e.cause.code || e.name)); });' "$URL" "$1"
}

check_probes() {
  local out
  out="$(probe "$DID")"
  echo "  $DID -> $out"
  [[ "$out" == "200 $DID -" ]] || return 1
  out="$(probe "did:ethr:0x3b0BC51Ab9De1e5B7B6E34E5b960285805C41736")"
  echo "  did:ethr (must be refused by the gateway) -> $out"
  [[ "$out" == 404\ * ]] || return 1
}

if [[ "$MODE" == "diff" ]]; then
  step "ownership of the live resolver objects (read-only)"
  for obj in "configmap/$NAME-gateway" "deployment/$NAME" "service/$NAME" "networkpolicy/$NAME-ingress" "networkpolicy/$NAME-egress"; do
    owner="$(k get "$obj" --ignore-not-found -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}|{.metadata.annotations.meta\.helm\.sh/release-name}')"
    case "$owner" in
      "") echo "  MISSING $obj (not created yet)" ;;
      Helm*|*"|"?*) die "$obj is owned by Helm ($owner): resolve ownership before any change" ;;
      *) echo "  OK      $obj (not Helm-managed)" ;;
    esac
  done
  step "kubectl diff against the live objects (server-side dry run, nothing persisted)"
  rc=0; k diff -f "$MANIFEST" || rc=$?
  case "$rc" in
    0) echo "NO DRIFT: live resolver objects match $(basename "$MANIFEST")" ;;
    1) echo "DRIFT above: review; changes need an approved apply of exactly this diff" ;;
    *) die "kubectl diff failed ($rc)" ;;
  esac
  exit 0
fi

if [[ "$MODE" == "verify" ]]; then
  step "verify (read-only)"
  k rollout status "deploy/$NAME" --timeout=60s
  k get svc "$NAME" -o jsonpath='{.spec.type} {.spec.clusterIP} ports={.spec.ports[*].port}{"\n"}'
  check_probes && echo "OK   resolver answers the Portal request form and resolves $DID" || die "probe failed"
  echo "worker resolver settings:"; worker_env | sed 's/^/  /'
  exit 0
fi

step "0 target and offline gates"
[[ -r "$KC" ]] || die "$KC not readable"
kubectl --kubeconfig "$KC" config get-contexts -o name | grep -qx "$CTX" || die "context $CTX not in $KC"
KUBECONFIG=/dev/null DID_RESOLVER_MANIFEST="$MANIFEST" bash "$HERE/tools/render-release.sh" > "$LOG" 2>&1 \
  || { grep -E '^FAIL' "$LOG" | head -10 >&2; die "offline gates failed (pin the images first: --pin)"; }
echo "OK   release gates + resolver gates DR1-DR10 pass (manifest, Portal resolver target, worker path)"

step "1 read-only live checks"
for obj in "configmap/$NAME-gateway" "deployment/$NAME" "service/$NAME" "networkpolicy/$NAME-ingress" "networkpolicy/$NAME-egress"; do
  [[ -z "$(k get "$obj" --ignore-not-found -o name)" ]] || die "$obj already exists: nothing is overwritten (use --verify)"
done
echo "OK   no resolver object exists yet"
cidr="$(ruby -ryaml -e 'YAML.load_stream(File.read(ARGV[0])).compact.each { |d| next unless d["kind"] == "NetworkPolicy"
  (d.dig("spec","egress") || []).each { |r| (r["to"] || []).each { |p| (c = p.dig("ipBlock","cidr")) && puts(c) } } }' "$MANIFEST")"
addrs="$(ruby -rresolv -e 'puts Resolv.getaddresses(ARGV[0]).grep(/\A\d+\.\d+\.\d+\.\d+\z/).sort' "$DID_HOST" 2>/dev/null || true)"
if [[ -z "$addrs" ]]; then
  echo "WARN $DID_HOST did not resolve from this machine; egress ipBlock $cidr unverified"
elif grep -qx "${cidr%/32}" <<<"$addrs"; then
  echo "OK   $DID_HOST -> $(tr '\n' ' ' <<<"$addrs")(egress ipBlock $cidr matches)"
else
  die "$DID_HOST resolves to $(tr '\n' ' ' <<<"$addrs")but the resolver egress allows only $cidr"
fi
echo "current processes-worker resolver settings:"; worker_env | sed 's/^/  /'
container="$(k get cronjob "$WORKER" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].name}')"
[[ "$container" == "$WORKER" ]] || die "unexpected worker container name '$container'"
PATCH="$(ruby -rjson -e 'n, u, *names = ARGV
  puts JSON.generate("spec" => { "jobTemplate" => { "spec" => { "template" => { "spec" => { "containers" => [
    { "name" => n, "env" => names.map { |e| { "name" => e, "value" => u } } }] } } } } })' "$container" "$URL" "${RESOLVER_ENVS[@]}")"

step "2 server-side dry runs (nothing persisted)"
k create --dry-run=server -f "$MANIFEST" -o name | sed 's/^/  would create /'
after="$(k patch cronjob "$WORKER" --type=strategic -p "$PATCH" --dry-run=server -o json | ruby -rjson -e '
  c = JSON.parse($stdin.read).dig("spec","jobTemplate","spec","template","spec","containers").first
  puts (c["env"] || []).select { |e| e["name"].end_with?("__UNIVERSALRESOLVERADDRESS") }.map { |e| "#{e["name"]}=#{e["value"]}" }')"
echo "$after" | sed 's/^/  worker env after patch: /'
for e in "${RESOLVER_ENVS[@]}"; do grep -qx "$e=$URL" <<<"$after" || die "dry-run patch did not set $e"; done

if [[ "$MODE" != "execute" ]]; then
  echo; echo "DRY RUN COMPLETE: nothing changed. Re-run with --execute after approval."
  exit 0
fi

step "3 confirmation"
{ exec 3<>/dev/tty; } 2>/dev/null || die "no terminal for confirmation; nothing changed"
printf 'Type exactly "%s": ' "$CONFIRM_PHRASE" >&3
answer=""; read -r answer <&3 || true; exec 3>&-
[[ "$answer" == "$CONFIRM_PHRASE" ]] || die "confirmation did not match; nothing changed"

step "4 create the resolver"
MUTATE=1
k create -f "$MANIFEST" -o name
MUTATE=0
k rollout status "deploy/$NAME" --timeout=300s || die "resolver not Ready; worker NOT patched (objects left for read-only diagnosis)"

step "5 in-cluster probe (Portal request form, through the Service)"
check_probes || die "resolver does not resolve $DID; worker NOT patched (objects left for read-only diagnosis)"
echo "OK   $DID resolves; did document id matches; no resolution error"

step "6 point the worker at the resolver"
MUTATE=1
k patch cronjob "$WORKER" --type=strategic -p "$PATCH" -o name
MUTATE=0
echo "worker resolver settings:"; worker_env | sed 's/^/  /'
echo; echo "DONE. Next: bash tools/did-validate-retrigger-be293.sh   (read-only check, then --execute with separate approval)"
