# frozen_string_literal: true

# Release gate for the two be293-portal Ingresses (offline; reads a rendered manifest, never a cluster).
# Complements tools/validate_render.rb, whose --allow-ingress mode only rejects other owners' hosts.
#
# Gates (I1-I7):
#   I1 exactly the approved Ingress objects, in be293
#   I2 ingressClassName nginx, ClusterIssuer letsencrypt-prod
#   I3 every rule host is an approved dedicated host; ExternalDNS hostname annotation lists exactly those hosts
#   I4 every rule host is covered by TLS with the dedicated Secret; no Secret shared between Ingresses
#   I5 every backend is a Service of this render, on a port that Service exposes
#   I6 regex paths use pathType ImplementationSpecific (ingress-nginx strict path validation)
#   I7 CORS origins are exact https origins (no wildcard, no localhost, no http)
#
# Usage: ruby tools/validate_ingress.rb --render FILE

require 'optparse'
require 'set'
require 'yaml'

module PortalIngressGates
  NAMESPACE = 'be293'
  INGRESS_CLASS = 'nginx'
  CLUSTER_ISSUER = 'letsencrypt-prod'
  APPROVED = {
    'be293-portal-frontend' => { host: 'portal-be293.test.tractus-x.com', tls_secret: 'be293-portal-frontend-tls' },
    'be293-portal-backend' => { host: 'portal-backend-be293.test.tractus-x.com', tls_secret: 'be293-portal-backend-tls' }
  }.freeze
  EXTERNAL_DNS_HOSTNAME = 'external-dns.alpha.kubernetes.io/hostname'
  CORS_ORIGIN = 'nginx.ingress.kubernetes.io/cors-allow-origin'
  REGEX_CHARS = /[()|*+?\[\]^$\\]/.freeze

  class Validator
    attr_reader :failures, :info

    def initialize
      @failures = []
      @info = []
    end

    def check(docs)
      ingresses = docs.select { |d| d['kind'] == 'Ingress' }
      services = docs.select { |d| d['kind'] == 'Service' }
                     .to_h { |s| [s.dig('metadata', 'name'), (s.dig('spec', 'ports') || []).map { |p| p['port'] }] }
      check_set(ingresses)
      seen_secrets = {}
      ingresses.each do |ing|
        name = ing.dig('metadata', 'name')
        approved = APPROVED[name]
        next unless approved

        check_class_and_issuer(name, ing)
        hosts = check_hosts(name, ing, approved)
        check_tls(name, ing, hosts, approved, seen_secrets)
        check_backends(name, ing, services)
        check_cors(name, ing)
      end
      self
    end

    private

    def fail(gate, msg)
      @failures << "[#{gate}] #{msg}"
    end

    def check_set(ingresses)
      names = ingresses.map { |i| i.dig('metadata', 'name') }
      (names - APPROVED.keys).each { |n| fail('I1', "unapproved Ingress #{n}") }
      (APPROVED.keys - names).each { |n| fail('I1', "approved Ingress #{n} not rendered") }
      dupes = names.group_by(&:itself).select { |_, v| v.size > 1 }.keys
      fail('I1', "duplicate Ingress names #{dupes}") unless dupes.empty?
      ingresses.each do |i|
        ns = i.dig('metadata', 'namespace')
        fail('I1', "Ingress #{i.dig('metadata', 'name')} namespace #{ns.inspect} != #{NAMESPACE}") unless ns == NAMESPACE
      end
    end

    def check_class_and_issuer(name, ing)
      cls = ing.dig('spec', 'ingressClassName')
      fail('I2', "#{name} ingressClassName #{cls.inspect} != #{INGRESS_CLASS}") unless cls == INGRESS_CLASS
      ann = ing.dig('metadata', 'annotations') || {}
      issuer = ann['cert-manager.io/cluster-issuer']
      fail('I2', "#{name} cluster-issuer #{issuer.inspect} != #{CLUSTER_ISSUER}") unless issuer == CLUSTER_ISSUER
      fail('I2', "#{name} must not use a namespaced cert-manager.io/issuer") if ann.key?('cert-manager.io/issuer')
    end

    def check_hosts(name, ing, approved)
      hosts = (ing.dig('spec', 'rules') || []).map { |r| r['host'] }
      fail('I3', "#{name} has no rules") if hosts.empty?
      hosts.each { |h| fail('I3', "#{name} host #{h.inspect} != approved #{approved[:host]}") unless h == approved[:host] }
      dns = (ing.dig('metadata', 'annotations') || {})[EXTERNAL_DNS_HOSTNAME].to_s.split(',').map(&:strip).reject(&:empty?)
      fail('I3', "#{name} #{EXTERNAL_DNS_HOSTNAME} #{dns.inspect} != rule hosts #{hosts.uniq.inspect}") unless dns.sort == hosts.uniq.sort
      @info << "#{name} host #{hosts.uniq.join(',')}"
      hosts
    end

    def check_tls(name, ing, hosts, approved, seen_secrets)
      tls = ing.dig('spec', 'tls') || []
      fail('I4', "#{name} has no TLS section") if tls.empty?
      covered = tls.flat_map { |t| t['hosts'] || [] }
      (hosts - covered).each { |h| fail('I4', "#{name} host #{h} not covered by TLS") }
      tls.each do |t|
        secret = t['secretName']
        fail('I4', "#{name} TLS secret #{secret.inspect} != dedicated #{approved[:tls_secret]}") unless secret == approved[:tls_secret]
        fail('I4', "TLS secret #{secret} shared by #{seen_secrets[secret]} and #{name}") if seen_secrets.key?(secret)
        seen_secrets[secret] = name
      end
    end

    def check_backends(name, ing, services)
      (ing.dig('spec', 'rules') || []).each do |r|
        (r.dig('http', 'paths') || []).each do |p|
          svc = p.dig('backend', 'service', 'name')
          port = p.dig('backend', 'service', 'port', 'number')
          if !services.key?(svc)
            fail('I5', "#{name} path #{p['path']} -> Service #{svc.inspect} is not part of this release")
          elsif !services[svc].include?(port)
            fail('I5', "#{name} path #{p['path']} -> #{svc}:#{port.inspect}, Service exposes #{services[svc].inspect}")
          end
          if p['path'].to_s.match?(REGEX_CHARS) && p['pathType'] != 'ImplementationSpecific'
            fail('I6', "#{name} regex path #{p['path']} uses pathType #{p['pathType'].inspect}")
          end
        end
      end
    end

    def check_cors(name, ing)
      origins = (ing.dig('metadata', 'annotations') || {})[CORS_ORIGIN]
      return if origins.nil?

      origins.split(',').map(&:strip).each do |o|
        fail('I7', "#{name} CORS origin #{o.inspect} is not an exact https origin") unless o.match?(%r{\Ahttps://[a-z0-9.-]+\z}) && !o.include?('*')
      end
    end
  end

  def self.load_docs(text)
    YAML.load_stream(text).compact.select { |d| d.is_a?(Hash) && d['kind'] }
  end
end

if $PROGRAM_NAME == __FILE__
  render = nil
  OptionParser.new { |o| o.on('--render FILE') { |v| render = v } }.parse!
  abort('usage: --render FILE is required') unless render

  begin
    v = PortalIngressGates::Validator.new.check(PortalIngressGates.load_docs(File.read(render)))
  rescue Psych::Exception, Errno::ENOENT => e
    warn "input error: #{e.message}"
    exit 2
  end
  v.info.each { |i| puts "info #{i}" }
  v.failures.each { |f| puts "FAIL #{f}" }
  puts(v.failures.empty? ? 'INGRESS RESULT PASS' : "INGRESS RESULT FAIL (#{v.failures.size})")
  exit(v.failures.empty? ? 0 : 1)
end
