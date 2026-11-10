# frozen_string_literal: true

# Tests for tools/validate_did_resolver.rb (DR1-DR10) on the real did-resolver-be293.alpha.yaml (image digests
# pinned to synthetic values in memory), plus the Portal-side gates on synthetic render/policy documents.
#
# Run: ruby tests/test_validate_did_resolver.rb

require 'minitest/autorun'
require 'yaml'
require_relative 'support/pinned_did_resolver'
require_relative '../tools/validate_did_resolver'

class ValidateDidResolverTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  URL = DidResolverGates::URL

  def docs
    YAML.load_stream(PinnedDidResolver.pin(File.read(PinnedDidResolver::SOURCE))).compact
  end

  def kind(d, k, i = 0)
    d.select { |x| x['kind'] == k }[i]
  end

  def pod(d)
    kind(d, 'Deployment')['spec']['template']['spec']
  end

  def container(d, name)
    pod(d)['containers'].find { |c| c['name'] == name }
  end

  def policy(d, type)
    d.find { |x| x['kind'] == 'NetworkPolicy' && x['spec']['policyTypes'] == [type] }
  end

  def conf!(d)
    cm = kind(d, 'ConfigMap')
    cm['data']['nginx.conf'] = yield(cm['data']['nginx.conf'])
    d
  end

  def failures_of(d, render: nil, policies: nil)
    DidResolverGates::Validator.new.check(d, render: render, policies: policies).failures.join("\n")
  end

  def worker(env)
    { 'kind' => 'CronJob', 'metadata' => { 'name' => 'be293-portal-processes-worker' },
      'spec' => { 'jobTemplate' => { 'spec' => { 'template' => { 'spec' => { 'containers' => [{ 'env' => env.map { |k, v| { 'name' => k, 'value' => v } } }] } } } } } }
  end

  def release_policies
    DidResolverGates.load(File.join(HERE, 'networkpolicies-be293-portal.alpha-release.yaml'))
  end

  def test_pinned_manifest_passes_all_gates_and_repo_pins_are_required
    assert_empty failures_of(docs, render: [worker(DidResolverGates::RESOLVER_ENVS.to_h { |k| [k, URL] })], policies: release_policies)
    unless File.read(PinnedDidResolver::SOURCE).match?(/did-uport:5\.0\.8@sha256:\h{64}/)
      assert_match(/\[DR3\] driver image .*not pinned/, failures_of(DidResolverGates.load(PinnedDidResolver::SOURCE)))
    end
    d = docs
    container(d, 'driver')['image'] = 'docker.io/uport/uni-resolver-driver-did-uport:latest'
    assert_match(/\[DR3\] driver image/, failures_of(d))
  end

  def test_portal_percent_encoding_matches_dotnet_escape_data_string
    assert_equal 'did%3Aweb%3Aidentity-hub-01.test.tractus-x.com%3ABPNL000000000342',
                 DidResolverGates.escape_data_string(DidResolverGates::SAMPLE_DID)
  end

  def test_dr1_dr2_no_public_exposure
    d = docs
    kind(d, 'Service')['spec']['type'] = 'LoadBalancer'
    assert_match(/\[DR2\] Service type "LoadBalancer"/, failures_of(d))
    d = docs
    kind(d, 'Service')['spec']['ports'] << { 'name' => 'driver', 'port' => 8081, 'targetPort' => 'driver' }
    assert_match(/\[DR2\] Service ports \[8080, 8081\]/, failures_of(d))
    d = docs << { 'kind' => 'Ingress', 'metadata' => { 'name' => 'x', 'namespace' => 'be293' } }
    assert_match(/\[DR1\] unexpected kind Ingress/, failures_of(d))
    d = docs
    kind(d, 'Service')['metadata']['namespace'] = 'release26-09'
    assert_match(/\[DR1\] Service\/be293-did-resolver namespace "release26-09"/, failures_of(d))
  end

  def test_dr4_gateway_accepts_only_identityhub_did_web
    d = conf!(docs) { |c| c.sub('(?<did>did:web:[a-z0-9-]+(\.[a-z0-9-]+)*\.test\.tractus-x\.com(:[A-Za-z0-9._-]+)*)', '(?<did>did:.+)') }
    out = failures_of(d)
    assert_match(/\[DR4\] gateway accepts did:ethr/, out)
    assert_match(/\[DR4\] gateway accepts did:web:evil\.example\.com/, out)
    d = conf!(docs) { |c| c.sub('(:[A-Za-z0-9._-]+)*)$"', '(:[A-Za-z0-9._-]+)*)"') } # end anchor dropped
    assert_match(/\[DR4\] gateway accepts did:web:identity-hub-01\.test\.tractus-x\.com\.evil\.example\.com:x/, failures_of(d))
    d = conf!(docs) { |c| c.sub('(?<did>did:web:[a-z0-9-]+', '(?<did>did:web:identity-hub-02') }
    assert_match(/\[DR4\] gateway rejects did:web:identity-hub-01.* as sent by the Portal/, failures_of(d))
  end

  def test_dr4_gateway_methods_paths_and_upstreams
    assert_match(/limited to GET/, failures_of(conf!(docs) { |c| c.sub('limit_except GET { deny all; }', '') }))
    assert_match(/default location must return 404/, failures_of(conf!(docs) { |c| c.sub('location / { return 404; }', 'location / { proxy_pass http://127.0.0.1:8081; }') }))
    assert_match(/unexpected proxy_pass targets \["http:\/\/evil:80\/\$did"\]/,
                 failures_of(conf!(docs) { |c| c.sub('http://127.0.0.1:8081/1.0/identifiers/$did', 'http://evil:80/$did') }))
  end

  def test_dr5_dr6_hardening_and_sizing
    d = docs
    container(d, 'driver')['securityContext']['runAsUser'] = 0
    container(d, 'gateway')['securityContext']['readOnlyRootFilesystem'] = false
    pod(d)['automountServiceAccountToken'] = true
    out = failures_of(d)
    assert_match(/\[DR5\] driver: runAsUser must be non-zero/, out)
    assert_match(/\[DR5\] gateway: readOnlyRootFilesystem not true/, out)
    assert_match(/\[DR5\] automountServiceAccountToken not false/, out)
    d = docs
    container(d, 'driver')['resources'].delete('limits')
    kind(d, 'Deployment')['spec']['replicas'] = 2
    out = failures_of(d)
    assert_match(/\[DR6\] driver: memory limit required/, out)
    assert_match(/\[DR6\] replicas must be 1/, out)
  end

  def test_dr7_ingress_only_gateway_port_from_be293
    d = docs
    policy(d, 'Ingress')['spec']['ingress'][0]['from'] = [{ 'namespaceSelector' => {} }]
    assert_match(/\[DR7\] ingress source must be podSelector \{\} only/, failures_of(d))
    d = docs
    policy(d, 'Ingress')['spec']['ingress'][0]['ports'] = [{ 'protocol' => 'TCP', 'port' => 8081 }]
    assert_match(/\[DR7\] ingress ports/, failures_of(d))
  end

  def test_dr8_egress_restricted_to_dns_and_did_host
    d = docs
    policy(d, 'Egress')['spec']['egress'] << { 'to' => [{ 'ipBlock' => { 'cidr' => '0.0.0.0/0' } }], 'ports' => [{ 'protocol' => 'TCP', 'port' => 443 }] }
    assert_match(/\[DR8\] rule 3: ipBlock 0\.0\.0\.0\/0 is not a single \/32/, failures_of(d))
    d = docs
    policy(d, 'Egress')['spec']['egress'] << { 'to' => [{ 'namespaceSelector' => { 'matchLabels' => { 'kubernetes.io/metadata.name' => 'release26-09' } } }], 'ports' => [{ 'protocol' => 'TCP', 'port' => 5432 }] }
    assert_match(/\[DR8\] rule 3: destination .*release26-09.* not allowed/, failures_of(d))
    d = docs
    policy(d, 'Egress')['spec']['egress'] << { 'to' => [{ 'ipBlock' => { 'cidr' => '188.34.116.149/32' } }] }
    assert_match(/\[DR8\] rule 3 has no ports/, failures_of(d))
  end

  def test_dr9_worker_must_use_the_in_namespace_resolver
    old = worker('APPLICATIONCHECKLIST__IDENTITYHUB__UNIVERSALRESOLVERADDRESS' => 'https://dev.uniresolver.io/',
                 'APPLICATIONCHECKLIST__DIM__UNIVERSALRESOLVERADDRESS' => URL)
    out = failures_of(docs, render: [old])
    assert_match(/\[DR9\] .*IDENTITYHUB__UNIVERSALRESOLVERADDRESS "https:\/\/dev\.uniresolver\.io\/"/, out)
    assert_match(/\[DR9\] public universal resolver still referenced/, out)
    assert_match(/\[DR9\] be293-portal-processes-worker not rendered/, failures_of(docs, render: []))
  end

  def test_dr11_helm_release_must_not_render_resolver_objects
    ok = worker(DidResolverGates::RESOLVER_ENVS.to_h { |k| [k, URL] })
    assert_empty failures_of(docs, render: [ok])
    clash = { 'kind' => 'Service', 'metadata' => { 'name' => 'be293-did-resolver' } }
    assert_match(%r{\[DR11\] Helm release renders resolver objects \["Service/be293-did-resolver"\]}, failures_of(docs, render: [ok, clash]))
    other_kind = { 'kind' => 'ConfigMap', 'metadata' => { 'name' => 'be293-did-resolver' } }
    refute_match(/DR11/, failures_of(docs, render: [ok, other_kind]))
  end

  def test_dr10_release_policies_keep_the_worker_path
    narrowed = release_policies.reject { |p| p['metadata']['name'] == 'be293-portal-intra-namespace-egress' }
    assert_match(/\[DR10\]/, failures_of(docs, policies: narrowed))
  end
end
