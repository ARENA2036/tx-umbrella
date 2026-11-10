# frozen_string_literal: true

# Records the 8 BE-293 Portal backend images AFTER the isolated workflow has pushed them, in one consistent edit:
#   images.lock.yaml          source.branch / source.commit, and tag + digest of every `rebuilt` entry
#   values-be293-portal.yaml  the 8 `be293-<sha>@sha256:<digest>` image tags
#   ci/be293-portal-images.yml SOURCE_COMMIT (check_package.rb requires it to equal images.lock source.commit)
#
# Input is the digests the registry actually reports for the pushed tags, one line per image:
#   portal-administration-service sha256:<64 hex>
# (from the workflow step summaries or `docker buildx imagetools inspect <registry>/<image>:be293-<sha>`).
# Refuses: missing, extra or duplicate images; malformed digests or commit; placeholders; a digest equal to the
# currently recorded one (stale copy); any target line not found exactly once. Only the `rebuilt` section of
# images.lock (the deployed pins) is edited; `publishedNotDeployed` is left alone. Dry run by default.
#
# Usage: ruby tools/record_portal_images.rb --commit SHA --branch NAME --digests FILE [--write]

require 'optparse'

module RecordPortalImages
  IMAGES = %w[portal-administration-service portal-registration-service portal-marketplace-app-service
              portal-services-service portal-notification-service portal-maintenance-service portal-processes-worker
              portal-migrations].freeze
  HEX40 = /\A[0-9a-f]{40}\z/.freeze
  DIGEST = /\Asha256:[0-9a-f]{64}\z/.freeze

  class Error < StandardError; end

  module_function

  def parse_digests(text)
    seen = {}
    text.each_line.with_index(1) do |line, n|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      image, digest, extra = line.split(/\s+/)
      raise Error, "line #{n}: expected '<image> sha256:<64 hex>'" if extra || digest.nil?
      raise Error, "line #{n}: unknown image #{image}" unless IMAGES.include?(image)
      raise Error, "line #{n}: malformed digest for #{image}" unless digest.match?(DIGEST)
      raise Error, "line #{n}: duplicate #{image}" if seen.key?(image)

      seen[image] = digest
    end
    missing = IMAGES - seen.keys
    raise Error, "missing digests for #{missing.join(', ')}" unless missing.empty?

    seen
  end

  # Replaces the single line matching `pattern`: optionally only the first one after a line matching `after`, or
  # only inside the top-level YAML `section` (from its key to the next top-level key).
  def replace_once(lines, label, pattern, after: nil, section: nil)
    start = after ? lines.index { |l| l.match?(after) } : 0
    raise Error, "#{label}: anchor not found" unless start

    range = (-1...lines.size)
    if section
      head = lines.index { |l| l.match?(/^#{Regexp.escape(section)}:\s*$/) } or raise Error, "#{label}: section #{section} not found"
      tail = (head + 1...lines.size).find { |i| lines[i].match?(/^\S/) } || lines.size
      range = (head...tail)
    end
    hits = lines.each_index.select { |i| range.cover?(i) && i > (after ? start : -1) && lines[i].match?(pattern) }
    hits = hits.take(1) if after
    raise Error, "#{label}: expected exactly one match, found #{hits.size}" unless hits.size == 1

    i = hits.first
    old = lines[i]
    lines[i] = yield(old)
    [label, old.strip, lines[i].strip]
  end

  def apply(lock, values, workflow, commit:, branch:, digests:)
    raise Error, "commit must be a full 40-character lowercase SHA: #{commit.inspect}" unless commit.match?(HEX40)
    raise Error, "branch must be a plain branch name: #{branch.inspect}" unless branch.match?(%r{\A[A-Za-z0-9._/-]+\z})

    old_commit = lock[/^  commit: ([0-9a-f]{40})$/, 1] or raise Error, 'images.lock: source.commit not found'
    raise Error, "commit #{commit} is already recorded" if commit == old_commit

    lock_l = lock.lines
    values_l = values.lines
    wf_l = workflow.lines
    changes = []
    changes << replace_once(lock_l, 'images.lock source.branch', /^  branch: \S+/) { |l| l.sub(/branch: \S+/, "branch: #{branch}") }
    changes << replace_once(lock_l, 'images.lock source.commit', /^  commit: [0-9a-f]{40}/) { |l| l.sub(old_commit, commit) }
    changes << replace_once(wf_l, 'workflow SOURCE_COMMIT', /^  SOURCE_COMMIT: [0-9a-f]{40}$/) { |l| l.sub(/[0-9a-f]{40}/, commit) }
    digests.each do |image, digest|
      hex = digest.delete_prefix('sha256:')
      changes << replace_once(lock_l, "images.lock #{image}", /^  - \{image: #{Regexp.escape(image)}, .*tag: be293-[0-9a-f]{40}, digest: "[0-9a-f]{64}"\}/,
                              section: 'rebuilt') do |l|
        raise Error, "#{image}: digest equals the currently recorded one (stale input?)" if l.include?(%("#{hex}"))

        l.sub(/tag: be293-[0-9a-f]{40}/, "tag: be293-#{commit}").sub(/digest: "[0-9a-f]{64}"/, %(digest: "#{hex}"))
      end
      changes << replace_once(values_l, "values #{image}", /^\s+\w+tag: "be293-[0-9a-f]{40}@sha256:[0-9a-f]{64}"$/,
                              after: %r{^\s+name: "[^"]+/#{Regexp.escape(image)}"$}) do |l|
        l.sub(/"be293-[0-9a-f]{40}@sha256:[0-9a-f]{64}"/, %("be293-#{commit}@#{digest}"))
      end
    end
    [lock_l.join, values_l.join, wf_l.join, changes]
  end
end

if $PROGRAM_NAME == __FILE__
  opts = { write: false }
  OptionParser.new do |o|
    o.on('--commit SHA') { |v| opts[:commit] = v }
    o.on('--branch NAME') { |v| opts[:branch] = v }
    o.on('--digests FILE') { |v| opts[:digests] = v }
    o.on('--write') { opts[:write] = true }
  end.parse!
  abort('usage: --commit SHA --branch NAME --digests FILE [--write]') unless opts[:commit] && opts[:branch] && opts[:digests]

  here = File.expand_path('..', __dir__)
  files = { lock: 'images.lock.yaml', values: 'values-be293-portal.yaml', workflow: 'ci/be293-portal-images.yml' }.transform_values { |f| File.join(here, f) }
  begin
    digests = RecordPortalImages.parse_digests(File.read(opts[:digests]))
    lock, values, workflow, changes = RecordPortalImages.apply(*files.values.map { |f| File.read(f) },
                                                               commit: opts[:commit], branch: opts[:branch], digests: digests)
  rescue RecordPortalImages::Error, Errno::ENOENT => e
    warn "REFUSED: #{e.message}"
    exit 1
  end
  changes.each { |label, old, new| puts "#{label}:\n  - #{old}\n  + #{new}" }
  if opts[:write]
    File.write(files[:lock], lock)
    File.write(files[:values], values)
    File.write(files[:workflow], workflow)
    puts "WRITTEN #{changes.size} changes. Next: ruby tools/check_package.rb . && bash tools/render-release.sh"
  else
    puts "DRY RUN: #{changes.size} changes, nothing written (add --write)"
  end
end
