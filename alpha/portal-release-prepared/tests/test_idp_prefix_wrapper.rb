# frozen_string_literal: true

# Behavioural tests for tools/idp-prefix-be293.sh with stub kubectl/curl (no cluster, no Keycloak).
#   default    offline gates + read-only live/DB/Keycloak checks + server-side dry runs; never a real patch
#   refusals   different live prefix, alias already in Keycloak, dry run touching more than the env entry,
#              retrigger before the prefix is live, wrong number of eligible invitations, stale worker Job
#   privacy    Secret values never printed and never on a command line
#
# Run: ruby tests/test_idp_prefix_wrapper.rb

require 'minitest/autorun'
require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'support/pinned_smtp4dev'
require_relative 'support/pinned_did_resolver'

class IdpPrefixWrapperTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  SCRIPT = File.join(HERE, 'tools/idp-prefix-be293.sh')
  PREFIX = 'be293-alpha-idp-'
  P1 = '11111111-1111-1111-1111-111111111111'
  P2 = '22222222-2222-2222-2222-222222222222'

  def setup
    skip 'helm not installed' if `command -v helm`.strip.empty?
    @dir = Dir.mktmpdir('be293-idp-prefix-test')
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

  def kc_env
    [%w[KEYCLOAK__CENTRAL__CONNECTIONSTRING https://centralidp.test.tractus-x.com], %w[KEYCLOAK__CENTRAL__AUTHREALM CX-Central],
     %w[KEYCLOAK__CENTRAL__CLIENTID sa-cl1-reg-2], %w[KEYCLOAK__SHARED__CONNECTIONSTRING https://sharedidp.test.tractus-x.com],
     %w[KEYCLOAK__SHARED__AUTHREALM master], %w[KEYCLOAK__SHARED__CLIENTID sa-cl1-reg-1],
     %w[PROVISIONING__CENTRALREALM CX-Central], %w[PROVISIONING__SERVICEACCOUNTCLIENTPREFIX sa]].map { |n, v| { 'name' => n, 'value' => v } } +
      [{ 'name' => 'KEYCLOAK__CENTRAL__CLIENTSECRET', 'valueFrom' => { 'secretKeyRef' => { 'name' => 'be293-portal-keycloak', 'key' => 'central-client-secret' } } },
       { 'name' => 'KEYCLOAK__SHARED__CLIENTSECRET', 'valueFrom' => { 'secretKeyRef' => { 'name' => 'be293-portal-keycloak', 'key' => 'shared-client-secret' } } }]
  end

  def fixtures(live_prefix)
    env = kc_env
    env += [{ 'name' => 'PROVISIONING__IDPPREFIX', 'value' => live_prefix }] if live_prefix
    worker = { 'kind' => 'CronJob', 'metadata' => { 'name' => 'be293-portal-processes-worker' },
               'spec' => { 'suspend' => false, 'schedule' => '*/5 * * * *', 'jobTemplate' => { 'spec' => { 'template' => { 'spec' => {
                 'containers' => [{ 'name' => 'be293-portal-processes-worker', 'image' => 'w', 'env' => env }] } } } } } }
    admin = { 'kind' => 'Deployment', 'metadata' => { 'name' => 'be293-portal-administration-service' },
              'spec' => { 'replicas' => 3, 'template' => { 'spec' => {
                'containers' => [{ 'name' => 'be293-portal-administration-service', 'image' => 'a', 'env' => env }] } } } }
    File.write("#{@dir}/cronjob.json", JSON.generate(worker))
    File.write("#{@dir}/deployment.json", JSON.generate(admin))
  end

  def write_kubectl
    File.write("#{@dir}/secret.json", JSON.generate('data' => { 'central-client-secret' => Base64.strict_encode64('central-canary'),
                                                                 'shared-client-secret' => Base64.strict_encode64('shared-canary') }))
    File.write(File.join(@bin, 'kubectl'), <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      a = ARGV.join(' ')
      File.open('#{@dir}/kubectl.log', 'a') { |f| f.puts a }
      if a.include?('config get-contexts') then puts 'alpha'; exit 0 end
      if a.include?(' patch ') && !a.include?('--dry-run=server') then File.open('#{@dir}/kubectl.log', 'a') { |f| f.puts 'REAL-MUTATION' }; exit 0 end
      if a.include?(' rollout status ') then puts 'successfully rolled out'; exit 0 end
      if (m = a.match(/ get (cronjob|deployment) \\S+ -o json/)) then print File.read("#{@dir}/\#{m[1]}.json"); exit 0 end
      if a.include?(' get secret be293-portal-keycloak -o json') then print File.read('#{@dir}/secret.json'); exit 0 end
      if a.include?(' get jobs -o json')
        env = ENV['STUB_STALE_JOB'] ? [] : [{ 'name' => 'PROVISIONING__IDPPREFIX', 'value' => '#{PREFIX}' }]
        puts JSON.generate('items' => [{ 'metadata' => { 'name' => 'be293-portal-processes-worker-1', 'ownerReferences' => [{ 'kind' => 'CronJob', 'name' => 'be293-portal-processes-worker' }] },
                                         'status' => { 'active' => 1 }, 'spec' => { 'template' => { 'spec' => { 'containers' => [{ 'env' => env }] } } } }]); exit 0
      end
      if (m = a.match(/ patch (cronjob|deployment) \\S+ --type=strategic -p (.*) --dry-run=server -o json/))
        obj = JSON.parse(File.read("#{@dir}/\#{m[1]}.json"))
        patch = JSON.parse(ARGV[ARGV.index('-p') + 1])
        path = m[1] == 'cronjob' ? %w[spec jobTemplate spec template spec containers] : %w[spec template spec containers]
        pc = patch.dig(*path)[0]
        c = obj.dig(*path).find { |x| x['name'] == pc['name'] }
        pc['env'].each { |e| (x = c['env'].find { |y| y['name'] == e['name'] }) ? x.replace(e) : c['env'] << e }
        obj['spec']['replicas'] = 1 if ENV['STUB_PATCH_EXTRA'] && m[1] == 'deployment'
        print JSON.generate(obj); exit 0
      end
      if a.include?(' exec -i be293-portal-postgresql-0 ')
        sql = $stdin.read
        File.write('#{@dir}/sql.txt', sql)
        rows = ["SEQ|2", "#{P1}|t|t|0|0|t|t", "#{P2}|t|t|0|0|t|t"]
        rows << "33333333-3333-3333-3333-333333333333|t|t|0|0|t|t" if ENV['STUB_THREE']
        puts rows; exit 0
      end
      warn "stub kubectl: unexpected \#{a}"; exit 3
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'kubectl'))
  end

  def write_curl
    File.write(File.join(@bin, 'curl'), <<~RUBY)
      #!/usr/bin/env ruby
      cfg = $stdin.read
      File.open('#{@dir}/curl.log', 'a') { |f| f.puts ARGV.inspect }
      url = cfg[/^url = "(.*)"$/, 1]
      exists = ENV['STUB_KC_EXISTS']
      code, body =
        if url.end_with?('/token') then [200, '{"access_token":"tok-canary"}']
        elsif exists && url.end_with?("/instances/\#{exists}") then [200, '{}']
        elsif url =~ %r{/instances/idp2\\z} || url.end_with?('/realms/master') then [200, '{}']
        elsif url.include?('clientId=sa-cl1-reg-1') then [200, '[{"id":"x"}]']
        elsif url.include?('clientId=') then [200, '[]']
        else [404, '']
        end
      print body, "\\n", code
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'curl'))
  end

  def run_script(*args, live_prefix: nil, env: {})
    fixtures(live_prefix)
    full = { 'PATH' => "#{@bin}:#{ENV['PATH']}", 'ALPHA_KUBECONFIG' => @kc, 'SMTP4DEV_MANIFEST' => PinnedSmtp4dev.manifest(@dir), 'DID_RESOLVER_MANIFEST' => PinnedDidResolver.manifest(@dir),
             'HELM_CACHE_HOME' => "#{@dir}/hc", 'HELM_CONFIG_HOME' => "#{@dir}/hcfg", 'HELM_DATA_HOME' => "#{@dir}/hd" }.merge(env)
    Open3.capture2e(full, 'bash', SCRIPT, *args, stdin_data: '')
  end

  def log
    File.exist?("#{@dir}/kubectl.log") ? File.read("#{@dir}/kubectl.log") : ''
  end

  def assert_no_leak(out)
    %w[central-canary shared-canary tok-canary].each { |s| refute_includes out, s }
    curl_argv = File.exist?("#{@dir}/curl.log") ? File.read("#{@dir}/curl.log") : ''
    %w[central-canary shared-canary tok-canary].each { |s| refute_includes curl_argv, s }
  end

  def test_default_is_read_only_with_dry_runs
    out, st = run_script
    assert st.success?, out.lines.last(20).join
    assert_match(/OK   release render passes all gates/, out)
    assert_match(/provisioning IdP sequence: highest=2 \(next alias be293-alpha-idp-3\)/, out)
    assert_match(/eligible for retrigger-create-central-idp: 2 \(expected 2\)/, out)
    assert_match(/OK   absent in shared Keycloaks: be293-alpha-idp-1\.\.be293-alpha-idp-22/, out)
    assert_match(%r{OK   cronjob/be293-portal-processes-worker: only PROVISIONING__IDPPREFIX=be293-alpha-idp- added}, out)
    assert_match(/DRY RUN COMPLETE/, out)
    refute_includes log, 'REAL-MUTATION'
    assert(log.lines.grep(/ patch /).all? { |l| l.include?('--dry-run=server') })
    refute_match(/ (apply|create|replace|delete|scale|edit|annotate|label) /, log)
    refute_match(/release26-09/, log)
    assert(log.lines.reject { |l| l.include?('config get-contexts') }.all? { |l| l.include?("--kubeconfig #{@kc} --context alpha -n be293") })
    sql = File.read("#{@dir}/sql.txt")
    assert_match(/\ABEGIN READ ONLY;/, sql)
    refute_match(/\b(INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP|nextval|setval)\b/i, sql.gsub(/'[^']*'/, ''))
    assert_no_leak(out)
  end

  def test_refuses_a_different_live_prefix
    out, st = run_script(live_prefix: 'idp')
    refute st.success?
    assert_match(/a different PROVISIONING__IDPPREFIX \('idp'\) is already set live/, out)
    assert_empty log.lines.grep(/ patch /)
  end

  def test_refuses_when_an_alias_already_exists_in_keycloak
    out, st = run_script(env: { 'STUB_KC_EXISTS' => 'be293-alpha-idp-3' })
    refute st.success?
    assert_match(/FAIL EXISTS central IdP be293-alpha-idp-3/, out)
    assert_match(/Keycloak alias probe did not prove/, out)
    assert_empty log.lines.grep(/ patch /)
    assert_no_leak(out)
  end

  def test_refuses_a_dry_run_that_changes_more_than_the_env_entry
    out, st = run_script(env: { 'STUB_PATCH_EXTRA' => '1' })
    refute st.success?
    assert_match(/dry run changes more than PROVISIONING__IDPPREFIX/, out)
    refute_includes log, 'REAL-MUTATION'
  end

  def test_execute_requires_a_terminal
    out, st = run_script('--execute')
    refute st.success?
    assert_match(/no terminal for confirmation/, out)
    refute_includes log, 'REAL-MUTATION'
  end

  def test_retrigger_refuses_before_the_prefix_is_live
    out, st = run_script('--retrigger')
    refute st.success?
    assert_match(/not live on both workloads yet/, out)
    refute(File.exist?("#{@dir}/curl.log") && File.read("#{@dir}/curl.log").include?('retrigger'))
  end

  def test_retrigger_refuses_wrong_count_or_stale_worker_job_and_needs_a_terminal
    out, st = run_script('--retrigger', live_prefix: PREFIX, env: { 'STUB_THREE' => '1' })
    refute st.success?
    assert_match(/eligible invitations 3 != expected 2/, out)
    out, st = run_script('--retrigger', live_prefix: PREFIX, env: { 'STUB_STALE_JOB' => '1' })
    refute st.success?
    assert_match(/worker Job\(s\) without the prefix still running: be293-portal-processes-worker-1/, out)
    out, st = run_script('--retrigger', live_prefix: PREFIX)
    refute st.success?
    assert_match(/next aliases: be293-alpha-idp-3 \.\. be293-alpha-idp-4/, out)
    assert_match(/no terminal for confirmation/, out)
    refute_includes File.read("#{@dir}/curl.log"), 'retrigger'
  end
end
