# frozen_string_literal: true

# The repository manifest carries an unresolved digest until `tools/smtp4dev-be293.sh --pin` runs on an
# operator machine (the sandbox has no registry access). Tests that run the full gate chain use a copy pinned
# to a synthetic digest; the S3 gate itself is tested in tests/test_validate_smtp4dev.rb.
require 'tmpdir'

module PinnedSmtp4dev
  SYNTHETIC_DIGEST = "sha256:#{'a' * 64}"

  def self.manifest(dir)
    src = File.read(File.expand_path('../../smtp4dev-be293.alpha.yaml', __dir__))
    path = File.join(dir, 'smtp4dev-be293.alpha.yaml')
    File.write(path, src.sub(/(smtp4dev:3\.15\.0@)sha256:(<<PIN:[A-Z0-9_.]+>>|\h{64})/) { "#{$1}#{SYNTHETIC_DIGEST}" })
    path
  end
end
