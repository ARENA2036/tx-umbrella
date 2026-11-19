# frozen_string_literal: true

# Keeps bruno/BE293-Alpha-EDC-E2E in step with edc-e2e-provider-objects.alpha.json (the provider bodies and the catalog
# request must stay verbatim copies) and checks that no API key value is stored in the collection.
#
# Run: ruby tests/test_bruno_collection.rb

require 'minitest/autorun'
require 'json'

class BrunoCollectionTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  COLL = File.join(HERE, 'bruno', 'BE293-Alpha-EDC-E2E')

  def objects
    JSON.parse(File.read(File.join(HERE, 'edc-e2e-provider-objects.alpha.json')))
  end

  def bru(path)
    File.read(File.join(COLL, path))
  end

  def body(path)
    text = bru(path)[/^body:json \{\n(.*?)^\}\n/m, 1]
    refute_nil text, "#{path} has no body:json block"
    JSON.parse(text)
  end

  def test_provider_bodies_are_verbatim_copies_of_the_active_objects
    { '01-Provider/01-Create Asset.bru' => 'asset', '01-Provider/02-Create Access Policy.bru' => 'accessPolicy',
      '01-Provider/03-Create Contract Policy V2.bru' => 'contractPolicyV2',
      '01-Provider/04-Create Contract Definition V2.bru' => 'contractDefinitionV2',
      '02-Consumer/01-Request Catalog.bru' => 'consumerCatalogRequest' }.each do |file, key|
      assert_equal objects.fetch(key), body(file), "#{file} differs from #{key}"
    end
  end

  def test_provider_requests_use_the_provider_key_and_v3_paths
    { '01-Create Asset' => 'assets', '02-Create Access Policy' => 'policydefinitions',
      '03-Create Contract Policy V2' => 'policydefinitions', '04-Create Contract Definition V2' => 'contractdefinitions' }.each do |f, path|
      text = bru("01-Provider/#{f}.bru")
      assert_includes text, "url: {{Provider}}/v3/#{path}\n"
      assert_match(/auth:apikey \{\n  key: X-Api-Key\n  value: \{\{Provider_Api_Key\}\}/, text)
    end
  end

  def test_negotiation_echoes_contract_policy_v2_with_the_catalog_operand_form
    neg = body('02-Consumer/02-Initiate Contract Negotiation.bru')
    want = objects.dig('contractPolicyV2', 'policy', 'permission', 0, 'constraint', 'and').map(&:dup)
    want.find { |c| c['leftOperand'] == 'UsagePurpose' }['rightOperand'] = 'cx.core.industrycore:1' # catalog form
    assert_equal want, neg.dig('policy', 'permission', 0, 'constraint', 0, 'and')
    assert_equal '{{offerId}}', neg.dig('policy', '@id')
    assert_equal objects.dig('consumerCatalogRequest', 'counterPartyAddress'), body('02-Consumer/01-Request Catalog.bru')['counterPartyAddress']
    refute neg.dig('policy', 'permission', 0, 'constraint', 0, 'and').any? { |c| c['leftOperand'] == 'BusinessPartnerNumber' }
  end

  def test_transfer_is_http_pull_on_the_agreement
    t = body('02-Consumer/04-Initiate Transfer.bru')
    assert_equal %w[HttpData-PULL {{agreementId}} dataspace-protocol-http:2025-1], [t['transferType'], t['contractId'], t['protocol']]
  end

  def test_acceptance_is_the_payload_hash_and_length
    text = bru('02-Consumer/07-Fetch Data.bru')
    assert_includes text, 'url: {{DataPlane}}/api/public'
    assert_includes text, 'Authorization: {{edrToken}}'
    assert_includes text, 'to.equal(140)'
    assert_includes text, 'c48268cc16f6e04c1e3500a2d4cd717d656cff95da8abd32dab4f7071f8695c2'
  end

  def test_no_api_key_value_is_stored
    envs = Dir[File.join(COLL, 'environments', '*.bru')]
    refute_empty envs, 'no Bruno environment in environments/'
    envs.each do |f|
      text = File.read(f)
      secret = text[/^vars:secret \[\n(.*?)^\]/m, 1].to_s.split(/[,\s]+/).reject(&:empty?)
      %w[Provider_Api_Key Consumer_Api_Key].each do |k|
        assert_includes secret, k, "#{File.basename(f)}: #{k} must be a vars:secret entry (value kept out of Git)"
      end
      refute_match(/^\s*\w*Api_Key\s*:/, text, "#{File.basename(f)} assigns an API key value")
    end
    Dir[File.join(COLL, '**', '*.bru')].each do |f|
      refute_match(/X-Api-Key:\s*\S/, File.read(f), "#{File.basename(f)} sets a literal X-Api-Key header")
      next if f.include?('/environments/')

      refute_match(/Api_Key\s*:/, File.read(f), "#{File.basename(f)} defines an API key variable")
    end
  end
end
