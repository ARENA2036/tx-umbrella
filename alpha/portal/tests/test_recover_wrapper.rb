# frozen_string_literal: true

# Behavioural tests for tools/recover-be293.sh and tools/compare_release_live.rb with stub kubectl/helm (no
# cluster is contacted). One real OFFLINE post-rendered render (KUBECONFIG=/dev/null) serves both as the
# would-be release (`helm upgrade --dry-run=server -o json`) and as the "live" objects, so the comparison
# runs on genuine chart output. Every helm invocation is logged and asserted.
#
# Run: ruby tests/test_recover_wrapper.rb

require 'minitest/autorun'
require_relative 'support/pinned_smtp4dev'
require_relative 'support/pinned_did_resolver'
require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'tmpdir'
require 'yaml'
require_relative '../tools/compare_release_live'

class RecoverWrapperTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  SCRIPT = File.join(HERE, 'tools/recover-be293.sh')
  CHART = File.expand_path('../../handoff/BE-293-umbrella-3.17.0/chart/umbrella/charts/portal-2.6.0.tgz', HERE)
  REAL_HELM = `command -v helm`.strip
  VALUES = %w[values-be293-portal.yaml values-be293-portal.alpha-release.yaml values-be293-portal.alpha-retention.yaml
              values-be293-portal.alpha-smtp4dev.yaml].freeze

  def setup
    skip 'helm not installed' if REAL_HELM.empty?
    @dir = Dir.mktmpdir('be293-recover-test')
    @bin = File.join(@dir, 'bin')
    FileUtils.mkdir_p(@bin)
    @kc = File.join(@dir, 'alpha.yaml')
    File.write(@kc, '')
    @env = { 'KUBECONFIG' => '/dev/null', 'HELM_PLUGINS' => File.join(HERE, 'helm-plugins'), 'HELM_CACHE_HOME' => "#{@dir}/hc",
             'HELM_CONFIG_HOME' => "#{@dir}/hcfg", 'HELM_DATA_HOME' => "#{@dir}/hd" }
    write_release
    write_kubectl
    write_helm
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  # Live keycloak/interfaces were pre-created by tools/create-be293-secret.sh (adoption metadata, 64-hex keys)
  # and adopted; server-side lookup renders exactly that data, so the fixture uses it on both sides.
  def as_adopted_live_secret(doc)
    return doc unless doc['kind'] == 'Secret' && %w[be293-portal-keycloak be293-portal-interfaces].include?(doc['metadata']['name'])

    data = (doc.delete('stringData') || {}).to_h { |k, v| [k, k.include?('encryption-key') ? SecureRandom.hex(32) : v.to_s] }
    doc['data'] = data.transform_values { |v| Base64.strict_encode64(v) }
    doc['metadata']['labels'] = (doc['metadata']['labels'] || {}).merge('app.kubernetes.io/managed-by' => 'Helm')
    doc['metadata']['annotations'] = (doc['metadata']['annotations'] || {}).merge('meta.helm.sh/release-name' => 'be293-portal', 'meta.helm.sh/release-namespace' => 'be293')
    doc
  end

  # Release JSON as `helm upgrade --dry-run=server -o json` returns it, and the matching live objects.
  def write_release
    args = [REAL_HELM, 'template', 'be293-portal', CHART, '--namespace', 'be293', '--post-renderer', 'be293-retention']
    VALUES.each { |v| args += ['-f', File.join(HERE, v)] }
    out, err, st = Open3.capture3(@env, *args)
    assert st.success?, err
    docs = YAML.load_stream(out).compact.map { |d| as_adopted_live_secret(d) }
    hooks, manifest = docs.partition { |d| d.dig('metadata', 'annotations', 'helm.sh/hook') }
    File.write("#{@dir}/release.json", JSON.generate('manifest' => manifest.map { |d| YAML.dump(d) }.join, 'hooks' => hooks.map { |d| { 'name' => d['metadata']['name'] } }))
    live = manifest.to_h do |d|
      d = Marshal.load(Marshal.dump(d))
      if d['kind'] == 'Secret' && d['stringData'] # the API server stores stringData as base64 data
        d['data'] = (d['data'] || {}).merge(d.delete('stringData').transform_values { |v| Base64.strict_encode64(v.to_s) })
      end
      ["#{d['kind'].downcase}/#{d['metadata']['name']}", d]
    end
    @canary = Base64.strict_decode64(live.fetch('secret/be293-portal-interfaces')['data']['bpdm-client-secret'])
    File.write("#{@dir}/live.json", JSON.generate(live))
    nps = YAML.load_stream(File.read(File.join(HERE, 'networkpolicies-be293-portal.alpha-release.yaml'))).compact
    File.write("#{@dir}/netpol.json", JSON.generate('items' => nps))
  end

  def write_kubectl
    File.write(File.join(@bin, 'kubectl'), <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      a = ARGV.join(' ')
      live = JSON.parse(File.read('#{@dir}/live.json'))
      if a.include?('config get-contexts') then puts 'alpha'; exit 0 end
      if a.include?('get networkpolicy -n be293 -o json')
        np = JSON.parse(File.read('#{@dir}/netpol.json'))
        np['items'].each { |p| (p['spec']['egress'] || []).each { |r| (r['ports'] || []).reject! { |x| x['port'].to_s == '8053' } } } if ENV['STUB_NO_8053']
        puts JSON.generate(np); exit 0
      end
      if (m = a.match(/get job (\\S+) .*jsonpath/)) then print(m[1].include?('-manual-') ? '1' : ''); exit 0 end
      if a.match?(/get job \S+ .*-o name/) then exit 0 end
      if a.include?('get service be293-smtp4dev') then puts 'service/be293-smtp4dev' unless ENV['STUB_NO_SINK']; exit 0 end
      if a.match?(/get pvc .*jsonpath/) then print 'Bound'; exit 0 end
      if a.match?(/get cronjob .*jsonpath/) then print 'true'; exit 0 end
      if (m = a.match(/get (\\S+) (\\S+) -n be293.* -o json/))
        obj = live["\#{m[1].downcase}/\#{m[2]}"]
        if obj && ENV['STUB_SECRET_DRIFT'] && m[2] == 'be293-portal-interfaces'
          obj['data']['mailing-encryption-key0'] = ['f' * 64].pack('m0')
        end
        if obj && ENV['STUB_ENV_DRIFT'] && m[1] == 'Deployment' && m[2] == 'be293-portal-services-service'
          obj['spec']['template']['spec']['containers'][0]['env'] << { 'name' => 'MANUAL_ONLY', 'value' => 'x' }
        end
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
        lint|template) exec "#{REAL_HELM}" "$@" ;;
      esac
      case "$*" in
        "plugin list"*) exec "#{REAL_HELM}" plugin list ;;
        *" history "*) if [ -n "${STUB_HISTORY:-}" ]; then echo "$STUB_HISTORY"; else echo '[{"revision":1,"status":"failed"}]'; fi ;;
        *" upgrade "*"--dry-run=server"*) cat "#{@dir}/release.json" ;;
        *" upgrade "*) echo "REAL-UPGRADE" >> "#{@dir}/helm.log" ;;
        *) exit 0 ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(@bin, 'helm'))
  end

  def run_wrapper(*args, env: {})
    full = @env.reject { |k, _| k == 'KUBECONFIG' }.merge('PATH' => "#{@bin}:#{ENV['PATH']}", 'ALPHA_KUBECONFIG' => @kc, 'SMTP4DEV_MANIFEST' => PinnedSmtp4dev.manifest(@dir), 'DID_RESOLVER_MANIFEST' => PinnedDidResolver.manifest(@dir)).merge(env)
    Open3.capture2e(full, 'bash', SCRIPT, *args, stdin_data: '')
  end

  def helm_log
    File.exist?("#{@dir}/helm.log") ? File.read("#{@dir}/helm.log") : ''
  end

  def test_default_mode_is_a_verified_dry_run_with_no_drift
    out, st = run_wrapper
    assert st.success?, out.lines.last(25).join
    assert_match(/OK   be293-portal: 1 revision, failed/, out)
    assert_match(/OK    release manifest: .*ArenaAdminRoles set/, out)
    assert_match(/^SAME  Secret\/be293-portal-interfaces$/, out)
    assert_match(/^COMPARE SAME=\d+$/, out)
    assert_match(/DRY RUN COMPLETE/, out)
    upgrades = helm_log.lines.grep(/ upgrade /)
    assert_equal 1, upgrades.size
    %w[--dry-run=server --no-hooks --post-renderer --kube-context].each { |f| assert_includes upgrades.first, f }
    VALUES.each { |v| assert_includes upgrades.first, v }
    refute_includes helm_log, 'REAL-UPGRADE'
    refute_match(/--install|--force|--reset-values|--reuse-values|--take-ownership|--force-conflicts|--rollback-on-failure|--atomic|--cleanup-on-fail/, helm_log)
    refute_match(/^(uninstall|rollback|install) |\s(uninstall|rollback) /, helm_log)
    refute_includes out, @canary, 'Secret values must never be printed'
  end

  def test_release_not_in_recovery_state_aborts_before_dry_run
    out, st = run_wrapper(env: { 'STUB_HISTORY' => '[{"revision":1,"status":"deployed"}]' })
    refute st.success?
    assert_match(/release history is '1 deployed'/, out)
    assert_empty helm_log.lines.grep(/ upgrade /)
  end

  def test_secret_key_change_aborts_without_printing_values
    out, st = run_wrapper(env: { 'STUB_SECRET_DRIFT' => '1' })
    refute st.success?
    assert_match(/FAIL  Secret\/be293-portal-interfaces: key mailing-encryption-key0: DIFFERS/, out)
    assert_match(/a Secret key would change/, out)
    refute_includes out, @canary
    refute_includes helm_log, 'REAL-UPGRADE'
  end

  # Unreviewed drift (not in expected-drift.alpha.yaml) is shown and stops the run before the confirmation.
  def test_unreviewed_drift_aborts_before_any_upgrade
    out, st = run_wrapper(env: { 'STUB_ENV_DRIFT' => '1' })
    refute st.success?
    assert_match(/DRIFT Deployment\/be293-portal-services-service: container \S+ env MANUAL_ONLY: only live \(manual change, upgrade keeps it unless Helm owned it\)/, out)
    assert_match(/^UNEXPECTED Deployment\/be293-portal-services-service: container \S+ env MANUAL_ONLY: only live/, out)
    assert_match(/EXPECTED-DRIFT FAIL: 1 unreviewed drift item\(s\)/, out)
    assert_match(/unreviewed drift: nothing upgraded/, out)
    refute_includes helm_log, 'REAL-UPGRADE'
  end

  def test_missing_dns_8053_policy_aborts
    out, st = run_wrapper(env: { 'STUB_NO_8053' => '1' })
    refute st.success?
    assert_match(/no be293 NetworkPolicy allows port 8053/, out)
    assert_empty helm_log.lines.grep(/ upgrade /)
  end

  def test_missing_mail_sink_aborts_before_dry_run
    out, st = run_wrapper(env: { 'STUB_NO_SINK' => '1' })
    refute st.success?
    assert_match(/Service be293-smtp4dev missing/, out)
    assert_empty helm_log.lines.grep(/ upgrade /)
  end

  def test_execute_requires_a_terminal_confirmation
    out, st = run_wrapper('--execute')
    refute st.success?
    assert_match(/no terminal for confirmation|confirmation did not match/, out)
    refute_includes helm_log, 'REAL-UPGRADE'
  end

  def test_compare_unit_detects_image_and_missing_objects
    d = { 'kind' => 'Deployment', 'metadata' => { 'name' => 'x' },
          'spec' => { 'replicas' => 3, 'template' => { 'spec' => { 'containers' => [{ 'name' => 'c', 'image' => 'a@sha256:1', 'env' => [] }] } } } }
    live = Marshal.load(Marshal.dump(d))
    live['spec']['template']['spec']['containers'][0]['image'] = 'a@sha256:2'
    r = CompareReleaseLive.compare([d, d.merge('metadata' => { 'name' => 'y' })], ->(_, n) { n == 'x' ? live : nil })
    assert_equal [['DRIFT', 'Deployment/x: container c image'], ['DRIFT', 'Deployment/y: missing live (an upgrade would CREATE it)']], r
  end
end
