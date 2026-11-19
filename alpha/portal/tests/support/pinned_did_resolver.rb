# frozen_string_literal: true

# The repository manifest carries unresolved digests until `tools/did-resolver-be293.sh --pin` runs on an
# operator machine (the sandbox has no registry access). Tests that run the full gate chain use a copy pinned
# to synthetic digests; the DR3 gate itself is tested in tests/test_validate_did_resolver.rb.
require 'tmpdir'

module PinnedDidResolver
  SYNTHETIC_DIGEST = "sha256:#{'a' * 64}"
  SOURCE = File.expand_path('../../did-resolver-be293.alpha.yaml', __dir__)

  def self.pin(text)
    text.gsub(/(did-uport:5\.0\.8@|nginx-unprivileged:1\.28\.0-alpine@)sha256:(<<PIN:[A-Z0-9_.]+>>|\h{64})/) { "#{$1}#{SYNTHETIC_DIGEST}" }
  end

  def self.manifest(dir)
    path = File.join(dir, 'did-resolver-be293.alpha.yaml')
    File.write(path, pin(File.read(SOURCE)))
    path
  end
end
