# frozen_string_literal: true

# Tests for the zero-automatic-data-deletion controls: the release-local post-renderer
# (helm-plugins/be293-retention/post-render.rb) and the gate tools/validate_retention.rb. Synthetic manifests,
# plus offline integration renders of the real chart (KUBECONFIG=/dev/null, no cluster).
#
# Run: ruby tests/test_validate_retention.rb

require 'minitest/autorun'
require_relative 'support/pinned_smtp4dev'
require_relative 'support/pinned_did_resolver'
require 'json'
require 'open3'
require 'tmpdir'
require 'yaml'
require_relative '../tools/validate_retention'
require_relative '../helm-plugins/be293-retention/post-render'

class ValidateRetentionTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  CHART = File.expand_path('../../handoff/BE-293-umbrella-3.17.0/chart/umbrella/charts/portal-2.6.0.tgz', HERE)
  SEED = {
    'addresses.json' => JSON.generate([{ 'id' => 'b4db3945-19a7-4a50-97d6-e66e8dfd04fb', 'city' => 'Munich' }]),
    'companies.json' => JSON.generate([{ 'id' => '2dc4249f-b5ca-4d42-bef1-7a7a950a4f87', 'name' => 'Catena-X' }])
  }.freeze

  # --- synthetic manifest helpers --------------------------------------------------------------
  def meta(name, annotations = nil)
    m = { 'name' => name, 'namespace' => 'be293' }
    m['annotations'] = annotations if annotations
    m
  end

  def cronjob(name, suspend: true, env: [])
    spec = { 'schedule' => '0 0 * * *', 'jobTemplate' => { 'spec' => { 'template' => { 'spec' => { 'containers' => [{ 'name' => 'c', 'env' => env }] } } } } }
    spec['suspend'] = suspend unless suspend.nil?
    { 'kind' => 'CronJob', 'metadata' => meta(name), 'spec' => spec }
  end

  def maintenance(suspend: true, days: '365000')
    cronjob('be293-portal-portal-maintenance', suspend: suspend, env: [
              { 'name' => 'BATCHPROCESSING_DELETEDOCUMENTSINTERVALINDAYS', 'value' => days },
              { 'name' => 'BATCHPROCESSING_RETRIGGERCLEARINGHOUSEINTERVALINDAYS', 'value' => '365000' }
            ])
  end

  def secret(name, keep: true)
    { 'kind' => 'Secret', 'metadata' => meta(name, keep ? { 'helm.sh/resource-policy' => 'keep' } : nil), 'stringData' => { 'k' => 'v' } }
  end

  def statefulset(policy: { 'whenDeleted' => 'Retain', 'whenScaled' => 'Retain' }, vct: true, volumes: [])
    spec = { 'template' => { 'spec' => { 'containers' => [{ 'name' => 'pg' }], 'volumes' => volumes } } }
    spec['persistentVolumeClaimRetentionPolicy'] = policy if policy
    spec['volumeClaimTemplates'] = [{ 'metadata' => { 'name' => 'data' } }] if vct
    { 'kind' => 'StatefulSet', 'metadata' => meta('be293-portal-postgresql'), 'spec' => spec }
  end

  def migration_job(env: nil, annotations: { 'helm.sh/hook' => 'post-install,post-upgrade' }, ttl: nil)
    env ||= [{ 'name' => 'SEEDING__DATAPATHS__0', 'value' => 'Seeder/Data/' }, { 'name' => 'SEEDING__DATAPATHS__1', 'value' => 'Seeder/Data/overwrite' }]
    spec = { 'template' => { 'spec' => { 'containers' => [{ 'name' => 'm', 'env' => env, 'volumeMounts' => [{ 'mountPath' => '/migrations/Seeder/Data/overwrite' }] }] } } }
    spec['ttlSecondsAfterFinished'] = ttl if ttl
    { 'kind' => 'Job', 'metadata' => meta('be293-portal-portal-migrations', annotations), 'spec' => spec }
  end

  def seed_configmap(data = SEED)
    { 'kind' => 'ConfigMap', 'metadata' => meta('be293-portal-initial-data'), 'data' => data }
  end

  ADMIN_PREFIX = { 'be293-portal-marketplace-app-service' => 'APPMARKETPLACE', 'be293-portal-services-service' => 'SERVICES' }.freeze

  def admin_env(prefix, kinds)
    kinds.flat_map do |k|
      [{ 'name' => "#{prefix}__#{k}ADMINROLES__0__CLIENTID", 'value' => 'Cl2-CX-Portal' },
       { 'name' => "#{prefix}__#{k}ADMINROLES__0__USERROLENAMES__0", 'value' => 'CX Admin' }]
    end
  end

  def deployment(name, kinds: %w[CATENA ARENA])
    env = [{ 'name' => 'A', 'value' => '1' }] + admin_env(ADMIN_PREFIX.fetch(name), kinds) + [{ 'name' => 'Z', 'value' => '2' }]
    { 'kind' => 'Deployment', 'metadata' => meta(name), 'spec' => { 'template' => { 'spec' => { 'containers' => [{ 'name' => 'c', 'env' => env }] } } } }
  end

