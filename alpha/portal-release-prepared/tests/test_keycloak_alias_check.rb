# frozen_string_literal: true

# Tests for tools/keycloak_alias_check.rb: decision logic with a fake transport (no network), and the curl
# transport/CLI with a stub curl (secrets only via --config on stdin, never argv or output).
#
# Run: ruby tests/test_keycloak_alias_check.rb

require 'minitest/autorun'
require 'base64'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative '../tools/keycloak_alias_check'

class KeycloakAliasCheckTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  CENTRAL = KeycloakAliasCheck::Target.new('https://centralidp.example', 'CX-Central', 'sa-cl1-reg-2', 'c-secret')
  SHARED = KeycloakAliasCheck::Target.new('https://sharedidp.example', 'master', 'sa-cl1-reg-1', 's-secret')

  # Answers like the real Keycloaks: idp1/idp2 exist centrally (release26-09), everything be293-* is absent.
  class FakeKeycloak
    attr_reader :calls

    def initialize(overrides = {})
      @overrides = overrides
      @calls = []
    end

    def call(method, url, token: nil, form: nil)
      @calls << [method, url, token]
      return [200, JSON.generate('access_token' => "tok-#{form['client_id']}")] if url.end_with?('/protocol/openid-connect/token')
      return @overrides[url] if @overrides.key?(url)

      case url
      when %r{/identity-provider/instances/idp\d+\z} then [200, '{}']
      when %r{/identity-provider/instances/} then [404, '']
      when %r{/admin/realms/master\z} then [200, '{}']
      when %r{/admin/realms/master/clients\?clientId=sa-cl1-reg-1\z} then [200, '[{"id":"x"}]']
      when %r{/admin/realms/master/clients\?clientId=} then [200, '[]']
      when %r{/admin/realms/[^/]+\z} then [404, '']
      else [500, '']
      end
    end
  end

  def run_check(http, upto: 3)
    KeycloakAliasCheck::Checker.new(http: http).run(central: CENTRAL, shared: SHARED, central_realm: 'CX-Central', sa_prefix: 'sa',
                                                    prefix: 'be293-alpha-idp-', upto: upto, control_alias: 'idp2')
  end

  def test_all_absent_passes_with_controls_and_get_only
    http = FakeKeycloak.new
    c = run_check(http)
    assert_empty c.failures
    assert_match(/OK   controls/, c.lines.join)
    assert_match(/absent in shared Keycloaks: be293-alpha-idp-1\.\.be293-alpha-idp-3/, c.lines.join)
    assert(http.calls.reject { |m, u, _| u.end_with?('/token') }.all? { |m, _, _| m == 'GET' }, 'only GETs besides the token request')
    assert_includes http.calls.map { |c2| c2[1] }, 'https://sharedidp.example/auth/admin/realms/master/clients?clientId=sabe293-alpha-idp-2'
    assert(http.calls.select { |_, u, _| u.start_with?('https://sharedidp') && !u.end_with?('/token') }.all? { |_, _, t| t == 'tok-sa-cl1-reg-1' })
  end

  def test_existing_central_alias_shared_realm_or_client_fails
    c = run_check(FakeKeycloak.new('https://centralidp.example/auth/admin/realms/CX-Central/identity-provider/instances/be293-alpha-idp-2' => [200, '{}']))
    assert_includes c.failures, 'EXISTS central IdP be293-alpha-idp-2 (HTTP 200)'
    c = run_check(FakeKeycloak.new('https://sharedidp.example/auth/admin/realms/be293-alpha-idp-1' => [403, '']))
    assert_includes c.failures, 'EXISTS shared realm be293-alpha-idp-1 (HTTP 403)'
    c = run_check(FakeKeycloak.new('https://sharedidp.example/auth/admin/realms/master/clients?clientId=sabe293-alpha-idp-3' => [200, '[{"id":"y"}]']))
    assert_includes c.failures, 'EXISTS shared master client sabe293-alpha-idp-3'
  end

  def test_inconclusive_answers_fail_closed
    c = run_check(FakeKeycloak.new('https://centralidp.example/auth/admin/realms/CX-Central/identity-provider/instances/be293-alpha-idp-1' => [401, '']))
    assert_includes c.failures, 'UNKNOWN central IdP be293-alpha-idp-1 (HTTP 401)'
    c = run_check(FakeKeycloak.new('https://sharedidp.example/auth/admin/realms/master/clients?clientId=sabe293-alpha-idp-1' => [403, '']))
    assert_includes c.failures, 'UNKNOWN shared master client sabe293-alpha-idp-1 (HTTP 403)'
  end

  def test_failed_control_stops_before_probing
    http = FakeKeycloak.new('https://centralidp.example/auth/admin/realms/CX-Central/identity-provider/instances/idp2' => [404, ''])
    c = run_check(http)
    assert_match(/CONTROL central IdP idp2 -> HTTP 404/, c.failures.join)
    refute(http.calls.any? { |_, u, _| u.include?('be293-alpha-idp-') }, 'no alias probed when the control fails')
    c = run_check(FakeKeycloak.new('https://sharedidp.example/auth/admin/realms/master/clients?clientId=sa-cl1-reg-1' => [200, '[]']))
    assert_match(/CONTROL shared master client sa-cl1-reg-1/, c.failures.join)
  end

  def test_token_failure_and_bad_prefix_raise
    http =Class.new { def call(*, **) [401, '{}'] end }.new
    e = assert_raises(KeycloakAliasCheck::Error) { run_check(http) }
    assert_match(/token request for sa-cl1-reg-2 .* failed \(HTTP 401\)/, e.message)
    assert_raises(KeycloakAliasCheck::Error) do
      KeycloakAliasCheck::Checker.new(http: FakeKeycloak.new).run(central: CENTRAL, shared: SHARED, central_realm: 'CX-Central', sa_prefix: 'sa',
                                                                  prefix: 'idp', upto: 1, control_alias: 'idp2')
    end
  end

  # --- curl transport and CLI with a stub curl ---------------------------------------------------
  def with_stub_curl
    Dir.mktmpdir('kc-alias-test') do |dir|
      File.write(File.join(dir, 'curl'), <<~RUBY)
        #!/usr/bin/env ruby
        cfg = $stdin.read
        File.open('#{dir}/argv.log', 'a') { |f| f.puts ARGV.inspect }
        File.open('#{dir}/config.log', 'a') { |f| f.puts cfg }
        url = cfg[/^url = "(.*)"$/, 1]
        code, body =
          if url.end_with?('/token') then [200, '{"access_token":"tok-canary"}']
          elsif url =~ %r{/instances/idp2\\z} || url.end_with?('/realms/master') then [200, '{}']
          elsif url.include?('clientId=sa-cl1-reg-1') then [200, '[{"id":"x"}]']
          elsif url.include?('clientId=') then [200, '[]']
          else [404, '']
          end
        print body, "\\n", code
      RUBY
      FileUtils.chmod(0o755, File.join(dir, 'curl'))
      yield dir
    end
  end

  def secret_json
    JSON.generate('data' => { 'central-client-secret' => Base64.strict_encode64('central-canary"x'),
                              'shared-client-secret' => Base64.strict_encode64('shared-canary') })
  end

  def cli(dir, extra = [])
    args = %w[--central-url https://centralidp.example --central-auth-realm CX-Central --central-client sa-cl1-reg-2
              --shared-url https://sharedidp.example --shared-auth-realm master --shared-client sa-cl1-reg-1
              --central-realm CX-Central --sa-prefix sa --prefix be293-alpha-idp- --to 2 --control-alias idp2
              --central-key central-client-secret --shared-key shared-client-secret] + extra
    Open3.capture2e({ 'PATH' => "#{dir}:#{ENV['PATH']}" }, 'ruby', File.join(HERE, 'tools/keycloak_alias_check.rb'), *args, stdin_data: secret_json)
  end

  def test_cli_passes_secrets_only_via_curl_config_stdin
    with_stub_curl do |dir|
      out, st = cli(dir)
      assert st.success?, out
      assert_match(/OK   absent in shared Keycloaks/, out)
      argv = File.read("#{dir}/argv.log")
      %w[central-canary shared-canary tok-canary].each do |s|
        refute_includes argv, s, "#{s} must not be on the curl command line"
        refute_includes out, s, "#{s} must not be printed"
      end
      assert_includes File.read("#{dir}/config.log"), 'data-urlencode = "client_secret=central-canary\\"x"', 'quote escaped in curl config'
      assert(argv.lines.all? { |l| l.include?('"--proto", "=https"') })
    end
  end

  def test_cli_rejects_missing_key_and_http_urls_without_leaking
    with_stub_curl do |dir|
      out, st = cli(dir, %w[--shared-key nope])
      refute st.success?
      assert_match(/secret key nope missing/, out)
      refute_includes out, 'canary'
      out, st = cli(dir, %w[--central-url http://centralidp.example])
      refute st.success?
      assert_match(/must be https/, out)
    end
  end
end
