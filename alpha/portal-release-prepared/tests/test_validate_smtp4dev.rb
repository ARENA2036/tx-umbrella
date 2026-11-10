# frozen_string_literal: true

# Tests for tools/validate_smtp4dev.rb (S1-S9) on the real smtp4dev-be293.alpha.yaml (image digest pinned to a
# synthetic value in memory) and on real offline renders of the chart with and without the smtp4dev overlay.
#
# Run: ruby tests/test_validate_smtp4dev.rb

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'
require_relative '../tools/validate_smtp4dev'

class ValidateSmtp4devTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  CHART = File.expand_path('../../handoff/BE-293-umbrella-3.17.0/chart/umbrella/charts/portal-2.6.0.tgz', HERE)
  BASE_VALUES = %w[values-be293-portal.yaml values-be293-portal.alpha-release.yaml values-be293-portal.alpha-retention.yaml].freeze
  PINNED = "docker.io/rnwood/smtp4dev:3.15.0@sha256:#{'a' * 64}"

  def docs
    d = Smtp4devGates.load(File.join(HERE, 'smtp4dev-be293.alpha.yaml'))
    dep(d)['spec']['template']['spec']['containers'][0]['image'] = PINNED
    d
  end

  def dep(d)
    d.find { |x| x['kind'] == 'Deployment' }
  end
  def kind(d, k)
    d.find { |x| x['kind'] == k }
  end
  def container(d)
    dep(d)['spec']['template']['spec']['containers'][0]
  end

  def env!(d, name, value)
    env = container(d)['env']
    e = env.find { |x| x['name'].casecmp?(name) }
    value.nil? ? env.delete(e) : (e ? e['value'] = value : env << { 'name' => name, 'value' => value })
    d
  end

  def failures_of(d, render: nil)
    Smtp4devGates::Validator.new.check(d, render: render).failures.join("\n")
  end

  def test_pinned_manifest_passes_and_unpinned_repo_file_fails_s3
    assert_empty failures_of(docs)
    assert_match(/\[S3\].*pinned by digest/, failures_of(Smtp4devGates.load(File.join(HERE, 'smtp4dev-be293.alpha.yaml')))) unless
      File.read(File.join(HERE, 'smtp4dev-be293.alpha.yaml')).match?(/smtp4dev:3\.15\.0@sha256:\h{64}/)
    d = docs
    container(d)['image'] = 'docker.io/rnwood/smtp4dev:latest'
    assert_match(/\[S3\]/, failures_of(d))
  end

  def test_s1_s2_no_public_exposure
    d = docs
    kind(d, 'Service')['spec']['type'] = 'LoadBalancer'
    assert_match(/\[S2\] Service type "LoadBalancer"/, failures_of(d))
    d = docs
    kind(d, 'Service')['spec']['ports'] << { 'name' => 'http', 'port' => 80, 'targetPort' => 'http' }
    assert_match(/\[S2\] Service ports \[25, 80\]/, failures_of(d))
    d = docs << { 'kind' => 'Ingress', 'metadata' => { 'name' => 'ui', 'namespace' => 'be293' } }
    assert_match(/\[S1\] unexpected kind Ingress/, failures_of(d))
    d = docs
    kind(d, 'Service')['metadata']['namespace'] = 'release26-09'
    assert_match(/\[S1\].*namespace "release26-09"/, failures_of(d))
  end

  def test_s4_relay_must_stay_disabled_and_locked
    assert_match(/\[S4\] relayoptions__smtpserver/, failures_of(env!(docs, 'RelayOptions__SmtpServer', 'smtp.office365.com')))
    assert_match(/\[S4\] relayoptions__automaticrelayexpression/, failures_of(env!(docs, 'RelayOptions__AutomaticRelayExpression', nil)))
    assert_match(/\[S4\] relay credentials/, failures_of(env!(docs, 'RelayOptions__Login', 'x')))
    assert_match(/\[S4\] ServerOptions__LockSettings/, failures_of(env!(docs, 'ServerOptions__LockSettings', 'false')))
  end

  def test_s5_s6_protocols_and_hardening
    assert_match(/\[S5\] serveroptions__imapport/, failures_of(env!(docs, 'ServerOptions__ImapPort', '143')))
    d = docs
    container(d)['securityContext']['readOnlyRootFilesystem'] = false
    dep(d)['spec']['template']['spec']['securityContext']['runAsNonRoot'] = false
    msg = failures_of(d)
    assert_match(/\[S6\] readOnlyRootFilesystem/, msg)
    assert_match(/\[S6\] runAsNonRoot/, msg)
    d = docs
    container(d)['ports'][0]['hostPort'] = 25
    assert_match(/\[S6\] hostPort/, failures_of(d))
  end

  def test_s7_s8_storage_and_policy
    d = docs
    dep(d)['spec']['strategy']['type'] = 'RollingUpdate'
    assert_match(/\[S7\] strategy/, failures_of(d))
    assert_match(/\[S7\] database/, failures_of(env!(docs, 'ServerOptions__Database', 'database.db')))
    d = docs
    kind(d, 'NetworkPolicy')['spec']['ingress'][0]['from'] << { 'namespaceSelector' => {} }
    assert_match(/\[S8\] ingress source/, failures_of(d))
    d = docs
    kind(d, 'NetworkPolicy')['spec']['ingress'][0]['ports'] << { 'protocol' => 'TCP', 'port' => 8080 }
    assert_match(/\[S8\] ingress ports/, failures_of(d))
  end

  def render(values)
    Dir.mktmpdir do |dir|
      env = { 'KUBECONFIG' => '/dev/null', 'HELM_PLUGINS' => File.join(HERE, 'helm-plugins'), 'HELM_CACHE_HOME' => "#{dir}/c",
              'HELM_CONFIG_HOME' => "#{dir}/cfg", 'HELM_DATA_HOME' => "#{dir}/d" }
      args = ['helm', 'template', 'be293-portal', CHART, '--namespace', 'be293', '--post-renderer', 'be293-retention']
      values.each { |v| args += ['-f', File.join(HERE, v)] }
      out, err, st = Open3.capture3(env, *args)
      assert st.success?, err
      return Smtp4devGates.load_string(out)
    end
  end

  def test_s9_real_render_targets_the_sink_only_with_the_overlay
    skip 'helm not installed' unless system('command -v helm >/dev/null 2>&1')
    rendered = render(BASE_VALUES + ['values-be293-portal.alpha-smtp4dev.yaml'])
    assert_empty failures_of(docs, render: rendered)
    msg = failures_of(docs, render: render(BASE_VALUES))
    assert_match(/\[S9\] MAILINGSERVICE__MAIL__SMTPHOST "smtp.office365.com"/, msg)
    assert_match(%r{\[S9\] real SMTP provider referenced outside the shared-realm setting: \["be293-portal-processes-worker/MAILINGSERVICE__MAIL__SMTPHOST"\]}, msg)
  end

  # Decision 2026-11-08: new shared-IdP realms keep the live Alpha SMTP (office365:587, Secret reference).
  def test_s9_shared_realm_keeps_the_approved_live_configuration
    skip 'helm not installed' unless system('command -v helm >/dev/null 2>&1')
    rendered = render(BASE_VALUES + ['values-be293-portal.alpha-smtp4dev.yaml'])
    admin = rendered.find { |d| d['kind'] == 'Deployment' && d.dig('metadata', 'name') == 'be293-portal-administration-service' }
    env = admin['spec']['template']['spec']['containers'][0]['env']
    env.find { |e| e['name'] == 'PROVISIONING__SHAREDREALM__SMTPSERVER__HOST' }['value'] = 'be293-smtp4dev.be293.svc.cluster.local'
    env.find { |e| e['name'] == 'PROVISIONING__SHAREDREALM__SMTPSERVER__PASSWORD' }.replace('name' => 'PROVISIONING__SHAREDREALM__SMTPSERVER__PASSWORD', 'value' => 'x')
    msg = failures_of(docs, render: rendered)
    assert_match(/\[S9\] be293-portal-administration-service PROVISIONING__SHAREDREALM__SMTPSERVER__HOST "be293-smtp4dev.be293.svc.cluster.local" != approved live value "smtp.office365.com"/, msg)
    assert_match(/\[S9\] be293-portal-administration-service shared-realm SMTP password must reference Secret be293-portal-mailing, got nil/, msg)
    refute_match(/"x"/, msg)
  end
end