IDP_PREFIX = 'be293-alpha-idp-'

# Post-rendered Provisioning env of the two IdP alias generators (D10); prefix: nil = plain chart render.
def prov_env(prefix: IDP_PREFIX)
  env = [{ 'name' => 'PROVISIONING__CENTRALREALM', 'value' => 'CX-Central' }]
  env << { 'name' => 'PROVISIONING__IDPPREFIX', 'value' => prefix } if prefix
  env + [{ 'name' => 'PROVISIONING__SERVICEACCOUNTCLIENTPREFIX', 'value' => 'sa' }]
end

def admin_service(prefix: IDP_PREFIX)
  { 'kind' => 'Deployment', 'metadata' => meta('be293-portal-administration-service'),
    'spec' => { 'template' => { 'spec' => { 'containers' => [{ 'name' => 'c', 'env' => prov_env(prefix: prefix) }] } } } }
end

  def safe_docs
    [maintenance, cronjob('be293-portal-processes-worker', suspend: nil, env: prov_env),
     secret('be293-portal-postgres'), secret('be293-portal-keycloak'), secret('be293-portal-interfaces'),
     statefulset, migration_job, seed_configmap, admin_service] + ADMIN_PREFIX.keys.map { |n| deployment(n) }
  end

  def failures_of(docs, baseline: nil)
    validator = RetentionGates::Validator.new
    # Pin the synthetic seed data instead of the real one for unit tests.
    canon = SEED.keys.sort.map { |k| [k, JSON.parse(SEED[k])] }
    stub_const_sha(Digest::SHA256.hexdigest(JSON.generate(canon))) { validator.check(docs, baseline: baseline) }
    validator.failures.join("\n")
  end

  def stub_const_sha(value)
    old = RetentionGates::SEED_OVERWRITE_SHA256
    RetentionGates.send(:remove_const, :SEED_OVERWRITE_SHA256)
    RetentionGates.const_set(:SEED_OVERWRITE_SHA256, value)
    yield
  ensure
    RetentionGates.send(:remove_const, :SEED_OVERWRITE_SHA256)
    RetentionGates.const_set(:SEED_OVERWRITE_SHA256, old)
  end

  def replace(docs, kind, name, with)
    docs.map { |d| d['kind'] == kind && d.dig('metadata', 'name') == name ? with : d }
  end

  # --- gates -------------------------------------------------------------------------------------
  def test_safe_release_passes
    assert_empty failures_of(safe_docs)
  end

  def test_d1_maintenance_must_be_suspended_and_inert
    msg = failures_of(replace(safe_docs, 'CronJob', 'be293-portal-portal-maintenance', maintenance(suspend: nil, days: '80')))
    assert_match(/portal-maintenance is not suspended/, msg)
    assert_match(/DELETEDOCUMENTSINTERVALINDAYS="80" outside/, msg)
    too_big = failures_of(replace(safe_docs, 'CronJob', 'be293-portal-portal-maintenance', maintenance(days: '800000')))
    assert_match(/"800000" outside/, too_big, 'values near DateTimeOffset.MinValue must be rejected')
    gone = failures_of(safe_docs.reject { |d| d['kind'] == 'CronJob' && d['metadata']['name'].end_with?('maintenance') })
    assert_match(/portal-maintenance not rendered/, gone)
  end

  def test_d2_new_active_cronjob_fails
    msg = failures_of(safe_docs + [cronjob('be293-portal-new-cleanup', suspend: false)])
    assert_match(%r{CronJob/be293-portal-new-cleanup is active and not allow-listed}, msg)
  end

  def test_d3_secrets_need_keep
    msg = failures_of(replace(safe_docs, 'Secret', 'be293-portal-interfaces', secret('be293-portal-interfaces', keep: false)))
    assert_match(/be293-portal-interfaces lacks helm.sh\/resource-policy: keep/, msg)
  end

  def test_d4_helm_managed_pvc_without_keep_fails
    pvc = { 'kind' => 'PersistentVolumeClaim', 'metadata' => meta('be293-portal-extra') }
    assert_match(/PersistentVolumeClaim\/be293-portal-extra is Helm-managed/, failures_of(safe_docs + [pvc]))
  end

  def test_d5_postgres_persistence_and_retention
    assert_match(/not Retain\/Retain/, failures_of(replace(safe_docs, 'StatefulSet', 'be293-portal-postgresql', statefulset(policy: { 'whenDeleted' => 'Delete', 'whenScaled' => 'Retain' }))))
    assert_match(/not Retain\/Retain/, failures_of(replace(safe_docs, 'StatefulSet', 'be293-portal-postgresql', statefulset(policy: nil))))
    msg = failures_of(replace(safe_docs, 'StatefulSet', 'be293-portal-postgresql', statefulset(vct: false, volumes: [{ 'name' => 'data', 'emptyDir' => {} }])))
    assert_match(/no volumeClaimTemplate 'data'/, msg)
    assert_match(/volume 'data' is emptyDir/, msg)
  end

  def test_d6_hook_deletion_and_ttl
    msg = failures_of(replace(safe_docs, 'Job', 'be293-portal-portal-migrations',
                              migration_job(annotations: { 'helm.sh/hook' => 'post-install', 'helm.sh/hook-delete-policy' => 'hook-succeeded' }, ttl: 60)))
    assert_match(/hook-delete-policy=hook-succeeded/, msg)
    assert_match(/ttlSecondsAfterFinished/, msg)
    pre_delete = migration_job(annotations: { 'helm.sh/hook' => 'pre-delete' })
    assert_match(/pre-delete hook/, failures_of(replace(safe_docs, 'Job', 'be293-portal-portal-migrations', pre_delete)))
  end

  def test_d7_seeding_paths_test_data_and_pinned_rows
    env = [{ 'name' => 'SEEDING__DATAPATHS__0', 'value' => 'Seeder/Data/' }, { 'name' => 'SEEDING__TESTDATAENVIRONMENTS__0', 'value' => 'test' }]
    msg = failures_of(replace(safe_docs, 'Job', 'be293-portal-portal-migrations', migration_job(env: env)))
    assert_match(/seeding data paths/, msg)
    assert_match(/test-data seeding enabled/, msg)
    changed = SEED.merge('companies.json' => JSON.generate([{ 'id' => '2dc4249f-b5ca-4d42-bef1-7a7a950a4f87', 'name' => 'Other' }]))
    assert_match(/seed overwrite data changed/, failures_of(replace(safe_docs, 'ConfigMap', 'be293-portal-initial-data', seed_configmap(changed))))
  end

  def test_d8_post_renderer_diff_is_limited
    base = plain_docs
    assert_empty failures_of(safe_docs, baseline: base)
    tampered = safe_docs.map { |d| Marshal.load(Marshal.dump(d)) }
    tampered.find { |d| d['kind'] == 'StatefulSet' }['spec']['replicas'] = 0
    assert_match(/StatefulSet\/be293-portal-postgresql changed by post-renderer at spec.replicas/, failures_of(tampered, baseline: base))
    assert_match(/post-renderer dropped ConfigMap/, failures_of(safe_docs.reject { |d| d['kind'] == 'ConfigMap' }, baseline: base))
  end

  def test_d9_arena_admin_roles_must_mirror_catena
    name = 'be293-portal-services-service'
    assert_match(/D9.*services-service SERVICES__ARENAADMINROLES__\* \[\] != CATENA/, failures_of(replace(safe_docs, 'Deployment', name, deployment(name, kinds: %w[CATENA]))))
    wrong = deployment(name)
    wrong['spec']['template']['spec']['containers'][0]['env'].find { |e| e['name'] == 'SERVICES__ARENAADMINROLES__0__USERROLENAMES__0' }['value'] = 'Company Admin'
    assert_match(/D9.*services-service/, failures_of(replace(safe_docs, 'Deployment', name, wrong)))
    assert_match(/D9.*renders no SERVICES__CATENAADMINROLES/, failures_of(replace(safe_docs, 'Deployment', name, deployment(name, kinds: []))))
  end

  def test_d8_allows_only_mirrored_arena_entries
    base = plain_docs
    assert_empty failures_of(safe_docs, baseline: base)
    extra = safe_docs.map { |d| Marshal.load(Marshal.dump(d)) }
    extra.find { |d| d['metadata']['name'] == 'be293-portal-services-service' }['spec']['template']['spec']['containers'][0]['env'] << { 'name' => 'X', 'value' => 'y' }
    assert_match(/Deployment\/be293-portal-services-service changed by post-renderer at spec.template.spec.containers/, failures_of(extra, baseline: base))
  end

  # --- post-renderer -----------------------------------------------------------------------------
  def stream(docs)
    docs.map { |d| "# Source: portal/templates/x.yaml\n" + YAML.dump(d).sub(/\A---\n/, '') }.map { |c| "---\n#{c}" }.join
  end

  def plain_docs
    docs = safe_docs.map { |d| Marshal.load(Marshal.dump(d)) }
    docs.each do |d|
      d['spec'].delete('suspend') if d['kind'] == 'CronJob'
      d['metadata'].delete('annotations') if d['kind'] == 'Secret'
      d['spec']['template']['spec']['containers'][0]['env'].reject! { |e| e['name'].include?('__ARENAADMINROLES__') } if d['kind'] == 'Deployment'
      pod = d.dig('spec', 'jobTemplate', 'spec', 'template', 'spec') || d.dig('spec', 'template', 'spec') || {}
      (pod['containers'] || []).each { |c| c['env']&.reject! { |e| e['name'] == 'PROVISIONING__IDPPREFIX' } }
    end
  end

  def test_post_renderer_changes_only_targets_and_keeps_other_bytes
    input = stream(plain_docs)
    out = Be293Retention.transform(input)
    in_chunks = input.split(/^---[ \t]*\n/)
    out_chunks = out.split(/^---[ \t]*\n/)
    assert_equal in_chunks.size, out_chunks.size
    changed = in_chunks.zip(out_chunks).reject { |a, b| a == b }.map { |a, _| a[/^  name: (.*)$/, 1] }
    assert_equal %w[be293-portal-portal-maintenance be293-portal-postgres be293-portal-keycloak be293-portal-interfaces
                    be293-portal-marketplace-app-service be293-portal-services-service
                    be293-portal-administration-service be293-portal-processes-worker].sort, changed.sort
    docs = YAML.load_stream(out).compact
    assert_equal true, docs.find { |d| d['metadata']['name'] == 'be293-portal-portal-maintenance' }['spec']['suspend']
    assert_nil docs.find { |d| d['metadata']['name'] == 'be293-portal-processes-worker' }['spec']['suspend']
    assert(out_chunks.all? { |c| c.strip.empty? || c.start_with?('# Source:') }, 'Source headers preserved')
    env = docs.find { |d| d['metadata']['name'] == 'be293-portal-marketplace-app-service' }['spec']['template']['spec']['containers'][0]['env'].map { |e| e['name'] }
    assert_equal %w[A APPMARKETPLACE__CATENAADMINROLES__0__CLIENTID APPMARKETPLACE__ARENAADMINROLES__0__CLIENTID
                    APPMARKETPLACE__CATENAADMINROLES__0__USERROLENAMES__0 APPMARKETPLACE__ARENAADMINROLES__0__USERROLENAMES__0 Z], env
  end

  def test_post_renderer_refuses_when_chart_already_renders_arena_or_lacks_catena
    has_arena = plain_docs.map { |d| d['metadata']['name'] == 'be293-portal-services-service' ? deployment(d['metadata']['name']) : d }
    assert_match(/already renders SERVICES__ARENAADMINROLES/, assert_raises(Be293Retention::Error) { Be293Retention.transform(stream(has_arena)) }.message)
    no_catena = plain_docs.map { |d| d['metadata']['name'] == 'be293-portal-services-service' ? deployment(d['metadata']['name'], kinds: []) : d }
    assert_match(/renders no SERVICES__CATENAADMINROLES/, assert_raises(Be293Retention::Error) { Be293Retention.transform(stream(no_catena)) }.message)
  end

  def test_post_renderer_fails_closed
    assert_raises(Be293Retention::Error) { Be293Retention.transform('') }
    missing = plain_docs.reject { |d| d['metadata']['name'] == 'be293-portal-keycloak' }
    e = assert_raises(Be293Retention::Error) { Be293Retention.transform(stream(missing)) }
    assert_match(/Secret\/be293-portal-keycloak=0/, e.message)
    dup = plain_docs + [plain_docs.find { |d| d['kind'] == 'CronJob' && d['metadata']['name'].end_with?('maintenance') }]
    assert_match(/=2/, assert_raises(Be293Retention::Error) { Be293Retention.transform(stream(dup)) }.message)
    foreign = plain_docs.map { |d| d['metadata']['name'] == 'be293-portal-postgres' ? d.merge('metadata' => d['metadata'].merge('namespace' => 'release26-09')) : d }
    assert_match(/namespace "release26-09"/, assert_raises(Be293Retention::Error) { Be293Retention.transform(stream(foreign)) }.message)
  end

  def test_post_renderer_cli_writes_nothing_on_failure_and_never_echoes_secret_data
    script = File.join(HERE, 'helm-plugins/be293-retention/post-render.rb')
    docs = plain_docs.reject { |d| d['metadata']['name'] == 'be293-portal-keycloak' }
    docs.find { |d| d['metadata']['name'] == 'be293-portal-postgres' }['stringData'] = { 'k' => 'canary-must-not-leak' }
    out, err, st = Open3.capture3('ruby', script, stdin_data: stream(docs))
    assert_equal 1, st.exitstatus
    assert_empty out
    refute_includes err, 'canary-must-not-leak'
  end

