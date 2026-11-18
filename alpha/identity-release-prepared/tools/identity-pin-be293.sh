#!/usr/bin/env bash
# Resolve and pin the identity-stack and E2E-test-connector image digests (anonymous Docker Hub read; local files only).
#
#   bash tools/identity-pin-be293.sh          # list the <<PIN:...>> placeholders still open
#   bash tools/identity-pin-be293.sh --pin    # resolve each official image's multi-arch index digest, require linux/amd64,
#                                             # replace the placeholders in the values files, record images.lock.identity.yaml
#
# Only the official repositories below are accepted. Personal repositories are refused by construction.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES=("tractusx/issuerservice:0.4.1" "tractusx/identityhub:0.4.1" "hashicorp/vault:1.18.1" "tractusx/bdrs-server:0.6.0"
        "tractusx/edc-controlplane-postgresql-hashicorp-vault:0.13.0" "tractusx/edc-dataplane-hashicorp-vault:0.13.0"
        "nginxinc/nginx-unprivileged:1.27-alpine")
VALUES=("$HERE"/values-be293-*.yaml "$HERE/edc-datasource-be293.alpha.yaml")
LOCK="$HERE/images.lock.identity.yaml"
ACCEPT="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json"

die() { echo "ABORT: $*" >&2; exit 1; }
open_pins() { grep -ho '<<PIN:[^>]*>>' "${VALUES[@]}" | sort -u || true; }

case "${1:-}" in
  "") echo "open placeholders:"; open_pins | sed 's/^/  /'; [[ -z "$(open_pins)" ]] && echo "  none"; exit 0 ;;
  --pin) ;;
  *) echo "usage: identity-pin-be293.sh [--pin]" >&2; exit 2 ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/be293-identity-pin.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
{ echo "# Official images of the own identity stack and the E2E test connectors, pinned by digest (tools/identity-pin-be293.sh --pin)."
  echo "# resolved: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "images:"; } > "$WORK/lock"
for ref in "${IMAGES[@]}"; do
  repo="${ref%%:*}"; tag="${ref#*:}"
  case "$repo" in
    tractusx/issuerservice|tractusx/identityhub|tractusx/bdrs-server|hashicorp/vault) ;;
    tractusx/edc-controlplane-postgresql-hashicorp-vault|tractusx/edc-dataplane-hashicorp-vault|nginxinc/nginx-unprivileged) ;;
    *) die "refused: $repo is not an approved official repository" ;;
  esac
  token="$(curl -fsS --proto =https --max-time 20 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" \
           | ruby -rjson -e 'begin; print JSON.parse($stdin.read).fetch("token"); rescue StandardError; exit 1; end')" \
           || die "registry token request failed for $repo"
  printf 'Authorization: Bearer %s\n' "$token" > "$WORK/auth.hdr"
  # Accept every shape the registry may store, so the returned manifest and Docker-Content-Digest are the tag's own.
  manifest="$(curl -fsS --proto =https --max-time 20 -H "@$WORK/auth.hdr" \
            -H "Accept: $ACCEPT" -D "$WORK/hdr" "https://registry-1.docker.io/v2/$repo/manifests/$tag")" \
    || die "manifest read failed for $ref"
  digest="$(tr -d '\r' < "$WORK/hdr" | awk 'tolower($1) == "docker-content-digest:" {print $2}')"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "no valid digest for $ref"
  # Manifest list / OCI index: a linux/amd64 entry in .manifests[]. Single-platform manifest: .config.digest names the
  # image config blob, whose os/architecture are authoritative.
  shape="$(ruby -rjson -e 'm = JSON.parse(ARGV[0])
    if m["manifests"].is_a?(Array) then puts "index"
    elsif m.dig("config", "digest").to_s.match?(/\Asha256:\h{64}\z/) then puts "single #{m.dig("config", "digest")}"
    else puts "unknown" end' "$manifest")" || die "manifest for $ref is not JSON"
  case "$shape" in
    index)
      ruby -rjson -e 'm = JSON.parse(ARGV[0])["manifests"]; exit(m.any? { |x| x.dig("platform","os") == "linux" && x.dig("platform","architecture") == "amd64" } ? 0 : 1)' "$manifest" \
        || die "$ref has no linux/amd64 image in its index"
      kind="index, linux/amd64 entry present" ;;
    single\ *)
      config="${shape#single }"
      # Blob requests redirect to the registry's storage host; -L follows, the token header is only sent to the registry.
      platform="$(curl -fsSL --proto =https --max-time 30 -H "@$WORK/auth.hdr" "https://registry-1.docker.io/v2/$repo/blobs/$config" \
                  | ruby -rjson -e 'c = JSON.parse($stdin.read); print "#{c["os"]}/#{c["architecture"]}"')" \
        || die "config blob read failed for $ref"
      [[ "$platform" == "linux/amd64" ]] || die "$ref is single-platform $platform, not linux/amd64"
      kind="single-platform manifest, config says linux/amd64" ;;
    *) die "$ref: unrecognised manifest shape" ;;
  esac
  echo "  - {image: docker.io/$repo, tag: \"$tag\", digest: \"$digest\"}" >> "$WORK/lock"
  for f in "${VALUES[@]}"; do
    ruby -e 'f, ph, d = ARGV; s = File.read(f); File.write(f, s.gsub(ph, d)) if s.include?(ph)' "$f" "<<PIN:$ref>>" "$digest"
  done
  echo "OK   $ref -> $digest ($kind)"
done
mv "$WORK/lock" "$LOCK"
[[ -z "$(open_pins)" ]] || die "placeholders left: $(open_pins | tr '\n' ' ')"
echo "PINNED. Review the diff of the values files and $LOCK, then run tools/render-identity.sh --release."
