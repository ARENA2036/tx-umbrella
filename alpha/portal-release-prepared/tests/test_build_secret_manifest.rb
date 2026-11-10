# frozen_string_literal: true

# Unit tests for tools/build_secret_manifest.rb (no cluster, no tty): manifests built from the contract must
# pass tools/check_secret_contract.rb, and unsafe inputs are refused.
#
# Run: ruby tests/test_build_secret_manifest.rb

require 'minitest/autorun'
require 'base64'
require 'json'
require 'yaml'
require_relative '../tools/build_secret_manifest'
require_relative '../tools/check_secret_contract'

class BuildSecretManifestTest < Minitest::Test
  CONTRACT = YAML.safe_load(File.read(File.expand_path('../secrets-contract.yaml', __dir__)))
  BUILDABLE = %w[be293-portal-keycloak be293-portal-interfaces be293-portal-identityhub be293-portal-bdrs].freeze

  def spec(name)
    CONTRACT['secrets'].find { |s| s['name'] == name }
  end

  def owner_prompt
    ->(label) { "owner-value-for-#{label[/\A[^ ]+/]}" }
  end

  def test_every_buildable_secret_round_trips_through_the_contract_check
    BUILDABLE.each do |name|
      manifest = SecretManifest.build(spec(name), prompt: owner_prompt)
      results = SecretContract.check(spec(name), JSON.parse(JSON.generate(manifest)), mail_disabled: true)
      fails = results.select { |l, _| l == 'FAIL' }
      assert_empty fails, "#{name}: #{fails.inspect}"
    end
  end

  def test_adoption_metadata_only_for_chart_rendered_secrets
    kc = SecretManifest.build(spec('be293-portal-keycloak'), prompt: owner_prompt)['metadata']
    assert_equal 'Helm', kc['labels']['app.kubernetes.io/managed-by']
    assert_equal({ 'meta.helm.sh/release-name' => 'be293-portal', 'meta.helm.sh/release-namespace' => 'be293' }, kc['annotations'])

    ih = SecretManifest.build(spec('be293-portal-identityhub'), prompt: owner_prompt)['metadata']
    refute ih['labels'].key?('app.kubernetes.io/managed-by')
    refute ih.key?('annotations')
  end

  def test_encryption_keys_generated_fresh_and_owner_keys_prompted
    prompted = []
    prompt = ->(label) { prompted << label[/\A[^ ]+/]; 'x' }
    a = SecretManifest.build(spec('be293-portal-interfaces'), prompt: prompt)['data']
    b = SecretManifest.build(spec('be293-portal-interfaces'), prompt: ->(_) { 'x' })['data']
    assert_equal %w[be293-portal-interfaces/bpdm-client-secret be293-portal-interfaces/sdfactory-client-secret], prompted
    key = Base64.strict_decode64(a['mailing-encryption-key0'])
    assert_match(/\A\h{64}\z/, key)
    refute_equal a['mailing-encryption-key0'], b['mailing-encryption-key0']
    # unused keys get a printable sentinel: omitted keys make the chart write undecoded random bytes (NUL risk)
    assert_equal 'disabled-custodian-no-access', Base64.strict_decode64(a['custodian-client-secret'])
    assert_equal 'disabled-clearinghouse-no-access', Base64.strict_decode64(a['clearinghouse-client-secret-default'])
    spec('be293-portal-interfaces')['keys'].select { |_, k| k['class'] == 'unused' }.each_key do |key|
      assert_match(/\Adisabled-[a-z]+-no-access\z/, Base64.strict_decode64(a.fetch(key)))
    end
  end

  def test_refuses_empty_and_padded_values
    assert_raises(ArgumentError) { SecretManifest.build(spec('be293-portal-bdrs'), prompt: ->(_) { '' }) }
    assert_raises(ArgumentError) { SecretManifest.build(spec('be293-portal-bdrs'), prompt: ->(_) { ' key ' }) }
  end

  def test_refuses_secrets_that_must_not_be_pre_created
    %w[be293-portal-postgres be293-portal-mailing be293-portal-registry-pull].each do |name|
      assert_raises(ArgumentError) { SecretManifest.build(spec(name), prompt: owner_prompt) }
    end
  end
end
