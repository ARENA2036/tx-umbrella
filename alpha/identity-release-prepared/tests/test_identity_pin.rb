# frozen_string_literal: true

# Tests for tools/identity-pin-be293.sh with a stub curl (no network). The script and the values files are copied into a
# temporary package, so the real values files are never modified. Covers both registry manifest shapes:
# a manifest list / OCI index (platform entries) and a single-platform v2 manifest (platform from the config blob).
#
# Run: ruby tests/test_identity_pin.rb

require 'minitest/autorun'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'yaml'

class IdentityPinTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  IMAGES = %w[tractusx/issuerservice:0.4.1 tractusx/identityhub:0.4.1 hashicorp/vault:1.18.1 tractusx/bdrs-server:0.6.0
              tractusx/edc-controlplane-postgresql-hashicorp-vault:0.13.0 tractusx/edc-dataplane-hashicorp-vault:0.13.0
              nginxinc/nginx-unprivileged:1.27-alpine].freeze
  PINNED_FILES = ['values-be293-*.yaml', 'edc-datasource-be293.alpha.yaml'].freeze

  def setup
    @dir = Dir.mktmpdir('be293-pin-test')
    @pkg = File.join(@dir, 'pkg')
    FileUtils.mkdir_p(File.join(@pkg, 'tools'))
    FileUtils.cp(File.join(HERE, 'tools/identity-pin-be293.sh'), File.join(@pkg, 'tools'))
    PINNED_FILES.flat_map { |g| Dir[File.join(HERE, g)] }.each { |f| FileUtils.cp(f, @pkg) }
    unpin_copies
    @bin = File.join(@dir, 'bin')
    FileUtils.mkdir_p(@bin)
    write_curl
  end

  # The shipped files may already be pinned; the copies get their placeholders back (each digest recorded in
  # images.lock.identity.yaml maps to exactly one image reference), so the tests do not depend on the pin state.
  def unpin_copies
    lock = File.join(HERE, 'images.lock.identity.yaml')
    entries = File.exist?(lock) ? YAML.safe_load(File.read(lock))['images'] : []
    files = Dir[File.join(@pkg, '*.yaml')]
    entries.each do |e|
      ph = "<<PIN:#{e['image'].sub(%r{\Adocker\.io/}, '')}:#{e['tag']}>>"
      files.each { |f| File.write(f, File.read(f).gsub(e['digest'], ph)) }
    end
    text = files.map { |f| File.read(f) }.join
    IMAGES.each { |ref| raise "placeholder for #{ref} not present in the copies" unless text.include?("<<PIN:#{ref}>>") }
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def digest_for(ref)
    "sha256:#{Digest::SHA256.hexdigest(ref)}"
  end

  # STUB_SHAPES: "repo=index|single|single-arm64|index-arm64"; default: issuerservice single, the rest index.
  def write_curl
    File.write(File.join(@bin, 'curl'), <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      require 'digest'
      args = ARGV.dup
      url = args.last
      File.open('#{@dir}/curl.log', 'a') { |f| f.puts args.join(' ') }
      shapes = { 'tractusx/issuerservice' => 'single' }
      (ENV['STUB_SHAPES'] || '').split(',').each { |p| k, v = p.split('='); shapes[k] = v }
      if url.start_with?('https://auth.docker.io/token')
        print JSON.generate('token' => 'stub-token'); exit 0
      end
      if (m = url.match(%r{/v2/(.+)/manifests/(.+)\\z}))
        repo, tag = m[1], m[2]
        shape = shapes.fetch(repo, 'index')
        hdr = args[args.index('-D') + 1]
        File.write(hdr, "HTTP/1.1 200 OK\\r\\nDocker-Content-Digest: sha256:\#{Digest::SHA256.hexdigest("\#{repo}:\#{tag}")}\\r\\n\\r\\n")
        arch = shape.end_with?('arm64') ? 'arm64' : 'amd64'
        if shape.start_with?('index')
          print JSON.generate('mediaType' => 'application/vnd.oci.image.index.v1+json',
                              'manifests' => [{ 'digest' => 'sha256:' + 'a' * 64, 'platform' => { 'os' => 'linux', 'architecture' => arch } }])
        else
          print JSON.generate('mediaType' => 'application/vnd.docker.distribution.manifest.v2+json',
                              'config' => { 'digest' => "sha256:\#{Digest::SHA256.hexdigest("cfg-\#{arch}")}" }, 'layers' => [])
        end
        exit 0
      end
      if (m = url.match(%r{/v2/(.+)/blobs/sha256:(\\h{64})\\z}))
        arch = m[2] == Digest::SHA256.hexdigest('cfg-arm64') ? 'arm64' : 'amd64'
        print JSON.generate('os' => 'linux', 'architecture' => arch); exit 0
      end
      warn "stub curl: unexpected \#{url}"; exit 22
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'curl'))
  end

  def run_pin(env = {})
    Open3.capture2e({ 'PATH' => "#{@bin}:#{ENV['PATH']}" }.merge(env), 'bash', File.join(@pkg, 'tools/identity-pin-be293.sh'), '--pin')
  end

  def values_text
    Dir[File.join(@pkg, '*.yaml')].reject { |f| f.end_with?('images.lock.identity.yaml') }.map { |f| File.read(f) }.join
  end

  def test_single_platform_and_index_manifests_are_both_pinned
    out, st = run_pin
    assert st.success?, out
    IMAGES.each do |ref|
      assert_includes out, "OK   #{ref} -> #{digest_for(ref)}"
      assert_includes values_text, digest_for(ref)
    end
    assert_match(/tractusx\/issuerservice:0.4.1 .*single-platform manifest, config says linux\/amd64/, out)
    assert_match(/hashicorp\/vault:1.18.1 .*index, linux\/amd64 entry present/, out)
    refute_includes values_text, '<<PIN:'
    lock = File.read(File.join(@pkg, 'images.lock.identity.yaml'))
    IMAGES.each { |ref| assert_includes lock, digest_for(ref) }
    log = File.read(File.join(@dir, 'curl.log'))
    assert_includes log, 'application/vnd.docker.distribution.manifest.v2+json'
    assert_match(%r{/v2/tractusx/issuerservice/blobs/sha256:}, log)
  end

  def test_single_platform_non_amd64_is_rejected_and_nothing_pinned
    out, st = run_pin('STUB_SHAPES' => 'tractusx/issuerservice=single-arm64')
    refute st.success?
    assert_includes out, 'tractusx/issuerservice:0.4.1 is single-platform linux/arm64, not linux/amd64'
    assert_includes values_text, '<<PIN:tractusx/issuerservice:0.4.1>>'
    refute File.exist?(File.join(@pkg, 'images.lock.identity.yaml'))
  end

  def test_index_without_amd64_is_rejected
    out, st = run_pin('STUB_SHAPES' => 'tractusx/identityhub=index-arm64')
    refute st.success?
    assert_includes out, 'tractusx/identityhub:0.4.1 has no linux/amd64 image in its index'
  end

  def test_only_official_repositories_are_accepted
    script = File.join(@pkg, 'tools/identity-pin-be293.sh')
    File.write(script, File.read(script).sub('"hashicorp/vault:1.18.1"', '"payammirzaeiarena/be293-images:vault"'))
    out, st = run_pin
    refute st.success?
    assert_includes out, 'refused: payammirzaeiarena/be293-images is not an approved official repository'
  end

  def test_digest_is_the_tag_manifest_digest_not_the_config_digest
    out, st = run_pin
    assert st.success?, out
    refute_includes values_text, Digest::SHA256.hexdigest('cfg-amd64')
  end
end
