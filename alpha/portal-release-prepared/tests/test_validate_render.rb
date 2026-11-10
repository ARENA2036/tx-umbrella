# frozen_string_literal: true

# Unit tests for alpha/portal/tools/validate_render.rb using synthetic manifests, plus one offline
# integration test that renders the real chart with the Alpha overlay (no cluster access).
#
# Run: ruby alpha/portal/tests/test_validate_render.rb

require 'minitest/autorun'
require 'open3'
require 'yaml'
require_relative '../tools/validate_render'

class ValidateRenderTest < Minitest::Test
  DIGEST = 'a' * 64
  LOCK = {
    'registry' => 'registry.approved.example',
    'rebuilt' => [{ 'image' => 'portal-administration-service', 'tag' => 'be293-f5badda90', 'digest' => DIGEST }],
    'upstream' => [{ 'image' => 'docker.io/bitnamilegacy/postgresql', 'tag' => '15-debian-11', 'digest' => "sha256:#{DIGEST}" }],
    'forbidden' => %w[be293-images claimfix]
  }.freeze
  SECURE = { 'runAsNonRoot' => true, 'allowPrivilegeEscalation' => false }.freeze

  def validator(mode = 'offline')
    PortalRenderGates::Validator.new(mode: mode)
  end

  def deployment(name: 'be293-portal-administration-service', image: "registry.approved.example/portal-administration-service:be293-f5badda90@sha256:#{DIGEST}", env: [], ns: 'be293', ctx: SECURE)
    { 'kind' => 'Deployment', 'metadata' => { 'name' => name, 'namespace' => ns },
      'spec' => { 'template' => { 'spec' => { 'containers' => [{ 'name' => 'app', 'image' => image, 'env' => env, 'securityContext' => ctx }] } } } }
  end

  def migration_job(server: 'be293-portal-postgresql', hook: 'post-install,post-upgrade', name: 'be293-portal-portal-migrations')
    { 'kind' => 'Job', 'metadata' => { 'name' => name, 'namespace' => 'be293', 'annotations' => { 'helm.sh/hook' => hook } },
      'spec' => { 'template' => { 'spec' => { 'containers' => [{
        'name' => 'migrations', 'image' => "registry.approved.example/portal-administration-service:be293-f5badda90@sha256:#{DIGEST}",
        'securityContext' => SECURE,
        'env' => [{ 'name' => 'CONNECTIONSTRINGS__PORTALDB', 'value' => "Server=#{server};Database=postgres;Port=5432;User Id=portal;Password=$(PORTAL_PASSWORD);" }]
      }] } } } }
  end

  def db_service
    { 'kind' => 'Service', 'metadata' => { 'name' => 'be293-portal-postgresql', 'namespace' => 'be293' } }
  end

  def failures_of(v)
    v.result.failures.join("\n")
  end

  # --- G1 scope -------------------------------------------------------------------------------
  def test_scope_accepts_namespaced_objects_in_be293
    v = validator
    v.check_scope([deployment, db_service])
    assert_empty v.result.failures
  end

  def test_scope_rejects_cluster_scoped_and_foreign_namespace
    v = validator
    v.check_scope([{ 'kind' => 'ClusterRole', 'metadata' => { 'name' => 'x' } }, deployment(ns: 'release26-09')])
    assert_match(/ClusterRole\/x is cluster-scoped/, failures_of(v))
    assert_match(/namespace "release26-09" != be293/, failures_of(v))
  end

  def test_scope_rejects_ingress_unless_allowed
    v = validator
    v.check_scope([{ 'kind' => 'Ingress', 'metadata' => { 'name' => 'i', 'namespace' => 'be293' } }])
    assert_match(/kind not allowed/, failures_of(v))
  end

  # --- G2 hooks -------------------------------------------------------------------------------
  def test_hooks_allow_only_migration_jobs
    v = validator
    v.check_hooks([migration_job])
    assert_empty v.result.failures
  end

  def test_hooks_reject_other_hook_objects_and_phases
    v = validator
    v.check_hooks([migration_job(name: 'be293-portal-coredns-patch'), migration_job(hook: 'pre-install')])
    assert_match(/not an approved migration Job/, failures_of(v))
    assert_match(/hook phase\(s\) pre-install/, failures_of(v))
  end

  # --- G3 database targets --------------------------------------------------------------------
  def test_database_targets_release_local_postgresql
    v = validator
    v.check_database_targets([migration_job, db_service])
    assert_empty v.result.failures
  end

  def test_database_rejects_old_portal_database
    v = validator
    v.check_database_targets([migration_job(server: 'portal-backend-postgresql.release26-09.svc.cluster.local'), db_service])
    assert_match(/targets "portal-backend-postgresql.release26-09.svc.cluster.local"/, failures_of(v))
  end

  def test_database_rejects_literal_password_and_foreign_5432
    job = migration_job
    job['spec']['template']['spec']['containers'][0]['env'] = [
      { 'name' => 'CONNECTIONSTRINGS__PORTALDB', 'value' => 'Server=be293-portal-postgresql;Password=hunter2;' },
      { 'name' => 'OTHER_DB', 'value' => 'old-db.release26-09.svc.cluster.local:5432' }
    ]
    v = validator
    v.check_database_targets([job, db_service])
    assert_match(/embeds a literal password/, failures_of(v))
    assert_match(/OTHER_DB references port 5432/, failures_of(v))
  end

  # --- G4 images ------------------------------------------------------------------------------
  def test_images_accept_locked_digest_pinned_image
    v = validator
    v.check_images([deployment], LOCK)
    assert_empty v.result.failures
  end

  def test_images_reject_unpinned_forbidden_and_unlocked
    v = validator
    v.check_images([deployment(image: 'docker.io/x/portal:latest'),
                    deployment(image: "docker.io/someone/be293-images:portal-registration-claimfix-r1@sha256:#{DIGEST}")], LOCK)
    msg = failures_of(v)
    assert_match(/not digest-pinned/, msg)
    assert_match(/floating tag/, msg)
    assert_match(/forbidden source "be293-images"/, msg)
    assert_match(/not in images.lock/, msg)
  end

  def test_images_placeholder_allowed_offline_but_fails_release
    image = 'registry.approved.example/portal-administration-service:be293-f5badda90@sha256:<<IMAGE:DIGEST_ADMINISTRATION>>'
    offline = validator('offline')
    offline.check_images([deployment(image: image)], nil)
    assert_empty offline.result.failures
    assert_equal 1, offline.result.pending.size
    release = validator('release')
    release.check_images([deployment(image: image)], nil)
    assert_match(/placeholder/, failures_of(release))
  end

  # --- G5 shared-service configuration --------------------------------------------------------
  def test_shared_service_allowlisted_env_passes
    env = [{ 'name' => 'APPLICATIONCHECKLIST__IDENTITYHUB__BASEADDRESS', 'value' => 'http://identity-hub-01.release26-09.svc.cluster.local:8082/api/identity' }]
    v = validator
    v.check_shared_service_config([deployment(env: env)])
    assert_empty v.result.failures
  end

  def test_shared_service_rejects_unlisted_env_old_portal_and_local_hosts
    env = [
      { 'name' => 'SOMETHING__ADDRESS', 'value' => 'http://portal-backend.release26-09.svc.cluster.local' },
      { 'name' => 'PORTAL__ADDRESS', 'value' => 'https://portal.test.tractus-x.com/home' },
      { 'name' => 'IH', 'value' => 'http://identity-hub.tx.test' },
      { 'name' => 'EDC', 'value' => 'http://edc.connector.svc.cluster.local' }
    ]
    v = validator
    v.check_shared_service_config([deployment(env: env)])
    msg = failures_of(v)
    assert_match(/SOMETHING__ADDRESS points at release26-09 but is not in the approved integration allowlist/, msg)
    assert_match(/references portal.test.tractus-x.com \(old Portal\)/, msg)
    assert_match(/tx\\.test/, msg)
    assert_match(/connector/, msg)
  end

  def test_secret_env_must_use_value_from_except_chart_filler
    env = [
      { 'name' => 'APPLICATIONCHECKLIST__BPDM__PASSWORD', 'value' => 'empty' },
      { 'name' => 'KEYCLOAK__CENTRAL__CLIENTSECRET', 'value' => 'real-looking-secret' },
      { 'name' => 'IDENTITYHUB__APIKEY', 'valueFrom' => { 'secretKeyRef' => { 'name' => 'x', 'key' => 'y' } } }
    ]
    v = validator
    v.check_shared_service_config([deployment(env: env)])
    msg = failures_of(v)
    refute_match(/BPDM__PASSWORD/, msg)
    refute_match(/APIKEY/, msg)
    assert_match(/CLIENTSECRET is set inline/, msg)
  end

  def test_ingress_rejected_when_not_approved_and_foreign_host_always
    ing = { 'kind' => 'Ingress', 'metadata' => { 'name' => 'i', 'namespace' => 'be293' },
            'spec' => { 'rules' => [{ 'host' => 'portal.test.tractus-x.com' }] } }
    v = validator
    v.check_shared_service_config([ing], allow_ingress: true)
    assert_match(/belongs to another owner/, failures_of(v))
    v2 = validator
    v2.check_shared_service_config([ing], allow_ingress: false)
    assert_match(/Ingress is not approved/, failures_of(v2))
  end

  # --- G6 security context --------------------------------------------------------------------
  def test_security_context_required
    v = validator
    v.check_security_context([deployment(ctx: { 'runAsNonRoot' => false })])
    assert_match(/runAsNonRoot/, failures_of(v))
    assert_match(/privilege escalation/, failures_of(v))
  end

  # --- G7 values ------------------------------------------------------------------------------
  def test_values_reject_inline_credentials_but_allow_secret_names
    values = { 'backend' => { 'keycloak' => { 'secret' => 'be293-portal-keycloak', 'central' => { 'clientSecret' => 'abc' } },
                              'processesworker' => { 'identityHub' => { 'existingSecret' => 'x', 'apiKey' => '', 'issuerAdminApiKeySecretKey' => 'k' } } } }
    v = validator
    v.check_values(values)
    msg = failures_of(v)
    assert_match(/backend.keycloak.central.clientSecret carries an inline credential/, msg)
    refute_match(/existingSecret|issuerAdminApiKeySecretKey|keycloak.secret /, msg)
  end

  # --- G8 network policies --------------------------------------------------------------------
  def np(name, spec)
    { 'kind' => 'NetworkPolicy', 'metadata' => { 'name' => name, 'namespace' => 'be293' }, 'spec' => spec }
  end

  def default_deny
    np('deny', 'podSelector' => {}, 'policyTypes' => %w[Ingress Egress])
  end

  def test_network_policies_accept_default_deny
    v = validator
    v.check_network_policies([default_deny])
    assert_empty v.result.failures
  end

  def test_network_policies_reject_db_port_to_other_namespace_and_any_cidr
    bad = np('bad', 'podSelector' => {}, 'policyTypes' => ['Egress'], 'egress' => [
      { 'to' => [{ 'namespaceSelector' => { 'matchLabels' => { 'kubernetes.io/metadata.name' => 'release26-09' } } }],
        'ports' => [{ 'protocol' => 'TCP', 'port' => 5432 }] },
      { 'to' => [{ 'ipBlock' => { 'cidr' => '0.0.0.0/0' } }] }
    ])
    v = validator
    v.check_network_policies([default_deny, bad])
    assert_match(/opens TCP 5432 towards namespace release26-09/, failures_of(v))
    assert_match(%r{egress to 0.0.0.0/0}, failures_of(v))
  end

  def test_network_policies_require_default_deny
    v = validator
    v.check_network_policies([np('allow', 'podSelector' => {}, 'policyTypes' => ['Egress'], 'egress' => [{ 'to' => [{ 'podSelector' => {} }] }])])
    assert_match(/default-deny policy missing/, failures_of(v))
  end

  # --- G9 service map (Service port vs container port) ----------------------------------------
