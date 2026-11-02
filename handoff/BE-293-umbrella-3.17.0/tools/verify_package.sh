#!/usr/bin/env bash
# Offline, non-mutating verification of this handoff package. It never contacts a cluster and never
# writes rendered manifests to disk (renders are piped into inventory/check tools only).
# Usage: bash tools/verify_package.sh            (run from the package root)
set -euo pipefail
export RUBYOPT="${RUBYOPT:+$RUBYOPT }-EUTF-8:UTF-8"   # locale-independent Ruby I/O
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/be293-verify.XXXXXX")"; chmod 700 "$work"; trap 'rm -rf "$work"' EXIT
fail=0; step() { printf '\n== %s\n' "$*"; }
ok() { echo "PASS: $*"; }; ko() { echo "FAIL: $*"; fail=1; }
H="helm template be293-app chart/umbrella -n be293"

step "1. Artifact checksums against ARTIFACT-MANIFEST.md"
ruby -rdigest -e '
  bad = 0; n = 0
  File.read("ARTIFACT-MANIFEST.md").scan(/^\| `([^`]+)` \| `([0-9a-f]{64})` \|/) do |path, sum|
    n += 1
    actual = File.file?(path) ? Digest::SHA256.file(path).hexdigest : "missing"
    (puts "MISMATCH #{path}"; bad += 1) unless actual == sum
  end
  puts "checked=#{n} mismatches=#{bad}"; exit(bad.zero? && n.positive? ? 0 : 1)' && ok checksums || ko checksums

step "2. helm dependency list"
helm dependency list chart/umbrella >/dev/null && helm dependency list charts/umbrella-infrastructure >/dev/null && ok "dependencies resolvable from vendored packages" || ko "dependency list"

step "3. helm lint (example overlay + synthetic secrets)"
ruby tools/make_synthetic_secrets.rb values/values-be293-dev.secrets.example.yaml "$work/t.synthetic.secrets.yaml" >/dev/null
helm lint chart/umbrella -n be293 -f values/values-be293-dev.example.yaml -f "$work/t.synthetic.secrets.yaml" 2>/dev/null | grep -q '0 chart(s) failed' && ok "umbrella lint" || ko "umbrella lint"
helm lint charts/umbrella-infrastructure -f values/values-be293-vault.example.yaml 2>/dev/null | grep -q '0 chart(s) failed' && ok "vault lint" || ko "vault lint"

step "4. Render inventory vs DEV revision 21 (images normalized to the example registry)"
$H -f values/values-be293-dev.example.yaml -f "$work/t.synthetic.secrets.yaml" 2>/dev/null | ruby tools/render_inventory.rb --normalize-registry > "$work/a.json"
ruby tools/compare_inventory.rb inventory/expected-rev21-inventory.json "$work/a.json" && ok "baseline identical to revision 21" || ko "baseline differs"
helm template be293-vault charts/umbrella-infrastructure -n be293 -f values/values-be293-vault.example.yaml 2>/dev/null | ruby tools/render_inventory.rb > "$work/v.json"
ruby tools/compare_inventory.rb inventory/expected-vault-inventory.json "$work/v.json" && ok "vault identical to DEV be293-vault" || ko "vault differs"

step "5. Optional superuser SecretRef overlay: exactly the 6 intended differences"
$H -f values/values-be293-dev.example.yaml -f "$work/t.synthetic.secrets.yaml" -f values/values-be293-identityhub-superuser-secretref.yaml 2>/dev/null \
  | ruby tools/render_inventory.rb --normalize-registry > "$work/b.json"
d="$(ruby tools/compare_inventory.rb inventory/expected-rev21-inventory.json "$work/b.json" | grep -c '^  ' || true)"
[ "$d" = "6" ] && ok "secretref overlay: 6 differences (identityhub-superuser refs)" || ko "secretref overlay: $d differences"

step "6. No credential placeholder survives a render with a complete secrets overlay"
$H -f values/values-be293-dev.example.yaml -f "$work/t.synthetic.secrets.yaml" 2>/dev/null | ruby tools/check_placeholders.rb --allow-example-domain && ok "placeholders covered" || ko "placeholder left"

step "7. Guardrails fail closed"
$H -f values/values-be293-dev.example.yaml --set be293.privateImages.approvedRepository= >/dev/null 2>&1 && ko "missing approvedRepository accepted" || ok "missing approvedRepository rejected"
helm template x chart/umbrella -n other -f values/values-be293-dev.example.yaml >/dev/null 2>&1 && ko "wrong namespace accepted" || ok "wrong namespace rejected"

step "8. Manifests parse and reference only the example domain"
ruby -ryaml -e 'Dir["manifests/[0-9]*.yaml"].each { |f| d = YAML.load_file(f); raise "#{f}: not an Ingress" unless d["kind"] == "Ingress"; h = d["spec"]["rules"].map { |r| r["host"] } + d["spec"]["tls"].flat_map { |t| t["hosts"] } + [d.dig("metadata", "annotations", "external-dns.alpha.kubernetes.io/hostname")].compact; bad = h.reject { |x| x.end_with?(".example.invalid") }; raise "#{f}: non-example host #{bad}" unless bad.empty? }; puts "ingress manifests=#{Dir["manifests/[0-9]*.yaml"].size}"' && ok "manifests parse" || ko "manifests"

step "9. Secret pattern scan (file:line and rule only)"
ruby tools/scan.rb . "$work/scan.txt" >/dev/null
grep -E 'PEM-PRIVATE-KEY|JWT|JWK-PRIVATE|DOCKER-AUTH' "$work/scan.txt" | grep -v '^tools/' && ko "secret-like material in top-level files" || ok "no private keys, JWTs or docker auth in package files (vendored .tgz checked separately, see README)"

echo; [ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