def test_d10_idp_prefix_on_both_alias_generators
  worker = 'be293-portal-processes-worker'
  msg = failures_of(replace(safe_docs, 'CronJob', worker, cronjob(worker, suspend: nil, env: prov_env(prefix: nil))))
  assert_match(/\[D10\] CronJob\/be293-portal-processes-worker PROVISIONING__IDPPREFIX \[\] != \["be293-alpha-idp-"\]/, msg)
  msg = failures_of(replace(safe_docs, 'Deployment', 'be293-portal-administration-service', admin_service(prefix: 'idp')))
  assert_match(/\[D10\] Deployment\/be293-portal-administration-service PROVISIONING__IDPPREFIX \["idp"\]/, msg, 'release26-09 default must be rejected')
  assert_match(/\[D10\] Deployment\/be293-portal-administration-service not rendered/,
               failures_of(safe_docs.reject { |d| d['metadata']['name'] == 'be293-portal-administration-service' }))
  twice = safe_docs.map { |d| Marshal.load(Marshal.dump(d)) }
  twice.find { |d| d['kind'] == 'CronJob' && d['metadata']['name'] == worker }['spec']['jobTemplate']['spec']['template']['spec']['containers'][0]['env'] <<
    { 'name' => 'Provisioning__IdpPrefix', 'value' => 'idp' }
  assert_match(/\[D10\] CronJob\/be293-portal-processes-worker/, failures_of(twice), 'case-insensitive duplicate key must be caught')
  other = deployment('be293-portal-services-service')
  other['spec']['template']['spec']['containers'][0]['env'] << { 'name' => 'PROVISIONING__IDPPREFIX', 'value' => 'idp' }
  assert_match(/\[D10\] Deployment\/be293-portal-services-service renders a different IdpPrefix \["idp"\]/,
               failures_of(replace(safe_docs, 'Deployment', 'be293-portal-services-service', other)))
