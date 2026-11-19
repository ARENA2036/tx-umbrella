# frozen_string_literal: true

# Unit tests for tools/validate_ingress.rb using synthetic manifests, plus one offline integration test that
# runs tools/render-release.sh against the real chart and the Alpha release overlay (no cluster access).
#
# Run: ruby tests/test_validate_ingress.rb

require 'minitest/autorun'
require 'tmpdir'
require_relative 'support/pinned_smtp4dev'
require_relative 'support/pinned_did_resolver'
require 'open3'
require_relative '../tools/validate_ingress'

class ValidateIngressTest < Minitest::Test
  FRONT_HOST = 'portal-be293.test.tractus-x.com'
  BACK_HOST = 'portal-backend-be293.test.tractus-x.com'

  def service(name, port = 8080)
    { 'kind' => 'Service', 'metadata' => { 'name' => name, 'namespace' => 'be293' }, 'spec' => { 'ports' => [{ 'port' => port }] } }
  end

  def ingress(name:, host:, tls_secret:, paths:, ns: 'be293', cls: 'nginx', annotations: {}, tls_hosts: [host])
    ann = { 'cert-manager.io/cluster-issuer' => 'letsencrypt-prod',
            'external-dns.alpha.kubernetes.io/hostname' => host }.merge(annotations).compact
    { 'kind' => 'Ingress', 'metadata' => { 'name' => name, 'namespace' => ns, 'annotations' => ann },
      'spec' => { 'ingressClassName' => cls, 'tls' => [{ 'hosts' => tls_hosts, 'secretName' => tls_secret }],
                  'rules' => [{ 'host' => host, 'http' => { 'paths' => paths } }] } }
  end

  def path(p, svc, type: 'Prefix', port: 8080)
    { 'path' => p, 'pathType' => type, 'backend' => { 'service' => { 'name' => svc, 'port' => { 'number' => port } } } }
  end

  def frontend(**overrides)
    ingress(**{ name: 'be293-portal-frontend', host: FRONT_HOST, tls_secret: 'be293-portal-frontend-tls',
                paths: [path('/(.*)', 'be293-portal-portal', type: 'ImplementationSpecific')] }.merge(overrides))
  end

  def backend(**overrides)
    ingress(**{ name: 'be293-portal-backend', host: BACK_HOST, tls_secret: 'be293-portal-backend-tls',
                annotations: { 'nginx.ingress.kubernetes.io/cors-allow-origin' => "https://#{FRONT_HOST}" },
                paths: [path('/api/administration', 'be293-portal-administration-service')] }.merge(overrides))
  end

  def services
    [service('be293-portal-portal'), service('be293-portal-administration-service')]
  end

  def failures_of(docs)
    PortalIngressGates::Validator.new.check(docs).failures.join("\n")
  end

  def test_approved_pair_passes
    assert_empty failures_of(services + [frontend, backend])
  end

  def test_missing_and_unapproved_ingress
    extra = frontend(name: 'be293-portal-extra')
    msg = failures_of(services + [frontend, extra])
    assert_match(/unapproved Ingress be293-portal-extra/, msg)
    assert_match(/approved Ingress be293-portal-backend not rendered/, msg)
  end

  def test_foreign_namespace_rejected
    assert_match(/namespace "release26-09" != be293/, failures_of(services + [frontend(ns: 'release26-09'), backend]))
  end

  def test_wrong_class_and_issuer
    msg = failures_of(services + [frontend(cls: 'traefik', annotations: { 'cert-manager.io/cluster-issuer' => 'letsencrypt-staging' }), backend])
    assert_match(/ingressClassName "traefik" != nginx/, msg)
    assert_match(/cluster-issuer "letsencrypt-staging" != letsencrypt-prod/, msg)
  end

  def test_old_portal_host_rejected
    msg = failures_of(services + [frontend(host: 'portal.test.tractus-x.com'), backend])
    assert_match(/host "portal.test.tractus-x.com" != approved #{Regexp.escape(FRONT_HOST)}/, msg)
  end

  def test_external_dns_annotation_must_match_hosts
    msg = failures_of(services + [frontend(annotations: { 'external-dns.alpha.kubernetes.io/hostname' => nil }), backend])
    assert_match(/external-dns.alpha.kubernetes.io\/hostname \[\] != rule hosts/, msg)
  end

  def test_tls_must_cover_host_and_use_dedicated_unshared_secret
    msg = failures_of(services + [frontend(tls_hosts: ['other.test.tractus-x.com']), backend(tls_secret: 'be293-portal-frontend-tls')])
    assert_match(/host #{Regexp.escape(FRONT_HOST)} not covered by TLS/, msg)
    assert_match(/TLS secret "be293-portal-frontend-tls" != dedicated be293-portal-backend-tls/, msg)
    assert_match(/TLS secret be293-portal-frontend-tls shared by be293-portal-frontend and be293-portal-backend/, msg)
  end

  def test_backend_must_be_release_service_on_exposed_port
    msg = failures_of(services + [frontend, backend(paths: [path('/api/provisioning', 'be293-portal-provisioning-service'),
                                                         path('/api/administration', 'be293-portal-administration-service', port: 9090)])])
    assert_match(/Service "be293-portal-provisioning-service" is not part of this release/, msg)
    assert_match(/be293-portal-administration-service:9090, Service exposes \[8080\]/, msg)
  end

  def test_regex_path_requires_implementation_specific
    msg = failures_of(services + [frontend(paths: [path('/(.*)', 'be293-portal-portal', type: 'Prefix')]), backend])
    assert_match(/regex path \/\(\.\*\) uses pathType "Prefix"/, msg)
  end

  def test_cors_rejects_wildcard_localhost_and_http
    ann = { 'nginx.ingress.kubernetes.io/cors-allow-origin' => 'https://*.test.tractus-x.com, http://localhost:3000' }
    msg = failures_of(services + [frontend, backend(annotations: ann)])
    assert_match(/CORS origin "https:\/\/\*.test.tractus-x.com"/, msg)
    assert_match(/CORS origin "http:\/\/localhost:3000"/, msg)
  end

  # --- integration: real chart, base values + Alpha release overlay, offline ---------------------
  def test_release_render_passes_all_gates
    skip 'helm not installed' unless system('command -v helm >/dev/null 2>&1')
    script = File.expand_path('../tools/render-release.sh', __dir__)
    out, status = Dir.mktmpdir { |dir| Open3.capture2e({ 'SMTP4DEV_MANIFEST' => PinnedSmtp4dev.manifest(dir), 'DID_RESOLVER_MANIFEST' => PinnedDidResolver.manifest(dir) }, 'bash', script) }
    assert status.success?, "render-release.sh failed:\n#{out.lines.last(15).join}"
    assert_match(/objects=31 mode=release/, out)
    assert_match(/pending placeholders=0/, out)
    assert_match(/INGRESS RESULT PASS/, out)
  end
end
