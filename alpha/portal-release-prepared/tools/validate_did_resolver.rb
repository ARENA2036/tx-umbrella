# frozen_string_literal: true

# Offline gate for the self-hosted did:web resolver (did-resolver-be293.alpha.yaml) and, with --render /
# --networkpolicies, for the Portal side of the path. Reads files only.
#
#   DR1  every object in be293; exactly ConfigMap, Deployment, Service and two NetworkPolicies (no Ingress)
#   DR2  Service is ClusterIP, exposes only 8080 -> gateway port; no nodePort/externalIPs/loadBalancer
#   DR3  images pinned by sha256 digest: uport/uni-resolver-driver-did-uport 5.0.8, nginx-unprivileged 1.28.0-alpine
#   DR4  gateway: GET only; accepts the Portal's percent-encoded did:web of the IdentityHub; rejects other DID
#        methods, other domains and every other path; forwards the decoded DID to the driver on 127.0.0.1:8081
#   DR5  non-root, read-only root FS, no capabilities, no privilege escalation, no host namespaces/ports, no SA
#        token, RuntimeDefault seccomp (both containers)
#   DR6  one replica; CPU/memory requests and memory limits on both containers; readiness probes
#   DR7  ingress NetworkPolicy: resolver pods, Ingress only, from be293 pods only, gateway port only
#   DR8  egress NetworkPolicy: resolver pods, Egress only, cluster DNS + TCP 443 to a /32 or ingress-nginx only
#   DR9  (--render) processes-worker resolves DIDs through the in-namespace resolver Service (IdentityHub + DIM)
#   DR10 (--networkpolicies) the release policies still allow be293 pods -> be293 pods (worker -> resolver)
#   DR11 (--render) the Helm release renders no object with the same kind and name as a resolver object, so Helm
#        never takes over (or deletes) the separately managed resolver
#
# Usage: ruby tools/validate_did_resolver.rb --manifest did-resolver-be293.alpha.yaml
#                                            [--render RENDER.yaml] [--networkpolicies NP.yaml]

require 'optparse'
require 'yaml'

