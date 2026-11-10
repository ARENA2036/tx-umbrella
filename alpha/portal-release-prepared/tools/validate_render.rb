# frozen_string_literal: true

# Offline safety gates for the BE-293 Portal render (namespace be293).
#
# Usage:
#   ruby tools/validate_render.rb --render RENDER.yaml [--networkpolicies NP.yaml] [--values VALUES.yaml]
#        [--images-lock images.lock.yaml] [--expected-inventory expected-inventory.txt] [--mode offline|release]
#
# offline: placeholders (<<ALPHA:..>>, <<IMAGE:..>>) are reported but allowed.
# release: any placeholder is a failure.
# Secret data and env values of secret-bearing variables are never printed.
# Exit code: 0 = all gates pass, 1 = at least one failure, 2 = usage/input error.

require 'yaml'
require 'optparse'
require 'set'

module PortalRenderGates
  NAMESPACE = 'be293'
  RELEASE = 'be293-portal'
  ALLOWED_KINDS = %w[ConfigMap Secret Service Deployment StatefulSet CronJob Job NetworkPolicy].freeze
  ALLOWED_HOOK_JOBS = %w[portal-migrations provisioning-migrations].freeze
  ALLOWED_HOOK_PHASES = %w[post-install post-upgrade].freeze
  PLACEHOLDER = /<<(ALPHA|IMAGE):[A-Z0-9_]+>>/.freeze
  DIGEST = /@sha256:([0-9a-f]{64}|<<IMAGE:[A-Z0-9_]+>>)\z/.freeze
  # Hosts that belong to other owners and must never be targeted by this release.
  FORBIDDEN_HOSTS = %w[portal.test.tractus-x.com portal-backend.test.tractus-x.com].freeze
  FORBIDDEN_HOST_PATTERNS = [/\.tx\.test\b/, /example\.(org|invalid)\b/, /\.connector\.svc/, /\.kube-system\.svc/].freeze
  SHARED_NS_HOST = /\.release26-09\.svc\.cluster\.local/.freeze
  # Env variables that may point at release26-09 in-cluster services (the approved integration surface).
  SHARED_SERVICE_ENV_ALLOWLIST = Set.new(%w[
    APPLICATIONCHECKLIST__IDENTITYHUB__BASEADDRESS
    APPLICATIONCHECKLIST__IDENTITYHUB__ISSUERADMINBASEADDRESS
    BPNDIDRESOLVER__BASEADDRESS
    APPLICATIONCHECKLIST__SDFACTORY__SDFACTORYURL
    SDFACTORY__SDFACTORYURL
  ]).freeze
