# frozen_string_literal: true

# Tests for tools/validate_identity.rb on REAL offline renders of the five identity releases and of the Portal with and
# without the identity overlay, plus one negative case per safety property. No cluster is contacted.
#
# Run: ruby tests/test_validate_identity.rb

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'
require_relative '../tools/validate_identity'

class ValidateIdentityTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  ALPHA = File.expand_path('..', HERE)
  PORTAL = File.join(ALPHA, 'portal-release-prepared')
  CHARTS = { 'identity-vault' => 'vault-0.29.1.tgz', 'identity-postgresql' => 'postgresql-16.0.0.tgz',
             'issuerservice' => 'tractusx-issuerservice-v0.4.1.tgz', 'identityhub' => 'tractusx-identityhub-v0.4.1.tgz',
             'bdrs' => 'bdrs-server-0.6.0.tgz' }.freeze
  DUMMY = 'sha256:' + ('0' * 64)
  PORTAL_VALUES = %w[values-be293-portal.yaml values-be293-portal.alpha-release.yaml values-be293-portal.alpha-retention.yaml
                     values-be293-portal.alpha-smtp4dev.yaml].freeze

  def self.helm(args, dir)
    env = { 'KUBECONFIG' => '/dev/null', 'HELM_PLUGINS' => File.join(PORTAL, 'helm-plugins'), 'HELM_CACHE_HOME' => "#{dir}/c",
            'HELM_CONFIG_HOME' => "#{dir}/cfg", 'HELM_DATA_HOME' => "#{dir}/d" }
    out, err, st = Open3.capture3(env, 'helm', *args)
    raise err unless st.success?

    IdentityGates::Validator.load(out)
  end

  def self.fixtures
    @fixtures ||= Dir.mktmpdir do |dir|
      renders = CHARTS.to_h do |rel, chart|
        v = File.join(dir, "#{rel}.yaml")
        File.write(v, File.read(File.join(HERE, "values-be293-#{rel}.yaml")).gsub(/<<PIN:[^>]+>>/, DUMMY))
        [rel, helm(['template', "be293-#{rel}", File.join(ALPHA, 'identity-charts', chart), '-n', 'be293', '-f', v], dir)]
      end
      chart = File.join(ALPHA, 'portal-chart-2.6.0-patched', 'portal-2.6.0.tgz')
      base = ['template', 'be293-portal', chart, '-n', 'be293', '--post-renderer', 'be293-idp-switch'] +
             PORTAL_VALUES.flat_map { |f| ['-f', File.join(PORTAL, f)] }
      { renders: renders, before: helm(base, dir),
        after: helm(base + ['-f', File.join(PORTAL, 'values-be293-portal.alpha-identity.yaml')], dir) }
    end
  end

  def setup
    skip 'helm not installed' unless system('command -v helm >/dev/null 2>&1')
  end

  def fx
    Marshal.load(Marshal.dump(self.class.fixtures))
  end

  def load(file)
    IdentityGates::Validator.load(File.read(File.join(HERE, file)))
  end

  def run_all(f: fx, mode: 'offline', np: load('networkpolicies-be293-identity.alpha.yaml'),
              seed: load('identity-seed-be293.alpha.yaml'), job: load('identity-seed-job-be293.alpha.yaml'))
    v = IdentityGates::Validator.new(mode: mode)
    v.check_renders(f[:renders]).check_seed(seed, job).check_networkpolicies(np).check_portal(f[:before], f[:after])
    v.failures.join("\n")
  end

  def doc(f, rel, kind, name = nil)
    f[:renders][rel].find { |d| d['kind'] == kind && (name.nil? || d.dig('metadata', 'name') == name) }
  end

  def test_prepared_package_passes_offline
    assert_empty run_all
  end

  def test_release_mode_requires_pinned_digests
    f = fx
    f[:renders].each_value { |docs| docs.each { |d| (d.dig('spec', 'template', 'spec', 'containers') || []).each { |c| c['image'] = c['image'].sub(/sha256:\h{64}\z/, '<<PIN:x>>') } } }
    assert_match(/\[I4\] .*not pinned yet/, run_all(f: f, mode: 'release'))
  end

  def test_literal_password_in_config_map_fails
    f = fx
    doc(f, 'issuerservice', 'ConfigMap', 'be293-issuerservice-datasource-config')['data']['edc.datasource.holder.password'] = 'hunter2'
    msg = run_all(f: f)
    assert_match(/\[I3\] issuerservice ConfigMap\/be293-issuerservice-datasource-config key edc.datasource.holder.password carries a value/, msg)
    refute_includes msg, 'hunter2'
  end

  def test_placeholder_without_secret_override_fails
    f = fx
    c = doc(f, 'identityhub', 'Deployment')['spec']['template']['spec']['containers'][0]
    c['env'].reject! { |e| e['name'] == 'edc.vault.hashicorp.token' }
    assert_match(/\[I3\] identityhub edc.vault.hashicorp.token has no env override from a Secret/, run_all(f: f))
  end

  def test_personal_image_repository_fails
    f = fx
    doc(f, 'identityhub', 'Deployment')['spec']['template']['spec']['containers'][0]['image'] = "docker.io/payammirzaeiarena/be293-images:identityhub@#{DUMMY}"
    assert_match(/\[I4\] identityhub .*not an approved official repository/, run_all(f: f))
  end

  def test_vault_dev_mode_inmem_or_wrong_storage_class_fails
    f = fx
    sts = doc(f, 'identity-vault', 'StatefulSet')
    sts['spec']['volumeClaimTemplates'][0]['spec']['storageClassName'] = 'standard'
    sts['spec']['template']['spec']['containers'][0]['env'] << { 'name' => 'VAULT_DEV_ROOT_TOKEN_ID', 'value' => 'root' }
    cm = doc(f, 'identity-vault', 'ConfigMap')
    cm['data'].each_key { |k| cm['data'][k] = cm['data'][k].sub('storage "raft"', 'storage "inmem"') }
    msg = run_all(f: f)
    assert_match(/\[I5\] Vault PVC storageClass "standard"/, msg)
    assert_match(/\[I5\] Vault runs in dev mode/, msg)
    assert_match(/\[I5\] Vault storage is not integrated Raft/, msg)
  end

  def test_private_path_on_ingress_fails
    f = fx
    ing = doc(f, 'issuerservice', 'Ingress')
    ing['spec']['rules'][0]['http']['paths'] << { 'path' => '/api/admin', 'pathType' => 'Prefix' }
    assert_match(/\[I7\] issuerservice Ingress paths/, run_all(f: f))
  end

  def test_reference_to_release26_09_fails
    f = fx
    doc(f, 'bdrs', 'Deployment')['spec']['template']['spec']['containers'][0]['env'] << { 'name' => 'X', 'value' => 'http://bdrs-server.release26-09.svc.cluster.local:8081' }
    assert_match(/\[I8\] bdrs Deployment\/be293-bdrs refers to the shared identity stack/, run_all(f: f))
  end

  def test_seed_role_with_pods_log_fails
    seed = load('identity-seed-be293.alpha.yaml')
    seed.find { |d| d['kind'] == 'Role' }['rules'] << { 'apiGroups' => [''], 'resources' => ['pods/log'], 'verbs' => ['get'] }
    msg = run_all(seed: seed)
    assert_match(/\[I9\] seed Role is not PATCH-only/, msg)
    assert_match(/\[I9\] seed grants pods\/log/, msg)
  end

  def test_seed_script_with_xtrace_or_log_scraping_fails
    seed = load('identity-seed-be293.alpha.yaml')
    cm = seed.find { |d| d['kind'] == 'ConfigMap' }
    cm['data']['seed.sh'] = "set -x\nkubectl logs deploy/be293-identityhub\n" + cm['data']['seed.sh']
    msg = run_all(seed: seed)
    assert_match(/\[I9\] seed script enables xtrace/, msg)
    assert_match(/\[I9\] seed script reads pod logs/, msg)
  end

  def test_vault_port_open_to_ingress_controller_fails
    np = load('networkpolicies-be293-identity.alpha.yaml')
    np.find { |d| d.dig('metadata', 'name') == 'be293-identity-vault-ingress' }['spec']['ingress'] <<
      { 'from' => [{ 'namespaceSelector' => { 'matchLabels' => { 'kubernetes.io/metadata.name' => 'ingress-nginx' } } }], 'ports' => [{ 'port' => 8200 }] }
    msg = run_all(np: np)
    assert_match(/\[I10\] be293-identity-vault-ingress opens private port\(s\) \[8200\]/, msg)
  end

  def test_readiness_port_closed_inside_namespace_fails
    np = load('networkpolicies-be293-identity.alpha.yaml')
    %w[be293-issuerservice-ingress be293-identityhub-ingress].each do |n|
      np.find { |d| d.dig('metadata', 'name') == n }['spec']['ingress'].each { |r| r['ports'].reject! { |p| p['port'] == 8081 } }
    end
    msg = run_all(np: np)
    assert_match(/\[I10\] be293-issuerservice readiness port 8081 not open inside be293/, msg)
    assert_match(/\[I10\] be293-identityhub readiness port 8081 not open inside be293/, msg)
  end

  def test_seed_egress_wider_than_one_api_server_address_fails
    np = load('networkpolicies-be293-identity.alpha.yaml')
    eg = np.find { |d| d.dig('metadata', 'name') == 'be293-identity-seed-apiserver-egress' }
    eg['spec']['podSelector'] = {}
    eg['spec']['egress'][0]['to'] = [{ 'ipBlock' => { 'cidr' => '0.0.0.0/0' } }]
    eg['spec']['egress'][0]['ports'] << { 'protocol' => 'TCP', 'port' => 5432 }
    msg = run_all(np: np)
    assert_match(/\[I10\] be293-identity-seed-apiserver-egress egress does not select only the seed pod/, msg)
    assert_match(/\[I10\] be293-identity-seed-apiserver-egress egress allows more than one \/32 address/, msg)
    assert_match(/\[I10\] be293-identity-seed-apiserver-egress egress allows more than TCP 443/, msg)
  end

  def test_portal_overlay_still_pointing_at_shared_identity_hub_fails
    f = fx
    wl = f[:after].find { |d| d['kind'] == 'CronJob' && d.dig('metadata', 'name') == 'be293-portal-processes-worker' }
    e = wl['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['env'].find { |x| x['name'] == 'APPLICATIONCHECKLIST__IDENTITYHUB__BASEADDRESS' }
    e['value'] = 'http://identity-hub-01.release26-09.svc.cluster.local:8082/api/identity'
    assert_match(/\[I11\] be293-portal-processes-worker APPLICATIONCHECKLIST__IDENTITYHUB__BASEADDRESS still points at the shared identity stack/, run_all(f: f))
  end

  def test_portal_overlay_must_keep_worker_suspended_and_images
    f = fx
    wl = f[:after].find { |d| d['kind'] == 'CronJob' && d.dig('metadata', 'name') == 'be293-portal-processes-worker' }
    wl['spec']['suspend'] = false
    wl['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['image'] += '-other'
    msg = run_all(f: f)
    assert_match(/\[I11\] CronJob suspension differs/, msg)
    assert_match(/\[I11\] Portal images differ/, msg)
  end

  def test_portal_overlay_keeps_bpdm_on_the_shared_central_idp
    f = fx
    wl = f[:after].find { |d| d['kind'] == 'CronJob' && d.dig('metadata', 'name') == 'be293-portal-processes-worker' }
    e = wl['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['env'].find { |x| x['name'] == 'APPLICATIONCHECKLIST__BPDM__TOKENADDRESS' }
    e['value'] = 'https://centralidp-be293.test.tractus-x.com/auth/realms/CX-Central/protocol/openid-connect/token'
    assert_match(/\[I11\] be293-portal-processes-worker BPDM token address/, run_all(f: f))
  end
end
