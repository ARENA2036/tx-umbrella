# frozen_string_literal: true

# Tests for tools/validate_edc.rb on REAL offline renders of the two E2E test connectors and their PostgreSQL, plus one
# negative case per safety property. The decisive one renders the UNPATCHED upstream chart (the vendored package with the
# secret-refs patch reversed) and expects every literal credential to be caught. No cluster is contacted.
#
# Run: ruby tests/test_validate_edc.rb

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'yaml'
require_relative '../tools/validate_edc'

class ValidateEdcTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  CHARTS = File.expand_path('../charts/identity', HERE)
  CONNECTOR = File.join(CHARTS, 'tractusx-connector-0.13.0.tgz')
  PATCH = File.join(CHARTS, 'patches/tractusx-connector-0.13.0-secret-refs.patch')
  DUMMY = 'sha256:' + ('0' * 64)

  def self.helm(args, dir)
    env = { 'KUBECONFIG' => '/dev/null', 'HELM_CACHE_HOME' => "#{dir}/c", 'HELM_CONFIG_HOME' => "#{dir}/cfg", 'HELM_DATA_HOME' => "#{dir}/d" }
    out, err, st = Open3.capture3(env, 'helm', *args)
    raise err unless st.success?

    EdcGates::Validator.load(out)
  end

  def self.unpinned(dir, file)
    f = File.join(dir, File.basename(file))
    File.write(f, File.read(file).gsub(/<<PIN:[^>]+>>/, DUMMY))
    f
  end

  def self.render_connectors(chart, dir)
    common = unpinned(dir, File.join(HERE, 'values-be293-edc-common.yaml'))
    %w[fv1 guc].to_h do |c|
      ["edc-#{c}", helm(['template', "be293-edc-#{c}", chart, '-n', 'be293', '-f', common, '-f', File.join(HERE, "values-be293-edc-#{c}.yaml")], dir)]
    end
  end

  def self.fixtures
    @fixtures ||= Dir.mktmpdir do |dir|
      renders = render_connectors(CONNECTOR, dir)
      renders['edc-postgresql'] = helm(['template', 'be293-edc-postgresql', File.join(CHARTS, 'postgresql-16.0.0.tgz'), '-n', 'be293',
                                        '-f', File.join(HERE, 'values-be293-edc-postgresql.yaml')], dir)
      # upstream chart: the vendored package with the patch reversed. Its values need the literal keys, which the
      # be293 values set to the "from-secret-ref" placeholder: exactly what an unpatched install would put in the manifest.
      FileUtils.mkdir_p("#{dir}/up")
      system('tar', '-xzf', CONNECTOR, '-C', "#{dir}/up", exception: true)
      _, st = Open3.capture2e('patch', '-R', '-p1', '-s', '-i', PATCH, chdir: "#{dir}/up/tractusx-connector")
      raise 'reverse patch failed' unless st.success?

      { renders: renders, upstream: render_connectors("#{dir}/up/tractusx-connector", dir),
        ds: unpinned(dir, File.join(HERE, 'edc-datasource-be293.alpha.yaml')).then { |f| EdcGates::Validator.load(File.read(f)) } }
    end
  end

  def setup
    skip 'helm not installed' unless system('command -v helm >/dev/null 2>&1')
  end

  def fx
    Marshal.load(Marshal.dump(self.class.fixtures))
  end

  def np
    EdcGates::Validator.load(File.read(File.join(HERE, 'networkpolicies-be293-edc.alpha.yaml')))
  end

  def objects
    JSON.parse(File.read(File.join(HERE, 'edc-e2e-provider-objects.alpha.json')))
  end

  def run_all(renders: fx[:renders], mode: 'offline', policies: np, ds: fx[:ds], objs: objects)
    v = EdcGates::Validator.new(mode: mode)
    v.check_renders(renders).check_networkpolicies(policies).check_datasource(ds).check_objects(objs)
    v.failures.join("\n")
  end

  def deployment(renders, rel, plane)
    renders[rel].find { |d| d['kind'] == 'Deployment' && d.dig('metadata', 'name') == "be293-#{rel}-#{plane}" }
  end

  def test_prepared_package_passes_offline
    assert_empty run_all
  end

  def test_release_mode_requires_pinned_digests
    r = fx[:renders]
    deployment(r, 'edc-fv1', 'controlplane')['spec']['template']['spec']['containers'][0]['image'].sub!(/sha256:\h{64}\z/, '<<PIN:x>>')
    assert_match(/\[E4\] edc-fv1 .*digest not pinned yet/, run_all(renders: r, mode: 'release'))
  end

  def test_unpatched_upstream_chart_leaks_every_credential_as_a_literal
    r = fx[:renders].merge(fx[:upstream])
    msg = run_all(renders: r)
    %w[edc-fv1 edc-guc].each do |rel|
      %w[WEB_HTTP_MANAGEMENT_AUTH_KEY EDC_VAULT_HASHICORP_TOKEN EDC_DATASOURCE_DEFAULT_PASSWORD].each do |env|
        assert_match(/\[E3\] #{rel} Deployment\/be293-#{rel}-controlplane env #{env} is not read from a secretKeyRef/, msg)
      end
      assert_match(/\[E3\] #{rel} Deployment\/be293-#{rel}-dataplane env TX_EDC_DPF_CONSUMER_PROXY_AUTH_APIKEY is not read from a secretKeyRef/, msg)
    end
  end

  def test_literal_duplicate_next_to_a_secret_ref_fails
    r = fx[:renders]
    deployment(r, 'edc-guc', 'controlplane')['spec']['template']['spec']['containers'][0]['env'] << { 'name' => 'EDC_VAULT_HASHICORP_TOKEN', 'value' => 'root' }
    msg = run_all(renders: r)
    assert_match(/\[E3\] edc-guc Deployment\/be293-edc-guc-controlplane env EDC_VAULT_HASHICORP_TOKEN occurs 2 times/, msg)
    assert_match(/\[E3\] edc-guc Deployment\/be293-edc-guc-controlplane env EDC_VAULT_HASHICORP_TOKEN is not read from a secretKeyRef/, msg)
  end

  def test_secret_ref_to_the_wrong_secret_fails
    r = fx[:renders]
    e = deployment(r, 'edc-fv1', 'controlplane')['spec']['template']['spec']['containers'][0]['env'].find { |x| x['name'] == 'EDC_VAULT_HASHICORP_TOKEN' }
    e['valueFrom']['secretKeyRef']['name'] = 'be293-identityhub-vault-token'
    assert_match(%r{\[E3\] edc-fv1 controlplane EDC_VAULT_HASHICORP_TOKEN: expected secretKeyRef be293-edc-fv1-vault-token/token}, run_all(renders: r))
  end

  def test_div_url_or_bpn_as_sts_client_fails
    r = fx[:renders]
    env = deployment(r, 'edc-fv1', 'controlplane')['spec']['template']['spec']['containers'][0]['env']
    env << { 'name' => 'TX_EDC_IAM_STS_DIV_URL', 'value' => 'http://be293-identityhub.be293.svc.cluster.local:8087' }
    env.find { |x| x['name'] == 'EDC_IAM_STS_OAUTH_CLIENT_ID' }['value'] = 'BPNL000000000FV1'
    msg = run_all(renders: r)
    assert_match(/\[E5\] edc-fv1 controlplane sets a DIV URL/, msg)
    assert_match(/\[E5\] edc-fv1 controlplane EDC_IAM_STS_OAUTH_CLIENT_ID = "BPNL000000000FV1"/, msg)
  end

  def test_personal_image_fails
    r = fx[:renders]
    deployment(r, 'edc-guc', 'dataplane')['spec']['template']['spec']['containers'][0]['image'] = "docker.io/payammirzaeiarena/be293-images@#{DUMMY}"
    assert_match(/\[E4\] edc-guc .*payammirzaeiarena.* is not an approved official repository/, run_all(renders: r))
  end

  def test_management_port_or_namespace_selector_in_a_policy_fails
    policies = np
    cp = policies.find { |d| d.dig('metadata', 'name') == 'be293-edc-fv1-controlplane-ingress' }
    cp['spec']['ingress'][0]['ports'] << { 'protocol' => 'TCP', 'port' => 8081 }
    ih = policies.find { |d| d.dig('metadata', 'name') == 'be293-edc-identityhub-ingress' }
    ih['spec']['ingress'][0]['from'] << { 'namespaceSelector' => {} }
    msg = run_all(policies: policies)
    assert_match(/\[E7\] be293-edc-fv1-controlplane-ingress opens \[8081\] \(port-forward only\)/, msg)
    assert_match(/\[E7\] be293-edc-identityhub-ingress admits by namespaceSelector/, msg)
  end

  def contract_and(objs)
    objs['contractPolicyV2']['policy']['permission'][0]['constraint']['and']
  end

  def test_contract_policy_must_satisfy_the_connector_usage_policy_rules
    objs = objects
    contract_and(objs).reject! { |c| c['leftOperand'] == 'UsagePurpose' }
    assert_match(/\[E8\] contractPolicyV2 needs a UsagePurpose constraint/, run_all(objs: objs))

    objs = objects
    contract_and(objs).find { |c| c['leftOperand'] == 'UsagePurpose' }['operator'] = 'eq'
    assert_match(/\[E8\] contractPolicyV2 UsagePurpose operator "eq", only isAnyOf is accepted/, run_all(objs: objs))

    objs = objects
    contract_and(objs) << { 'leftOperand' => 'BusinessPartnerNumber', 'operator' => 'isAnyOf', 'rightOperand' => ['BPNL000000000GUC'] }
    assert_match(/\[E8\] contractPolicyV2 uses \["BusinessPartnerNumber"\]/, run_all(objs: objs))
  end

  def test_framework_agreement_must_be_exactly_data_exchange_governance_1_0
    objs = objects
    contract_and(objs).find { |c| c['leftOperand'] == 'FrameworkAgreement' }['rightOperand'] = 'DataExchangeGovernance:2.0'
    assert_match(/\[E8\] contractPolicyV2 needs exactly one FrameworkAgreement eq "DataExchangeGovernance:1.0"/, run_all(objs: objs))
  end

  def test_access_policy_allows_only_membership_and_bpn
    objs = objects
    objs['accessPolicy']['policy']['permission'][0]['constraint'][0]['and'] <<
      { 'leftOperand' => 'UsagePurpose', 'operator' => 'isAnyOf', 'rightOperand' => ['cx.core.industrycore:1'] }
    assert_match(/\[E8\] accessPolicy uses \["UsagePurpose"\]/, run_all(objs: objs))
  end

  def test_active_contract_definition_must_reference_the_v2_policy
    objs = objects
    objs['contractDefinitionV2']['contractPolicyId'] = 'be293-e2e-contract-policy-1'
    assert_match(/\[E8\] contractDefinitionV2 does not link accessPolicy and contractPolicyV2/, run_all(objs: objs))
  end
end
