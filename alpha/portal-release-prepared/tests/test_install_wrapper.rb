# frozen_string_literal: true

# Behavioural tests for tools/install-be293.sh with stub kubectl/helm binaries (no cluster is contacted).
# The helm stub turns `--dry-run=server` into a real OFFLINE `--dry-run=client` (KUBECONFIG=/dev/null), so the
# wrapper's retention verification runs on the genuine post-rendered release manifest. Synthetic Secrets exist
# only inside the stub. Every helm invocation is logged and asserted.
#
# Run: ruby tests/test_install_wrapper.rb

require 'minitest/autorun'
require_relative 'support/pinned_smtp4dev'
require_relative 'support/pinned_did_resolver'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../tools/build_secret_manifest'

class InstallWrapperTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  SCRIPT = File.join(HERE, 'tools/install-be293.sh')
  REAL_HELM = `command -v helm`.strip
  CONTRACT = YAML.safe_load(File.read(File.join(HERE, 'secrets-contract.yaml')))
  NETPOLS = YAML.load_stream(File.read(File.join(HERE, 'networkpolicies-be293-portal.alpha-release.yaml'))).compact.map { |d| d['metadata']['name'] }

  def setup
    skip 'helm not installed' if REAL_HELM.empty?
    @dir = Dir.mktmpdir('be293-wrapper-test')
    @bin = File.join(@dir, 'bin')
    FileUtils.mkdir_p([@bin, File.join(@dir, 'secrets')])
    @kc = File.join(@dir, 'alpha.yaml')
    File.write(@kc, '')
    write_secrets
    write_kubectl
    write_helm
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def write_secrets
    %w[be293-portal-keycloak be293-portal-interfaces be293-portal-identityhub be293-portal-bdrs].each do |n|
      spec = CONTRACT['secrets'].find { |s| s['name'] == n }
      File.write(File.join(@dir, 'secrets', n), JSON.generate(SecretManifest.build(spec, prompt: ->(_) { 'synthetic-test-value' })))
    end
    pull = { 'metadata' => { 'name' => 'be293-portal-registry-pull', 'namespace' => 'be293' }, 'type' => 'kubernetes.io/dockerconfigjson',
             'data' => { '.dockerconfigjson' => Base64.strict_encode64(JSON.generate('auths' => { 'harbor-hub-shared.arena.3ascloud.de' => {} })) } }
    File.write(File.join(@dir, 'secrets', 'be293-portal-registry-pull'), JSON.generate(pull))
  end

  def write_kubectl
    nps = NETPOLS.join(' ')
    File.write(File.join(@bin, 'kubectl'), <<~SH)
      #!/bin/bash
      a="$*"
      case "$a" in
        *"config get-contexts"*) echo alpha ;;
        *"config view"*) echo alpha-cluster ;;
        *"auth can-i"*) echo yes ;;
        *"get secret "*"--ignore-not-found -o json"*)
          n="$(sed -E 's/.*get secret ([^ ]+).*/\\1/' <<<"$a")"; f="#{@dir}/secrets/$n"; [ -f "$f" ] && cat "$f"; exit 0 ;;
        *"get secret "*"--ignore-not-found"*|*"get pvc "*|*"get job "*|*"get ingress -A"*) exit 0 ;;
        *"get networkpolicy "*" -n be293 --ignore-not-found -o name"*)
          n="$(sed -E 's/.*get networkpolicy ([^ ]+).*/\\1/' <<<"$a")"
          for x in #{nps}; do [ "$x" = "$n" ] && [ "${STUB_MISSING_NP:-}" != "$n" ] && echo "networkpolicy.networking.k8s.io/$n"; done; exit 0 ;;
        *"get storageclass"*) echo "premium reclaim=Retain binding=WaitForFirstConsumer expand=true default=true" ;;
        *"get clusterissuer"*) echo '{"status":{"conditions":[{"type":"Ready","status":"True"}]},"spec":{"acme":{"solvers":[{"http01":{"ingress":{"ingressClassName":"nginx"}}}]}}}' ;;
        *"get deploy -A"*) echo '{"items":[{"metadata":{"namespace":"external-dns","name":"external-dns"},"spec":{"replicas":1,"template":{"spec":{"containers":[{"image":"external-dns:v0","args":["--source=ingress"]}]}}},"status":{"readyReplicas":1}}]}' ;;
        *"-o json"*) echo '{"items":[]}' ;;
        *) echo "stub-ok" ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(@bin, 'kubectl'))
  end

  def write_helm
    File.write(File.join(@bin, 'helm'), <<~SH)
      #!/bin/bash
      echo "$*" >> "#{@dir}/helm.log"
      args=("$@")
      case "$1" in
        # Offline gates inside render-release.sh (KUBECONFIG=/dev/null): use the real helm.
        lint|template) exec "#{REAL_HELM}" "$@" ;;
      esac
      case "$*" in
        *" plugin list"*|"plugin list"*) exec "#{REAL_HELM}" plugin list ;;
        *" list "*) exit 0 ;;
        *" install "*"--dry-run=server"*)
          out=(); skip=0
          for x in "${args[@]}"; do
            if [ $skip = 1 ]; then skip=0; continue; fi
            case "$x" in --kubeconfig|--kube-context) skip=1 ;; --dry-run=server) out+=(--dry-run=client) ;; *) out+=("$x") ;; esac
          done
          KUBECONFIG=/dev/null HELM_CACHE_HOME="#{@dir}/hc" HELM_CONFIG_HOME="#{@dir}/hcfg" HELM_DATA_HOME="#{@dir}/hd" exec "#{REAL_HELM}" "${out[@]}" ;;
        *" install "*) echo "REAL-INSTALL" >> "#{@dir}/helm.log"; exit 0 ;;
        *) exit 0 ;;
      esac
    SH
    FileUtils.chmod(0o755, File.join(@bin, 'helm'))
  end

  def run_wrapper(*args, env: {})
    # Isolated Helm home: the real helm (plugin list) must not touch the operator's caches.
    full_env = { 'PATH' => "#{@bin}:#{ENV['PATH']}", 'ALPHA_KUBECONFIG' => @kc, 'HELM_CACHE_HOME' => "#{@dir}/hc",
                 'HELM_CONFIG_HOME' => "#{@dir}/hcfg", 'HELM_DATA_HOME' => "#{@dir}/hd",
                 'SMTP4DEV_MANIFEST' => PinnedSmtp4dev.manifest(@dir), 'DID_RESOLVER_MANIFEST' => PinnedDidResolver.manifest(@dir) }.merge(env)
    Open3.capture2e(full_env, 'bash', SCRIPT, *args, stdin_data: '')
  end

  def helm_log
    File.exist?("#{@dir}/helm.log") ? File.read("#{@dir}/helm.log") : ''
  end

  def test_default_mode_is_a_verified_dry_run_and_never_installs
    out, st = run_wrapper
    assert st.success?, out.lines.last(20).join
    assert_match(/OK   release manifest: maintenance suspended; keep on postgres\/keycloak\/interfaces; PVC Retain\/Retain; hooks = 2 migration Jobs; ArenaAdminRoles set/, out)
    assert_match(/DRY RUN COMPLETE/, out)
    installs = helm_log.lines.grep(/ install /)
    assert_equal 1, installs.size, helm_log
    line = installs.first
    assert_includes line, '--dry-run=server'
    assert_includes line, '--kubeconfig'
    assert_includes line, '--kube-context alpha'
    assert_includes line, '--namespace be293'
    assert_includes line, '--post-renderer be293-retention'
    %w[values-be293-portal.yaml values-be293-portal.alpha-release.yaml values-be293-portal.alpha-retention.yaml values-be293-portal.alpha-smtp4dev.yaml].each { |v| assert_includes line, v }
    refute_includes helm_log, 'REAL-INSTALL'
    refute_match(/--replace|--take-ownership|--force-conflicts|--rollback-on-failure|--atomic/, helm_log)
    subcommands = helm_log.lines.map { |l| l.sub(/\A--kubeconfig \S+ --kube-context \S+ /, '').split.first }.uniq.sort
    assert_equal %w[install lint list plugin template], subcommands, 'only read-only/dry-run helm subcommands may run'
    refute_includes out, 'synthetic-test-value'
  end

  def test_execute_requires_a_terminal_confirmation
    out, st = run_wrapper('--execute')
    refute st.success?
    assert_match(/no terminal for confirmation|confirmation did not match/, out)
    refute_includes helm_log, 'REAL-INSTALL'
  end

  def test_missing_kubeconfig_aborts_before_any_call
    out, st = run_wrapper(env: { 'ALPHA_KUBECONFIG' => File.join(@dir, 'nope.yaml') })
    refute st.success?
    assert_match(/not readable/, out)
    assert_equal '', helm_log
  end

  def test_missing_post_renderer_aborts
    out, st = run_wrapper(env: { 'HELM_PLUGINS_OVERRIDE_TEST' => '1' }) # sanity: present by default
    assert st.success?, out.lines.last(5).join
    FileUtils.mv(File.join(HERE, 'helm-plugins'), File.join(@dir, 'moved-plugins'))
    out, st = run_wrapper
    refute st.success?
    assert_match(/post-renderer be293-retention missing/, out)
  ensure
    FileUtils.mv(File.join(@dir, 'moved-plugins'), File.join(HERE, 'helm-plugins')) if File.exist?(File.join(@dir, 'moved-plugins'))
  end

  def test_preflight_fail_aborts_before_dry_run
    FileUtils.rm_f(File.join(@dir, 'secrets', 'be293-portal-bdrs'))
    out, st = run_wrapper
    refute st.success?
    assert_match(/ABORT: preflight reported FAIL/, out)
    assert_empty helm_log.lines.grep(/ install /)
  end

  def test_missing_networkpolicy_aborts_before_dry_run
    out, st = run_wrapper(env: { 'STUB_MISSING_NP' => 'be293-portal-default-deny' })
    refute st.success?
    assert_match(/NetworkPolicy be293-portal-default-deny missing/, out)
    assert_empty helm_log.lines.grep(/ install /)
  end

  def test_unsuspended_release_manifest_fails_verification
    verifier = File.join(HERE, 'tools/verify_release_retention.rb')
    manifest = "apiVersion: batch/v1\nkind: CronJob\nmetadata: {name: be293-portal-portal-maintenance}\nspec: {schedule: '0 0 * * *'}\n"
    out, st = Open3.capture2e('ruby', verifier, '--json', stdin_data: JSON.generate('manifest' => manifest, 'hooks' => []))
    refute st.success?
    assert_match(/maintenance CronJob not suspended/, out)
    assert_match(/be293-portal-postgres missing/, out)
  end
end