# --- R-BPDM ------------------------------------------------------------------------------------
def bpdm_docs(gate: '/gate/v6', pool: '/pool/v6', extra: [])
  h = 'https://business-partners.test.tractus-x.com'
  [deployment(env: [{ 'name' => 'APPLICATIONCHECKLIST__BPDM__BASEADDRESS', 'value' => "#{h}#{gate}" },
                    { 'name' => 'APPLICATIONCHECKLIST__BPDM__BUSINESSPARTNERPOOLBASEADDRESS', 'value' => "#{h}#{pool}" },
                    { 'name' => 'BPNACCESS__BASEADDRESS', 'value' => "#{h}#{pool}" }] + extra)]
end

def test_bpdm_addresses_with_one_api_version_pass
  v = validator
  v.check_bpdm(bpdm_docs)
  assert_empty v.result.failures
  assert_includes v.result.info, 'bpdm: api v6 (3 addresses)'
end

def test_bpdm_rejects_missing_version_wrong_prefix_mixed_versions_and_unreviewed_env
  v = validator
  v.check_bpdm(bpdm_docs(gate: '/gate'))
  assert_match(%r{APPLICATIONCHECKLIST__BPDM__BASEADDRESS="https://business-partners.test.tractus-x.com/gate" is not .*/gate/v<N>}, failures_of(v))
  v = validator
  v.check_bpdm(bpdm_docs(gate: '/pool/v6'))
  assert_match(/BASEADDRESS=.*\/pool\/v6" is not .*\/gate\/v<N>/, failures_of(v), 'Gate address must not point at the Pool')
  v = validator
  v.check_bpdm(bpdm_docs(pool: '/pool/v7'))
  assert_match(/BPDM API versions differ: \["v6", "v7"\]/, failures_of(v))
  v = validator
  v.check_bpdm(bpdm_docs(extra: [{ 'name' => 'X__URL', 'value' => 'https://business-partners.test.tractus-x.com/orchestrator' }]))
  assert_match(/X__URL points at BPDM but is not a reviewed BPDM address/, failures_of(v))
  v = validator
  v.check_bpdm([deployment(env: [])])
  assert_match(/no BPDM address rendered/, failures_of(v))
end

  SERVICE_MAP = YAML.safe_load(File.read(File.expand_path('../alpha-service-map.yaml', __dir__)))

  def egress_to(instance, *ports)
    np('egress', 'podSelector' => {}, 'policyTypes' => ['Egress'], 'egress' => [
      { 'to' => [{ 'namespaceSelector' => { 'matchLabels' => { 'kubernetes.io/metadata.name' => 'release26-09' } },
                   'podSelector' => { 'matchLabels' => { 'app.kubernetes.io/instance' => instance } } }],
        'ports' => ports.map { |p| { 'protocol' => 'TCP', 'port' => p } } }
    ])
  end

  def env_url(url)
    [deployment(env: [{ 'name' => 'X__BASEADDRESS', 'value' => url }])]
  end

  def test_service_map_accepts_confirmed_services_and_container_ports
    v = validator
    docs = env_url('http://issuer-service.release26-09.svc.cluster.local:8086/api/admin') +
           env_url('http://sdfactory.release26-09.svc.cluster.local/api/tagus/selfdescription')
    v.check_service_map(docs, [egress_to('issuer-service', 8086), egress_to('sdfactory', 8080), egress_to('bdrs-server', 8081)], SERVICE_MAP)
    assert_empty v.result.failures
  end

  def test_service_map_rejects_service_port_in_network_policy
    v = validator
    v.check_service_map([], [egress_to('sdfactory', 80)], SERVICE_MAP)
    assert_match(/port 80 is not a resolved container port \(Service port; NetworkPolicy needs the container port\)/, failures_of(v))
  end

  def test_service_map_rejects_container_port_in_service_url
    v = validator
    v.check_service_map(env_url('http://sdfactory.release26-09.svc.cluster.local:8080/x'), [], SERVICE_MAP)
    assert_match(/sdfactory:8080, not a Service port of sdfactory \(that is a container port/, failures_of(v))
  end

  def test_service_map_rejects_unknown_service_and_public_only_service_in_cluster
    v = validator
    v.check_service_map(env_url('http://portal-backend.release26-09.svc.cluster.local') +
                        env_url('http://centralidp-keycloak.release26-09.svc.cluster.local/auth') +
                        env_url('http://bpdm-bpdm-pool.release26-09.svc.cluster.local'), [], SERVICE_MAP)
    msg = failures_of(v)
    assert_match(/portal-backend, which is not in the confirmed release26-09 inventory/, msg)
    assert_match(/centralidp-keycloak in-cluster, but it is public issuer URL only/, msg)
    assert_match(/bpdm-bpdm-pool in-cluster, but it is public host only/, msg)
  end

  def test_service_map_rejects_unselected_or_unknown_pod_targets
    v = validator
    unselected = np('any', 'podSelector' => {}, 'policyTypes' => ['Egress'], 'egress' => [
      { 'to' => [{ 'namespaceSelector' => { 'matchLabels' => { 'kubernetes.io/metadata.name' => 'release26-09' } } }],
        'ports' => [{ 'protocol' => 'TCP', 'port' => 8080 }] }
    ])
    v.check_service_map([], [unselected, egress_to('portal', 8080)], SERVICE_MAP)
    assert_match(/allows egress to all pods of release26-09/, failures_of(v))
    assert_match(/"portal" does not match a confirmed pod selector/, failures_of(v))
  end

  def test_service_map_placeholder_instance_limited_to_confirmed_container_ports
    v = validator
    v.check_service_map([], [egress_to('<<ALPHA:IDENTITYHUB_INSTANCE>>', 8082), egress_to('<<ALPHA:IDENTITYHUB_INSTANCE>>', 9999)], SERVICE_MAP)
    msg = failures_of(v)
    refute_match(/port 8082/, msg)
    assert_match(/port 9999 is not a resolved container port/, msg)
  end

  # --- inventory ------------------------------------------------------------------------------
  def test_inventory_detects_missing_and_extra
    v = validator
    v.check_inventory([deployment], ['Deployment/other'])
    assert_match(/missing objects: Deployment\/other/, failures_of(v))
    assert_match(/unexpected objects: Deployment\/be293-portal-administration-service/, failures_of(v))
  end

  def test_unknown_mode_rejected
    assert_raises(ArgumentError) { PortalRenderGates::Validator.new(mode: 'yolo') }
  end

  # --- integration: real chart, real overlay, offline -----------------------------------------
  def test_offline_render_of_alpha_overlay_passes_all_gates
    skip 'helm not installed' unless system('command -v helm >/dev/null 2>&1')
    script = File.expand_path('../tools/render.sh', __dir__)
    out, status = Open3.capture2e('bash', script, 'offline')
    assert status.success?, "render.sh offline failed:\n#{out.lines.last(15).join}"
    assert_match(/objects=29 mode=offline/, out)
    assert_match(/RESULT PASS/, out)
  end

  def test_release_mode_blocks_while_placeholders_remain
    skip 'helm not installed' unless system('command -v helm >/dev/null 2>&1')
    script = File.expand_path('../tools/render.sh', __dir__)
    out, status = Open3.capture2e('bash', script, 'release')
    refute status.success?, 'release mode must fail while placeholders remain'
    assert_match(/FAIL \[placeholder\]/, out)
  end
end
