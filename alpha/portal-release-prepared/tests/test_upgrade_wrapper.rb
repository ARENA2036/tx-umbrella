# frozen_string_literal: true

# Behavioural tests for tools/upgrade-be293.sh with stub kubectl/helm (no cluster is contacted). One real OFFLINE
# post-rendered render (KUBECONFIG=/dev/null) is both the would-be release and the "live" state; the live worker
# CronJob runs the previous image (owned by helm), which is the one drift this upgrade exists for.
#
# Run: ruby tests/test_upgrade_wrapper.rb

require 'minitest/autorun'
require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'tmpdir'
require 'yaml'

class UpgradeWrapperTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  SCRIPT = File.join(HERE, 'tools/upgrade-be293.sh')
  CHART = File.expand_path('../../handoff/BE-293-umbrella-3.17.0/chart/umbrella/charts/portal-2.6.0.tgz', HERE)
  REAL_HELM = `command -v helm`.strip
  VALUES = %w[values-be293-portal.yaml values-be293-portal.alpha-release.yaml values-be293-portal.alpha-retention.yaml
              values-be293-portal.alpha-smtp4dev.yaml].freeze
  WORKER = 'be293-portal-processes-worker'
  OLD_IMAGE = 'harbor-hub-shared.arena.3ascloud.de/be293/portal-processes-worker:be293-2cd5dd8a4aa8c6c84c9c01bebeb62ffbd65c6b3a@sha256:421bf1fd9c7ff3f912557b85b56ebdc0c5770c853bc49d5fd6a94b5ae946a399'
  ADMIN = 'be293-portal-administration-service'

  def setup
    skip 'helm not installed' if REAL_HELM.empty?
    @dir = Dir.mktmpdir('be293-upgrade-test')
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

  def adopted(doc)
    return doc unless doc['kind'] == 'Secret' && %w[be293-portal-keycloak be293-portal-interfaces].include?(doc['metadata']['name'])

    data = (doc.delete('stringData') || {}).to_h { |k, v| [k, k.include?('encryption-key') ? SecureRandom.hex(32) : v.to_s] }
    doc['data'] = data.transform_values { |v| Base64.strict_encode64(v) }
    doc['metadata']['labels'] = (doc['metadata']['labels'] || {}).merge('app.kubernetes.io/managed-by' => 'Helm')
    doc['metadata']['annotations'] = (doc['metadata']['annotations'] || {}).merge('meta.helm.sh/release-name' => 'be293-portal', 'meta.helm.sh/release-namespace' => 'be293')
    doc
  end

  def helm_owns(path_tail, cname, kind)
    base = kind == 'CronJob' ? %w[f:spec f:jobTemplate f:spec f:template f:spec f:containers] : %w[f:spec f:template f:spec f:containers]
    leaf = path_tail.reverse.reduce({}) { |acc, k| { k => acc } }
    tree = (base + ["k:#{JSON.generate('name' => cname)}"]).reverse.reduce(leaf) { |acc, k| { k => acc } }
    [{ 'manager' => 'helm', 'operation' => 'Apply', 'fieldsV1' => tree }]
  end

  def write_release
    args = [REAL_HELM, 'template', 'be293-portal', CHART, '--namespace', 'be293', '--post-renderer', 'be293-retention']
    VALUES.each { |v| args += ['-f', File.join(HERE, v)] }
    out, err, st = Open3.capture3(@env, *args)
    assert st.success?, err
    docs = YAML.load_stream(out).compact.map { |d| adopted(d) }
    hooks, manifest = docs.partition { |d| d.dig('metadata', 'annotations', 'helm.sh/hook') }
    release = ->(m) { JSON.generate('manifest' => m.map { |d| YAML.dump(d) }.join, 'hooks' => hooks.map { |d| { 'name' => d['metadata']['name'] } }) }
    File.write("#{@dir}/release.json", release.call(manifest))
    other = Marshal.load(Marshal.dump(manifest))
    other.find { |d| d['kind'] == 'CronJob' && d['metadata']['name'] == WORKER }
         .dig('spec', 'jobTemplate', 'spec', 'template', 'spec', 'containers')[0]['image'] = OLD_IMAGE.sub('421bf1fd', '00000000')
    File.write("#{@dir}/release-other-pin.json", release.call(other))
    live = manifest.to_h do |d|
      d = Marshal.load(Marshal.dump(d))
      if d['kind'] == 'Secret' && d['stringData']
        d['data'] = (d['data'] || {}).merge(d.delete('stringData').transform_values { |v| Base64.strict_encode64(v.to_s) })
      end
      ["#{d['kind'].downcase}/#{d['metadata']['name']}", d]
    end
    @new_image = live.fetch("cronjob/#{WORKER}").dig('spec', 'jobTemplate', 'spec', 'template', 'spec', 'containers')[0]['image']
    @canary = Base64.strict_decode64(live.fetch('secret/be293-portal-interfaces')['data']['bpdm-client-secret'])
    File.write("#{@dir}/live.json", JSON.generate(live))
    File.write("#{@dir}/owner-image.json", JSON.generate(helm_owns(%w[f:image], WORKER, 'CronJob')))
    env_owner = helm_owns(['f:env', "k:#{JSON.generate('name' => 'APPLICATIONCHECKLIST__BPDM__BASEADDRESS')}", 'f:value'], ADMIN, 'Deployment')
    File.write("#{@dir}/owner-env.json", JSON.generate(env_owner))
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
      w = live['cronjob/#{WORKER}']
      wc = w['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]
      unless ENV['STUB_WORKER_CURRENT']
        wc['image'] = '#{OLD_IMAGE}'
        w['metadata']['managedFields'] = JSON.parse(File.read('#{@dir}/owner-image.json'))
      end
      if ENV['STUB_ADMIN_BPDM_OLD']
        d = live['deployment/#{ADMIN}']
        e = d['spec']['template']['spec']['containers'][0]['env'].find { |x| x['name'] == 'APPLICATIONCHECKLIST__BPDM__BASEADDRESS' }
        e['value'] = 'https://business-partners.test.tractus-x.com/gate'
        d['metadata']['managedFields'] = JSON.parse(File.read('#{@dir}/owner-env.json'))
      end
      if a.include?('config get-contexts') then puts 'alpha'; exit 0 end
      if a.include?('get networkpolicy -n be293 -o json') then puts File.read('#{@dir}/netpol.json'); exit 0 end
      if a.include?('get service be293-smtp4dev') then puts 'service/be293-smtp4dev'; exit 0 end
      if a.match?(/get pvc .*jsonpath/) then print 'Bound'; exit 0 end
      if a.match?(/get cronjob \\S+ .*status\\.active/) then print(ENV['STUB_ACTIVE'] || ''); exit 0 end
      if a.match?(/get cronjob .*jsonpath/) then print 'true'; exit 0 end
      if (m = a.match(/get (\\S+) (\\S+) -n be293.* -o json/))
        obj = live["\#{m[1].downcase}/\#{m[2]}"]
        obj['data']['mailing-encryption-key0'] = ['f' * 64].pack('m0') if obj && ENV['STUB_SECRET_DRIFT'] && m[2] == 'be293-portal-interfaces'
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
        *" history "*) if [ -n "${STUB_HISTORY:-}" ]; then echo "$STUB_HISTORY"; else echo '[{"revision":3,"status":"superseded"},{"revision":4,"status":"deployed"}]'; fi ;;
        *" upgrade "*"--dry-run=server"*) cat "#{@dir}/${STUB_RELEASE:-release.json}" ;;
        *" upgrade "*) echo "REAL-UPGRADE" >> "#{@dir}/helm.log" ;;
        *) exit 0 ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(@bin, 'helm'))
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

  def test_values_render_the_reviewed_worker_pin
    assert_equal 'harbor-hub-shared.arena.3ascloud.de/be293/portal-processes-worker:be293-e2451f87628c8ae56c131f136e5ad3e12703a1f6@sha256:0857101e376c52277f88ec081b2902e6883f530e6d27d914fc83d05d7e72d3a6', @new_image
  end

  def test_default_mode_is_a_read_only_dry_run_with_only_the_worker_drift
    out, st = run_wrapper
    assert st.success?, out.lines.last(25).join
    assert_match(/OK   be293-portal: revision 4, deployed/, out)
    assert_match(/OK   rendered #{WORKER} image is the reviewed pin/, out)
    assert_match(%r{^DRIFT CronJob/#{WORKER}: container #{WORKER} image \[owner: helm\]$}, out)
    assert_match(/EXPECTED-DRIFT OK/, out)
    assert_match(/OK   drift limited to #{WORKER} image and Rancher Ingress annotations/, out)
    assert_match(/DRY RUN COMPLETE/, out)
    upgrades = helm_log.lines.grep(/ upgrade /)
    assert_equal 1, upgrades.size
    %w[--dry-run=server --no-hooks --post-renderer --kube-context].each { |f| assert_includes upgrades.first, f }
    refute_includes helm_log, 'REAL-UPGRADE'
    refute_match(/--install|--force|--reset-values|--reuse-values|--take-ownership|--force-conflicts|--rollback-on-failure|--atomic|--cleanup-on-fail/, helm_log)
    refute_match(/^(uninstall|rollback|install) |\s(uninstall|rollback) /, helm_log)
    kubectl_log.lines.reject { |l| l.include?('config get-contexts') }.each { |l| assert_match(/\Aget |--kubeconfig \S+ --context alpha --request-timeout=20s get /, l) }
    refute_includes out, @canary, 'Secret values must never be printed'
  end

  def test_wrong_release_state_aborts_before_the_dry_run
    ['[{"revision":3,"status":"deployed"}]', '[{"revision":4,"status":"deployed"},{"revision":5,"status":"failed"}]',
     '[{"revision":4,"status":"superseded"},{"revision":5,"status":"deployed"}]'].each do |hist|
      out, st = run_wrapper(env: { 'STUB_HISTORY' => hist })
      refute st.success?, hist
      assert_match(/expected '4 deployed': nothing changed/, out)
    end
    assert_empty helm_log.lines.grep(/ upgrade /)
  end

  def test_rendered_worker_image_other_than_the_reviewed_pin_aborts
    out, st = run_wrapper(env: { 'STUB_RELEASE' => 'release-other-pin.json' })
    refute st.success?
    assert_match(/is not the reviewed pin: nothing upgraded/, out)
    refute_includes helm_log, 'REAL-UPGRADE'
  end

  # The admin BPDM drift is listed in expected-drift.alpha.yaml (from revision 2), so the drift gate accepts it;
  # the worker-only scope check must still stop the run.
  def test_listed_drift_on_another_workload_is_outside_the_worker_only_scope
    out, st = run_wrapper(env: { 'STUB_ADMIN_BPDM_OLD' => '1' })
    refute st.success?
    assert_match(/EXPECTED-DRIFT OK/, out)
    assert_match(%r{drift outside the worker-only scope: Deployment/#{ADMIN}}, out)
    refute_includes helm_log, 'REAL-UPGRADE'
  end

  def test_live_worker_already_on_the_pin_has_nothing_to_upgrade
    out, st = run_wrapper(env: { 'STUB_WORKER_CURRENT' => '1' })
    refute st.success?
    assert_match(/no #{WORKER} image drift: .*nothing to upgrade/, out)
  end

  def test_secret_key_change_aborts_without_printing_values
    out, st = run_wrapper(env: { 'STUB_SECRET_DRIFT' => '1' })
    refute st.success?
    assert_match(/a Secret key would change/, out)
    refute_includes out, @canary
    refute_includes helm_log, 'REAL-UPGRADE'
  end

  def test_running_worker_job_is_reported_not_blocking
    out, st = run_wrapper(env: { 'STUB_ACTIVE' => 'be293-portal-processes-worker-29000000' })
    assert st.success?, out.lines.last(10).join
    assert_match(/WARN #{WORKER} Job running \(be293-portal-processes-worker-29000000\)/, out)
  end

  def test_execute_requires_a_terminal_confirmation
    # Compare before/after: real snapshots from earlier live upgrades may already exist in .evidence/.
    snapshots = -> { Dir.exist?(File.join(HERE, '.evidence')) ? Dir.children(File.join(HERE, '.evidence')).grep(/\Apre-revision-/).sort : [] }
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
    assert_includes out, 'usage: upgrade-be293.sh [--execute]'
    assert_empty helm_log
  end
end