end

def test_d8_allows_only_the_reviewed_idp_prefix_entry
  base = plain_docs
  changed = safe_docs.map { |d| Marshal.load(Marshal.dump(d)) }
  changed.find { |d| d['metadata']['name'] == 'be293-portal-administration-service' }['spec']['template']['spec']['containers'][0]['env']
         .find { |e| e['name'] == 'PROVISIONING__CENTRALREALM' }['value'] = 'release26-09-realm'
  assert_match(/Deployment\/be293-portal-administration-service changed by post-renderer/, failures_of(changed, baseline: base))
end

def test_post_renderer_inserts_idp_prefix_after_central_realm_and_refuses_existing
  docs = YAML.load_stream(Be293Retention.transform(stream(plain_docs))).compact
  [%w[CronJob be293-portal-processes-worker], %w[Deployment be293-portal-administration-service]].each do |kind, name|
    d = docs.find { |x| x['kind'] == kind && x['metadata']['name'] == name }
    env = (d.dig('spec', 'jobTemplate', 'spec', 'template', 'spec') || d.dig('spec', 'template', 'spec'))['containers'][0]['env']
    assert_equal [%w[PROVISIONING__CENTRALREALM CX-Central], ['PROVISIONING__IDPPREFIX', IDP_PREFIX], %w[PROVISIONING__SERVICEACCOUNTCLIENTPREFIX sa]],
                 env.map { |e| [e['name'], e['value']] }, "#{kind}/#{name}"
  end
  assert_equal IDP_PREFIX, Be293Retention::IDP_PREFIX, 'post-renderer and gate must agree'
  assert_equal IDP_PREFIX, RetentionGates::IDP_PREFIX

  preset = plain_docs.map { |d| d['metadata']['name'] == 'be293-portal-administration-service' ? admin_service(prefix: 'idp') : d }
  assert_match(/administration-service already renders PROVISIONING__IDPPREFIX/,
               assert_raises(Be293Retention::Error) { Be293Retention.transform(stream(preset)) }.message)
  no_anchor = plain_docs.map { |d| d['metadata']['name'] == 'be293-portal-processes-worker' ? cronjob('be293-portal-processes-worker', suspend: nil) : d }
  assert_match(/processes-worker: PROVISIONING__CENTRALREALM rendered in 0 containers/,
               assert_raises(Be293Retention::Error) { Be293Retention.transform(stream(no_anchor)) }.message)
