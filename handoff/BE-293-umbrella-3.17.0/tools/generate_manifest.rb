# Regenerates ARTIFACT-MANIFEST.md: SHA-256, origin and source of every file in this package.
# Files marked "copied unchanged" are compared with their source; any mismatch aborts.
# Usage (from the package root, inside the integration repository):
#   ruby tools/generate_manifest.rb [path-to-source-checkout]
# The source checkout defaults to ~/Projects/public-tractus-x-umbrella; when it is absent, the
# umbrella-infrastructure copies are listed but not re-compared.
Encoding.default_external = Encoding::UTF_8 # tools must not depend on the caller locale (LANG may be unset in CI)
require 'digest'

REC = File.expand_path('../../recovery/be293-dev-3.17.0', Dir.pwd)
FORK = File.expand_path(ARGV[0] || '~/Projects/public-tractus-x-umbrella')
DATE = Time.now.utc.strftime('%Y-%m-%d')
sha = ->(p) { Digest::SHA256.file(p).hexdigest }

RULES = [
  [%r{\Achart/umbrella/(.+)}, ->(m) { ["recovery/be293-dev-3.17.0/chart/umbrella/#{m[1]} (Git, commit 60c0b81)", 'copied unchanged', File.join(REC, 'chart/umbrella', m[1])] }],
  [%r{\Acharts/umbrella-infrastructure/(.+)}, lambda { |m|
    tracked = %w[Chart.yaml values.yaml .helmignore].include?(m[1]) ? 'tracked @ a5b07c5' : 'untracked'
    ["source checkout charts/umbrella-infrastructure/#{m[1]} (#{tracked})", 'copied unchanged', File.join(FORK, 'charts/umbrella-infrastructure', m[1])]
  }],
  [%r{\Avalues/(values-be293-dev\.example\.yaml|values-be293-dev\.secrets\.example\.yaml)\z}, ->(m) { ["recovery/be293-dev-3.17.0/values/#{m[1]} (Git, commit 60c0b81)", 'copied unchanged', File.join(REC, 'values', m[1])] }],
  [%r{\Avalues/values-be293-vault\.example\.yaml\z}, ->(_) { ['source checkout charts/values-be293-vault-dev.yaml (untracked)', 'copied; header comment added', nil] }],
  [%r{\Avalues/values-be293-identityhub-superuser-secretref\.yaml\z}, ->(_) { ['derived from source checkout charts/values-callback-activation.yaml and charts/umbrella/values-combined-portal-additions.yaml (working tree)', 'new overlay (optional)', nil] }],
  [%r{\Amanifests/10-}, ->(_) { ['live Ingress be293/be293-identityhub-legacy-did (read-only, 2026-11-02)', 'reconstructed; domain sanitized; equals live', nil] }],
  [%r{\Amanifests/11-}, ->(_) { ['source checkout hack/manifests/be293-identityhub-did-documents-ingress.yaml (untracked)', 'copied; domain sanitized; equals live', nil] }],
  [%r{\Amanifests/12-}, ->(_) { ['live Ingress be293/be293-issuer-legacy-did (read-only, 2026-11-02)', 'reconstructed; domain sanitized; equals live', nil] }],
  [%r{\Amanifests/13-}, ->(_) { ['source checkout hack/manifests/be293-issuer-statuslist-ingress.yaml (tracked)', 'copied; domain sanitized; equals live', nil] }],
  [%r{\Atools/(apply_environment|scan|secrets_example|envnames|inventory|objhash)\.rb\z}, ->(m) { ["recovery/be293-dev-3.17.0/tools/#{m[1]}.rb (Git)", 'copied unchanged', File.join(REC, 'tools', "#{m[1]}.rb")] }],
  [%r{\Atools/}, ->(_) { %w[new tooling] + [nil] }],
  [%r{\Ainventory/expected-rev21-inventory\.json\z}, ->(_) { ['helm get manifest + hooks be293-app revision 21 (read-only) | tools/render_inventory.rb --normalize-registry', 'generated; no values', nil] }],
  [%r{\Ainventory/expected-vault-inventory\.json\z}, ->(_) { ['helm get manifest + hooks be293-vault revision 1 (read-only) | tools/render_inventory.rb', 'generated; no values', nil] }],
  [%r{\Ainventory/IMAGE-INVENTORY\.yaml\z}, ->(_) { ['live pod imageIDs, revision 21 manifest, source checkout publication manifest and lock files', 'authored; registry sanitized', nil] }],
  [/./, ->(_) { %w[new documentation] + [nil] }]
].freeze

files = Dir.glob('**/*', File::FNM_DOTMATCH).select { |f| File.file?(f) && f != 'ARTIFACT-MANIFEST.md' }.sort
rows = []; mismatches = []; compared = 0
files.each do |f|
  rule, fn = RULES.find { |rx, _| rx.match?(f) }
  src, kind, source_path = fn.call(rule.match(f))
  if source_path && File.file?(source_path)
    compared += 1
    mismatches << f unless sha.(source_path) == sha.(f)
  elsif source_path && !source_path.start_with?(FORK)
    mismatches << "#{f} (source missing)"
  end
  rows << "| `#{f}` | `#{sha.(f)}` | #{kind} | #{src} |"
end
abort "SOURCE MISMATCH: #{mismatches.join(', ')}" unless mismatches.empty?

File.write('ARTIFACT-MANIFEST.md', <<~MD)
  # Artifact Manifest

  Generated #{DATE} by `tools/generate_manifest.rb`. It lists every file in this package (except this manifest) with its SHA-256, how it was produced, and its source.

  - "Source checkout" means `public-tractus-x-umbrella` (Federity-X fork), branch `feat/BE-293-connector-bundle-and-portal-integration` @ `a5b07c5` plus its uncommitted working tree.
  - "recovery/…" means this repository, branch `feat/BE-293-development` @ `df91837`.
  - Copies marked "copied unchanged" were re-compared with their source by SHA-256 during generation: #{compared} compared, 0 mismatches.
  - Re-check the package with `bash tools/verify_package.sh`, step 1.

  | File | SHA-256 | Produced by | Source |
  |---|---|---|---|
  #{rows.join("\n")}
MD
puts "files=#{rows.size} compared-with-source=#{compared} mismatches=0"
