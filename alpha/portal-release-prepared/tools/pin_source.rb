# frozen_string_literal: true

# Re-pin the BE-293 Portal package to a new ARENA2036/portal-backend commit, consistently in:
#   ci/be293-portal-images.yml   env.SOURCE_COMMIT; drops the CI Dockerfile patch for maintenance when
#                                --upstream-dockerfile-fixed is given (the pinned commit then contains it)
#   images.lock.yaml             source.commit and every rebuilt tag
#   values-be293-portal.yaml     every rebuilt image tag
# Tags follow the CI scheme `be293-<full 40-char sha>`; digests are left as <<IMAGE:...>> placeholders.
#
# Usage: ruby tools/pin_source.rb <40-hex-sha> [--upstream-dockerfile-fixed] [PACKAGE_DIR]

PKG_DEFAULT = File.expand_path('..', __dir__)
REBUILT_TAG_KEYS = %w[administrationservicetag registrationservicetag appmarketplaceservicetag servicesservicetag
                      notificationservicetag portalmaintenancetag portalmigrationstag processesworkertag].freeze

def die(msg)
  warn msg
  exit 2
end

def rewrite(path)
  text = File.read(path)
  updated = yield(text.dup)
  File.write(path, updated) unless updated == text
  updated != text
end

sha = ARGV.find { |a| a.match?(/\A[0-9a-f]{40}\z/) } or die('usage: pin_source.rb <40-hex-sha> [--upstream-dockerfile-fixed] [PACKAGE_DIR]')
fixed = ARGV.include?('--upstream-dockerfile-fixed')
pkg = ARGV.reject { |a| a == sha || a.start_with?('--') }.first || PKG_DEFAULT
workflow = File.join(pkg, 'ci', 'be293-portal-images.yml')
lock = File.join(pkg, 'images.lock.yaml')
values = File.join(pkg, 'values-be293-portal.yaml')
[workflow, lock, values].each { |f| die("missing #{f}") unless File.file?(f) }
tag = "be293-#{sha}"

rewrite(workflow) do |t|
  count = t.scan(/^  SOURCE_COMMIT: [0-9a-f]{40}$/).size
  die("expected exactly one SOURCE_COMMIT in #{workflow}, found #{count}") unless count == 1
  t = t.sub(/^  SOURCE_COMMIT: [0-9a-f]{40}$/, "  SOURCE_COMMIT: #{sha}")
  t = t.sub(/^(# BE-293 Portal backend images from ARENA2036\/portal-backend@)[0-9a-f]{40}/, "\\1#{sha}")
  if fixed
    # The pinned commit carries the Dockerfile fix: remove the CI-side patch step entirely and build every
    # image from its upstream Dockerfile again.
    start = t.index('      # Build-input fix for the pinned source')
    stop = t.index('      - name: Set up Docker Buildx')
    if start && stop && start < stop
      t = t[0...start] + t[stop..-1]
    elsif t.include?('id: dockerfile')
      die('cannot locate the Prepare Dockerfile step boundaries; edit the workflow manually')
    end
    t = t.gsub(', patch: onboarding-walletprovider}', '}')
    t = t.gsub('file: ${{ steps.dockerfile.outputs.path }}', 'file: ${{ matrix.dockerfile }}')
  end
  t
end

rewrite(lock) do |t|
  t = t.sub(/^(  commit: )[0-9a-f]{9,40}\b/, "\\1#{sha}")
  t.gsub(/tag: be293-[0-9a-f]{9,40}\b/, "tag: #{tag}")
end

rewrite(values) do |t|
  REBUILT_TAG_KEYS.each do |k|
    n = t.scan(/^(\s+#{k}: ")be293-[0-9a-f]{9,40}(@sha256:)/).size
    die("expected one #{k} in #{values}, found #{n}") unless n == 1
    t = t.sub(/^(\s+#{k}: ")be293-[0-9a-f]{9,40}(@sha256:)/, "\\1#{tag}\\2")
  end
  t
end

puts "pinned #{sha} (tag #{tag})#{fixed ? ', CI Dockerfile patch disabled' : ''} in #{pkg}"
