# frozen_string_literal: true

# Tests for tools/record_portal_images.rb on copies of the real images.lock.yaml, values-be293-portal.yaml and
# ci/be293-portal-images.yml (synthetic digests in memory; the repository files are never written).
#
# Run: ruby tests/test_record_portal_images.rb

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require_relative '../tools/record_portal_images'

class RecordPortalImagesTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  # A hypothetical NEXT build: the tests must not depend on which commit the repository files currently record.
  NEW = "0123456789abcdef0123456789abcdef01234567"
  RECORDED = YAML.safe_load(File.read(File.join(HERE, "images.lock.yaml")))
  RECORDED_COMMIT = RECORDED.dig("source", "commit")
  RECORDED_ADMIN = "sha256:" + RECORDED["rebuilt"].find { |e| e["image"] == "portal-administration-service" }["digest"]
  BRANCH = 'fix/BE-293-retrigger-validate-did-in-progress'
  FILES = %w[images.lock.yaml values-be293-portal.yaml ci/be293-portal-images.yml].freeze

  def digests(overrides = {})
    RecordPortalImages::IMAGES.each_with_index.to_h { |img, i| [img, "sha256:#{format('%x', i + 1) * 64}"] }.merge(overrides)
  end

  def digest_text(d = digests)
    d.map { |img, dg| "#{img} #{dg}" }.join("\n") + "\n"
  end

  def originals
    FILES.map { |f| File.read(File.join(HERE, f)) }
  end

  def apply(d = digests, commit: NEW)
    RecordPortalImages.apply(*originals, commit: commit, branch: BRANCH, digests: d)
  end

  def test_records_all_eight_images_consistently
    lock, values, workflow, changes = apply
    assert_equal 3 + 2 * 8, changes.size
    y = YAML.safe_load(lock)
    assert_equal NEW, y.dig('source', 'commit')
    assert_equal BRANCH, y.dig('source', 'branch')
    y['rebuilt'].each do |e|
      assert_equal "be293-#{NEW}", e['tag']
      assert_equal digests[e['image']].delete_prefix('sha256:'), e['digest']
    end
    RecordPortalImages::IMAGES.each do |img|
      assert_match(%r{name: "[^"]+/#{img}"\n\s+\w+tag: "be293-#{NEW}@#{digests[img]}"}, values)
    end
    refute_match(/be293-(?!#{NEW})[0-9a-f]{40}@/, values)
    assert_match(/^  SOURCE_COMMIT: #{NEW}$/, workflow)
    # Only the targeted lines change.
    assert_equal originals[1].lines.size, values.lines.size
    assert_equal 8, originals[1].lines.zip(values.lines).count { |a, b| a != b }
    assert_equal 1, originals[2].lines.zip(workflow.lines).count { |a, b| a != b }
    # Published-but-not-deployed builds are never touched (they share the rebuilt line shape).
    assert_equal YAML.safe_load(originals[0])['publishedNotDeployed'], y['publishedNotDeployed']
  end

  def test_recorded_files_still_pass_check_package
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(Dir.glob(File.join(HERE, '*.{yaml,yml,md,txt}')) + [File.join(HERE, 'ci'), File.join(HERE, 'tools')], dir)
      lock, values, workflow, = apply
      File.write(File.join(dir, 'images.lock.yaml'), lock)
      File.write(File.join(dir, 'values-be293-portal.yaml'), values)
      File.write(File.join(dir, 'ci/be293-portal-images.yml'), workflow)
      out, st = Open3.capture2e('ruby', File.join(HERE, 'tools/check_package.rb'), dir)
      assert st.success?, out
      assert_match(/PACKAGE PASS/, out)
    end
  end

  def test_refuses_incomplete_duplicate_unknown_or_malformed_input
    d = digests
    d.delete('portal-migrations')
    assert_raises_msg(/missing digests for portal-migrations/) { RecordPortalImages.parse_digests(digest_text(d)) }
    assert_raises_msg(/duplicate portal-processes-worker/) do
      RecordPortalImages.parse_digests(digest_text + "portal-processes-worker sha256:#{'f' * 64}\n")
    end
    assert_raises_msg(/unknown image portal-frontend/) { RecordPortalImages.parse_digests("portal-frontend sha256:#{'a' * 64}\n") }
    assert_raises_msg(/malformed digest/) do
      RecordPortalImages.parse_digests(digest_text(digests('portal-administration-service' => 'sha256:<<PIN:ADMIN>>')))
    end
    assert_raises_msg(/malformed digest/) { RecordPortalImages.parse_digests(digest_text(digests('portal-migrations' => "sha256:#{'A' * 64}"))) }
    assert_raises_msg(/expected '<image> sha256:<64 hex>'/) { RecordPortalImages.parse_digests("portal-migrations\n") }
  end

  def test_refuses_bad_commit_stale_digest_and_rerecording
    assert_raises_msg(/full 40-character/) { apply(commit: '274096a9') }
    assert_raises_msg(/already recorded/) { apply(commit: RECORDED_COMMIT) }
    stale = digests('portal-administration-service' => RECORDED_ADMIN)
    assert_raises_msg(/portal-administration-service: digest equals the currently recorded one/) { apply(stale) }
  end

  def test_cli_is_dry_run_by_default_and_never_writes_on_refusal
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'tools'))
      FileUtils.mkdir_p(File.join(dir, 'ci'))
      FILES.each { |f| FileUtils.cp(File.join(HERE, f), File.join(dir, f)) }
      FileUtils.cp(File.join(HERE, 'tools/record_portal_images.rb'), File.join(dir, 'tools'))
      before = FILES.map { |f| File.read(File.join(dir, f)) }
      File.write(File.join(dir, 'd.txt'), digest_text)
      run = ->(*a) { Open3.capture2e('ruby', File.join(dir, 'tools/record_portal_images.rb'), '--commit', NEW, '--branch', BRANCH, '--digests', File.join(dir, 'd.txt'), *a) }
      out, st = run.call
      assert st.success?, out
      assert_match(/DRY RUN: 19 changes, nothing written/, out)
      assert_equal before, FILES.map { |f| File.read(File.join(dir, f)) }
      File.write(File.join(dir, 'd.txt'), digest_text.lines.first)
      out, st = run.call('--write')
      refute st.success?
      assert_match(/REFUSED: missing digests/, out)
      assert_equal before, FILES.map { |f| File.read(File.join(dir, f)) }
      File.write(File.join(dir, 'd.txt'), digest_text)
      out, st = run.call('--write')
      assert st.success?, out
      assert_includes File.read(File.join(dir, 'images.lock.yaml')), "commit: #{NEW}"
    end
  end

  def assert_raises_msg(re, &blk)
    e = assert_raises(RecordPortalImages::Error, &blk)
    assert_match(re, e.message)
  end
end