# R-BPDM: every BPDM address must be the public host plus /gate|/pool and the API version. The backend appends
# relative paths (input/business-partners, legal-entities/{bpn}, ...) and the BPDM Ingress only strips the
# /gate or /pool prefix; without /v<N> the Gate answers 404. One version for Gate and Pool across the release.
BPDM_HOST = 'https://business-partners.test.tractus-x.com'
BPDM_URL = %r{\Ahttps://business-partners\.test\.tractus-x\.com/(gate|pool)/(v\d+)\z}.freeze
BPDM_ENV = {
  'APPLICATIONCHECKLIST__BPDM__BASEADDRESS' => 'gate', 'BPDM_GATE_API_URL' => 'gate',
  'APPLICATIONCHECKLIST__BPDM__BUSINESSPARTNERPOOLBASEADDRESS' => 'pool', 'BPNACCESS__BASEADDRESS' => 'pool', 'BPDM_POOL_API_URL' => 'pool'
}.freeze
  SECRET_ENV_NAME = /(PASSWORD|CLIENTSECRET|APIKEY|ENCRYPTIONKEY)\z/.freeze
  # The upstream chart fills unused password-grant fields with the literal "empty" (client-credentials flows).
  NON_SECRET_FILLERS = ['', 'empty'].freeze
  SECRET_VALUE_KEY = /(password|apikey|api_key|encryptionkey|clientsecret|token)\z/i.freeze
  CLUSTER_SCOPED = %w[Namespace ClusterRole ClusterRoleBinding CustomResourceDefinition
                      MutatingWebhookConfiguration ValidatingWebhookConfiguration PodSecurityPolicy
                      StorageClass IngressClass PriorityClass ClusterIssuer PersistentVolume].freeze

  Result = Struct.new(:failures, :pending, :info)

  class Validator
    attr_reader :result

    def initialize(mode:)
      raise ArgumentError, "unknown mode #{mode}" unless %w[offline release].include?(mode)

      @mode = mode
      @result = Result.new([], [], [])
    end

    def fail(gate, msg)
      @result.failures << "[#{gate}] #{msg}"
    end

    def placeholder(where, text)
      return unless text.is_a?(String) && text.match?(PLACEHOLDER)

      text.scan(PLACEHOLDER) { @result.pending << "#{where}: #{Regexp.last_match(0)}" }
      fail('placeholder', "#{where} still contains #{text.scan(PLACEHOLDER).size} placeholder(s)") if @mode == 'release'
    end

    def self.load_docs(text)
      YAML.load_stream(text).select { |d| d.is_a?(Hash) && d['kind'] }
    end

    def id(doc)
      "#{doc['kind']}/#{doc.dig('metadata', 'name')}"
    end

    def pod_spec(doc)
      doc.dig('spec', 'template', 'spec') || doc.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
    end

    def containers(doc)
      spec = pod_spec(doc)
      return [] unless spec

      (spec['initContainers'] || []) + (spec['containers'] || [])
    end

    # G1: only namespaced, allow-listed kinds, all in be293.
    def check_scope(docs, allow_ingress: false)
      docs.each do |d|
        kind = d['kind']
        fail('scope', "#{id(d)} is cluster-scoped") if CLUSTER_SCOPED.include?(kind) || kind.start_with?('Cluster')
        allowed = ALLOWED_KINDS + (allow_ingress ? ['Ingress'] : [])
        fail('scope', "#{id(d)} kind not allowed") unless allowed.include?(kind)
        ns = d.dig('metadata', 'namespace')
        fail('scope', "#{id(d)} namespace #{ns.inspect} != #{NAMESPACE}") unless ns.nil? || ns == NAMESPACE
        @result.info << "#{id(d)} has no namespace (Helm assigns release namespace)" if ns.nil?
      end
    end

    # G2: only the two Portal migration Jobs may be hooks, and only post-install/post-upgrade.
    def check_hooks(docs)
      docs.each do |d|
        hook = d.dig('metadata', 'annotations', 'helm.sh/hook')
        next unless hook

        name = d.dig('metadata', 'name').to_s
        allowed = d['kind'] == 'Job' && ALLOWED_HOOK_JOBS.any? { |j| name == "#{RELEASE}-#{j}" }
        fail('hooks', "#{id(d)} is a Helm hook (#{hook}) but not an approved migration Job") unless allowed
        phases = hook.split(',').map(&:strip)
        bad = phases - ALLOWED_HOOK_PHASES
        fail('hooks', "#{id(d)} uses hook phase(s) #{bad.join(',')}") unless bad.empty?
        @result.info << "hook #{id(d)} #{hook}" if allowed
      end
    end

    # G3: every database connection string targets the release-local PostgreSQL Service.
    def check_database_targets(docs)
      services = docs.select { |d| d['kind'] == 'Service' }.map { |d| d.dig('metadata', 'name') }.to_set
      expected = "#{RELEASE}-postgresql"
      fail('database', "release-local Service #{expected} not rendered") unless services.include?(expected)
      found = 0
      each_env(docs) do |doc, _c, env|
        name = env['name'].to_s
        value = env['value']
        next unless value.is_a?(String)

        if name.start_with?('CONNECTIONSTRINGS__')
          found += 1
          server = value[/(?:Server|Host)=([^;]+)/i, 1]
          if server.nil?
            fail('database', "#{id(doc)} #{name} has no Server= part")
          elsif server != expected
            fail('database', "#{id(doc)} #{name} targets #{server.inspect}, expected #{expected}")
          end
          fail('database', "#{id(doc)} #{name} embeds a literal password") if value.match?(/Password=(?!\$\()/i)
        elsif value.match?(/:5432\b/) && !value.include?(expected)
          fail('database', "#{id(doc)} #{name} references port 5432 outside the release database")
        end
      end
      fail('database', 'no CONNECTIONSTRINGS__* found; migrations target cannot be verified') if found.zero?
      migrations = docs.select { |d| d['kind'] == 'Job' && d.dig('metadata', 'annotations', 'helm.sh/hook') }
      migrations.each do |job|
        targets = containers(job).flat_map { |c| (c['env'] || []).select { |e| e['name'].to_s.start_with?('CONNECTIONSTRINGS__') } }
        fail('database', "#{id(job)} hook Job has no connection string") if targets.empty?
      end
    end

    # G4: images are digest-pinned, listed in images.lock and never from forbidden sources.
    def check_images(docs, lock)
      allowed = Set.new
      forbidden = []
      if lock
        registry = lock['registry'].to_s
        (lock['rebuilt'] || []).each { |i| allowed << "#{registry}/#{i['image']}:#{i['tag']}@sha256:#{i['digest']}" }
        (lock['upstream'] || []).each do |i|
          allowed << "#{i['image']}:#{i['tag']}@#{i['digest']}"
          allowed << "#{i['image']}@#{i['digest']}"
        end
        forbidden = lock['forbidden'] || []
      end
      docs.each do |d|
        containers(d).each do |c|
          image = c['image'].to_s
          where = "#{id(d)} container #{c['name']}"
          fail('images', "#{where} image is not digest-pinned: #{image}") unless image.match?(DIGEST)
          fail('images', "#{where} uses a floating tag: #{image}") if image.match?(/:latest(@|\z)/)
          forbidden.each { |f| fail('images', "#{where} uses forbidden source #{f.inspect}") if image.include?(f) }
          fail('images', "#{where} image not in images.lock: #{image}") if lock && !allowed.include?(image)
          placeholder(where, image)
        end
      end
    end

    # G5: shared-service configuration surface.
    def check_shared_service_config(docs, allow_ingress: false)
      each_env(docs) do |doc, _c, env|
        name = env['name'].to_s
        if env.key?('value') && name.match?(SECRET_ENV_NAME) && !NON_SECRET_FILLERS.include?(env['value'].to_s)
          fail('secrets', "#{id(doc)} #{name} is set inline; secret-bearing variables must use valueFrom")
        end
        value = env['value']
        next unless value.is_a?(String)

        check_text("#{id(doc)} env #{name}", value)
        if value.match?(SHARED_NS_HOST) && !SHARED_SERVICE_ENV_ALLOWLIST.include?(name)
          fail('shared-services', "#{id(doc)} #{name} points at release26-09 but is not in the approved integration allowlist")
        end
        @result.info << "shared: #{name} -> #{value}" if value.match?(SHARED_NS_HOST)
        @result.info << "disabled: #{name}" if value.include?('.disabled.invalid')
      end
      docs.select { |d| d['kind'] == 'ConfigMap' }.each do |cm|
        (cm['data'] || {}).each { |k, v| check_text("#{id(cm)} data #{k}", v.to_s) }
      end
      docs.select { |d| d['kind'] == 'Ingress' }.each do |ing|
        fail('ingress', "#{id(ing)} rendered while Ingress is not approved") unless allow_ingress
        (ing.dig('spec', 'rules') || []).each do |r|
          fail('ingress', "#{id(ing)} host #{r['host']} belongs to another owner") if FORBIDDEN_HOSTS.include?(r['host'])
        end
      end
    end

# R-BPDM: Gate and Pool base addresses carry the API version, one version everywhere.
def check_bpdm(docs)
  versions = []
  seen = 0
  each_env(docs) do |doc, _c, env|
    value = env['value']
    kind = BPDM_ENV[env['name'].to_s]
    if kind.nil?
      fail('bpdm', "#{id(doc)} #{env['name']} points at BPDM but is not a reviewed BPDM address") if value.to_s.start_with?(BPDM_HOST)
      next
    end
    seen += 1
    m = value.to_s.match(BPDM_URL)
    next fail('bpdm', "#{id(doc)} #{env['name']}=#{value.inspect} is not #{BPDM_HOST}/#{kind}/v<N>") unless m && m[1] == kind

    versions << m[2]
  end
  fail('bpdm', 'no BPDM address rendered') if seen.zero?
  fail('bpdm', "BPDM API versions differ: #{versions.uniq.sort.inspect}") if versions.uniq.size > 1
  @result.info << "bpdm: api #{versions.first} (#{seen} addresses)" if versions.uniq.size == 1
end

    # G6: security context aligned with the repository's Kyverno policies.
    def check_security_context(docs)
      docs.each do |d|
        pod = pod_spec(d) || {}
        pod_ctx = pod['securityContext'] || {}
        containers(d).each do |c|
          ctx = c['securityContext'] || {}
          where = "#{id(d)} container #{c['name']}"
          non_root = ctx.key?('runAsNonRoot') ? ctx['runAsNonRoot'] : pod_ctx['runAsNonRoot']
          fail('security-context', "#{where} does not set runAsNonRoot=true") unless non_root == true
          fail('security-context', "#{where} allows privilege escalation") unless ctx['allowPrivilegeEscalation'] == false
        end
      end
    end

    # G7: values file must not carry credentials.
    def check_values(values, path = [])
      case values
      when Hash
        values.each do |k, v|
          key_path = path + [k.to_s]
          if k.to_s.match?(SECRET_VALUE_KEY) && v.is_a?(String) && !v.empty? && !k.to_s.match?(/address\z/i)
            fail('values', "#{key_path.join('.')} carries an inline credential")
          end
          check_values(v, key_path)
        end
      when Array
        values.each_with_index { |v, i| check_values(v, path + [i.to_s]) }
      end
    end

    # G8: NetworkPolicies stay in be293 and never open the database port outside the namespace.
    def check_network_policies(docs)
      fail('networkpolicy', 'no NetworkPolicy provided') if docs.empty?
      names = docs.map { |d| d.dig('metadata', 'name') }
      fail('networkpolicy', 'default-deny policy missing') unless docs.any? { |d| d.dig('spec', 'podSelector') == {} && %w[Ingress Egress].all? { |t| (d.dig('spec', 'policyTypes') || []).include?(t) } && !d['spec'].key?('ingress') && !d['spec'].key?('egress') }
      docs.each do |d|
        fail('networkpolicy', "#{id(d)} kind #{d['kind']}") unless d['kind'] == 'NetworkPolicy'
        ns = d.dig('metadata', 'namespace')
        fail('networkpolicy', "#{id(d)} namespace #{ns.inspect}") unless ns == NAMESPACE
        (d.dig('spec', 'egress') || []).each do |rule|
          (rule['to'] || []).each do |peer|
            cidr = peer.dig('ipBlock', 'cidr').to_s
            fail('networkpolicy', "#{id(d)} egress to #{cidr}") if %w[0.0.0.0/0 ::/0].include?(cidr)
            placeholder("#{id(d)} ipBlock", cidr)
            ns_sel = peer.dig('namespaceSelector', 'matchLabels', 'kubernetes.io/metadata.name')
            ports = (rule['ports'] || []).map { |p| p['port'] }
            if ns_sel && ports.include?(5432)
              fail('networkpolicy', "#{id(d)} opens TCP 5432 towards namespace #{ns_sel}")
            end
            ports.each { |p| placeholder("#{id(d)} port", p.to_s) }
            (peer.dig('podSelector', 'matchLabels') || {}).each_value { |v| placeholder("#{id(d)} selector", v.to_s) }
            placeholder("#{id(d)} namespaceSelector", ns_sel.to_s) if ns_sel
          end
        end
        (d.dig('spec', 'ingress') || []).each do |rule|
          (rule['from'] || []).each do |peer|
            ns_sel = peer.dig('namespaceSelector', 'matchLabels', 'kubernetes.io/metadata.name')
            placeholder("#{id(d)} namespaceSelector", ns_sel.to_s) if ns_sel
          end
        end
      end
      @result.info << "networkpolicies: #{names.join(', ')}"
    end

    # G9: cross-namespace targets agree with the confirmed release26-09 inventory (alpha-service-map.yaml).
    # Env URLs must use a confirmed Service name and Service port; NetworkPolicies select pods and must
    # use the resolved container port. Services marked public-only must not be addressed in-cluster.
    def check_service_map(docs, np_docs, service_map)
      services = service_map.fetch('services')
      suffix = ".#{service_map.fetch('dnsSuffix')}"
      each_env(docs) do |doc, _c, env|
        value = env['value']
        next unless value.is_a?(String)

        value.scan(%r{(https?)://([^/:"\s]+)#{Regexp.escape(suffix)}(?::(\d+))?}) do |scheme, host, port|
          next if host.match?(PLACEHOLDER) && host.match?(/\A<<ALPHA:[A-Z0-9_]+>>\z/)

          where = "#{id(doc)} #{env['name']}"
          entry = services[host]
          if entry.nil?
            fail('service-map', "#{where} targets #{host}, which is not in the confirmed release26-09 inventory")
            next
          end
          if entry.key?('portalUse') && !entry.key?('podSelector')
            fail('service-map', "#{where} addresses #{host} in-cluster, but it is #{entry['portalUse']}")
            next
          end
          effective = port ? port.to_i : (scheme == 'https' ? 443 : 80)
          service_ports = entry['ports'].values.map { |p| p['service'] }
          next if service_ports.include?(effective)

          container_ports = entry['ports'].values.map { |p| p['container'] }.compact
          hint = container_ports.include?(effective) ? ' (that is a container port; Services are addressed by Service port)' : ''
          fail('service-map', "#{where} uses #{host}:#{effective}, not a Service port of #{host}#{hint}")
        end
      end

      np_docs.each do |np|
        (np.dig('spec', 'egress') || []).each do |rule|
          (rule['to'] || []).each do |peer|
            next unless peer.dig('namespaceSelector', 'matchLabels', 'kubernetes.io/metadata.name') == service_map['namespace']

            instance = peer.dig('podSelector', 'matchLabels', 'app.kubernetes.io/instance')
            where = "#{id(np)} egress to #{instance.inspect}"
            if instance.nil?
              fail('service-map', "#{id(np)} allows egress to all pods of #{service_map['namespace']}; select a confirmed instance")
              next
            end
            candidates = if instance.match?(PLACEHOLDER)
                           services.values.select { |s| s['podSelector'] }
                         else
                           services.values.select { |s| s.dig('podSelector', 'app.kubernetes.io/instance') == instance }
                         end
            if candidates.empty?
              fail('service-map', "#{where} does not match a confirmed pod selector")
              next
            end
            container_ports = candidates.flat_map { |s| s['ports'].values.map { |p| p['container'] } }.compact
            service_ports = candidates.flat_map { |s| s['ports'].values.map { |p| p['service'] } }
            (rule['ports'] || []).each do |p|
              port = p['port']
              next if port.is_a?(String) && port.match?(PLACEHOLDER)

              next if container_ports.include?(port)

              hint = service_ports.include?(port) ? ' (Service port; NetworkPolicy needs the container port)' : ''
              fail('service-map', "#{where} port #{port} is not a resolved container port#{hint}")
            end
          end
        end
      end
    end

    # G10: every secretKeyRef / envFrom secretRef / imagePullSecret in the render points at a Secret and key
    # declared in secrets-contract.yaml (catches typos that would only surface as CreateContainerConfigError).
    def check_secret_refs(docs, contract)
      declared = {}
      (contract['secrets'] || []).each { |s| declared[s['name']] = (s['keys'] || {}).keys }
      docs.each do |d|
        spec = pod_spec(d) || {}
        (spec['imagePullSecrets'] || []).each do |p|
          fail('secret-refs', "#{id(d)} imagePullSecret #{p['name']} not declared") unless declared.key?(p['name'])
        end
        containers(d).each do |c|
          (c['env'] || []).each do |e|
            ref = e.dig('valueFrom', 'secretKeyRef')
            next unless ref

            name = ref['name']
            key = ref['key']
            if !declared.key?(name)
              fail('secret-refs', "#{id(d)} #{e['name']} -> Secret #{name} not declared")
            elsif !declared[name].include?(key)
              fail('secret-refs', "#{id(d)} #{e['name']} -> key #{key} not declared for Secret #{name}")
            end
          end
          (c['envFrom'] || []).each do |ef|
            name = ef.dig('secretRef', 'name')
            fail('secret-refs', "#{id(d)} envFrom Secret #{name} not declared") if name && !declared.key?(name)
          end
        end
      end
    end

    def check_inventory(docs, expected)
      actual = docs.map { |d| id(d) }.sort
      missing = expected - actual
      extra = actual - expected
      fail('inventory', "missing objects: #{missing.join(', ')}") unless missing.empty?
      fail('inventory', "unexpected objects: #{extra.join(', ')}") unless extra.empty?
    end

    private

    def check_text(where, text)
      FORBIDDEN_HOSTS.each { |h| fail('shared-services', "#{where} references #{h} (old Portal)") if text.match?(%r{(//|\A)#{Regexp.escape(h)}([:/]|\z)}) }
      FORBIDDEN_HOST_PATTERNS.each { |p| fail('shared-services', "#{where} matches forbidden pattern #{p.source}") if text.match?(p) }
      placeholder(where, text)
    end

    def each_env(docs)
      docs.each do |d|
        containers(d).each do |c|
          (c['env'] || []).each { |e| yield d, c, e }
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  opts = { mode: 'offline' }
  OptionParser.new do |o|
    o.on('--render FILE') { |v| opts[:render] = v }
    o.on('--networkpolicies FILE') { |v| opts[:np] = v }
    o.on('--values FILE') { |v| opts[:values] = v }
    o.on('--images-lock FILE') { |v| opts[:lock] = v }
    o.on('--expected-inventory FILE') { |v| opts[:inventory] = v }
    o.on('--service-map FILE') { |v| opts[:service_map] = v }
    o.on('--secrets-contract FILE') { |v| opts[:contract] = v }
    o.on('--mode MODE') { |v| opts[:mode] = v }
    o.on('--allow-ingress') { opts[:ingress] = true }
  end.parse!
  abort('usage: --render FILE is required') unless opts[:render]

  begin
    v = PortalRenderGates::Validator.new(mode: opts[:mode])
    docs = PortalRenderGates::Validator.load_docs(File.read(opts[:render]))
    abort('render contains no Kubernetes objects') if docs.empty?
    v.check_scope(docs, allow_ingress: opts[:ingress])
    v.check_hooks(docs)
    v.check_database_targets(docs)
    v.check_images(docs, opts[:lock] && YAML.safe_load(File.read(opts[:lock])))
    v.check_shared_service_config(docs, allow_ingress: opts[:ingress])
    v.check_bpdm(docs)
    v.check_security_context(docs)
    v.check_values(YAML.safe_load(File.read(opts[:values]))) if opts[:values]
    np_docs = opts[:np] ? PortalRenderGates::Validator.load_docs(File.read(opts[:np])) : []
    if opts[:np]
      v.check_scope(np_docs)
      v.check_network_policies(np_docs)
    end
    v.check_service_map(docs, np_docs, YAML.safe_load(File.read(opts[:service_map]))) if opts[:service_map]
    v.check_secret_refs(docs, YAML.safe_load(File.read(opts[:contract]))) if opts[:contract]
    if opts[:inventory]
      expected = File.readlines(opts[:inventory]).map(&:strip).reject { |l| l.empty? || l.start_with?('#') }.sort
      v.check_inventory(docs, expected)
    end
  rescue Psych::Exception, Errno::ENOENT => e
    warn "input error: #{e.message}"
    exit 2
  end

  r = v.result
  puts "objects=#{docs.size} mode=#{opts[:mode]}"
  puts "pending placeholders=#{r.pending.size} (#{r.pending.map { |p| p[/<<[^>]+>>/] }.uniq.size} unique)"
  r.pending.map { |p| p[/<<[^>]+>>/] }.uniq.sort.each { |p| puts "  pending #{p}" }
  r.failures.each { |f| puts "FAIL #{f}" }
  puts(r.failures.empty? ? 'RESULT PASS' : "RESULT FAIL (#{r.failures.size})")
  exit(r.failures.empty? ? 0 : 1)
end
