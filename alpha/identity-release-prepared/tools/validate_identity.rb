# frozen_string_literal: true

# Offline gates for the own identity stack in be293 (tools/render-identity.sh feeds it the renders). Reads files only.
#
#   I1  every rendered object (Helm test hooks excluded) is namespaced in be293 or unnamespaced-but-namespaced-kind;
#       no cluster-scoped kind; no Secret object (every credential comes from an existing Secret)
#   I2  no subchart of the official charts renders (bundled postgres/vault/pgadmin4 stay disabled)
#   I3  no credential in a ConfigMap or a literal env value: every sensitive config key carries only a placeholder and is
#       overridden by an `env` entry of the same name from a secretKeyRef
#   I4  images: official repositories only; pinned by sha256 digest (release mode: no open <<PIN:…>> placeholder)
#   I5  Vault: integrated Raft storage, never dev mode / inmem, PVC on premium-perf1-stackit, PVC retained, no Ingress
#   I6  PostgreSQL: persistence on premium-perf1-stackit, PVC retained
#   I7  Ingress: only issuer-be293 / identityhub-be293, class nginx, letsencrypt-prod, external-dns hostname = host, TLS,
#       public paths only (no admin, identity, STS or management path)
#   I8  nothing refers to release26-09 or to the shared identity hosts
#   I9  seed: Role = PATCH on three named Secrets only (no pods/log, exec, wildcard, list, create); pinned image;
#       script never runs `set -x` or reads pod logs
#   I10 NetworkPolicies: be293 only; Vault and PostgreSQL admit only the three applications; the ingress controller
#       reaches only public ports
#   I11 Portal overlay: IdentityHub/BDRS settings point only at be293; keys from the new Secrets; BPDM token address still
#       the shared CentralIDP; images and CronJob suspension identical to the four-file render
#
# Usage: ruby tools/validate_identity.rb --renders DIR [--mode release] --networkpolicies F --seed F --seed-job F
#                                        --portal-before F --portal-after F

require 'optparse'
require 'yaml'

