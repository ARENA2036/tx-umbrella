# frozen_string_literal: true

# Behavioural tests for tools/identity-vault-be293.sh under the macOS system bash (3.2, where `set -u` rejects an empty
# "${array[@]}"), with stub kubectl/curl (no cluster, no Vault). --init runs on a pseudo-terminal (Ruby PTY) and the test
# types the confirmation only after the prompt appears, exactly as an operator would; that reaches the unauthenticated
# POST with an empty header array, which is what failed before.
#
# Run: ruby tests/test_identity_vault_wrapper.rb

require 'minitest/autorun'
require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'io/wait'
require 'pty'
require 'tmpdir'

class IdentityVaultWrapperTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  SCRIPT = File.join(HERE, 'tools/identity-vault-be293.sh')
  BASH = '/bin/bash'
  ROOT_TOKEN = 'stub-root-token-canary'

  def setup
    skip 'no /bin/bash' unless File.executable?(BASH)
    @dir = Dir.mktmpdir('be293-vault-test')
    @bin = File.join(@dir, 'bin')
    @vault_dir = File.join(@dir, 'vault')
    FileUtils.mkdir_p(@bin)
    @kc = File.join(@dir, 'alpha.yaml')
    File.write(@kc, '')
    File.write(File.join(@bin, 'kubectl'), <<~SH)
      #!/bin/sh
      echo "$*" >> "#{@dir}/kubectl.log"
      case "$*" in
        *port-forward*) exec sleep 30 ;;
        *"get pods -n be293 -l app.kubernetes.io/instance=be293-identity-vault,app.kubernetes.io/name=vault,component=server"*)
          printf '%s' "${STUB_PODS-be293-identity-vault-0}"; exit 0 ;;
      esac
      exit 3
    SH
    File.write(File.join(@bin, 'curl'), <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      a = ARGV.dup
      url = a.last
      File.open('#{@dir}/curl.log', 'a') { |f| f.puts a.reject { |x| x.start_with?('@') }.join(' ') }
      out = a.include?('-o') ? a[a.index('-o') + 1] : nil
      body, code = case url
                   when %r{/v1/sys/health\\z} then ['{}', 200]
                   when %r{/v1/sys/seal-status\\z}
                     [JSON.generate('initialized' => false, 'sealed' => true, 'progress' => 0, 't' => 0, 'storage_type' => 'raft'), 200]
                   when %r{/v1/sys/init\\z}
                     [JSON.generate('keys_base64' => %w[k1 k2 k3 k4 k5], 'root_token' => '#{ROOT_TOKEN}'), 200]
                   else ['', 404]
                   end
      File.write(out, body) if out && out != '/dev/null'
      print code if a.include?('-w')
    RUBY
    %w[kubectl curl].each { |f| FileUtils.chmod(0o755, File.join(@bin, f)) }
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def env
    { 'PATH' => "#{@bin}:#{ENV['PATH']}", 'ALPHA_KUBECONFIG' => @kc, 'BE293_VAULT_DIR' => @vault_dir, 'TMPDIR' => @dir }
  end

  def curl_log
    File.exist?("#{@dir}/curl.log") ? File.read("#{@dir}/curl.log") : ''
  end

  def test_status_runs_on_bash_3_2_with_an_empty_header_array
    out, st = Open3.capture2e(env, BASH, SCRIPT, '--status', stdin_data: '')
    assert st.success?, out
    refute_match(/unbound variable/, out)
    assert_includes out, 'initialized=false sealed=true'
    refute_includes curl_log, 'X-Vault-Token'
    assert_includes out, 'OK   port-forward to pod/be293-identity-vault-0 on 127.0.0.1:18200'
    log = File.read("#{@dir}/kubectl.log").lines
    assert_equal 2, log.size, log.join
    assert_match(/--context alpha --request-timeout=20s get pods -n be293 -l app\.kubernetes\.io\/instance=be293-identity-vault,app\.kubernetes\.io\/name=vault,component=server -o jsonpath=/, log[0])
    # The POD, not the Service: a sealed/uninitialised Vault is never Ready, so the Service has no endpoints.
    # bound to loopback only (--address), never 0.0.0.0
    assert_match(/port-forward -n be293 --address 127\.0\.0\.1 pod\/be293-identity-vault-0 18200:8200\z/, log[1].chomp)
    refute_match(/svc\//, log.join)
  end

  # Run the script on a pseudo-terminal like an operator: wait for the prompt, then type the answer (CR, as a terminal
  # sends it). Never pre-type input or close the terminal's input: `script(1)` with piped stdin wrote the answer before
  # the prompt existed and then injected VEOF on end of input (BSD script.c), so whether the line survived until
  # `read` was a matter of timing, not of the code under test. Returns [output, exit status].
  def run_on_pty(env_vars, argv, answer, timeout: 60)
    out = +''
    PTY.spawn(env_vars, *argv) do |r, w, pid|
      deadline = Time.now + timeout
      typed = false
      loop do
        break if Time.now > deadline
        next unless r.wait_readable(0.2)

        begin
          out << r.readpartial(4096)
        rescue Errno::EIO, EOFError
          break # child closed the terminal (exited)
        end
        if !typed && out.include?('Type exactly')
          w.write("#{answer}\r")
          w.flush
          typed = true
        end
      end
      Process.kill('TERM', pid) if Time.now > deadline
      _, status = Process.wait2(pid)
      return [out, status]
    end
  end

  def pty_available?
    PTY.spawn('true') { |_r, _w, pid| Process.wait(pid) }
    true
  rescue StandardError
    false
  end

  def test_init_on_bash_3_2_writes_the_material_to_a_private_file_and_prints_nothing_secret
    skip 'pseudo-terminals not permitted here (openpty); covered by test_api_function_with_empty_header_array' unless pty_available?
    out, st = run_on_pty(env, [BASH, SCRIPT, '--init'], 'initialize the be293 identity vault')
    refute_match(/unbound variable/, out)
    assert_includes out, 'Type exactly "initialize the be293 identity vault"', out
    assert st.success?, out
    init = File.join(@vault_dir, 'vault-init.json')
    assert File.exist?(init), out
    assert_equal ROOT_TOKEN, JSON.parse(File.read(init))['root_token']
    assert_equal '600', format('%o', File.stat(init).mode & 0o777)
    assert_equal '700', format('%o', File.stat(@vault_dir).mode & 0o777)
    refute_includes out, ROOT_TOKEN, 'init material must never be printed'
    assert_match(%r{-X PUT .*http://127\.0\.0\.1:18200/v1/sys/init}, curl_log)
  end

  def test_init_with_a_wrong_confirmation_changes_nothing
    skip 'pseudo-terminals not permitted here (openpty)' unless pty_available?
    out, st = run_on_pty(env, [BASH, SCRIPT, '--init'], 'initialise the be293 identity vault')
    refute st.success?
    assert_includes out, 'ABORT: confirmation did not match; nothing changed'
    refute File.exist?(File.join(@vault_dir, 'vault-init.json'))
    refute_match(%r{/v1/sys/init}, curl_log)
  end

  def test_missing_vault_pod_fails_clearly_before_any_port_forward
    out, st = Open3.capture2e(env.merge('STUB_PODS' => ''), BASH, SCRIPT, '--status', stdin_data: '')
    refute st.success?
    assert_includes out, 'ABORT: no Vault server pod found in be293'
    assert_includes out, 'is release be293-identity-vault installed?'
    refute_match(/port-forward/, File.read("#{@dir}/kubectl.log"))
    assert_empty curl_log
  end

  def test_more_than_one_vault_pod_is_refused
    out, st = Open3.capture2e(env.merge('STUB_PODS' => 'be293-identity-vault-0 be293-identity-vault-1'), BASH, SCRIPT, '--status', stdin_data: '')
    refute st.success?
    assert_includes out, 'expected exactly one Vault server pod in be293, found 2'
    refute_match(/port-forward/, File.read("#{@dir}/kubectl.log"))
  end

  def test_init_refuses_a_second_initialisation
    FileUtils.mkdir_p(@vault_dir)
    File.write(File.join(@vault_dir, 'vault-init.json'), '{}')
    out, st = Open3.capture2e(env, BASH, SCRIPT, '--init', stdin_data: '')
    refute st.success?
    assert_includes out, 'Vault was initialised already; nothing changed'
    refute_match(%r{/v1/sys/init}, curl_log)
  end

  # The real api() function from the script, under bash 3.2 and `set -u`, with the empty header array of an
  # unauthenticated call: POST with a body (the --init/--unseal path that failed) and GET (--status).
  def test_api_function_with_empty_header_array
    fn = File.read(SCRIPT)[/^api\(\) \{\n.*?^\}\n/m]
    refute_nil fn, 'api() not found in the script'
    work = File.join(@dir, 'work')
    FileUtils.mkdir_p(work)
    File.write(File.join(work, 'body'), '{"secret_shares":5,"secret_threshold":3}')
    harness = <<~SH
      set -euo pipefail
      WORK="#{work}"; VAULT="http://127.0.0.1:18200"
      #{fn}
      : > "$WORK/token.hdr"
      echo "post=$(api PUT /v1/sys/init "$WORK/body")"
      echo "get=$(api GET /v1/sys/seal-status)"
    SH
    out, st = Open3.capture2e(env, BASH, '-c', harness)
    refute_match(/unbound variable/, out)
    assert st.success?, out
    assert_includes out, 'post=200'
    assert_includes out, 'get=200'
    refute_includes curl_log, 'X-Vault-Token'
    assert_match(%r{-X PUT .*--data-binary .*http://127\.0\.0\.1:18200/v1/sys/init}, curl_log)
  end

  # --configure-edc needs a typed confirmation (a pty, not available everywhere), so its functions are run directly under
  # bash 3.2 against a stateful stub Vault that records which token made each call. Canary values prove nothing secret is
  # printed and that the STS secret is copied exactly, read with the root token and written with the connector's token.
  STS_CANARY = 'sts-secret-canary-4711'
  EDC_TOKEN = 'edc-token-canary-0815'

  def write_edc_stubs(kubectl_secret_exists: false)
    File.write(File.join(@bin, 'curl'), <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      a = ARGV.dup
      url = a.last
      method = a[a.index('-X') + 1]
      hdr = a.each_cons(2).find { |x, y| x == '-H' && y.start_with?('@') }&.last&.delete_prefix('@')
      token = hdr ? File.read(hdr)[/X-Vault-Token: (.*)/, 1] : nil
      body = a.find { |x| x.start_with?('@') && x != "@\#{hdr}" }&.delete_prefix('@')
      state_f = '#{@dir}/vault.json'
      state = File.exist?(state_f) ? JSON.parse(File.read(state_f)) : {}
      File.open('#{@dir}/edc-calls.log', 'a') { |f| f.puts [method, url.sub('http://127.0.0.1:18200', ''), token == '#{ROOT_TOKEN}' ? 'root' : (token == '#{EDC_TOKEN}' ? 'edc' : token.inspect)].join(' ') }
      path = url.sub('http://127.0.0.1:18200', '')
      out = a[a.index('-o') + 1]
      code, resp =
        if path == '/v1/identityhub/data/bpnl000000000fv1-sts-client-secret'
          token == '#{ROOT_TOKEN}' ? [200, { 'data' => { 'data' => { 'content' => '#{STS_CANARY}' } } }] : [403, {}]
        elsif path == '/v1/auth/token/create-orphan'
          [200, { 'auth' => { 'client_token' => '#{EDC_TOKEN}' } }]
        elsif (m = path.match(%r{\\A/v1/(edc-fv1)/data/(.+)\\z}))
          key = "\#{m[1]}/\#{m[2]}"
          if token != '#{EDC_TOKEN}' then [403, {}]
          elsif method == 'GET' then state.key?(key) ? [200, { 'data' => { 'data' => { 'content' => state[key] } } }] : [404, {}]
          elsif state.key?(key) then [400, {}]
          else state[key] = JSON.parse(File.read(body)).dig('data', 'content'); File.write(state_f, JSON.generate(state)); [200, {}]
          end
        else [404, {}]
        end
      File.write(out, JSON.generate(resp))
      print code
    RUBY
    File.write(File.join(@bin, 'kubectl'), <<~SH)
      #!/bin/sh
      echo "$*" >> "#{@dir}/kubectl.log"
      case "$*" in
        *"get secret be293-edc-fv1-vault-token"*"-o name"*) #{kubectl_secret_exists ? 'echo secret/be293-edc-fv1-vault-token' : ':'} ; exit 0 ;;
        *"get secret be293-edc-fv1-vault-token"*"jsonpath"*) printf '%s' "$(printf '%s' '#{EDC_TOKEN}' | base64)"; exit 0 ;;
        *"create secret generic be293-edc-fv1-vault-token"*) cat "$(echo "$*" | sed -n 's/.*--from-file=token=\\([^ ]*\\).*/\\1/p')" > "#{@dir}/created-token"; exit 0 ;;
      esac
      exit 3
    SH
    %w[curl kubectl].each { |f| FileUtils.chmod(0o755, File.join(@bin, f)) }
  end

  def edc_harness(steps)
    src = File.read(SCRIPT)
    fns = %w[die k api root_header].map { |n| src[/^#{n}\(\) \{\n.*?^\}\n/m] || src[/^#{n}\(\) \{.*\n/] }
    block = src[/^# --- E2E test connectors \(--configure-edc\) ---\n.*?^# --- end E2E test connectors ---\n/m]
    refute_nil block, 'configure-edc block not found'
    work = File.join(@dir, 'work')
    FileUtils.mkdir_p(work)
    FileUtils.mkdir_p(@vault_dir)
    File.write(File.join(@vault_dir, 'vault-init.json'), JSON.generate('root_token' => ROOT_TOKEN, 'keys_base64' => []))
    <<~SH
      set -euo pipefail
      WORK="#{work}"; VAULT="http://127.0.0.1:18200"; NS=be293; KC="#{@kc}"; CTX=alpha; INIT_FILE="#{@vault_dir}/vault-init.json"
      #{fns.compact.join("\n")}
      #{block}
      root_header; cp "$WORK/token.hdr" "$WORK/root.hdr"
      #{steps}
    SH
  end

  def run_edc(steps = 'edc_token edc-fv1; use_header edc-fv1; edc_keys edc-fv1; copy_sts_secret edc-fv1 bpnl000000000fv1')
    Open3.capture2e(env, BASH, '-c', edc_harness(steps))
  end

  def vault_state
    JSON.parse(File.read(File.join(@dir, 'vault.json')))
  end

  def test_configure_edc_copies_the_sts_secret_exactly_with_the_right_tokens_and_prints_nothing_secret
    write_edc_stubs
    out, st = run_edc
    assert st.success?, out
    refute_match(/unbound variable/, out)
    [STS_CANARY, EDC_TOKEN, ROOT_TOKEN, 'BEGIN PRIVATE KEY'].each { |c| refute_includes out, c, 'nothing secret may be printed' }
    s = vault_state
    assert_equal STS_CANARY, s['edc-fv1/edc-wallet-secret']
    assert_match(/\A-----BEGIN PRIVATE KEY-----/, s['edc-fv1/tokenSignerPrivateKey'])
    assert_match(/\A-----BEGIN PUBLIC KEY-----/, s['edc-fv1/tokenSignerPublicKey'])
    assert_equal 32, Base64.strict_decode64(s['edc-fv1/tokenEncryptionAesKey']).bytesize
    assert_includes out, 'OK   edc-wallet-secret matches IdentityHub (SHA-256 compared, value not shown)'
    calls = File.read(File.join(@dir, 'edc-calls.log'))
    assert_match(%r{^GET /v1/identityhub/data/bpnl000000000fv1-sts-client-secret root$}, calls)
    calls.lines.grep(%r{/v1/edc-fv1/}).each { |l| assert l.end_with?(" edc\n"), "connector mount used with the wrong token: #{l}" }
    assert_equal EDC_TOKEN, File.read(File.join(@dir, 'created-token')), 'token stored in its Secret before use'
    # the Secret is created before the first connector-token call
    klog = File.read(File.join(@dir, 'kubectl.log'))
    assert_match(/create secret generic be293-edc-fv1-vault-token -n be293 --from-file=token=/, klog)
    Dir[File.join(@dir, 'work', '*')].each { |f| refute_includes File.read(f), STS_CANARY, "#{File.basename(f)} still holds the STS secret" }
  end

  def test_configure_edc_rerun_overwrites_nothing_and_reuses_the_stored_token
    write_edc_stubs
    _, st = run_edc
    assert st.success?
    before = vault_state
    FileUtils.rm_f(File.join(@dir, 'edc-calls.log'))
    write_edc_stubs(kubectl_secret_exists: true)
    out, st = run_edc
    assert st.success?, out
    assert_equal before, vault_state
    assert_includes out, 'OK   Secret be293-edc-fv1-vault-token exists: token reused'
    assert_includes out, 'OK   edc-fv1 token-signer pair exists (not overwritten)'
    assert_includes out, 'OK   edc-fv1/edc-wallet-secret exists (not overwritten)'
    refute_match(%r{^POST /v1/(edc-fv1/data|auth/token)}, File.read(File.join(@dir, 'edc-calls.log')))
  end

  def test_configure_edc_refuses_a_half_present_signer_pair
    write_edc_stubs
    File.write(File.join(@dir, 'vault.json'), JSON.generate('edc-fv1/tokenSignerPublicKey' => 'x'))
    out, st = run_edc
    refute st.success?
    assert_includes out, 'edc-fv1 has only one half of the token-signer pair: fix by hand, nothing written'
    assert_equal({ 'edc-fv1/tokenSignerPublicKey' => 'x' }, vault_state)
  end

  def test_configure_edc_without_root_token_explains_generate_root
    write_edc_stubs
    harness = edc_harness('')
    File.write(File.join(@vault_dir, 'vault-init.json'), JSON.generate('keys_base64' => []))
    out, st = Open3.capture2e(env, BASH, '-c', harness)
    refute st.success?
    assert_includes out, 'regenerate one with the unseal keys (vault operator generate-root)'
  end

  def test_every_package_script_parses_under_bash_3_2
    Dir[File.join(HERE, 'tools/*.sh')].each do |f|
      _, st = Open3.capture2e(BASH, '-n', f)
      assert st.success?, "#{File.basename(f)} does not parse under #{BASH}"
    end
  end
end
