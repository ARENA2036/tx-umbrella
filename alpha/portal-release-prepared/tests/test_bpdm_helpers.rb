# frozen_string_literal: true

# Unit tests for tools/bpdm_openapi.rb (API version from the live OpenAPI document) and tools/env_patch.rb
# (plain env patches and their dry-run assertion). Offline.
#
# Run: ruby tests/test_bpdm_helpers.rb

require 'minitest/autorun'
require 'json'
require_relative '../tools/bpdm_openapi'
require_relative '../tools/env_patch'
require_relative 'support/bpdm_openapi_fixture'
require 'open3'

class BpdmHelpersTest < Minitest::Test
  def gate_doc(prefix = '/v6', skip: nil)
    paths = { "#{prefix}/input/business-partners" => { 'put' => {}, 'post' => {} },
              "#{prefix}/sharing-state/ready" => { 'post' => {} },
              "#{prefix}/output/business-partners/search" => { 'post' => {} },
              "#{prefix}/sharing-state" => { 'get' => {} } }
    paths.delete("#{prefix}/#{skip}") if skip
    { 'info' => { 'title' => 'Business Partner Data Management Gate', 'version' => '7.2.0' }, 'paths' => paths }
  end

  def pool_doc(prefix = '/v6')
    { 'paths' => { "#{prefix}/cx-memberships" => { 'put' => {} }, "#{prefix}/legal-entities/{idValue}" => { 'get' => {} } } }
  end

  def test_openapi_resolves_one_version_for_every_backend_call
    assert_equal '/v6', BpdmOpenApi.resolve(gate_doc, 'gate')[0]
    assert_equal '/v7', BpdmOpenApi.resolve(gate_doc('/v7'), 'gate')[0]
    assert_equal '/v6', BpdmOpenApi.resolve(pool_doc, 'pool')[0]
    assert_equal '', BpdmOpenApi.resolve(gate_doc(''), 'gate')[0], 'an unversioned API resolves to no prefix'
  end

  def test_openapi_fails_on_missing_call_wrong_verb_or_mixed_versions
    prefix, missing, = BpdmOpenApi.resolve(gate_doc(skip: 'sharing-state/ready'), 'gate')
    assert_nil prefix
    assert_equal ['POST sharing-state/ready'], missing
    doc = gate_doc
    doc['paths']['/v6/input/business-partners'] = { 'post' => {} }
    assert_includes BpdmOpenApi.resolve(doc, 'gate')[1], 'PUT input/business-partners'
    mixed = gate_doc
    mixed['paths']['/v7/input/business-partners'] = mixed['paths'].delete('/v6/input/business-partners')
    assert_nil BpdmOpenApi.resolve(mixed, 'gate')[0]
    refute_nil BpdmOpenApi.resolve(pool_doc, 'pool')[0]
    assert_nil BpdmOpenApi.resolve({ 'paths' => { '/v6/legal-entities' => { 'get' => {} } } }, 'pool')[0]
  end

  def test_schema_v6_gate_matches_every_field_bpn_creation_uses
    doc = BpdmOpenApiFixture.gate
    assert_equal '/v6', BpdmOpenApi.resolve(doc, 'gate')[0]
    results = BpdmOpenApi.check_fields(doc, 'gate', '/v6')
    assert_equal 4, results.size
    assert(results.all? { |_, miss, blocks| miss.empty? && blocks }, results.inspect)
  end

  def street_doc(street)
    { 'components' => { 'schemas' => {
      'Address' => { 'type' => 'object', 'properties' => { 'street' => street } },
      'StreetAlias' => { '$ref' => '#/components/schemas/StreetDto' },
      'StreetDto' => BpdmOpenApiFixture.obj(:name, :houseNumber),
      'PoBox' => BpdmOpenApiFixture.obj(:houseNumber)
    } } }
  end

  def field?(street, path)
    doc = street_doc(street)
    BpdmOpenApi.field?(doc, doc.dig('components', 'schemas', 'Address'), path)
  end

  def test_resolver_follows_nested_ref_and_nullable_one_of
    ref = BpdmOpenApiFixture.r('StreetDto')
    alias_ref = BpdmOpenApiFixture.r('StreetAlias')
    null = { 'type' => 'null' }
    assert field?(ref, 'street.name'), 'plain $ref'
    assert field?(alias_ref, 'street.houseNumber'), 'nested $ref -> $ref'
    assert field?({ 'oneOf' => [ref, null] }, 'street.name'), 'nullable oneOf (springdoc, BPDM 7.5.0 street)'
    assert field?({ 'oneOf' => [null, alias_ref] }, 'street.houseNumber'), 'null first, nested $ref'
    assert field?({ 'anyOf' => [ref, { 'type' => ['null'] }] }, 'street.name'), 'nullable anyOf'
    assert field?({ 'allOf' => [{ 'oneOf' => [ref, null] }] }, 'street.name'), 'oneOf inside allOf'
  end

  def test_resolver_stays_fail_closed_for_missing_or_incompatible_fields
    ref = BpdmOpenApiFixture.r('StreetDto')
    null = { 'type' => 'null' }
    refute field?({ 'oneOf' => [ref, null] }, 'street.nameSuffix'), 'property truly missing behind nullable oneOf'
    refute field?({ 'oneOf' => [null] }, 'street.name'), 'null-only oneOf'
    refute field?({ 'oneOf' => [ref, BpdmOpenApiFixture.r('Missing')] }, 'street.name'), 'unresolvable alternative'
    refute field?({ 'oneOf' => [ref, BpdmOpenApiFixture.r('PoBox')] }, 'street.name'), 'name absent from one non-null alternative'
    assert field?({ 'oneOf' => [ref, BpdmOpenApiFixture.r('PoBox')] }, 'street.houseNumber'), 'present in every alternative'
    refute field?(BpdmOpenApiFixture.r('Missing'), 'street'), 'dangling $ref'
    refute field?({ 'type' => 'string' }, 'street.name'), 'scalar has no properties'
  end

  def test_schema_gate_mismatch_blocks_and_names_the_field
    results = BpdmOpenApi.check_fields(BpdmOpenApiFixture.gate(drop: :street_name), 'gate', '/v6')
    label, miss, blocks = results.first
    assert_equal 'PUT /v6/input/business-partners', label
    assert_equal ['[].address.physicalPostalAddress.street.name'], miss
    assert blocks
  end

  def test_schema_upstream_pool_lacks_the_arena_membership_field_but_does_not_block
    cx, le = BpdmOpenApi.check_fields(BpdmOpenApiFixture.pool, 'pool', '/v6')
    assert_equal ['PUT /v6/cx-memberships', ['memberships[].isArenaXMember'], false], cx
    assert_equal ['GET /v6/legal-entities/{}', [], false], le
    assert_empty BpdmOpenApi.check_fields(BpdmOpenApiFixture.pool(member_field: 'isArenaXMember'), 'pool', '/v6')[0][1]
  end

  # BPDM 7.5.0 v7 moved calls the backend needs: gate sharing-state (GET and POST ready) -> /v7/business-partners/sharing-state
  # and pool cx-memberships -> /v7/data-space-participants. A v7 base therefore cannot serve the pinned backend.
  def test_v7_layout_of_7_5_0_cannot_serve_the_backend
    gate = BpdmOpenApiFixture.gate
    gate['paths'] = gate['paths'].map { |p, o| [p.sub('/v6/', '/v7/').sub('/v7/sharing-state', '/v7/business-partners/sharing-state'), o] }.to_h
    assert_nil BpdmOpenApi.resolve(gate, 'gate')[0]
    assert_equal ['POST sharing-state/ready', 'GET sharing-state'], BpdmOpenApi.resolve(gate, 'gate')[1]
    pool = BpdmOpenApiFixture.pool('/v7')
    pool['paths']['/v7/data-space-participants'] = pool['paths'].delete('/v7/cx-memberships')
    assert_equal ['PUT cx-memberships'], BpdmOpenApi.resolve(pool, 'pool')[1]
  end

  def test_cli_exit_codes_and_output
    cli = File.expand_path('../tools/bpdm_openapi.rb', __dir__)
    out, st = Open3.capture2('ruby', cli, '--api', 'pool', stdin_data: JSON.generate(BpdmOpenApiFixture.pool))
    assert st.success?, out
    assert_match(%r{\AOK pool prefix=/v6 title="Business Partner Data Management Pool" version="7.5.0"}, out)
    assert_match(/SCHEMA MISMATCH PUT \/v6\/cx-memberships: missing memberships\[\]\.isArenaXMember \(not used by BPN Creation\)/, out)
    out, st = Open3.capture2('ruby', cli, '--api', 'gate', stdin_data: JSON.generate(BpdmOpenApiFixture.gate(drop: :street_name)))
    refute st.success?
    assert_match(/\(blocks BPN Creation\)/, out)
    out, st = Open3.capture2('ruby', cli, '--api', 'gate', stdin_data: 'not json')
    refute st.success?
    assert_match(/FAIL gate: OpenAPI document is not JSON/, out)
  end

  def cronjob(env)
    { 'kind' => 'CronJob', 'spec' => { 'schedule' => '*/5 * * * *', 'jobTemplate' => { 'spec' => { 'template' => { 'spec' => {
      'containers' => [{ 'name' => 'w', 'env' => env }] } } } } } }
  end

  def test_env_patch_builds_strategic_patch_for_both_kinds
    pairs = [%w[A x]]
    assert_equal({ 'spec' => { 'jobTemplate' => { 'spec' => { 'template' => { 'spec' => { 'containers' => [{ 'name' => 'w', 'env' => [{ 'name' => 'A', 'value' => 'x' }] }] } } } } } },
                 EnvPatch.patch('CronJob', 'w', pairs))
    assert_equal({ 'spec' => { 'template' => { 'spec' => { 'containers' => [{ 'name' => 'w', 'env' => [{ 'name' => 'A', 'value' => 'x' }] }] } } } },
                 EnvPatch.patch('Deployment', 'w', pairs))
    assert_raises(EnvPatch::Error) { EnvPatch.pairs(['NOVALUE']) }
  end

  def test_env_patch_assert_accepts_only_the_named_changes
    live = cronjob([{ 'name' => 'A', 'value' => 'old' }, { 'name' => 'S', 'valueFrom' => { 'secretKeyRef' => { 'name' => 's', 'key' => 'k' } } }])
    after = Marshal.load(Marshal.dump(live))
    after['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['env'][0]['value'] = 'new'
    assert EnvPatch.assert(live, after, [%w[A new]])
    e = assert_raises(EnvPatch::Error) { EnvPatch.assert(live, after, [%w[A other]]) }
    assert_match(/expected/, e.message)
    extra = Marshal.load(Marshal.dump(after))
    extra['spec']['suspend'] = true
    assert_match(/changes more than A/, assert_raises(EnvPatch::Error) { EnvPatch.assert(live, extra, [%w[A new]]) }.message)
    secret = Marshal.load(Marshal.dump(after))
    secret['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['env'][1]['valueFrom']['secretKeyRef']['key'] = 'other'
    assert_raises(EnvPatch::Error) { EnvPatch.assert(live, secret, [%w[A new]]) }
  end

  def test_env_patch_values_and_show_never_expose_secret_refs
    render = YAML.dump(cronjob([{ 'name' => 'A', 'value' => 'v' }, { 'name' => 'S', 'valueFrom' => {} }]).merge('metadata' => { 'name' => 'w' }))
    assert_equal ['A=v'], EnvPatch.values(render, 'CronJob', 'w', ['A'])
    assert_match(/not a plain value/, assert_raises(EnvPatch::Error) { EnvPatch.values(render, 'CronJob', 'w', ['S']) }.message)
    doc = YAML.safe_load(render)
    assert_equal ['A=v', 'S=<secretRef>', 'Z=<unset>'], EnvPatch.show(doc, %w[A S Z])
    assert_equal 'w', EnvPatch.container(doc, 'A')
  end
end
