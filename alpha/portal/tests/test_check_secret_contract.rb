# frozen_string_literal: true

# Unit tests for tools/check_secret_contract.rb (synthetic Secrets, no cluster). Every test also asserts that
# no secret value appears in the output.
#
# Run: ruby tests/test_check_secret_contract.rb

require 'minitest/autorun'
require 'base64'
require 'json'
require 'open3'
require 'yaml'
require_relative '../tools/check_secret_contract'

class CheckSecretContractTest < Minitest::Test
  CONTRACT_FILE = File.expand_path('../secrets-contract.yaml', __dir__)
  SCRIPT = File.expand_path('../tools/check_secret_contract.rb', __dir__)
  CONTRACT = YAML.safe_load(File.read(CONTRACT_FILE))
  HEX = 'ab' * 32
  CANARY = 'canary-Secret-Value-must-never-be-printed'

  def spec(name)
    CONTRACT['secrets'].find { |s| s['name'] == name }
  end

  def secret(name, data, adopted: true, type: 'Opaque')
    meta = { 'name' => name, 'namespace' => 'be293' }
    if adopted
      meta['labels'] = { 'app.kubernetes.io/managed-by' => 'Helm' }
      meta['annotations'] = { 'meta.helm.sh/release-name' => 'be293-portal', 'meta.helm.sh/release-namespace' => 'be293' }
    end
    { 'metadata' => meta, 'type' => type, 'data' => data.transform_values { |v| Base64.strict_encode64(v) } }
  end

  def run_check(name, secret, mail_disabled: false)
    SecretContract.check(spec(name), secret, mail_disabled: mail_disabled)
  end

  def levels(results)
    results.map(&:first)
  end

  def text(results)
    results.map(&:last).join("\n")
  end

  def test_valid_identityhub_secret_passes_without_printing_values
    r = run_check('be293-portal-identityhub', secret('be293-portal-identityhub',
                                                     { 'identityhub-api-key' => CANARY, 'issuerservice-admin-api-key' => CANARY }, adopted: false))
    refute_includes levels(r), 'FAIL'
    refute_includes text(r), CANARY
  end

  def test_missing_required_secret_fails
    assert_includes levels(run_check('be293-portal-bdrs', nil)), 'FAIL'
  end

  def test_empty_owner_key_fails
    r = run_check('be293-portal-bdrs', secret('be293-portal-bdrs', { 'management-api-key' => '' }, adopted: false))
    assert_match(%r{be293-portal-bdrs/management-api-key \(owner-provisioned\) missing or empty}, text(r))
  end

  def test_adopted_secret_without_helm_metadata_fails
    data = { 'central-client-secret' => CANARY, 'shared-client-secret' => CANARY }
    r = run_check('be293-portal-keycloak', secret('be293-portal-keycloak', data, adopted: false))
    assert_match(/lacks Helm adoption metadata/, text(r))
    refute_includes text(r), CANARY
  end

  def test_encryption_keys_must_be_64_hex
    keys = spec('be293-portal-interfaces')['keys'].select { |_, k| k['class'] != 'unused' }.keys
    data = keys.to_h { |k| [k, k.include?('encryption') ? HEX : CANARY] }
    data['mailing-encryption-key0'] = 'not-hex'
    r = run_check('be293-portal-interfaces', secret('be293-portal-interfaces', data))
    assert_match(%r{mailing-encryption-key0 is not 64 hex characters}, text(r))
    assert_equal 1, levels(r).count('FAIL')
    refute_includes text(r), CANARY
  end

  # The chart's lookup branch writes randAlphaNum unencoded into data:, so a decoded key can hold a NUL byte.
  def test_nul_byte_in_any_key_fails_and_unused_sentinel_passes
    keys = spec('be293-portal-interfaces')['keys'].reject { |_, k| k['class'] == 'unused' }.keys
    data = keys.to_h { |k| [k, k.include?('encryption') ? HEX : CANARY] }
    data['custodian-client-secret'] = 'disabled-custodian-no-access'
    r = run_check('be293-portal-interfaces', secret('be293-portal-interfaces', data))
    refute_includes levels(r), 'FAIL'
    assert_match(%r{custodian-client-secret \(unused\) present, 28 bytes, no NUL}, text(r))

    data['dim-client-secret'] = "ab\0cd#{CANARY}"
    r = run_check('be293-portal-interfaces', secret('be293-portal-interfaces', data))
    assert_match(%r{dim-client-secret \(unused\) contains a NUL byte}, text(r))
    assert_equal 1, levels(r).count('FAIL')
    refute_includes text(r), CANARY
  end

  def test_mailing_absent_is_ok_only_when_mail_disabled
    assert_includes levels(run_check('be293-portal-mailing', nil)), 'FAIL'
    refute_includes levels(run_check('be293-portal-mailing', nil, mail_disabled: true)), 'FAIL'
  end

  def test_chart_generated_postgres_absent_ok_present_warns
    assert_equal ['OK'], levels(run_check('be293-portal-postgres', nil)).uniq
    data = %w[postgres-password replication-password portal-password provisioning-password].to_h { |k| [k, CANARY] }
    r = run_check('be293-portal-postgres', secret('be293-portal-postgres', data))
    assert_match(/Helm lookup will REUSE/, text(r))
  end

  def test_pull_secret_type_and_registry
    cfg = { 'auths' => { 'harbor-hub-shared.arena.3ascloud.de' => { 'auth' => Base64.strict_encode64("robot:#{CANARY}") } } }.to_json
    ok = run_check('be293-portal-registry-pull',
                   secret('be293-portal-registry-pull', { '.dockerconfigjson' => cfg }, adopted: false, type: 'kubernetes.io/dockerconfigjson'))
    refute_includes levels(ok), 'FAIL'
    refute_includes text(ok), CANARY

    other = { 'auths' => { 'docker.io' => {} } }.to_json
    bad = run_check('be293-portal-registry-pull', secret('be293-portal-registry-pull', { '.dockerconfigjson' => other }, adopted: false))
    assert_match(/type "Opaque" != kubernetes.io\/dockerconfigjson/, text(bad))
    assert_match(/has NO entry for harbor-hub-shared/, text(bad))
  end

  def test_cli_absent_secret_and_exit_codes
    out, st = Open3.capture2e('ruby', SCRIPT, '--contract', CONTRACT_FILE, '--name', 'be293-portal-bdrs', stdin_data: '')
    assert_equal 1, st.exitstatus
    assert_match(/FAIL be293-portal-bdrs missing/, out)

    json = secret('be293-portal-bdrs', { 'management-api-key' => CANARY }, adopted: false).to_json
    out, st = Open3.capture2e('ruby', SCRIPT, '--contract', CONTRACT_FILE, '--name', 'be293-portal-bdrs', stdin_data: json)
    assert_equal 0, st.exitstatus, out
    refute_includes out, CANARY
    refute_includes out, Base64.strict_encode64(CANARY)
  end
end