module IdentityGates
  NAMESPACE = 'be293'
  RELEASES = %w[identity-vault identity-postgresql issuerservice identityhub bdrs].freeze
  CLUSTER_KINDS = %w[ClusterRole ClusterRoleBinding CustomResourceDefinition Namespace PersistentVolume
                     MutatingWebhookConfiguration ValidatingWebhookConfiguration PriorityClass StorageClass].freeze
  IMAGE_REPOS = %r{\A(docker\.io/)?(tractusx/(issuerservice|identityhub|bdrs-server)|hashicorp/vault|bitnamilegacy/postgresql|alpine/k8s)[:@]}.freeze
  DIGEST = /@sha256:\h{64}\z/.freeze
  SENSITIVE = /(password|token|secret|api\.key)\z/i.freeze
  PLACEHOLDERS = ['from-secret-ref', 'unused', ''].freeze
  STORAGE_CLASS = 'premium-perf1-stackit'
  INGRESS = { 'issuerservice' => { host: 'issuer-be293.test.tractus-x.com', paths: %w[/ /api/issuance /statuslist] },
              'identityhub' => { host: 'identityhub-be293.test.tractus-x.com', paths: %w[/ /api/credentials] } }.freeze
  FORBIDDEN = /release26-09|identity-hub-0\d\.|issuer-service\.test\.tractus-x\.com|bdrs-server\.release26-09/.freeze
  PRIVATE_PORTS = [8200, 5432, 8086, 8087, 8085, 8081].freeze

  class Validator
    attr_reader :failures, :notes

    def initialize(mode: 'offline')
      @mode = mode
      @failures = []
      @notes = []
    end

    def fail(gate, msg)
      @failures << "[#{gate}] #{msg}"
    end

    def self.load(text)
      YAML.load_stream(text).compact.select { |d| d.is_a?(Hash) && d['kind'] }
    end

    def test_hook?(d)
      d.dig('metadata', 'annotations', 'helm.sh/hook').to_s.include?('test')
    end

    def pod_spec(d)
      d.dig('spec', 'jobTemplate', 'spec', 'template', 'spec') || d.dig('spec', 'template', 'spec')
    end

    def containers(d)
      s = pod_spec(d) || {}
      (s['containers'] || []) + (s['initContainers'] || [])
    end

    def ref(d)
      "#{d['kind']}/#{d.dig('metadata', 'name')}"
    end

    # renders: {release => [docs]}
    def check_renders(renders)
      renders.each do |rel, docs|
        docs.reject { |d| test_hook?(d) }.each do |d|
          ns = d.dig('metadata', 'namespace')
          fail('I1', "#{rel} #{ref(d)} namespace #{ns.inspect}") unless ns.nil? || ns == NAMESPACE
          fail('I1', "#{rel} #{ref(d)} is cluster-scoped") if CLUSTER_KINDS.include?(d['kind'])
          fail('I1', "#{rel} #{ref(d)} renders a Secret") if d['kind'] == 'Secret'
          chart = d.dig('metadata', 'labels', 'helm.sh/chart').to_s
          fail('I2', "#{rel} #{ref(d)} comes from a bundled subchart (#{chart})") if %w[issuerservice identityhub bdrs].include?(rel) && chart.match?(/\A(postgres|vault|pgadmin4)-/)
          containers(d).each { |c| check_image(rel, d, c['image'].to_s) }
          fail('I8', "#{rel} #{ref(d)} refers to the shared identity stack") if YAML.dump(d).match?(FORBIDDEN)
        end
        check_secrets_in_config(rel, docs.reject { |d| test_hook?(d) })
      end
      check_vault(renders.fetch('identity-vault', []))
      check_postgresql(renders.fetch('identity-postgresql', []))
      check_ingresses(renders)
      self
    end

    def check_image(rel, doc, image)
      fail('I4', "#{rel} #{ref(doc)} image #{image} is not an approved official repository") unless image.match?(IMAGE_REPOS)
      if image.include?('<<PIN:')
        @mode == 'release' ? fail('I4', "#{rel} #{ref(doc)} image digest not pinned yet: #{image}") : (@notes << "#{rel}: digest pending (#{image[/<<PIN:[^>]+>>/]})")
      elsif !image.match?(DIGEST)
        fail('I4', "#{rel} #{ref(doc)} image #{image} is not pinned by digest")
      end
    end

    def check_secrets_in_config(rel, docs)
      overrides = docs.flat_map { |d| containers(d) }.flat_map { |c| c['env'] || [] }
      docs.each do |d|
        containers(d).flat_map { |c| c['env'] || [] }.each do |e|
          next unless e['name'].to_s.match?(SENSITIVE) || e['name'].to_s.match?(/PASSWORD|TOKEN\z|SECRET\z|API_?KEY\z/)
          next if e.key?('valueFrom') || PLACEHOLDERS.include?(e['value'].to_s) || e['name'].to_s.end_with?('ALIAS')
          fail('I3', "#{rel} #{ref(d)} env #{e['name']} has a literal value")
        end
        next unless d['kind'] == 'ConfigMap'

        (d['data'] || {}).each do |k, v|
          next unless k.match?(SENSITIVE)

          unless PLACEHOLDERS.include?(v.to_s)
            fail('I3', "#{rel} ConfigMap/#{d.dig('metadata', 'name')} key #{k} carries a value, not a placeholder")
            next
          end
          next unless v == 'from-secret-ref'

          o = overrides.find { |e| e['name'] == k }
          fail('I3', "#{rel} #{k} has no env override from a Secret") unless o&.dig('valueFrom', 'secretKeyRef')
        end
      end
    end

    def check_vault(docs)
      sts = docs.find { |d| d['kind'] == 'StatefulSet' }
      return fail('I5', 'Vault StatefulSet not rendered') unless sts

      cfg = docs.select { |d| d['kind'] == 'ConfigMap' }.flat_map { |d| (d['data'] || {}).values }.join("\n")
      fail('I5', 'Vault storage is not integrated Raft') unless cfg.include?('storage "raft"')
      fail('I5', 'Vault config mentions inmem') if cfg.include?('inmem')
      env = containers(sts).flat_map { |c| c['env'] || [] }.map { |e| e['name'] }
      args = containers(sts).flat_map { |c| (c['args'] || []) + (c['command'] || []) }.join(' ')
      fail('I5', 'Vault runs in dev mode') if env.include?('VAULT_DEV_ROOT_TOKEN_ID') || args.include?('-dev')
      check_pvc('I5', 'Vault', sts)
      fail('I5', 'Vault has an Ingress') if docs.any? { |d| d['kind'] == 'Ingress' }
    end

    def check_postgresql(docs)
      sts = docs.find { |d| d['kind'] == 'StatefulSet' }
      return fail('I6', 'PostgreSQL StatefulSet not rendered') unless sts

      check_pvc('I6', 'PostgreSQL', sts)
    end

    def check_pvc(gate, what, sts)
      vcts = sts.dig('spec', 'volumeClaimTemplates') || []
      fail(gate, "#{what} has no volumeClaimTemplate") if vcts.empty?
      vcts.each { |v| fail(gate, "#{what} PVC storageClass #{v.dig('spec', 'storageClassName').inspect}") unless v.dig('spec', 'storageClassName') == STORAGE_CLASS }
      pol = sts.dig('spec', 'persistentVolumeClaimRetentionPolicy') || {}
      fail(gate, "#{what} PVC retention is not Retain/Retain") unless pol['whenDeleted'] == 'Retain' && pol['whenScaled'] == 'Retain'
    end

    def check_ingresses(renders)
      renders.each do |rel, docs|
        docs.select { |d| d['kind'] == 'Ingress' }.each do |ing|
          want = INGRESS[rel]
          next fail('I7', "#{rel} must not have an Ingress (#{ref(ing)})") unless want

          a = ing.dig('metadata', 'annotations') || {}
          hosts = (ing.dig('spec', 'rules') || []).map { |r| r['host'] }
          fail('I7', "#{rel} Ingress hosts #{hosts.inspect}") unless hosts == [want[:host]]
          fail('I7', "#{rel} Ingress class #{ing.dig('spec', 'ingressClassName').inspect}") unless ing.dig('spec', 'ingressClassName') == 'nginx'
          fail('I7', "#{rel} Ingress cluster-issuer") unless a['cert-manager.io/cluster-issuer'] == 'letsencrypt-prod'
          fail('I7', "#{rel} Ingress external-dns hostname") unless a['external-dns.alpha.kubernetes.io/hostname'] == want[:host]
          fail('I7', "#{rel} Ingress TLS") unless (ing.dig('spec', 'tls') || []).flat_map { |t| t['hosts'] } == [want[:host]]
          paths = (ing.dig('spec', 'rules') || []).flat_map { |r| r.dig('http', 'paths') || [] }.map { |p| p['path'] }
          fail('I7', "#{rel} Ingress paths #{paths.sort.inspect} != #{want[:paths].sort.inspect}") unless paths.sort == want[:paths].sort
        end
        fail('I7', "#{rel} public Ingress missing") if INGRESS.key?(rel) && docs.none? { |d| d['kind'] == 'Ingress' }
      end
    end

    def check_seed(rbac_docs, job_docs)
      role = rbac_docs.find { |d| d['kind'] == 'Role' }
      return fail('I9', 'seed Role missing') unless role

      rules = role['rules'] || []
      ok = rules.size == 1 && rules[0]['resources'] == ['secrets'] && rules[0]['verbs'] == ['patch'] &&
           (rules[0]['resourceNames'] || []).sort == %w[be293-identityhub-superuser be293-issuerservice-superuser be293-portal-identityhub-be293]
      fail('I9', "seed Role is not PATCH-only on the three named Secrets: #{rules.inspect}") unless ok
      text = YAML.dump(rbac_docs + job_docs)
      fail('I9', 'seed grants pods/log or exec') if text.match?(%r{pods/log|pods/exec})
      fail('I9', 'seed RBAC uses a wildcard') if rules.any? { |r| (r['verbs'].to_a + r['resources'].to_a + r['apiGroups'].to_a).include?('*') }
      script = rbac_docs.find { |d| d['kind'] == 'ConfigMap' }&.dig('data', 'seed.sh').to_s
      fail('I9', 'seed script missing') if script.empty?
      fail('I9', 'seed script enables xtrace') if script.match?(/^\s*set\s+-[a-z]*x/)
      fail('I9', 'seed script reads pod logs') if script.match?(/kubectl\s+logs|\/log\b/)
      (rbac_docs + job_docs).each { |d| fail('I1', "seed #{ref(d)} namespace") unless d.dig('metadata', 'namespace') == NAMESPACE }
      job_docs.each { |d| containers(d).each { |c| check_image('seed', d, c['image'].to_s) } }
      self
    end

    def check_networkpolicies(docs)
      docs.each do |np|
        name = np.dig('metadata', 'name')
        fail('I10', "#{name} namespace") unless np.dig('metadata', 'namespace') == NAMESPACE
        (np.dig('spec', 'ingress') || []).each do |rule|
          from_ingress = (rule['from'] || []).any? { |f| f.dig('namespaceSelector', 'matchLabels', 'kubernetes.io/metadata.name') == 'ingress-nginx' }
          ports = (rule['ports'] || []).map { |p| p['port'] }
          fail('I10', "#{name} opens private port(s) #{(ports & PRIVATE_PORTS).inspect} to the ingress controller") if from_ingress && (ports & PRIVATE_PORTS).any?
          fail('I10', "#{name} admits another namespace") if (rule['from'] || []).any? { |f| f['namespaceSelector'] && !from_ingress }
        end
      end
      %w[be293-identity-vault be293-identity-postgresql].each do |inst|
        np = docs.find { |d| d.dig('spec', 'podSelector', 'matchLabels', 'app.kubernetes.io/instance') == inst }
        next fail('I10', "no NetworkPolicy for #{inst}") unless np

        froms = (np.dig('spec', 'ingress') || []).flat_map { |r| r['from'] || [] }
        allowed = froms.map { |f| f.dig('podSelector', 'matchLabels', 'app.kubernetes.io/instance').to_s }
        fail('I10', "#{inst} admits #{allowed.inspect}") unless allowed.sort == %w[be293-bdrs be293-identityhub be293-issuerservice]
      end
      # Egress exceptions to the namespace default-deny: only the seed pod, only one /32 address, only TCP 443.
      docs.select { |d| (d.dig('spec', 'egress') || []).any? }.each do |np|
        name = np.dig('metadata', 'name')
        fail('I10', "#{name} egress does not select only the seed pod") unless np.dig('spec', 'podSelector') == { 'matchLabels' => { 'app.kubernetes.io/name' => 'be293-identity-seed' } }
        np.dig('spec', 'egress').each do |rule|
          to = rule['to'] || []
          fail('I10', "#{name} egress allows more than one /32 address") unless !to.empty? && to.all? { |t| t.keys == ['ipBlock'] && t.dig('ipBlock', 'cidr').to_s.end_with?('/32') && !t['ipBlock'].key?('except') }
          fail('I10', "#{name} egress allows more than TCP 443") unless rule['ports'] == [{ 'protocol' => 'TCP', 'port' => 443 }]
        end
      end
      # The seed job waits on /api/check/readiness (8081) through the Service; kubelet probes bypass NetworkPolicy, it does not.
      %w[be293-issuerservice be293-identityhub].each do |inst|
        np = docs.find { |d| d.dig('spec', 'podSelector', 'matchLabels', 'app.kubernetes.io/instance') == inst }
        next fail('I10', "no NetworkPolicy for #{inst}") unless np

        in_ns = (np.dig('spec', 'ingress') || []).select { |r| (r['from'] || []).include?('podSelector' => {}) }
        fail('I10', "#{inst} readiness port 8081 not open inside be293 (seed job)") unless in_ns.any? { |r| (r['ports'] || []).any? { |p| p['port'] == 8081 } }
      end
      self
    end

    def env_map(docs)
      docs.each_with_object({}) do |d, h|
        containers(d).flat_map { |c| c['env'] || [] }.each { |e| (h[d.dig('metadata', 'name')] ||= {})[e['name']] = e }
      end
    end

    def check_portal(before, after)
      env = env_map(after)
      seen = 0
      env.each do |wl, vars|
        vars.each do |n, e|
          next unless n.start_with?('APPLICATIONCHECKLIST__IDENTITYHUB__', 'BPNDIDRESOLVER__')

          seen += 1
          fail('I11', "#{wl} #{n} still points at the shared identity stack") if e['value'].to_s.match?(FORBIDDEN)
          r = e.dig('valueFrom', 'secretKeyRef')
          fail('I11', "#{wl} #{n} key from #{r['name']}") if r && !r['name'].end_with?('-be293')
        end
        bpdm = vars['APPLICATIONCHECKLIST__BPDM__TOKENADDRESS']&.dig('value')
        fail('I11', "#{wl} BPDM token address #{bpdm.inspect} is not the shared CentralIDP") if bpdm && !bpdm.start_with?('https://centralidp.test.tractus-x.com/')
      end
      fail('I11', 'no IdentityHub/BDRS settings rendered') if seen.zero?
      img = ->(docs) { docs.flat_map { |d| containers(d).map { |c| "#{ref(d)} #{c['image']}" } }.sort }
      fail('I11', 'Portal images differ from the four-file render') unless img.call(before) == img.call(after)
      susp = ->(docs) { docs.select { |d| d['kind'] == 'CronJob' }.to_h { |d| [d.dig('metadata', 'name'), d.dig('spec', 'suspend')] } }
      fail('I11', "CronJob suspension differs: #{susp.call(after).inspect}") unless susp.call(before) == susp.call(after)
      self
    end
  end
