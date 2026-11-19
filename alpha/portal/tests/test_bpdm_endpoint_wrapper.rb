# frozen_string_literal: true

# Behavioural tests for tools/bpdm-endpoint-be293.sh with stub kubectl/curl (no cluster, no BPDM).
#   default    offline gates + read-only be293/release26-09 reads + anonymous OpenAPI GETs + dry-run patch only
#   refusals   live API version differs from the reviewed values, OpenAPI unverifiable, dry run touching more
#   scope      release26-09 is only read; BPDM only receives GETs; be293 only a dry-run patch
#
# Run: ruby tests/test_bpdm_endpoint_wrapper.rb

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'support/pinned_smtp4dev'
require_relative 'support/pinned_did_resolver'

class BpdmEndpointWrapperTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  SCRIPT = File.join(HERE, 'tools/bpdm-endpoint-be293.sh')
  H = 'https://business-partners.test.tractus-x.com'

  def setup
    skip 'helm not installed' if `command -v helm`.strip.empty?
    @dir = Dir.mktmpdir('be293-bpdm-test')
    @bin = File.join(@dir, 'bin')
    FileUtils.mkdir_p(@bin)
    @kc = File.join(@dir, 'alpha.yaml')
    File.write(@kc, '')
    write_fixtures
    write_kubectl
    write_curl
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def env(gate, pool)
    [{ 'name' => 'APPLICATIONCHECKLIST__BPDM__BASEADDRESS', 'value' => "#{H}#{gate}" },
     { 'name' => 'APPLICATIONCHECKLIST__BPDM__CLIENTSECRET', 'valueFrom' => { 'secretKeyRef' => { 'name' => 'be293-portal-bpdm', 'key' => 'k' } } },
     { 'name' => 'APPLICATIONCHECKLIST__BPDM__BUSINESSPARTNERPOOLBASEADDRESS', 'value' => "#{H}#{pool}" }]
  end

  def write_fixtures
    worker = { 'kind' => 'CronJob', 'metadata' => { 'name' => 'be293-portal-processes-worker' },
               'spec' => { 'schedule' => '*/5 * * * *', 'jobTemplate' => { 'spec' => { 'template' => { 'spec' => {
                 'containers' => [{ 'name' => 'be293-portal-processes-worker', 'env' => env('/gate', '/pool') }] } } } } } }
    dep = ->(n, e) { { 'kind' => 'Deployment', 'metadata' => { 'name' => n }, 'spec' => { 'template' => { 'spec' => { 'containers' => [{ 'name' => n, 'image' => 'x', 'env' => e }] } } } } }
    File.write("#{@dir}/cronjob.json", JSON.generate(worker))
    File.write("#{@dir}/deployment.json", JSON.generate(dep.call('be293-portal-registration-service', [{ 'name' => 'BPNACCESS__BASEADDRESS', 'value' => "#{H}/pool" }])))
    File.write("#{@dir}/shared-workloads.json", JSON.generate('items' => [
      dep.call('portal-backend-administration-service', env('/gate/v6', '/pool/v6')),
      dep.call('bpdm-bpdm-gate', []).tap { |d| d['spec']['template']['spec']['containers'][0]['image'] = 'docker.io/tractusx/bpdm-gate:7.5.0' }
    ]))
    File.write("#{@dir}/shared-ingress.json", JSON.generate('items' => [{
      'metadata' => { 'name' => 'bpdm-bpdm-gate', 'annotations' => { 'nginx.ingress.kubernetes.io/rewrite-target' => '/$2', 'nginx.ingress.kubernetes.io/x-forwarded-prefix' => '/gate' } },
      'spec' => { 'rules' => [{ 'host' => 'business-partners.test.tractus-x.com', 'http' => { 'paths' => [
        { 'path' => '/gate(/|$)(.*)', 'pathType' => 'ImplementationSpecific', 'backend' => { 'service' => { 'name' => 'bpdm-bpdm-gate', 'port' => { 'number' => 80 } } } }] } }] } }]))
  end

  def write_kubectl
    File.write(File.join(@bin, 'kubectl'), <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      a = ARGV.join(' ')
      File.open('#{@dir}/kubectl.log', 'a') { |f| f.puts a }
      if a.include?('config get-contexts') then puts 'alpha'; exit 0 end
      if a.include?(' patch ') && !a.include?('--dry-run=server') then File.open('#{@dir}/kubectl.log', 'a') { |f| f.puts 'REAL-MUTATION' }; exit 0 end
      if a.include?('-n release26-09 ')
        exit 4 unless a.include?(' get ')
        if a.include?('get ingress') then print File.read('#{@dir}/shared-ingress.json') else print File.read('#{@dir}/shared-workloads.json') end
        exit 0
      end
      if a.include?(' exec ') then File.write('#{@dir}/sql.log', $stdin.read); puts 'application_id | bpn_entry'; exit 0 end
      if a.include?(' get cronjob/') then print File.read('#{@dir}/cronjob.json'); exit 0 end
      if a.include?(' get deployment/') then print File.read('#{@dir}/deployment.json'); exit 0 end
      if a.include?(' patch cronjob be293-portal-processes-worker ') && a.include?('--dry-run=server')
        obj = JSON.parse(File.read('#{@dir}/cronjob.json'))
        c = obj['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]
        JSON.parse(ARGV[ARGV.index('-p') + 1])['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['env'].each do |e|
          c['env'].find { |x| x['name'] == e['name'] }.replace(e)
        end
        obj['spec']['suspend'] = true if ENV['STUB_PATCH_EXTRA']
        print JSON.generate(obj); exit 0
      end
      warn "stub kubectl: unexpected \#{a}"; exit 3
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'kubectl'))
  end

  def write_curl
    File.write(File.join(@bin, 'curl'), <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      require '#{File.join(HERE, 'tests/support/bpdm_openapi_fixture')}'
      File.open('#{@dir}/curl.log', 'a') { |f| f.puts ARGV.inspect }
      url = ARGV.last
      out = ARGV[ARGV.index('-o') + 1]
      v = ENV['STUB_API_VERSION'] || '/v6'
      doc = if ENV['STUB_NO_DOCS'] || !url.end_with?('/docs/api-docs') then nil
            elsif url.include?('/gate/') then BpdmOpenApiFixture.gate(v, drop: ENV['STUB_GATE_DROP']&.to_sym)
            else BpdmOpenApiFixture.pool(v, member_field: ENV['STUB_POOL_MEMBER'] || 'isCatenaXMember')
            end
      File.write(out, doc ? JSON.generate(doc) : 'not found')
      print(doc ? '200' : '404')
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'curl'))
  end

  def run_script(*args, env: {})
    full = { 'PATH' => "#{@bin}:#{ENV['PATH']}", 'ALPHA_KUBECONFIG' => @kc, 'SMTP4DEV_MANIFEST' => PinnedSmtp4dev.manifest(@dir), 'DID_RESOLVER_MANIFEST' => PinnedDidResolver.manifest(@dir),
             'HELM_CACHE_HOME' => "#{@dir}/hc", 'HELM_CONFIG_HOME' => "#{@dir}/hcfg", 'HELM_DATA_HOME' => "#{@dir}/hd" }.merge(env)
    Open3.capture2e(full, 'bash', SCRIPT, *args, stdin_data: '')
  end

  def log
    File.exist?("#{@dir}/kubectl.log") ? File.read("#{@dir}/kubectl.log") : ''
  end

  def test_default_verifies_live_api_and_dry_runs_the_worker_patch_only
    out, st = run_script
    assert st.success?, out.lines.last(20).join
    assert_match(%r{reviewed values: gate #{H}/gate/v6 · pool #{H}/pool/v6}, out)
    assert_match(%r{cronjob/be293-portal-processes-worker APPLICATIONCHECKLIST__BPDM__BASEADDRESS=#{H}/gate$}, out)
    assert_match(%r{portal-backend-administration-service APPLICATIONCHECKLIST__BPDM__BASEADDRESS=#{H}/gate/v6}, out, 'release26-09 reference shown')
    assert_match(%r{ingress/bpdm-bpdm-gate /gate\(/\|\$\)\(\.\*\) \(ImplementationSpecific\) -> bpdm-bpdm-gate:80 rewrite-target="/\$2"}, out)
    assert_match(%r{image docker.io/tractusx/bpdm-gate:7.5.0}, out)
    assert_match(/OK gate prefix=\/v6 title="Business Partner Data Management Gate" version="7.5.0"/, out)
    assert_match(%r{SCHEMA OK PUT /v6/input/business-partners}, out)
    assert_match(%r{SCHEMA OK GET /v6/sharing-state}, out)
    assert_match(%r{WARN pool schema differs.*\n.*SCHEMA MISMATCH PUT /v6/cx-memberships: missing memberships\[\]\.isArenaXMember \(not used by BPN Creation\)}, out)
    assert_match(%r{verified gate base: #{H}/gate/v6   \(PUT #{H}/gate/v6/input/business-partners\)}, out)
    assert_match(/only APPLICATIONCHECKLIST__BPDM__BASEADDRESS and APPLICATIONCHECKLIST__BPDM__BUSINESSPARTNERPOOLBASEADDRESS change/, out)
    refute_match(/CLIENTSECRET=[^<]/, out)
    assert_match(/DRY RUN COMPLETE/, out)
    refute_includes log, 'REAL-MUTATION'
    assert(log.lines.grep(/-n release26-09 /).all? { |l| l.include?(' get ') }, 'release26-09 read-only')
    assert(log.lines.grep(/ patch /).all? { |l| l.include?('--dry-run=server') && l.include?('-n be293 ') })
    curl = File.read("#{@dir}/curl.log")
    refute_match(/"-X"|"--request"|"-d"|"--data|"-T"|"PUT"|"POST"/, curl, 'BPDM receives GETs only')
    assert(curl.lines.all? { |l| l.include?('"--proto", "=https"') })
  end

  def test_aborts_when_live_api_version_differs_from_reviewed_values
    out, st = run_script(env: { 'STUB_API_VERSION' => '/v7' })
    refute st.success?
    assert_match(%r{set bpdm.portalGateApiPath=/gate/v7 and bpdm.poolApiPath=/pool/v7}, out)
    assert_empty log.lines.grep(/ patch /)
  end

  def test_aborts_when_gate_schema_lacks_a_field_bpn_creation_sends
    out, st = run_script(env: { 'STUB_GATE_DROP' => 'street_name' })
    refute st.success?
    assert_match(/SCHEMA MISMATCH PUT \/v6\/input\/business-partners: missing \[\]\.address\.physicalPostalAddress\.street\.name \(blocks BPN Creation\)/, out)
    assert_match(/does not accept\/return the fields the pinned backend uses for BPN Creation/, out)
    assert_empty log.lines.grep(/ patch /)
  end

  def test_no_pool_warning_when_pool_accepts_the_backend_membership_field
    out, st = run_script(env: { 'STUB_POOL_MEMBER' => 'isArenaXMember' })
    assert st.success?, out.lines.last(20).join
    refute_match(/WARN pool schema/, out)
    assert_match(%r{SCHEMA OK PUT /v6/cx-memberships}, out)
  end

  def test_aborts_when_openapi_cannot_be_verified
    out, st = run_script(env: { 'STUB_NO_DOCS' => '1' })
    refute st.success?
    assert_match(/could not verify the live gate API/, out)
    assert_empty log.lines.grep(/ patch /)
  end

  def test_rejects_a_dry_run_that_changes_more_and_execute_needs_a_terminal
    out, st = run_script(env: { 'STUB_PATCH_EXTRA' => '1' })
    refute st.success?
    assert_match(/changes more than APPLICATIONCHECKLIST__BPDM__BASEADDRESS/, out)
    out, st = run_script('--execute')
    refute st.success?
    assert_match(/no terminal for confirmation/, out)
    refute_includes log, 'REAL-MUTATION'
  end

  def test_verify_is_read_only_and_skips_shared_namespace
    out, st = run_script('--verify')
    assert st.success?, out
    assert_match(/reviewed \(render\): gate #{Regexp.escape(H)}\/gate\/v6/, out)
    refute_match(/release26-09|patch/, log)
  end

  def test_bpn_status_runs_read_only_sql_only
    out, st = run_script('--bpn-status')
    assert st.success?, out
    sql = File.read("#{@dir}/sql.log")
    assert_match(/\ABEGIN READ ONLY;/, sql)
    assert_match(/ROLLBACK;\s*\z/, sql)
    refute_match(/\b(INSERT|UPDATE|DELETE|ALTER|DROP|TRUNCATE|CREATE|GRANT|COMMIT)\b/i, sql)
    assert_match(/RETRIGGER_BUSINESS_PARTNER_NUMBER_PUSH/, sql)
    assert_match(/<email>/, sql, 'step messages are masked')
    assert_includes log, 'exec -i be293-portal-postgresql-0 -c postgresql'
    refute_match(/release26-09| patch /, log)
    assert_match(/Retrigger only after the worker uses the verified addresses/, out)
  end
end
