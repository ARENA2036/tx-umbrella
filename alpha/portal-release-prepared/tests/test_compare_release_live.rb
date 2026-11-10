# frozen_string_literal: true

# Unit tests for tools/compare_release_live.rb (no cluster): API-server defaults must not show as drift, real
# differences must, values are printed only when plainly non-secret, and field ownership turns a change of a
# kubectl-owned field into an SSA CONFLICT (FAIL).
#
# Run: ruby tests/test_compare_release_live.rb

require 'minitest/autorun'
require 'json'
require_relative '../tools/compare_release_live'

class CompareReleaseLiveTest < Minitest::Test
  def deep(obj)
    JSON.parse(JSON.generate(obj))
  end

  def compare(rendered, live)
    CompareReleaseLive.compare([rendered], ->(_k, _n) { live })
  end

  def service(ports, type: nil)
    { 'kind' => 'Service', 'metadata' => { 'name' => 'svc' },
      'spec' => { 'type' => type, 'selector' => { 'app' => 'x' }, 'ports' => ports }.compact }
  end

  def container(env: [], **extra)
    { 'name' => 'app', 'image' => 'reg/app:be293-1@sha256:aa', 'env' => env }.merge(extra.transform_keys(&:to_s))
  end

  def deployment(c = container, pod = {})
    { 'kind' => 'Deployment', 'metadata' => { 'name' => 'dep' },
      'spec' => { 'replicas' => 1, 'selector' => { 'matchLabels' => { 'app' => 'x' } },
                  'template' => { 'spec' => { 'containers' => [c] }.merge(pod) } } }
  end

  def managed(manager, env_name: nil, image: false, cronjob: false)
    leaf = {}
    leaf['f:env'] = { "k:{\"name\":\"#{env_name}\"}" => { '.' => {}, 'f:value' => {} } } if env_name
    leaf['f:image'] = {} if image
    containers = { 'f:containers' => { 'k:{"name":"app"}' => leaf } }
    spec = cronjob ? { 'f:spec' => { 'f:jobTemplate' => { 'f:spec' => { 'f:template' => { 'f:spec' => containers } } } } } : { 'f:spec' => { 'f:template' => { 'f:spec' => containers } } }
    { 'manager' => manager, 'operation' => manager == 'helm' ? 'Apply' : 'Update', 'fieldsV1' => spec }
  end

  # --- Services --------------------------------------------------------------------------------------------
  def test_service_defaults_are_not_drift
    rendered = service([{ 'port' => 8080, 'targetPort' => 8080 }])
    live = service([{ 'port' => 8080, 'targetPort' => 8080, 'protocol' => 'TCP' }], type: 'ClusterIP')
    assert_equal [['SAME', 'Service/svc']], compare(rendered, live)
    pg = service([{ 'name' => 'tcp-postgresql', 'port' => 5432, 'targetPort' => 'tcp-postgresql', 'nodePort' => nil }])
    pg_live = service([{ 'name' => 'tcp-postgresql', 'port' => 5432, 'targetPort' => 'tcp-postgresql', 'protocol' => 'TCP' }], type: 'ClusterIP')
    assert_equal 'SAME', compare(pg, pg_live)[0][0]
    no_target = service([{ 'port' => 80 }])
    assert_equal 'SAME', compare(no_target, service([{ 'port' => 80, 'targetPort' => 80, 'protocol' => 'TCP' }]))[0][0]
  end

  def test_real_service_changes_are_drift
    live = service([{ 'port' => 8080, 'targetPort' => 8080, 'protocol' => 'TCP' }], type: 'ClusterIP')
    assert_match(/spec\.ports/, compare(service([{ 'port' => 8080, 'targetPort' => 8081 }]), live)[0][1])
    assert_match(/spec\.ports/, compare(service([{ 'port' => 8080, 'targetPort' => 8080, 'protocol' => 'UDP' }]), live)[0][1])
    assert_match(/spec\.type \(live=ClusterIP rendered=NodePort\)/, compare(service([{ 'port' => 8080 }], type: 'NodePort'), live)[0][1])
    np = service([{ 'port' => 80, 'nodePort' => 30080 }], type: 'NodePort')
    assert_match(/spec\.ports/, compare(np, service([{ 'port' => 80, 'nodePort' => 30081, 'protocol' => 'TCP' }], type: 'NodePort'))[0][1])
  end

  # --- Ingress ---------------------------------------------------------------------------------------------
  def ingress(annotations)
    { 'kind' => 'Ingress', 'metadata' => { 'name' => 'ing', 'annotations' => annotations },
      'spec' => { 'ingressClassName' => 'nginx', 'rules' => [{ 'host' => 'portal-be293.test.tractus-x.com' }] } }
  end

  def test_ingress_bookkeeping_annotations_are_ignored_but_real_ones_reported
    user = { 'cert-manager.io/cluster-issuer' => 'letsencrypt-prod', 'external-dns.alpha.kubernetes.io/hostname' => 'portal-be293.test.tractus-x.com' }
    live = ingress(user.merge('meta.helm.sh/release-name' => 'be293-portal', 'meta.helm.sh/release-namespace' => 'be293'))
    assert_equal 'SAME', compare(ingress(user), live)[0][0]
    changed = ingress(user.merge('cert-manager.io/cluster-issuer' => 'letsencrypt-staging'))
    assert_match(%r{annotation cert-manager\.io/cluster-issuer: differs}, compare(changed, live)[0][1])
    extra = ingress(user.merge('nginx.ingress.kubernetes.io/proxy-body-size' => '8m'))
    assert_match(%r{annotation nginx\.ingress\.kubernetes\.io/proxy-body-size: only rendered}, compare(extra, live)[0][1])
    manual = ingress(user).tap { |i| i['metadata']['annotations'] = user.merge('nginx.ingress.kubernetes.io/whitelist-source-range' => '10.0.0.0/8') }
    assert_match(/whitelist-source-range: only live/, compare(ingress(user), manual)[0][1])
  end

  # --- workloads: defaults vs real changes ------------------------------------------------------------------
  def test_workload_api_defaults_are_not_drift
    rendered = deployment(container(ports: [{ 'containerPort' => 8080 }],
                                    readinessProbe: { 'httpGet' => { 'path' => '/health', 'port' => 8080 } },
                                    resources: { 'requests' => { 'cpu' => '0.5', 'memory' => '128Mi' } },
                                    volumeMounts: [{ 'name' => 'cfg', 'mountPath' => '/cfg' }]),
                          'volumes' => [{ 'name' => 'cfg', 'configMap' => { 'name' => 'c' } }])
    live = deep(rendered)
    lc = live['spec']['template']['spec']['containers'][0]
    lc['ports'][0]['protocol'] = 'TCP'
    lc['readinessProbe'] = { 'httpGet' => { 'path' => '/health', 'port' => 8080, 'scheme' => 'HTTP' }, 'timeoutSeconds' => 1,
                             'periodSeconds' => 10, 'successThreshold' => 1, 'failureThreshold' => 3 }
    lc['resources'] = { 'requests' => { 'cpu' => '500m', 'memory' => '134217728' } }
    lc['volumeMounts'][0]['readOnly'] = false
    lc['terminationMessagePath'] = '/dev/termination-log'
    live['spec']['template']['spec']['volumes'][0]['configMap']['defaultMode'] = 420
    live['spec']['template']['spec']['securityContext'] = {}
    live['spec']['template']['spec']['serviceAccountName'] = 'default'
    assert_equal [['SAME', 'Deployment/dep']], compare(rendered, live)
  end

  def test_workload_security_relevant_changes_are_drift
    rendered = deployment(container(securityContext: { 'runAsNonRoot' => true, 'readOnlyRootFilesystem' => true },
                                    resources: { 'limits' => { 'memory' => '512Mi' } },
                                    livenessProbe: { 'tcpSocket' => { 'port' => 8080 } }),
                          'automountServiceAccountToken' => false)
    live = deep(rendered)
    ls = live['spec']['template']['spec']
    ls['containers'][0]['securityContext']['readOnlyRootFilesystem'] = false
    ls['containers'][0]['resources']['limits']['memory'] = '1Gi'
    ls['containers'][0].delete('livenessProbe')
    ls['serviceAccountName'] = 'privileged'
    ls['automountServiceAccountToken'] = true
    live['spec']['selector'] = { 'matchLabels' => { 'app' => 'y' } }
    msg = compare(rendered, live)[0][1]
    %w[selector serviceAccountName automountServiceAccountToken].each { |k| assert_match(/\b#{k}\b/, msg) }
    assert_match(/container app securityContext/, msg)
    assert_match(/container app resources/, msg)
    assert_match(/container app livenessProbe/, msg)
  end

  # --- env values and ownership ---------------------------------------------------------------------------
  def env(pairs)
    pairs.map { |k, v| v.is_a?(Hash) ? { 'name' => k, 'valueFrom' => v } : { 'name' => k, 'value' => v } }
  end

  def test_env_values_shown_only_when_plainly_public
    rendered = deployment(container(env: env('BPNACCESS__BASEADDRESS' => 'https://business-partners.test.tractus-x.com/pool/v6',
                                             'SMTP__HOST' => 'be293-smtp4dev.be293.svc.cluster.local',
                                             'SMTP__USER' => 'be293-portal', 'SMTP__PASSWORD' => 'rendered-pw',
                                             'X__TOKENADDRESS' => 'https://idp.example/token')))
    live = deployment(container(env: env('BPNACCESS__BASEADDRESS' => 'https://business-partners.test.tractus-x.com/pool',
                                         'SMTP__HOST' => 'smtp.office365.com', 'SMTP__USER' => 'it@arena2036.de',
                                         'SMTP__PASSWORD' => 'live-pw', 'X__TOKENADDRESS' => 'https://idp.example/token')))
    msg = compare(rendered, live)[0][1]
    assert_includes msg, 'env BPNACCESS__BASEADDRESS: value differs (live=https://business-partners.test.tractus-x.com/pool rendered=https://business-partners.test.tractus-x.com/pool/v6)'
    assert_includes msg, 'env SMTP__HOST: value differs (live=smtp.office365.com rendered=be293-smtp4dev.be293.svc.cluster.local)'
    assert_match(/env SMTP__USER: value differs(;|\z)/, msg)
    assert_match(/env SMTP__PASSWORD: value differs(;|\z)/, msg)
    refute_includes msg, 'pw'
    refute_includes msg, 'arena2036.de'
    refute_includes msg, 'TOKENADDRESS'
  end

  def test_change_of_a_kubectl_owned_field_is_an_ssa_conflict
    rendered = deployment(container(env: env('A' => 'http://new.svc.cluster.local/')))
    live = deep(deployment(container(env: env('A' => 'https://old.example.invalid/'))))
    live['metadata']['managedFields'] = [managed('helm'), managed('kubectl-patch', env_name: 'A')]
    level, msg = compare(rendered, live)[0]
    assert_equal 'FAIL', level
    assert_match(/env A: value differs .*\[CONFLICT: owned by kubectl-patch, an SSA upgrade without --force-conflicts would FAIL\]/, msg)
  end

  def test_change_of_a_helm_owned_field_is_reported_as_owned_drift
    rendered = deployment(container(env: env('A' => 'http://new.svc.cluster.local/')))
    live = deep(deployment(container(env: env('A' => 'https://old.example.invalid/'))))
    live['metadata']['managedFields'] = [managed('helm', env_name: 'A')]
    level, msg = compare(rendered, live)[0]
    assert_equal 'DRIFT', level
    assert_match(/\[owner: helm\]/, msg)
  end

  def test_identical_value_on_a_kubectl_owned_field_is_not_a_conflict
    rendered = deployment(container(env: env('A' => 'http://same.svc.cluster.local/')))
    live = deep(rendered)
    live['metadata']['managedFields'] = [managed('kubectl-set', image: true), managed('kubectl-patch', env_name: 'A')]
    assert_equal [['SAME', 'Deployment/dep']], compare(rendered, live)
  end

  def test_cronjob_ownership_path
    cj = lambda do |value|
      { 'kind' => 'CronJob', 'metadata' => { 'name' => 'cj' },
        'spec' => { 'schedule' => '*/5 * * * *', 'jobTemplate' => { 'spec' => { 'template' => { 'spec' => { 'containers' => [container(env: env('B' => value))] } } } } } }
    end
    live = deep(cj.call('http://old.svc.cluster.local/'))
    live['metadata']['managedFields'] = [managed('kubectl-patch', env_name: 'B', cronjob: true)]
    level, msg = compare(cj.call('http://new.svc.cluster.local/'), live)[0]
    assert_equal 'FAIL', level
    assert_match(/env B: .*CONFLICT: owned by kubectl-patch/, msg)
  end

  # --- Secrets (unchanged behaviour) ---------------------------------------------------------------------
  def test_secret_change_is_fail_and_identical_is_same
    s = ->(v) { { 'kind' => 'Secret', 'metadata' => { 'name' => 's' }, 'data' => { 'k' => v } } }
    assert_equal 'SAME', compare(s.call('YQ=='), s.call('YQ=='))[0][0]
    level, msg = compare(s.call('Yg=='), s.call('YQ=='))[0]
    assert_equal 'FAIL', level
    assert_match(/key k: DIFFERS/, msg)
    refute_includes msg, 'YQ'
    sd = { 'kind' => 'Secret', 'metadata' => { 'name' => 's' }, 'stringData' => { 'k' => 'a' } }
    assert_equal 'SAME', compare(sd, s.call('YQ=='))[0][0]
  end

  # --- Rancher annotation ownership ---------------------------------------------------------------------
  def with_annotation_owner(live, manager)
    live['metadata']['managedFields'] = [{ 'manager' => manager, 'operation' => 'Update',
                                           'fieldsV1' => { 'f:metadata' => { 'f:annotations' => { 'f:field.cattle.io/publicEndpoints' => {} } } } }]
    live
  end

  def test_live_only_annotation_owned_by_rancher_is_kept_but_helm_owned_is_fail
    user = { 'cert-manager.io/cluster-issuer' => 'letsencrypt-prod' }
    live = ingress(user.merge('field.cattle.io/publicEndpoints' => '[{"addresses":["188.34.116.149"]}]'))
    level, msg = compare(ingress(user), with_annotation_owner(deep(live), 'rancher'))[0]
    assert_equal 'DRIFT', level
    assert_includes msg, 'annotation field.cattle.io/publicEndpoints: only live (upgrade keeps it unless Helm owned it) [owner: rancher]'
    refute_includes msg, '188.34'
    level, msg = compare(ingress(user), with_annotation_owner(deep(live), 'helm'))[0]
    assert_equal 'FAIL', level
    assert_match(/REMOVED BY UPGRADE: owned by helm/, msg)
  end

  # --- reviewed expected drift ---------------------------------------------------------------------------
  # The DRIFT lines of the 2026-11-08 recovery dry run, verbatim (non-secret URLs only).
  DRY_RUN_2026_11_08 = [
    'Deployment/be293-portal-administration-service: container be293-portal-administration-service env APPLICATIONCHECKLIST__BPDM__BASEADDRESS: value differs (live=https://business-partners.test.tractus-x.com/gate rendered=https://business-partners.test.tractus-x.com/gate/v6) [owner: helm]; container be293-portal-administration-service env APPLICATIONCHECKLIST__BPDM__BUSINESSPARTNERPOOLBASEADDRESS: value differs (live=https://business-partners.test.tractus-x.com/pool rendered=https://business-partners.test.tractus-x.com/pool/v6) [owner: helm]; container be293-portal-administration-service env APPLICATIONCHECKLIST__DIM__UNIVERSALRESOLVERADDRESS: value differs (live=https://universal-resolver.disabled.invalid/ rendered=http://be293-did-resolver.be293.svc.cluster.local:8080/) [owner: helm]; container be293-portal-administration-service env APPLICATIONCHECKLIST__IDENTITYHUB__UNIVERSALRESOLVERADDRESS: value differs (live=https://universal-resolver.disabled.invalid/ rendered=http://be293-did-resolver.be293.svc.cluster.local:8080/) [owner: helm]; container be293-portal-administration-service env BPNACCESS__BASEADDRESS: value differs (live=https://business-partners.test.tractus-x.com/pool rendered=https://business-partners.test.tractus-x.com/pool/v6) [owner: helm]',
    'Deployment/be293-portal-marketplace-app-service: container be293-portal-marketplace-app-service env DIM__UNIVERSALRESOLVERADDRESS: value differs (live=https://universal-resolver.disabled.invalid/ rendered=http://be293-did-resolver.be293.svc.cluster.local:8080/) [owner: helm]',
    'Deployment/be293-portal-registration-service: container be293-portal-registration-service env BPNACCESS__BASEADDRESS: value differs (live=https://business-partners.test.tractus-x.com/pool rendered=https://business-partners.test.tractus-x.com/pool/v6) [owner: helm]',
    'Deployment/be293-portal-services-service: container be293-portal-services-service env DIM__UNIVERSALRESOLVERADDRESS: value differs (live=https://universal-resolver.disabled.invalid/ rendered=http://be293-did-resolver.be293.svc.cluster.local:8080/) [owner: helm]',
    'Deployment/be293-portal-portal: container be293-portal-portal env BPDM_GATE_API_URL: value differs (live=https://business-partners.test.tractus-x.com/gate rendered=https://business-partners.test.tractus-x.com/gate/v6) [owner: helm]; container be293-portal-portal env BPDM_POOL_API_URL: value differs (live=https://business-partners.test.tractus-x.com/pool rendered=https://business-partners.test.tractus-x.com/pool/v6) [owner: helm]',
    'Ingress/be293-portal-backend: annotation field.cattle.io/publicEndpoints: only live (upgrade keeps it unless Helm owned it)',
    'Ingress/be293-portal-frontend: annotation field.cattle.io/publicEndpoints: only live (upgrade keeps it unless Helm owned it) [owner: rancher]'
  ].map { |m| ['DRIFT', m] }.freeze

  def expected_file
    YAML.safe_load(File.read(File.expand_path('../expected-drift.alpha.yaml', __dir__)))
  end

  def test_reviewed_expected_drift_accepts_exactly_the_dry_run
    assert_empty CompareReleaseLive.unexpected_items(DRY_RUN_2026_11_08, expected_file)
    assert_empty CompareReleaseLive.unexpected_items([['SAME', 'Service/x']], expected_file)
  end

  def test_unreviewed_or_changed_drift_is_flagged
    extra = DRY_RUN_2026_11_08 + [['DRIFT', 'Deployment/be293-portal-notification-service: container be293-portal-notification-service image [owner: helm]']]
    assert_equal ['Deployment/be293-portal-notification-service: container be293-portal-notification-service image [owner: helm]'],
                 CompareReleaseLive.unexpected_items(extra, expected_file)
    changed = DRY_RUN_2026_11_08.map { |l, m| [l, m.sub('gate/v6) [owner: helm]', 'gate/v7) [owner: helm]')] }
    assert_equal 2, CompareReleaseLive.unexpected_items(changed, expected_file).size
    conflict = DRY_RUN_2026_11_08.map { |l, m| [l, m.sub('BPNACCESS__BASEADDRESS: value differs (live=https://business-partners.test.tractus-x.com/pool rendered=https://business-partners.test.tractus-x.com/pool/v6) [owner: helm]', 'BPNACCESS__BASEADDRESS: value differs (live=https://business-partners.test.tractus-x.com/pool rendered=https://business-partners.test.tractus-x.com/pool/v6) [owner: helm,kubectl-patch]')] }
    assert_equal 2, CompareReleaseLive.unexpected_items(conflict, expected_file).size
    sibling = [['DRIFT', 'Deployment/be293-portal-assets: container be293-portal-assets env X: value differs [owner: helm]']]
    assert_equal 1, CompareReleaseLive.unexpected_items(sibling, expected_file).size
  end

  def test_missing_live_object_is_reported
    assert_match(/missing live/, compare(service([{ 'port' => 1 }]), nil)[0][1])
  end
end
