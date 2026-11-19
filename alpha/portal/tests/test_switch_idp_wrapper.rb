# frozen_string_literal: true

# Behavioural tests for tools/switch-idp-be293.sh with stub kubectl/helm/curl (no cluster or network is contacted).
# Two real OFFLINE post-rendered renders of the patched chart (KUBECONFIG=/dev/null): the values files as committed at
# HEAD (before the IdP switch, post-renderer be293-retention) are the "live" state, the working-tree values files
# (post-renderer be293-idp-switch) are the would-be release. The live worker CronJob is suspended by a manager other
# than helm; the Portal client secrets equal the new realm secrets.
#
# Run: ruby tests/test_switch_idp_wrapper.rb

require 'minitest/autorun'
require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'tmpdir'
require 'yaml'

class SwitchIdpWrapperTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  SCRIPT = File.join(HERE, 'tools/switch-idp-be293.sh')
  CHART = File.expand_path('../charts/portal-2.6.0-patched/portal-2.6.0.tgz', HERE)
  REAL_HELM = `command -v helm`.strip
  VALUES = %w[values-be293-portal.yaml values-be293-portal.alpha-release.yaml values-be293-portal.alpha-retention.yaml
              values-be293-portal.alpha-smtp4dev.yaml].freeze
  WORKER = 'be293-portal-processes-worker'
  ADMIN = 'be293-portal-administration-service'
  CENTRAL = 'https://centralidp-be293.test.tractus-x.com'
  SHARED = 'https://sharedidp-be293.test.tractus-x.com'

  def setup
    skip 'helm not installed' if REAL_HELM.empty?
    skip 'patched chart package missing' unless File.exist?(CHART)
    @dir = Dir.mktmpdir('be293-idp-test')
    @bin = File.join(@dir, 'bin')
    FileUtils.mkdir_p(@bin)
    @kc = File.join(@dir, 'alpha.yaml')
    File.write(@kc, '')
    @env = { 'KUBECONFIG' => '/dev/null', 'HELM_PLUGINS' => File.join(HERE, 'helm-plugins'), 'HELM_CACHE_HOME' => "#{@dir}/hc",
             'HELM_CONFIG_HOME' => "#{@dir}/hcfg", 'HELM_DATA_HOME' => "#{@dir}/hd" }
    write_state
    write_kubectl
    write_helm
    write_curl
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def render(files, post_renderer)
    args = [REAL_HELM, 'template', 'be293-portal', CHART, '--namespace', 'be293', '--post-renderer', post_renderer]
    files.each { |v| args += ['-f', v] }
    out, err, st = Open3.capture3(@env, *args)
    assert st.success?, err
    YAML.load_stream(out).compact
  end

  def as_live_secret(doc)
    data = (doc.delete('stringData') || {}).to_h { |k, v| [k, k.include?('encryption-key') ? SecureRandom.hex(32) : v.to_s] }
    doc['data'] = (doc['data'] || {}).merge(data.transform_values { |v| Base64.strict_encode64(v) })
    doc['metadata']['labels'] = (doc['metadata']['labels'] || {}).merge('app.kubernetes.io/managed-by' => 'Helm')
    doc['metadata']['annotations'] = (doc['metadata']['annotations'] || {}).merge('meta.helm.sh/release-name' => 'be293-portal', 'meta.helm.sh/release-namespace' => 'be293')
    doc
  end

  # The live release still runs the values from before the IdP switch: the parent of commit 5d548d7 ("switch Portal to
  # the own IdPs and local mail sink"). Reading HEAD stopped working once the switch itself was committed (live would
  # equal the target). Each file's path at that commit is looked up with ls-tree, so a later folder rename does not
  # break the lookup.
  PRE_SWITCH = '5d548d7^'

  def head_values
    listing, st = Open3.capture2('git', '-C', HERE, 'ls-tree', '-r', '--full-tree', '--name-only', PRE_SWITCH, '--', 'alpha')
    assert st.success?, "git ls-tree #{PRE_SWITCH}"
    VALUES.map do |v|
      found = listing.lines.map(&:chomp).select { |p| p.end_with?("/#{v}") }
      assert_equal 1, found.size, "#{v} at #{PRE_SWITCH}: #{found.inspect}"
      path = File.join(@dir, "head-#{v}")
      out, st = Open3.capture2('git', '-C', HERE, 'show', "#{PRE_SWITCH}:#{found.first}")
      assert st.success?, "git show #{v}"
      File.write(path, out)
      path
    end
  end

  def write_state
    before = head_values
    merge = ->(a, b) { a.is_a?(Hash) && b.is_a?(Hash) ? a.merge(b) { |_, x, y| merge.call(x, y) } : b }
    File.write("#{@dir}/values-live.json", JSON.generate(before.map { |f| YAML.safe_load(File.read(f)) }.reduce { |a, b| merge.call(a, b) }))

    # Secrets: ONE adopted copy for both sides (each offline render regenerates chart-random values).
    docs = render(VALUES.map { |v| File.join(HERE, v) }, 'be293-idp-switch').map { |d| d['kind'] == 'Secret' ? as_live_secret(d) : d }
    hooks, manifest = docs.partition { |d| d.dig('metadata', 'annotations', 'helm.sh/hook') }
    secrets = manifest.select { |d| d['kind'] == 'Secret' }.to_h { |d| ["secret/#{d['metadata']['name']}", Marshal.load(Marshal.dump(d))] }
    release = ->(m) { JSON.generate('manifest' => m.map { |d| YAML.dump(d) }.join, 'hooks' => hooks.map { |d| { 'name' => d['metadata']['name'] } }) }
    File.write("#{@dir}/release.json", release.call(manifest))
    other = Marshal.load(Marshal.dump(manifest))
    other.find { |d| d['kind'] == 'Deployment' && d['metadata']['name'] == ADMIN }
         .dig('spec', 'template', 'spec', 'containers')[0]['image'] += '-other'
    File.write("#{@dir}/release-other-image.json", release.call(other))

    live = render(before, 'be293-retention').reject { |d| d.dig('metadata', 'annotations', 'helm.sh/hook') || d['kind'] == 'Secret' }.to_h do |d|
      ["#{d['kind'].downcase}/#{d['metadata']['name']}", d]
    end.merge(secrets)
    w = live.fetch("cronjob/#{WORKER}")
    w['spec']['suspend'] = true
    w['metadata']['managedFields'] = [{ 'manager' => 'kubectl-patch', 'operation' => 'Update', 'fieldsV1' => { 'f:spec' => { 'f:suspend' => {} } } }]
    kc = live.fetch('secret/be293-portal-keycloak')['data']
    @canary = Base64.strict_decode64(kc['central-client-secret'])
    live['secret/be293-centralidp-seeding-service-accounts'] =
      { 'kind' => 'Secret', 'metadata' => { 'name' => 'be293-centralidp-seeding-service-accounts' }, 'data' => { 'sa-cl1-reg-2' => kc['central-client-secret'] } }
    live['secret/be293-sharedidp-seeding-master'] =
      { 'kind' => 'Secret', 'metadata' => { 'name' => 'be293-sharedidp-seeding-master' }, 'data' => { 'sa-provisioning' => kc['shared-client-secret'] } }
    File.write("#{@dir}/live.json", JSON.generate(live))
    nps = YAML.load_stream(File.read(File.join(HERE, 'networkpolicies-be293-portal.alpha-release.yaml'))).compact
    File.write("#{@dir}/netpol.json", JSON.generate('items' => nps))
  end

  def write_kubectl
    File.write(File.join(@bin, 'kubectl'), <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      a = ARGV.join(' ')
      File.open('#{@dir}/kubectl.log', 'a') { |f| f.puts a }
      live = JSON.parse(File.read('#{@dir}/live.json'))
      live['cronjob/#{WORKER}']['spec']['suspend'] = false if ENV['STUB_WORKER_RUNNING']
      live['secret/be293-sharedidp-seeding-master']['data']['sa-provisioning'] = ['other'].pack('m0') if ENV['STUB_SECRET_MISMATCH']
      if a.include?('config get-contexts') then puts 'alpha'; exit 0 end
      if a.include?('get networkpolicy -n be293 -o json') then puts File.read('#{@dir}/netpol.json'); exit 0 end
      if a.include?('get service be293-smtp4dev') then puts 'service/be293-smtp4dev'; exit 0 end
      if a.match?(/get pvc .*jsonpath/) then print 'Bound 1b2c3d4e-uid'; exit 0 end
      if (m = a.match(/get cronjob (\\S+) .*jsonpath=\\{\\.spec\\.suspend\\}/)) then print(live["cronjob/\#{m[1]}"]['spec']['suspend'] ? 'true' : 'false'); exit 0 end
      if (m = a.match(/get ((?:deployment|statefulset|cronjob|ingress)(?:,\\S+)?) -n be293 -o json/))
        kinds = m[1].split(',')
        puts JSON.generate('items' => live.values.select { |d| kinds.include?(d['kind'].downcase) }); exit 0
      end
      if (m = a.match(/get secret ((?:\\S+ )+)-n be293 -o json/)) && m[1].split.size > 1
        puts JSON.generate('items' => m[1].split.map { |n| live["secret/\#{n}"] }.compact); exit 0
      end
      if (m = a.match(/get (\\S+) (\\S+) -n be293.* -o json/))
        obj = live["\#{m[1].downcase}/\#{m[2]}"]
        puts JSON.generate(obj) if obj
        exit 0
      end
      warn "stub kubectl: unexpected \#{a}"; exit 3
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'kubectl'))
  end

  def write_helm
    File.write(File.join(@bin, 'helm'), <<~SH)
      #!/bin/bash
      echo "$*" >> "#{@dir}/helm.log"
      case "$1" in
        lint|template|package) exec "#{REAL_HELM}" "$@" ;;
      esac
      case "$*" in
        "plugin list"*) exec "#{REAL_HELM}" plugin list ;;
        *" history "*) if [ -n "${STUB_HISTORY:-}" ]; then echo "$STUB_HISTORY"; else echo '[{"revision":4,"status":"superseded"},{"revision":5,"status":"deployed"}]'; fi ;;
        *" get values "*) if [ -n "${STUB_VALUES_EXTRA:-}" ]; then ruby -rjson -e 'v = JSON.parse(File.read(ARGV[0])); v["semanticsAddress"] = "https://other.invalid"; puts JSON.generate(v)' "#{@dir}/values-live.json"; else cat "#{@dir}/values-live.json"; fi ;;
        *" upgrade "*"--dry-run=server"*) cat "#{@dir}/${STUB_RELEASE:-release.json}" ;;
        *" upgrade "*) echo "REAL-UPGRADE" >> "#{@dir}/helm.log" ;;
        *) exit 0 ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(@bin, 'helm'))
  end

  def write_curl
    File.write(File.join(@bin, 'curl'), <<~SH)
      #!/bin/bash
      echo "$*" >> "#{@dir}/curl.log"
      url="${@: -1}"
      iss="${url%/.well-known/openid-configuration}"
      [ -n "${STUB_ISSUER_WRONG:-}" ] && iss="https://centralidp.test.tractus-x.com/auth/realms/CX-Central"
      printf '{"issuer":"%s"}' "$iss"
    SH
    FileUtils.chmod(0o755, File.join(@bin, 'curl'))
  end

  def run_wrapper(*args, env: {})
    full = @env.reject { |k, _| k == 'KUBECONFIG' }.merge('PATH' => "#{@bin}:#{ENV['PATH']}", 'ALPHA_KUBECONFIG' => @kc).merge(env)
    Open3.capture2e(full, 'bash', SCRIPT, *args, stdin_data: '')
  end

  def helm_log
    File.exist?("#{@dir}/helm.log") ? File.read("#{@dir}/helm.log") : ''
  end

  def kubectl_log
    File.exist?("#{@dir}/kubectl.log") ? File.read("#{@dir}/kubectl.log") : ''
  end

  def test_default_mode_is_a_read_only_dry_run_with_only_idp_and_smtp_drift
    out, st = run_wrapper
    assert st.success?, out.lines.last(30).join
    assert_match(/OK   be293-portal: revision 5, deployed/, out)
    assert_match(/CHANGE centralidp\.address/, out)
    assert_match(/CHANGE backend\.processesworker\.bpdm\.tokenAddress/, out)
    assert_match(/OK   live values = the four values files except the reviewed IdP\/SMTP keys/, out)
    assert_match(%r{OK   be293-portal-keycloak/central-client-secret vs be293-centralidp-seeding-service-accounts/sa-cl1-reg-2: MATCH}, out)
    assert_match(%r{OK   be293-portal-keycloak/shared-client-secret vs be293-sharedidp-seeding-master/sa-provisioning: MATCH}, out)
    assert_match(%r{OK   OIDC issuer #{CENTRAL}/auth/realms/CX-Central}, out)
    assert_match(/OK   live #{WORKER} suspended$/, out)
    assert_match(/OK   rendered: be293-portal-portal-maintenance and #{WORKER} suspended/, out)
    refute_match(%r{^DRIFT CronJob/#{WORKER}: suspend}, out)
    assert_match(/OK   every rendered image equals the live image/, out)
    assert_match(/OK   rendered: BPDM on the shared CentralIDP/, out)
    assert_match(%r{^DRIFT Deployment/#{ADMIN}: .*container #{ADMIN} env KEYCLOAK__CENTRAL__CONNECTIONSTRING: value differs \(live=https://centralidp\.test\.tractus-x\.com rendered=#{CENTRAL}\)}, out)
    refute_match(/^DRIFT .*BPDM__TOKENADDRESS/, out)
    assert_match(/EXPECTED-DRIFT OK/, out)
    assert_match(/DRY RUN COMPLETE/, out)
    upgrades = helm_log.lines.grep(/ upgrade /)
    assert_equal 1, upgrades.size
    %w[--dry-run=server --no-hooks --kube-context charts/portal-2.6.0-patched/portal-2.6.0.tgz] + ['--post-renderer be293-idp-switch'].each { |f| assert_includes upgrades.first, f }
    VALUES.each_cons(2) { |a, b| assert_operator upgrades.first.index(a), :<, upgrades.first.index(b) }
    refute_includes helm_log, 'REAL-UPGRADE'
    refute_match(/--install|--force|--reset-values|--reuse-values|--take-ownership|--force-conflicts|--rollback-on-failure|--atomic|--cleanup-on-fail/, helm_log)
    kubectl_log.lines.reject { |l| l.include?('config get-contexts') }.each { |l| assert_match(/--kubeconfig \S+ --context alpha --request-timeout=20s get /, l) }
    refute_includes out, @canary, 'Secret values must never be printed'
  end

  def test_wrong_release_state_aborts_before_the_dry_run
    out, st = run_wrapper(env: { 'STUB_HISTORY' => '[{"revision":6,"status":"deployed"}]' })
    refute st.success?
    assert_match(/expected '5 deployed': nothing changed/, out)
    assert_empty helm_log.lines.grep(/ upgrade /)
  end

  def test_live_values_drift_outside_the_switch_aborts_before_the_dry_run
    out, st = run_wrapper(env: { 'STUB_VALUES_EXTRA' => '1' })
    refute st.success?
    assert_match(/FAIL live value differs from the values files outside the switch: semanticsAddress/, out)
    refute_includes out, 'https://other.invalid'
    assert_empty helm_log.lines.grep(/ upgrade /)
  end

  def test_client_secret_not_matching_the_new_realm_aborts_without_printing_values
    out, st = run_wrapper(env: { 'STUB_SECRET_MISMATCH' => '1' })
    refute st.success?
    assert_match(%r{FAIL be293-portal-keycloak/shared-client-secret vs be293-sharedidp-seeding-master/sa-provisioning: MISMATCH}, out)
    refute_includes out, @canary
    assert_empty helm_log.lines.grep(/ upgrade /)
  end

  def test_unexpected_oidc_issuer_aborts
    out, st = run_wrapper(env: { 'STUB_ISSUER_WRONG' => '1' })
    refute st.success?
    assert_match(/FAIL OIDC issuer of #{CENTRAL}\/auth\/realms\/CX-Central is 'https:\/\/centralidp\.test/, out)
    assert_empty helm_log.lines.grep(/ upgrade /)
  end

  def test_unsuspended_worker_aborts
    out, st = run_wrapper(env: { 'STUB_WORKER_RUNNING' => '1' })
    refute st.success?
    assert_match(/FAIL live #{WORKER} not suspended: suspend it before the switch/, out)
    assert_empty helm_log.lines.grep(/ upgrade /)
  end

  def test_rendered_image_other_than_live_aborts
    out, st = run_wrapper(env: { 'STUB_RELEASE' => 'release-other-image.json' })
    refute st.success?
    assert_match(%r{rendered image differs from live for: Deployment/#{ADMIN}}, out)
    refute_includes helm_log, 'REAL-UPGRADE'
  end

  def test_execute_requires_a_terminal_confirmation
    snapshots = -> { Dir.exist?(File.join(HERE, '.evidence')) ? Dir.children(File.join(HERE, '.evidence')).grep(/idp-switch/).sort : [] }
    before = snapshots.call
    out, st = run_wrapper('--execute')
    refute st.success?
    assert_match(/no terminal for confirmation|confirmation did not match/, out)
    refute_includes helm_log, 'REAL-UPGRADE'
    assert_equal before, snapshots.call, 'no snapshot before the confirmation'
  end

  def test_unknown_argument_is_rejected
    out, st = run_wrapper('--yes')
    assert_equal 2, st.exitstatus
    assert_includes out, 'usage: switch-idp-be293.sh [--execute]'
    assert_empty helm_log
  end
end
