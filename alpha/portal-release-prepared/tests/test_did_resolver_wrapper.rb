# frozen_string_literal: true

# Behavioural tests for tools/did-resolver-be293.sh --pin with a stub registry (stub curl; no network, no cluster).
#   accepted  single-platform Docker schema 2 manifest whose config is linux/amd64 (the uport driver case) and a
#             multi-platform OCI index with a linux/amd64 image (the nginx-unprivileged case)
#   rejected  wrong architecture, missing os/architecture, index without (or with ambiguous) linux/amd64,
#             unexpected manifest types, and every digest mismatch (top level, child manifest, config blob)
# Every rejection must leave the manifest unpinned (fail closed).
#
# Run: ruby tests/test_did_resolver_wrapper.rb

require 'minitest/autorun'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

class DidResolverWrapperTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  SCRIPT = File.join(HERE, 'tools/did-resolver-be293.sh')
  DOCKER_V2 = 'application/vnd.docker.distribution.manifest.v2+json'
  OCI_MANIFEST = 'application/vnd.oci.image.manifest.v1+json'
  OCI_INDEX = 'application/vnd.oci.image.index.v1+json'
  DRIVER = 'uport/uni-resolver-driver-did-uport'
  GATEWAY = 'nginxinc/nginx-unprivileged'

  def setup
    @dir = Dir.mktmpdir('be293-did-resolver-pin')
    @bin = File.join(@dir, 'bin')
    @reg = File.join(@dir, 'registry')
    FileUtils.mkdir_p([@bin, @reg])
    @manifest = File.join(@dir, 'did-resolver-be293.alpha.yaml')
    FileUtils.cp(File.join(HERE, 'did-resolver-be293.alpha.yaml'), @manifest)
    unpin!
    write_curl
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  # The repository copy may already be pinned; tests always start from placeholders.
  def unpin!
    s = File.read(@manifest)
    s = s.sub(/(did-uport:5\.0\.8@)sha256:\h{64}/, '\1sha256:<<PIN:UNI_RESOLVER_DRIVER_DID_UPORT_5.0.8_INDEX_DIGEST>>')
    s = s.sub(/(nginx-unprivileged:1\.28\.0-alpine@)sha256:\h{64}/, '\1sha256:<<PIN:NGINX_UNPRIVILEGED_1.28.0_ALPINE_INDEX_DIGEST>>')
    File.write(@manifest, s)
  end

  # --- stub registry ------------------------------------------------------------------------------------------
  def sha(body)
    "sha256:#{Digest::SHA256.hexdigest(body)}"
  end

  # Stores a registry object; refs are tags or digests. Returns the content digest.
  def put(repo, ref, body, type: nil, digest_header: nil)
    d = File.join(@reg, repo.tr('/', '_'))
    FileUtils.mkdir_p(d)
    File.write(File.join(d, ref.tr(':', '_')), body)
    File.write(File.join(d, "#{ref.tr(':', '_')}.meta"), JSON.generate('type' => type, 'digest' => digest_header || sha(body)))
    sha(body)
  end

  def config(os: 'linux', arch: 'amd64')
    JSON.generate({ 'architecture' => arch, 'os' => os, 'config' => {} }.compact)
  end

  def image(repo, cfg, type: DOCKER_V2, cfg_type: 'application/vnd.docker.container.image.v1+json', tamper_config: false)
    put(repo, "blob-#{sha(cfg)}", tamper_config ? "#{cfg} " : cfg); cd = sha(cfg)
    body = JSON.pretty_generate('schemaVersion' => 2, 'mediaType' => type,
                                'config' => { 'mediaType' => cfg_type, 'digest' => cd, 'size' => cfg.bytesize },
                                'layers' => [{ 'mediaType' => 'application/vnd.docker.image.rootfs.diff.tar.gzip', 'digest' => sha('layer'), 'size' => 5 }]) + "\n"
    [body, cd]
  end

  def single(repo, tag, **kw)
    body, = image(repo, config(**kw.slice(:os, :arch)), **kw.reject { |k, _| %i[os arch].include?(k) })
    put(repo, tag, body, type: kw[:type] || DOCKER_V2)
  end

  def index(repo, tag, platforms: [%w[linux amd64], %w[linux arm64]], tamper_child: false)
    entries = platforms.map do |os, arch|
      body, = image(repo, config(os: os, arch: arch), type: OCI_MANIFEST, cfg_type: 'application/vnd.oci.image.config.v1+json')
      d = sha(body)
      put(repo, d, tamper_child && arch == 'amd64' ? body.sub('"schemaVersion"', '"schemaVersion" ') : body, type: OCI_MANIFEST, digest_header: d)
      { 'mediaType' => OCI_MANIFEST, 'digest' => d, 'size' => body.bytesize, 'platform' => { 'os' => os, 'architecture' => arch } }
    end
    put(repo, tag, JSON.generate('schemaVersion' => 2, 'mediaType' => OCI_INDEX, 'manifests' => entries), type: OCI_INDEX)
  end

  def write_curl
    File.write(File.join(@bin, 'curl'), <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      a = ARGV
      url = a.last
      if url.include?('auth.docker.io') then print '{"token":"anonymous-test-token"}'; exit 0 end
      m = url.match(%r{/v2/(.+)/(manifests|blobs)/([^/]+)\\z}) or exit 7
      repo, what, ref = m[1], m[2], m[3]
      ref = "blob-\#{ref}" if what == 'blobs'
      f = File.join('#{@reg}', repo.tr('/', '_'), ref.tr(':', '_'))
      exit 22 unless File.exist?(f)
      meta = JSON.parse(File.read("\#{f}.meta"))
      hdr = "HTTP/1.1 200 OK\\r\\n"
      hdr += "Content-Type: \#{meta['type']}\\r\\n" if meta['type']
      hdr += "Docker-Content-Digest: \#{meta['digest']}\\r\\n" if what == 'manifests'
      File.write(a[a.index('-D') + 1], hdr + "\\r\\n")
      File.binwrite(a[a.index('-o') + 1], File.binread(f))
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'curl'))
  end

  def pin
    Open3.capture2e({ 'PATH' => "#{@bin}:#{ENV['PATH']}", 'DID_RESOLVER_MANIFEST' => @manifest, 'ALPHA_KUBECONFIG' => '/nonexistent' },
                    'bash', SCRIPT, '--pin', stdin_data: '')
  end

  def pinned?(repo)
    File.read(@manifest).match?(/#{Regexp.escape(repo)}:[^@"]+@sha256:\h{64}"/)
  end

  # --- tests --------------------------------------------------------------------------------------------------
  def test_pins_single_platform_driver_and_multi_platform_gateway
    driver = single(DRIVER, '5.0.8')
    gateway = index(GATEWAY, '1.28.0-alpine')
    out, st = pin
    assert st.success?, out
    text = File.read(@manifest)
    assert_includes text, "docker.io/#{DRIVER}:5.0.8@#{driver}"
    assert_includes text, "docker.io/#{GATEWAY}:1.28.0-alpine@#{gateway}"
    assert_match(/#{DRIVER}:5\.0\.8 -> #{driver} \(single-platform manifest; .* is linux\/amd64\)/, out)
    assert_match(/#{GATEWAY}:1\.28\.0-alpine -> #{gateway} \(multi-platform index; .* is linux\/amd64\)/, out)
    refute_includes out, 'anonymous-test-token'
  end

  def test_single_platform_oci_manifest_is_accepted
    single(DRIVER, '5.0.8', type: OCI_MANIFEST, cfg_type: 'application/vnd.oci.image.config.v1+json')
    index(GATEWAY, '1.28.0-alpine')
    out, st = pin
    assert st.success?, out
  end

  def test_rejects_driver_built_for_another_architecture
    single(DRIVER, '5.0.8', arch: 'arm64')
    index(GATEWAY, '1.28.0-alpine')
    out, st = pin
    refute st.success?
    assert_match(/config: image is linux\/arm64, need linux\/amd64/, out)
    assert_match(/not verified as linux\/amd64/, out)
    refute pinned?(DRIVER)
  end

  def test_rejects_config_without_platform_metadata
    single(DRIVER, '5.0.8', os: nil, arch: nil)
    out, st = pin
    refute st.success?
    assert_match(/config: missing os\/architecture/, out)
    refute pinned?(DRIVER)
  end

  def test_rejects_index_without_amd64_or_with_ambiguous_amd64
    single(DRIVER, '5.0.8')
    index(GATEWAY, '1.28.0-alpine', platforms: [%w[linux arm64]])
    out, st = pin
    refute st.success?
    assert_match(/index: no linux\/amd64 manifest/, out)
    refute pinned?(GATEWAY)
    index(GATEWAY, '1.28.0-alpine', platforms: [%w[linux amd64], %w[linux amd64]])
    out, st = pin
    refute st.success?
    assert_match(/2 linux\/amd64 manifests \(ambiguous\)/, out)
  end

  def test_rejects_unexpected_manifest_types
    put(DRIVER, '5.0.8', '{"schemaVersion":1,"name":"x"}', type: 'application/vnd.docker.distribution.manifest.v1+prettyjws')
    out, st = pin
    refute st.success?
    assert_match(/unexpected manifest type 'application\/vnd\.docker\.distribution\.manifest\.v1\+prettyjws'/, out)
    put(DRIVER, '5.0.8', '{}', type: nil)
    out, st = pin
    refute st.success?
    assert_match(/unexpected manifest type '<none>'/, out)
    refute pinned?(DRIVER)
  end

  # --- --diff (read-only drift and ownership check) --------------------------------------------------------
  def write_kubectl(owner: '|', diff_rc: 0)
    File.write(File.join(@dir, 'alpha.yaml'), '')
    File.write(File.join(@bin, 'kubectl'), <<~RUBY)
      #!/usr/bin/env ruby
      a = ARGV.join(' ')
      File.open('#{@dir}/kubectl.log', 'a') { |f| f.puts a }
      if a.include?('config get-contexts') then puts 'alpha'; exit 0 end
      if a.include?(' get ') && a.include?('jsonpath') then print #{owner.inspect}; exit 0 end
      if a.include?(' diff -f ') then puts '+  replicas: 2' if #{diff_rc} == 1; exit #{diff_rc} end
      warn "stub kubectl: unexpected \#{a}"; exit 3
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'kubectl'))
  end

  def diff_mode
    Open3.capture2e({ 'PATH' => "#{@bin}:#{ENV['PATH']}", 'DID_RESOLVER_MANIFEST' => @manifest, 'ALPHA_KUBECONFIG' => File.join(@dir, 'alpha.yaml') },
                    'bash', SCRIPT, '--diff', stdin_data: '')
  end

  def test_diff_reports_no_drift_and_only_reads
    write_kubectl
    out, st = diff_mode
    assert st.success?, out
    assert_match(/OK      deployment\/be293-did-resolver \(not Helm-managed\)/, out)
    assert_match(/NO DRIFT/, out)
    log = File.read(File.join(@dir, 'kubectl.log'))
    refute_match(/ (apply|create|patch|delete|replace|edit|scale|rollout restart) /, log)
    assert_match(/ diff -f /, log)
  end

  def test_diff_shows_drift_without_changing_anything
    write_kubectl(diff_rc: 1)
    out, st = diff_mode
    assert st.success?, out
    assert_match(/DRIFT above/, out)
  end

  def test_diff_refuses_helm_owned_resolver_objects
    write_kubectl(owner: 'Helm|be293-portal')
    out, st = diff_mode
    refute st.success?
    assert_match(/owned by Helm \(Helm\|be293-portal\)/, out)
    refute_match(/ diff -f /, File.read(File.join(@dir, 'kubectl.log')))
  end

  def test_rejects_every_digest_mismatch
    body, = image(DRIVER, config)
    put(DRIVER, '5.0.8', body, type: DOCKER_V2, digest_header: "sha256:#{'c' * 64}")
    out, st = pin
    refute st.success?
    assert_match(/content does not match its digest/, out)

    single(DRIVER, '5.0.8', tamper_config: true)
    out, st = pin
    refute st.success?
    assert_match(/config blob does not match its digest/, out)

    single(DRIVER, '5.0.8')
    index(GATEWAY, '1.28.0-alpine', tamper_child: true)
    out, st = pin
    refute st.success?
    assert_match(/linux\/amd64 manifest does not match its digest/, out)
    refute pinned?(GATEWAY)

    put(DRIVER, '5.0.8', body, type: DOCKER_V2, digest_header: 'md5:abc')
    out, st = pin
    refute st.success?
    assert_match(/no valid Docker-Content-Digest/, out)
  end
end