module DidResolverGates
  NAMESPACE = 'be293'
  NAME = 'be293-did-resolver'
  PORT = 8080
  DRIVER_PORT = 8081
  URL = "http://#{NAME}.#{NAMESPACE}.svc.cluster.local:#{PORT}/"
  WORKER = 'be293-portal-processes-worker'
  RESOLVER_ENVS = %w[APPLICATIONCHECKLIST__IDENTITYHUB__UNIVERSALRESOLVERADDRESS APPLICATIONCHECKLIST__DIM__UNIVERSALRESOLVERADDRESS].freeze
  IMAGES = {
    'driver' => %r{\Adocker\.io/uport/uni-resolver-driver-did-uport:5\.0\.8@sha256:\h{64}\z},
    'gateway' => %r{\Adocker\.io/nginxinc/nginx-unprivileged:1\.28\.0-alpine@sha256:\h{64}\z}
  }.freeze
  KINDS = { 'ConfigMap' => 1, 'Deployment' => 1, 'Service' => 1, 'NetworkPolicy' => 2 }.freeze
  # The DID of the application being onboarded, exactly as the Portal sends it (Uri.EscapeDataString).
  SAMPLE_DID = 'did:web:identity-hub-01.test.tractus-x.com:BPNL000000000342'
  ACCEPT = [SAMPLE_DID, 'did:web:identity-hub-02.test.tractus-x.com:BPNL000000000001'].freeze
  REJECT = ['did:ethr:0x3b0BC51Ab9De1e5B7B6E34E5b960285805C41736', 'did:web:evil.example.com:x',
            'did:web:identity-hub-01.test.tractus-x.com.evil.example.com:x', 'did:web:test.tractus-x.com.evil.com',
            'did:peer:2.Ez6LS', 'did:web:identity-hub-01.test.tractus-x.com:a/../../health',
            'did:web:IDENTITY-HUB-01.test.tractus-x.com:x'].freeze

  # Percent-encodes like .NET Uri.EscapeDataString (RFC 3986 unreserved characters stay literal).
  def self.escape_data_string(s)
    s.bytes.map { |b| b.chr.match?(/[A-Za-z0-9\-._~]/) ? b.chr : format('%%%02X', b) }.join
  end

  # nginx matches locations against the decoded URI.
  def self.decode(s)
    s.gsub(/%(\h\h)/) { Regexp.last_match(1).hex.chr }
  end

  class Validator
    attr_reader :failures

    def initialize
      @failures = []
    end

    def fail(gate, msg)
      @failures << "[#{gate}] #{msg}"
    end

    def check(docs, render: nil, policies: nil)
      docs.each do |d|
        fail('DR1', "#{d['kind']}/#{d.dig('metadata', 'name')} namespace #{d.dig('metadata', 'namespace').inspect}") unless d.dig('metadata', 'namespace') == NAMESPACE
        fail('DR1', "unexpected kind #{d['kind']}") unless KINDS.key?(d['kind'])
      end
      KINDS.each { |k, n| fail('DR1', "#{n} #{k} expected, found #{find(docs, k).size}") unless find(docs, k).size == n }
      return self unless @failures.empty?

      dep = find(docs, 'Deployment').first
      pod = dep.dig('spec', 'template', 'spec') || {}
      containers = (pod['containers'] || []).to_h { |c| [c['name'], c] }
      fail('DR1', "containers #{containers.keys.inspect} (expected gateway and driver)") unless containers.keys.sort == %w[driver gateway]
      return self unless @failures.empty?

      gw_port = port_of(containers['gateway'], 'http')
      check_service(find(docs, 'Service').first, dep, gw_port)
      containers.each { |name, c| fail('DR3', "#{name} image #{c['image'].inspect} not pinned by digest (run tools/did-resolver-be293.sh --pin)") unless c['image'].to_s.match?(IMAGES[name]) }
      check_gateway(find(docs, 'ConfigMap').first, pod, containers['gateway'])
      check_security(pod, containers)
      check_sizing(dep, containers)
      ingress_np, egress_np = find(docs, 'NetworkPolicy').partition { |np| np.dig('spec', 'policyTypes') == ['Ingress'] }
      check_ingress_policy(ingress_np.first, dep, gw_port)
      check_egress_policy(egress_np.first, dep)
      check_render(render) if render
      check_ownership(docs, render) if render
      check_release_policies(policies) if policies
      self
    end

    private

    def find(docs, kind)
      docs.select { |d| d['kind'] == kind }
    end

    def port_of(container, name)
      (container['ports'] || []).find { |p| p['name'] == name }&.fetch('containerPort', nil)
    end

    def selects?(np, dep)
      sel = np.dig('spec', 'podSelector', 'matchLabels') || {}
      tpl = dep.dig('spec', 'template', 'metadata', 'labels') || {}
      !sel.empty? && sel.all? { |k, v| tpl[k] == v }
    end

    def check_service(svc, dep, gw_port)
      spec = svc['spec'] || {}
      fail('DR2', "Service name #{svc.dig('metadata', 'name')} != #{NAME}") unless svc.dig('metadata', 'name') == NAME
      fail('DR2', "Service type #{spec['type'].inspect} (must be ClusterIP)") unless spec['type'] == 'ClusterIP'
      %w[externalIPs loadBalancerIP loadBalancerSourceRanges externalName].each { |k| fail('DR2', "Service sets #{k}") if spec.key?(k) }
      ports = spec['ports'] || []
      fail('DR2', "Service ports #{ports.map { |p| p['port'] }.inspect} (only #{PORT})") unless ports.size == 1 && ports[0]['port'] == PORT
      fail('DR2', 'Service port sets nodePort') if ports.any? { |p| p.key?('nodePort') }
      target = ports[0] && ports[0]['targetPort']
      fail('DR2', "Service targets #{target.inspect}, not the gateway port") unless target == 'http' || target == gw_port
      fail('DR2', "gateway must listen on #{PORT}, found #{gw_port.inspect}") unless gw_port == PORT
      tpl = dep.dig('spec', 'template', 'metadata', 'labels') || {}
      sel = spec['selector'] || {}
      fail('DR2', 'Service selector does not match the resolver pods') if sel.empty? || !sel.all? { |k, v| tpl[k] == v }
    end

    def check_gateway(cm, pod, gw)
      conf = cm.dig('data', 'nginx.conf').to_s
      vol = (pod['volumes'] || []).find { |v| v.dig('configMap', 'name') == cm.dig('metadata', 'name') }
      mount = vol && (gw['volumeMounts'] || []).find { |m| m['name'] == vol['name'] }
      fail('DR4', 'gateway does not mount the ConfigMap as /etc/nginx/nginx.conf') unless mount && mount['mountPath'] == '/etc/nginx/nginx.conf' && mount['subPath'] == 'nginx.conf'
      fail('DR4', "gateway does not listen on #{PORT}") unless conf.match?(/^\s*listen #{PORT};/)
      fail('DR4', 'default location must return 404') unless conf.match?(%r{location / \{ return 404; \}})
      passes = conf.scan(/proxy_pass\s+(\S+);/).flatten
      allowed = ["http://127.0.0.1:#{DRIVER_PORT}/1.0/identifiers/$did", "http://127.0.0.1:#{DRIVER_PORT}/health"]
      fail('DR4', "unexpected proxy_pass targets #{(passes - allowed).inspect}") unless (passes - allowed).empty? && passes.include?(allowed.first)
      fail('DR4', 'every location that proxies must be limited to GET') unless conf.scan(/limit_except GET \{ deny all; \}/).size == passes.size
      re = identifiers_regex(conf)
      return fail('DR4', 'no identifiers location regex found') unless re

      ACCEPT.each do |did|
        path = DidResolverGates.decode("/1.0/identifiers/#{DidResolverGates.escape_data_string(did)}")
        m = re.match(path)
        fail('DR4', "gateway rejects #{did} as sent by the Portal (percent-encoded)") unless m && m[:did] == did
        fail('DR4', "gateway rejects the unencoded #{did}") unless re.match?("/1.0/identifiers/#{did}")
      end
      REJECT.each { |did| fail('DR4', "gateway accepts #{did}") if re.match?(DidResolverGates.decode("/1.0/identifiers/#{DidResolverGates.escape_data_string(did)}")) }
      %w[/health /info /metrics /1.0/identifiers/ /1.0/properties].each { |p| fail('DR4', "gateway forwards #{p}") if re.match?(p) }
    end

    def identifiers_regex(conf)
      src = conf[%r{location ~ "(\^/1\\\.0/identifiers/[^"]+)"}, 1]
      src && Regexp.new(src)
    rescue RegexpError
      nil
    end

    def check_security(pod, containers)
      psc = pod['securityContext'] || {}
      fail('DR5', 'pod runAsNonRoot not true') unless psc['runAsNonRoot'] == true
      fail('DR5', 'pod seccompProfile not RuntimeDefault') unless psc.dig('seccompProfile', 'type') == 'RuntimeDefault'
      fail('DR5', 'automountServiceAccountToken not false') unless pod['automountServiceAccountToken'] == false
      %w[hostNetwork hostPID hostIPC].each { |k| fail('DR5', "#{k} set") if pod[k] }
      containers.each do |name, c|
        csc = c['securityContext'] || {}
        fail('DR5', "#{name}: runAsUser must be non-zero") unless (csc['runAsUser'] || psc['runAsUser']).to_i.positive?
        fail('DR5', "#{name}: readOnlyRootFilesystem not true") unless csc['readOnlyRootFilesystem'] == true
        fail('DR5', "#{name}: allowPrivilegeEscalation not false") unless csc['allowPrivilegeEscalation'] == false
        fail('DR5', "#{name}: capabilities not drop [ALL]") unless csc.dig('capabilities', 'drop') == ['ALL'] && !csc.dig('capabilities', 'add')
        fail('DR5', "#{name}: privileged") if csc['privileged']
        fail('DR5', "#{name}: hostPort set") if (c['ports'] || []).any? { |p| p.key?('hostPort') }
      end
    end

    def check_sizing(dep, containers)
      fail('DR6', 'replicas must be 1') unless dep.dig('spec', 'replicas') == 1
      containers.each do |name, c|
        r = c['resources'] || {}
        fail('DR6', "#{name}: cpu and memory requests required") unless r.dig('requests', 'cpu') && r.dig('requests', 'memory')
        fail('DR6', "#{name}: memory limit required") unless r.dig('limits', 'memory')
        fail('DR6', "#{name}: readinessProbe required") unless c['readinessProbe']
      end
    end

    def check_ingress_policy(np, dep, gw_port)
      return fail('DR7', 'no Ingress-only NetworkPolicy') unless np

      fail('DR7', 'ingress NetworkPolicy does not select the resolver pods') unless selects?(np, dep)
      rules = np.dig('spec', 'ingress') || []
      fail('DR7', "exactly one ingress rule expected, found #{rules.size}") unless rules.size == 1
      r = rules.first || {}
      fail('DR7', 'ingress source must be podSelector {} only (be293 pods)') unless r['from'] == [{ 'podSelector' => {} }]
      fail('DR7', "ingress ports #{r['ports'].inspect} (only TCP #{gw_port})") unless r['ports'] == [{ 'protocol' => 'TCP', 'port' => gw_port }]
    end

    def check_egress_policy(np, dep)
      return fail('DR8', 'no Egress-only NetworkPolicy') unless np && np.dig('spec', 'policyTypes') == ['Egress']

      fail('DR8', 'egress NetworkPolicy does not select the resolver pods') unless selects?(np, dep)
      (np.dig('spec', 'egress') || []).each_with_index do |rule, i|
        to = rule['to'] || []
        ports = (rule['ports'] || []).map { |p| [p['protocol'], p['port']] }
        fail('DR8', "rule #{i} has no destination (would allow any)") if to.empty?
        fail('DR8', "rule #{i} has no ports (would allow any)") if ports.empty?
        to.each do |peer|
          if (cidr = peer.dig('ipBlock', 'cidr'))
            fail('DR8', "rule #{i}: ipBlock #{cidr} is not a single /32") unless cidr.match?(%r{\A\d{1,3}(\.\d{1,3}){3}/32\z})
            fail('DR8', "rule #{i}: ipBlock #{cidr} only for TCP 443") unless ports == [['TCP', 443]]
          elsif peer.dig('namespaceSelector', 'matchLabels', 'kubernetes.io/metadata.name') == 'kube-system'
            fail('DR8', "rule #{i}: kube-system only for kube-dns") unless peer.dig('podSelector', 'matchLabels', 'k8s-app') == 'kube-dns'
            fail('DR8', "rule #{i}: DNS ports only") unless ports.all? { |_, p| [53, 8053].include?(p) }
          elsif peer.dig('namespaceSelector', 'matchLabels', 'kubernetes.io/metadata.name') == 'ingress-nginx'
            fail('DR8', "rule #{i}: ingress-nginx only for TCP 443") unless ports == [['TCP', 443]]
          else
            fail('DR8', "rule #{i}: destination #{peer.inspect} not allowed")
          end
        end
      end
    end

    def env_of(doc)
      spec = doc.dig('spec', 'jobTemplate', 'spec', 'template', 'spec') || doc.dig('spec', 'template', 'spec') || {}
      (spec['containers'] || []).flat_map { |c| c['env'] || [] }.to_h { |e| [e['name'], e['value']] }
    end

    def check_render(render)
      worker = render.find { |d| d['kind'] == 'CronJob' && d.dig('metadata', 'name') == WORKER }
      return fail('DR9', "#{WORKER} not rendered") unless worker

      env = env_of(worker)
      RESOLVER_ENVS.each { |k| fail('DR9', "#{WORKER} #{k} #{env[k].inspect} != #{URL}") unless env[k] == URL }
      leaks = render.flat_map { |d| env_of(d).select { |_, v| v.to_s.match?(/uniresolver\.io|godiddy/) }.keys.map { |k| "#{d.dig('metadata', 'name')}/#{k}" } }
      fail('DR9', "public universal resolver still referenced: #{leaks.inspect}") unless leaks.empty?
    end

    def check_ownership(docs, render)
      ours = docs.map { |d| [d['kind'], d.dig('metadata', 'name')] }
      clash = render.map { |d| [d['kind'], d.dig('metadata', 'name')] } & ours
      return if clash.empty?

      fail('DR11', "Helm release renders resolver objects #{clash.map { |k, n| "#{k}/#{n}" }.inspect} (ownership conflict)")
    end

    def check_release_policies(policies)
      ok = policies.any? do |np|
        np.dig('metadata', 'namespace') == NAMESPACE && np.dig('spec', 'podSelector') == {} &&
          (np.dig('spec', 'policyTypes') || []).include?('Egress') &&
          (np.dig('spec', 'egress') || []).any? { |r| r['to'] == [{ 'podSelector' => {} }] && !r.key?('ports') }
      end
      fail('DR10', 'release NetworkPolicies no longer allow be293 pods -> be293 pods (worker could not reach the resolver)') unless ok
    end
  end

  def self.load(file)
    YAML.load_stream(File.read(file)).compact.select { |d| d.is_a?(Hash) && d['kind'] }
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {}
  OptionParser.new do |o|
    o.on('--manifest FILE') { |v| opts[:manifest] = v }
    o.on('--render FILE') { |v| opts[:render] = v }
    o.on('--networkpolicies FILE') { |v| opts[:policies] = v }
  end.parse!
  abort('usage: --manifest FILE [--render FILE] [--networkpolicies FILE]') unless opts[:manifest]

  begin
    docs = DidResolverGates.load(opts[:manifest])
    render = opts[:render] && DidResolverGates.load(opts[:render])
    policies = opts[:policies] && DidResolverGates.load(opts[:policies])
  rescue Psych::Exception, Errno::ENOENT => e
    warn "input error: #{e.class}"
    exit 2
  end
  v = DidResolverGates::Validator.new.check(docs, render: render, policies: policies)
  v.failures.each { |f| puts "FAIL #{f}" }
  puts(v.failures.empty? ? 'DID RESOLVER RESULT PASS' : "DID RESOLVER RESULT FAIL (#{v.failures.size})")
  exit(v.failures.empty? ? 0 : 1)
end