end

def test_real_post_rendered_chart_sets_idp_prefix
  skip 'helm not installed' unless system('command -v helm >/dev/null 2>&1')
  Dir.mktmpdir do |dir|
    values = %w[values-be293-portal.yaml values-be293-portal.alpha-release.yaml values-be293-portal.alpha-retention.yaml]
    plain = render(dir, values, post_render: false)
    msg = RetentionGates::Validator.new.check(plain).failures.join("\n")
    assert_match(/\[D10\] CronJob\/be293-portal-processes-worker PROVISIONING__IDPPREFIX \[\]/, msg, 'chart alone must not satisfy D10')
    docs = render(dir, values)
    assert_empty RetentionGates::Validator.new.check(docs).failures.grep(/D10/)
    prefixed = docs.select { |d| (d.dig('spec', 'jobTemplate', 'spec', 'template', 'spec') || d.dig('spec', 'template', 'spec') || {}).fetch('containers', [])
                                   .flat_map { |c| c['env'] || [] }.any? { |e| e['name'] == 'PROVISIONING__IDPPREFIX' } }
    assert_equal %w[CronJob/be293-portal-processes-worker Deployment/be293-portal-administration-service],
                 prefixed.map { |d| "#{d['kind']}/#{d['metadata']['name']}" }.sort
  end