end

if $PROGRAM_NAME == __FILE__
  o = { mode: 'offline' }
  OptionParser.new do |p|
    p.on('--renders DIR') { |v| o[:renders] = v }
    p.on('--mode MODE') { |v| o[:mode] = v }
    p.on('--networkpolicies F') { |v| o[:np] = v }
    p.on('--seed F') { |v| o[:seed] = v }
    p.on('--seed-job F') { |v| o[:job] = v }
    p.on('--portal-before F') { |v| o[:before] = v }
    p.on('--portal-after F') { |v| o[:after] = v }
  end.parse!
  abort('usage: see header') unless o.values_at(:renders, :np, :seed, :job, :before, :after).all?
  v = IdentityGates::Validator.new(mode: o[:mode])
  renders = IdentityGates::RELEASES.to_h { |r| [r, IdentityGates::Validator.load(File.read(File.join(o[:renders], "#{r}.yaml")))] }
  v.check_renders(renders)
  v.check_seed(IdentityGates::Validator.load(File.read(o[:seed])), IdentityGates::Validator.load(File.read(o[:job])))
  v.check_networkpolicies(IdentityGates::Validator.load(File.read(o[:np])))
  v.check_portal(IdentityGates::Validator.load(File.read(o[:before])), IdentityGates::Validator.load(File.read(o[:after])))
  v.notes.uniq.each { |n| puts "NOTE #{n}" }
  v.failures.each { |f| puts "FAIL #{f}" }
  puts(v.failures.empty? ? "IDENTITY RESULT PASS (mode #{o[:mode]})" : "IDENTITY RESULT FAIL (#{v.failures.size})")
  exit(v.failures.empty? ? 0 : 1)
end
