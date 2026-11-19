# frozen_string_literal: true

# Behavioural tests for tools/smtp4dev-be293.sh with stub kubectl/curl (no cluster, no registry).
#   --pin      digest integrity (index must hash to Docker-Content-Digest, linux/amd64 present), writes the pin
#   default    offline gates + read-only checks + server-side dry runs only; never a real create/patch
#   refusals   existing objects are never overwritten; --execute needs a terminal
#
# Run: ruby tests/test_smtp4dev_wrapper.rb

require 'minitest/autorun'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'support/pinned_smtp4dev'
require_relative 'support/pinned_did_resolver'

class Smtp4devWrapperTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  SCRIPT = File.join(HERE, 'tools/smtp4dev-be293.sh')
  INDEX = JSON.generate('manifests' => [{ 'digest' => "sha256:#{'b' * 64}", 'platform' => { 'os' => 'linux', 'architecture' => 'amd64' } }])

  def setup
    skip 'helm not installed' if `command -v helm`.strip.empty?
    @dir = Dir.mktmpdir('be293-smtp4dev-test')
    @bin = File.join(@dir, 'bin')
    FileUtils.mkdir_p(@bin)
    @kc = File.join(@dir, 'alpha.yaml')
    File.write(@kc, '')
    write_kubectl
    write_curl
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def worker_json
    JSON.generate('spec' => { 'jobTemplate' => { 'spec' => { 'template' => { 'spec' => { 'containers' => [{
      'name' => 'be293-portal-processes-worker',
      'env' => [{ 'name' => 'MAILINGSERVICE__MAIL__SMTPHOST', 'value' => 'smtp.office365.com' },
                { 'name' => 'MAILINGSERVICE__MAIL__SMTPPASSWORD', 'valueFrom' => { 'secretKeyRef' => { 'name' => 'be293-portal-mailing', 'key' => 'password' } } },
                { 'name' => 'MAILINGSERVICE__MAIL__SMTPPORT', 'value' => '587' },
                { 'name' => 'MAILINGSERVICE__MAIL__SMTPUSER', 'value' => 'it@arena2036.de' }] }] } } } } })
  end

  def write_kubectl
    File.write("#{@dir}/worker.json", worker_json)
    File.write(File.join(@bin, 'kubectl'), <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      a = ARGV.join(' ')
      File.open('#{@dir}/kubectl.log', 'a') { |f| f.puts a }
      if a.include?('config get-contexts') then puts 'alpha'; exit 0 end
      if a.match?(/ (create|patch) /) && !a.include?('--dry-run=server')
        File.open('#{@dir}/kubectl.log', 'a') { |f| f.puts 'REAL-MUTATION' }; exit 0
      end
      if (m = a.match(/get (pvc|deployment|service|networkpolicy)\\/(\\S+) .*-o name/))
        puts "\#{m[1]}/\#{m[2]}" if ENV['STUB_EXISTS'] == m[1]; exit 0
      end
      if a.include?('get storageclass') then puts 'true'; exit 0 end
      worker = JSON.parse(File.read('#{@dir}/worker.json'))
      if a.include?('get cronjob') && a.include?('jsonpath') then print 'be293-portal-processes-worker'; exit 0 end
      if a.include?('get cronjob') then puts JSON.generate(worker); exit 0 end
      if a.include?('create --dry-run=server')
        puts %w[persistentvolumeclaim/be293-smtp4dev-data deployment.apps/be293-smtp4dev service/be293-smtp4dev networkpolicy.networking.k8s.io/be293-smtp4dev-smtp-ingress]; exit 0
      end
      if a.include?('patch cronjob')
        patch = JSON.parse(ARGV[ARGV.index('-p') + 1])
        c = worker['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]
        patch['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['env'].each do |e|
          (x = c['env'].find { |y| y['name'] == e['name'] }) ? x.replace(e) : c['env'] << e
        end
        puts JSON.generate(worker); exit 0
      end
      warn "stub kubectl: unexpected \#{a}"; exit 3
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'kubectl'))
  end

  def write_curl
    File.write("#{@dir}/index.json", INDEX)
    File.write(File.join(@bin, 'curl'), <<~RUBY)
      #!/usr/bin/env ruby
      require 'digest'
      a = ARGV.join(' ')
      if a.include?('auth.docker.io') then print '{"token":"anonymous-test-token"}'; exit 0 end
      if a.include?('/manifests/3.15.0')
        body = File.read('#{@dir}/index.json')
        digest = ENV['STUB_BAD_DIGEST'] ? "sha256:\#{'c' * 64}" : "sha256:\#{Digest::SHA256.hexdigest(body)}"
        File.write(ARGV[ARGV.index('-D') + 1], "HTTP/1.1 200 OK\\r\\nDocker-Content-Digest: \#{digest}\\r\\n\\r\\n")
        print body; exit 0
      end
      exit 7
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'curl'))
  end

  def run_script(*args, env: {}, manifest: nil)
    manifest ||= PinnedSmtp4dev.manifest(@dir)
    full = { 'PATH' => "#{@bin}:#{ENV['PATH']}", 'ALPHA_KUBECONFIG' => @kc, 'SMTP4DEV_MANIFEST' => manifest, 'DID_RESOLVER_MANIFEST' => PinnedDidResolver.manifest(@dir),
             'HELM_CACHE_HOME' => "#{@dir}/hc", 'HELM_CONFIG_HOME' => "#{@dir}/hcfg", 'HELM_DATA_HOME' => "#{@dir}/hd" }.merge(env)
    Open3.capture2e(full, 'bash', SCRIPT, *args, stdin_data: '')
  end

  def log
    File.exist?("#{@dir}/kubectl.log") ? File.read("#{@dir}/kubectl.log") : ''
  end

  def unpinned_copy
    path = File.join(@dir, 'unpinned.yaml')
    FileUtils.cp(File.join(HERE, 'smtp4dev-be293.alpha.yaml'), path)
    File.write(path, File.read(path).sub(/smtp4dev:3\.15\.0@sha256:\h{64}/, 'smtp4dev:3.15.0@sha256:<<PIN:SMTP4DEV_3.15.0_INDEX_DIGEST>>'))
    path
  end

  def test_pin_writes_verified_digest
    path = unpinned_copy
    out, st = run_script('--pin', manifest: path)
    assert st.success?, out
    digest = "sha256:#{Digest::SHA256.hexdigest(INDEX)}"
    assert_includes File.read(path), "docker.io/rnwood/smtp4dev:3.15.0@#{digest}"
    refute_includes out, 'anonymous-test-token'
    assert_empty log, 'pin must not contact the cluster'
  end

  def test_pin_rejects_digest_mismatch
    path = unpinned_copy
    out, st = run_script('--pin', manifest: path, env: { 'STUB_BAD_DIGEST' => '1' })
    refute st.success?
    assert_match(/index content does not match its digest/, out)
    assert_includes File.read(path), '<<PIN:'
  end

  def test_default_is_dry_run_only
    out, st = run_script
    assert st.success?, out.lines.last(15).join
    assert_match(/would create service\/be293-smtp4dev/, out)
    assert_match(/worker env after patch: MAILINGSERVICE__MAIL__SMTPHOST=be293-smtp4dev.be293.svc.cluster.local/, out)
    assert_match(/MAILINGSERVICE__MAIL__SMTPPASSWORD=<secretRef>/, out)
    assert_match(/DRY RUN COMPLETE/, out)
    refute_includes log, 'REAL-MUTATION'
    refute_match(/ (apply|replace|delete|exec) /, log)
    refute_match(/release26-09/, log)
    assert(log.lines.grep(/ (create|patch) /).all? { |l| l.include?('--dry-run=server') })
  end

  def test_existing_object_is_never_overwritten
    out, st = run_script(env: { 'STUB_EXISTS' => 'deployment' })
    refute st.success?
    assert_match(/deployment\/be293-smtp4dev already exists: nothing is overwritten/, out)
    assert_empty log.lines.grep(/ create /)
  end

  def test_unpinned_manifest_fails_the_gates
    out, st = run_script(manifest: unpinned_copy)
    refute st.success?
    assert_match(/\[S3\]/, out)
    assert_match(/offline gates failed/, out)
    assert_empty log.lines.grep(/ (create|patch) /)
  end

  def test_execute_requires_a_terminal
    out, st = run_script('--execute')
    refute st.success?
    assert_match(/no terminal for confirmation/, out)
    refute_includes log, 'REAL-MUTATION'
  end
end