end

  # --- integration: real chart, offline ---------------------------------------------------------
  def helm_env(dir)
    { 'KUBECONFIG' => '/dev/null', 'HELM_KUBECONTEXT' => '', 'HELM_PLUGINS' => File.join(HERE, 'helm-plugins'),
      'HELM_CACHE_HOME' => "#{dir}/c", 'HELM_CONFIG_HOME' => "#{dir}/cfg", 'HELM_DATA_HOME' => "#{dir}/d" }
  end

  def render(dir, values, post_render: true)
    args = ['helm', 'template', 'be293-portal', CHART, '--namespace', 'be293']
    values.each { |v| args += ['-f', File.join(HERE, v)] }
    args += ['--post-renderer', 'be293-retention'] if post_render
    out, err, st = Open3.capture3(helm_env(dir), *args)
    assert st.success?, err
    RetentionGates.load_docs(out)
  end

  def test_real_render_without_retention_controls_fails_the_gate
    skip 'helm not installed' unless system('command -v helm >/dev/null 2>&1')
    Dir.mktmpdir do |dir|
      unprotected = render(dir, %w[values-be293-portal.yaml values-be293-portal.alpha-release.yaml], post_render: false)
      msg = RetentionGates::Validator.new.check(unprotected).failures.join("\n")
      assert_match(/portal-maintenance is not suspended/, msg)
      assert_match(/DELETEDOCUMENTSINTERVALINDAYS="80"/, msg)
      assert_match(/be293-portal-postgres lacks helm.sh\/resource-policy: keep/, msg)
      assert_match(/persistentVolumeClaimRetentionPolicy \{\} is not Retain\/Retain/, msg)
      assert_match(/D9.*marketplace-app-service APPMARKETPLACE__ARENAADMINROLES__\* \[\] != CATENA/, msg)
    end
  end

  def test_real_post_rendered_chart_mirrors_admin_roles
    skip 'helm not installed' unless system('command -v helm >/dev/null 2>&1')
    Dir.mktmpdir do |dir|
      docs = render(dir, %w[values-be293-portal.yaml values-be293-portal.alpha-release.yaml values-be293-portal.alpha-retention.yaml])
      { 'be293-portal-marketplace-app-service' => 'APPMARKETPLACE', 'be293-portal-services-service' => 'SERVICES' }.each do |name, p|
        env = docs.find { |d| d['kind'] == 'Deployment' && d['metadata']['name'] == name }['spec']['template']['spec']['containers'].flat_map { |c| c['env'] }
        get = ->(n) { env.find { |e| e['name'] == n }&.fetch('value') }
        assert_equal 'Cl2-CX-Portal', get.call("#{p}__ARENAADMINROLES__0__CLIENTID")
        assert_equal 'CX Admin', get.call("#{p}__ARENAADMINROLES__0__USERROLENAMES__0")
        assert_equal 'CX Admin', get.call("#{p}__CATENAADMINROLES__0__USERROLENAMES__0"), 'Catena entry preserved'
      end
    end
  end

  def test_release_render_passes_all_gates
    skip 'helm not installed' unless system('command -v helm >/dev/null 2>&1')
    out, status = Dir.mktmpdir do |dir|
      Open3.capture2e({ 'KUBECONFIG' => '/dev/null', 'SMTP4DEV_MANIFEST' => PinnedSmtp4dev.manifest(dir), 'DID_RESOLVER_MANIFEST' => PinnedDidResolver.manifest(dir) }, 'bash', File.join(HERE, 'tools/render-release.sh'))
    end
    assert status.success?, "render-release.sh failed:\n#{out.lines.last(15).join}"
    assert_match(/^RETENTION RESULT PASS/, out)
    assert_match(/^RETENTION D8 RESULT PASS/, out)
    assert_match(/objects=31 mode=release/, out)
  end
end
