# frozen_string_literal: true

# Offline gates for the two hand-deployed E2E test connectors in be293 (tools/render-edc.sh feeds it the renders). Reads
# files only.
#
#   E1  every rendered object (Helm test hooks excluded) is namespaced in be293; no cluster-scoped kind; no Secret, no
#       Ingress; nothing refers to release26-09 or the shared identity hosts
#   E2  no bundled subchart (vault, postgres) of the connector chart renders
#   E3  every sensitive env value comes from a secretKeyRef: the four connector credentials by name and Secret, and any other
#       *PASSWORD/*TOKEN/*SECRET/*API(_)KEY/*AUTH_KEY env; no env name occurs twice in a container (no literal duplicate
#       left next to a secretKeyRef); no ConfigMap key or value carries a credential or the placeholder
#   E4  images: official repositories only, pinned by sha256 digest (release mode: no open <<PIN:...>> placeholder)
#   E5  DCP/STS as proven in PR #2: no DIV URL; OAuth STS at IdentityHub 8087; client_id = participant id = the DID;
#       secret alias edc-wallet-secret; context id = plain participant id; credential service in-cluster on 8083 with that
#       id; only our issuer trusted; BDRS in be293; did:web over HTTPS not disabled; own Vault mount per connector
#   E6  PostgreSQL: persistence on premium-perf1-stackit, PVC retained, no literal password in the init SQL
#   E7  NetworkPolicies: be293 only, ingress only, pod selectors only (no namespaceSelector, no ipBlock); the management API
#       (8081 on a control plane), the consumer proxy (8186) and metrics (9090) are opened to no pod; IdentityHub only
#       8083/8087, Vault only 8200, PostgreSQL only 5432, all from the four connector pods; data source only from the
#       provider data plane
#   E8  provider objects (the active set; v1 contract objects are kept in the file for rollback only): access policy uses only
#       Membership and BusinessPartnerNumber (both, BPN = the consumer); contract policy uses only Membership,
#       FrameworkAgreement (eq, exactly DataExchangeGovernance:1.0) and UsagePurpose (isAnyOf), never BusinessPartnerNumber
#       (tractusx-edc 0.13.0 UsagePolicyValidator / PolicyValidationConstants); the contract definition links the two; the
#       asset reads the be293 data source; the data source runs non-root on a read-only root filesystem
#
# Usage: ruby tools/validate_edc.rb --renders DIR [--mode release] --networkpolicies F --datasource F --objects F

require 'digest'
require 'json'
require 'optparse'
require 'yaml'

module EdcGates
  NAMESPACE = 'be293'
  ISSUER = 'did:web:issuer-be293.test.tractus-x.com:BPNL00000003CRHK'
  IH = 'http://be293-identityhub.be293.svc.cluster.local'
  CONNECTORS = {
    'edc-fv1' => { bpn: 'BPNL000000000FV1', pid: 'bpnl000000000fv1', role: :provider },
    'edc-guc' => { bpn: 'BPNL000000000GUC', pid: 'bpnl000000000guc', role: :consumer }
  }.freeze
  POD_INSTANCES = CONNECTORS.keys.flat_map { |c| %W[be293-#{c}-controlplane be293-#{c}-dataplane] }.freeze
  CLUSTER_KINDS = %w[ClusterRole ClusterRoleBinding CustomResourceDefinition Namespace PersistentVolume
                     MutatingWebhookConfiguration ValidatingWebhookConfiguration PriorityClass StorageClass].freeze
  IMAGE_REPOS = %r{\A(docker\.io/)?(tractusx/edc-controlplane-postgresql-hashicorp-vault|tractusx/edc-dataplane-hashicorp-vault|
                   bitnamilegacy/postgresql|nginxinc/nginx-unprivileged)[:@]}x.freeze
  DIGEST = /@sha256:\h{64}\z/.freeze
  SENSITIVE_ENV = /(PASSWORD|TOKEN|SECRET|APIKEY|API_KEY|AUTH_KEY|ACCESS_KEY|ACCESS_KEY_ID)\z/.freeze
  REQUIRED_SECRET_ENV = {
    'controlplane' => { 'WEB_HTTP_MANAGEMENT_AUTH_KEY' => ['%s-auth', 'management-api-key'],
                        'EDC_VAULT_HASHICORP_TOKEN' => ['%s-vault-token', 'token'],
                        'EDC_DATASOURCE_DEFAULT_PASSWORD' => ['be293-edc-db-users', '%s_DB_PASSWORD'] },
    'dataplane' => { 'TX_EDC_DPF_CONSUMER_PROXY_AUTH_APIKEY' => ['%s-auth', 'proxy-api-key'],
                     'EDC_VAULT_HASHICORP_TOKEN' => ['%s-vault-token', 'token'],
                     'EDC_DATASOURCE_DEFAULT_PASSWORD' => ['be293-edc-db-users', '%s_DB_PASSWORD'] }
  }.freeze
  FORBIDDEN = /release26-09|identity-hub-0\d\.|issuer-service\.test\.tractus-x\.com|bdrs-server\.release26-09/.freeze
  CLOSED_PORTS = { 'controlplane' => [8081, 9090], 'dataplane' => [8186, 9090] }.freeze
  STORAGE_CLASS = 'premium-perf1-stackit'
  ACCESS_OPERANDS = %w[Membership BusinessPartnerNumber].freeze
  CONTRACT_OPERANDS = %w[Membership FrameworkAgreement UsagePurpose].freeze
  FRAMEWORK_AGREEMENT = 'DataExchangeGovernance:1.0'
  # the objects the provider runs with; contractPolicy/contractDefinition (v1) stay in the file for rollback only
  ACTIVE_CONTRACT_POLICY = 'contractPolicyV2'
  ACTIVE_CONTRACT_DEFINITION = 'contractDefinitionV2'

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
      d.dig('spec', 'template', 'spec')
    end

    def containers(d)
      s = pod_spec(d) || {}
      (s['containers'] || []) + (s['initContainers'] || [])
    end

    def ref(d)
      "#{d['kind']}/#{d.dig('metadata', 'name')}"
    end

    def env_of(doc)
      (containers(doc).first || {})['env'] || []
    end

    def value(env, name)
      env.find { |e| e['name'] == name }&.fetch('value', nil)
    end

    # renders: {release => [docs]} with releases edc-fv1, edc-guc, edc-postgresql
    def check_renders(renders)
      renders.each do |rel, docs|
        docs.reject { |d| test_hook?(d) }.each do |d|
          ns = d.dig('metadata', 'namespace')
          fail('E1', "#{rel} #{ref(d)} namespace #{ns.inspect}") unless ns.nil? || ns == NAMESPACE
          fail('E1', "#{rel} #{ref(d)} is cluster-scoped") if CLUSTER_KINDS.include?(d['kind'])
          fail('E1', "#{rel} #{ref(d)} renders a #{d['kind']}") if %w[Secret Ingress].include?(d['kind'])
          fail('E1', "#{rel} #{ref(d)} refers to the shared identity stack") if YAML.dump(d).match?(FORBIDDEN)
          chart = d.dig('metadata', 'labels', 'helm.sh/chart').to_s
          fail('E2', "#{rel} #{ref(d)} comes from a bundled subchart (#{chart})") if CONNECTORS.key?(rel) && chart.match?(/\A(postgres|vault)-/)
          containers(d).each { |c| check_image(rel, d, c['image'].to_s) }
        end
        check_credentials(rel, docs.reject { |d| test_hook?(d) })
      end
      CONNECTORS.each { |name, c| check_dcp(name, c, renders.fetch(name, [])) }
      check_postgresql(renders.fetch('edc-postgresql', []))
      self
    end

    def check_image(rel, doc, image)
      fail('E4', "#{rel} #{ref(doc)} image #{image} is not an approved official repository") unless image.match?(IMAGE_REPOS)
      if image.include?('<<PIN:')
        @mode == 'release' ? fail('E4', "#{rel} #{ref(doc)} image digest not pinned yet: #{image}") : (@notes << "#{rel}: digest pending (#{image[/<<PIN:[^>]+>>/]})")
      elsif !image.match?(DIGEST)
        fail('E4', "#{rel} #{ref(doc)} image #{image} is not pinned by digest")
      end
    end

    def check_credentials(rel, docs)
      docs.each do |d|
        containers(d).each do |c|
          names = (c['env'] || []).map { |e| e['name'] }
          names.group_by(&:itself).each { |n, v| fail('E3', "#{rel} #{ref(d)} env #{n} occurs #{v.size} times") if v.size > 1 }
          (c['env'] || []).each do |e|
            next unless e['name'].to_s.match?(SENSITIVE_ENV)
            next if e.dig('valueFrom', 'secretKeyRef', 'name')

            fail('E3', "#{rel} #{ref(d)} env #{e['name']} is not read from a secretKeyRef")
          end
        end
        if d['kind'] == 'ConfigMap'
          (d['data'] || {}).each do |k, v|
            fail('E3', "#{rel} #{ref(d)} key #{k} looks like a credential") if k.match?(/password|token|secret|api.?key/i) && !k.end_with?('.sql')
            fail('E3', "#{rel} #{ref(d)} key #{k} carries the from-secret-ref placeholder") if v.to_s.include?('from-secret-ref')
          end
        end
      end
      return unless CONNECTORS.key?(rel)

      REQUIRED_SECRET_ENV.each do |plane, expected|
        dep = docs.find { |d| d['kind'] == 'Deployment' && d.dig('metadata', 'name') == "be293-#{rel}-#{plane}" }
        next fail('E3', "#{rel}: no #{plane} Deployment") unless dep

        expected.each do |name, (secret, key)|
          e = env_of(dep).find { |x| x['name'] == name }
          want = [format(secret, "be293-#{rel}"), format(key, rel.sub('edc-', 'EDC_').upcase)]
          got = [e&.dig('valueFrom', 'secretKeyRef', 'name'), e&.dig('valueFrom', 'secretKeyRef', 'key')]
          fail('E3', "#{rel} #{plane} #{name}: expected secretKeyRef #{want.join('/')}, got #{e ? (got.compact.empty? ? 'a literal' : got.join('/')) : 'nothing'}") unless got == want
        end
      end
    end

    def check_dcp(name, c, docs)
      did = "did:web:identityhub-be293.test.tractus-x.com:#{c[:bpn]}"
      cs = "#{IH}:8083/api/credentials/v1/participants/#{c[:pid]}"
      %w[controlplane dataplane].each do |plane|
        dep = docs.find { |d| d['kind'] == 'Deployment' && d.dig('metadata', 'name') == "be293-#{name}-#{plane}" }
        next fail('E5', "#{name}: no #{plane} Deployment") unless dep

        env = env_of(dep)
        expect = {
          'EDC_PARTICIPANT_ID' => did, 'EDC_IAM_ISSUER_ID' => did, 'EDC_PARTICIPANT_CONTEXT_ID' => c[:pid],
          'EDC_IAM_STS_OAUTH_TOKEN_URL' => "#{IH}:8087/api/sts/token", 'EDC_IAM_STS_OAUTH_CLIENT_ID' => did,
          'EDC_IAM_STS_OAUTH_CLIENT_SECRET_ALIAS' => 'edc-wallet-secret', 'TX_EDC_IAM_DCP_CREDENTIALSERVICE_URL' => cs,
          'EDC_VAULT_HASHICORP_URL' => 'http://be293-identity-vault.be293.svc.cluster.local:8200',
          'EDC_VAULT_HASHICORP_API_SECRET_PATH' => "/v1/#{name}"
        }
        expect['TX_EDC_IAM_DCP_BDRS_SERVER_URL'] = 'http://be293-bdrs.be293.svc.cluster.local:8082/api/directory' if plane == 'controlplane'
        expect.each { |k, v| fail('E5', "#{name} #{plane} #{k} = #{value(env, k).inspect}, expected #{v.inspect}") unless value(env, k) == v }
        fail('E5', "#{name} #{plane} sets a DIV URL (the proven setup has none)") if env.any? { |e| e['name'].to_s.include?('DIV') }
        fail('E5', "#{name} #{plane} disables did:web over HTTPS") if value(env, 'EDC_IAM_DID_WEB_USE_HTTPS').to_s == 'false'
        issuers = env.select { |e| e['name'].to_s.match?(/\AEDC_IAM_TRUSTED-ISSUER_\d+-ISSUER_ID\z/) }.map { |e| e['value'] }
        fail('E5', "#{name} #{plane} trusted issuers #{issuers.inspect}, expected only #{ISSUER}") if plane == 'controlplane' && issuers != [ISSUER]
      end
    end

    def check_postgresql(docs)
      sts = docs.find { |d| d['kind'] == 'StatefulSet' }
      return fail('E6', 'no PostgreSQL StatefulSet') unless sts

      vct = (sts.dig('spec', 'volumeClaimTemplates') || []).first || {}
      fail('E6', "PostgreSQL storageClass #{vct.dig('spec', 'storageClassName').inspect}") unless vct.dig('spec', 'storageClassName') == STORAGE_CLASS
      fail('E6', 'PostgreSQL PVC not retained') unless sts.dig('spec', 'persistentVolumeClaimRetentionPolicy', 'whenDeleted') == 'Retain'
      sql = docs.select { |d| d['kind'] == 'ConfigMap' }.flat_map { |d| (d['data'] || {}).values }.join("\n")
      fail('E6', 'init SQL sets a literal password') if sql.match?(/PASSWORD\s+'/i)
      fail('E6', 'init SQL does not create both connector databases') unless %w[edc_fv1 edc_guc].all? { |db| sql.include?("CREATE DATABASE #{db} OWNER #{db}") }
    end

    def from_instances(rule)
      (rule['from'] || []).map { |f| f.dig('podSelector', 'matchLabels', 'app.kubernetes.io/instance').to_s }
    end

    def check_networkpolicies(docs)
      docs.each do |np|
        name = np.dig('metadata', 'name')
        fail('E7', "#{name} namespace") unless np.dig('metadata', 'namespace') == NAMESPACE
        fail('E7', "#{name} is not ingress-only") unless np.dig('spec', 'policyTypes') == ['Ingress'] && !np['spec'].key?('egress')
        sel = np.dig('spec', 'podSelector', 'matchLabels') || {}
        fail('E7', "#{name} selects every pod") if sel.empty?
        (np.dig('spec', 'ingress') || []).each do |rule|
          (rule['from'] || []).each do |f|
            fail('E7', "#{name} admits by #{(f.keys - ['podSelector']).join(',')}") unless f.keys == ['podSelector']
            fail('E7', "#{name} has an empty podSelector") if (f.dig('podSelector', 'matchLabels') || {}).empty?
          end
          fail('E7', "#{name} has a rule without from") if (rule['from'] || []).empty?
          inst = sel['app.kubernetes.io/instance'].to_s
          plane = inst[/-(controlplane|dataplane)\z/, 1]
          ports = (rule['ports'] || []).map { |p| p['port'] }
          fail('E7', "#{name} opens #{(ports & CLOSED_PORTS[plane]).inspect} (port-forward only)") if plane && (ports & CLOSED_PORTS[plane]).any?
          unknown = from_instances(rule) - POD_INSTANCES
          fail('E7', "#{name} admits pods outside the four connector pods: #{unknown.inspect}") unless unknown.empty?
        end
      end
      { 'be293-identityhub' => [8083, 8087], 'be293-identity-vault' => [8200], 'be293-edc-postgresql' => [5432] }.each do |inst, want|
        np = docs.find { |d| d.dig('spec', 'podSelector', 'matchLabels', 'app.kubernetes.io/instance') == inst }
        next fail('E7', "no connector NetworkPolicy for #{inst}") unless np

        rules = np.dig('spec', 'ingress') || []
        ports = rules.flat_map { |r| (r['ports'] || []).map { |p| p['port'] } }.sort
        fail('E7', "#{inst} opens #{ports.inspect}, expected #{want.inspect}") unless ports == want
        fail('E7', "#{inst} does not admit exactly the four connector pods") unless rules.all? { |r| from_instances(r).sort == POD_INSTANCES.sort }
      end
      ds = docs.find { |d| d.dig('spec', 'podSelector', 'matchLabels', 'app.kubernetes.io/name') == 'be293-edc-datasource' }
      if ds.nil?
        fail('E7', 'no NetworkPolicy for the data source')
      elsif (ds.dig('spec', 'ingress') || []).flat_map { |r| from_instances(r) } != ['be293-edc-fv1-dataplane']
        fail('E7', 'the data source admits more than the provider data plane')
      end
      self
    end

    def check_datasource(docs)
      docs.each do |d|
        fail('E1', "data source #{ref(d)} namespace") unless d.dig('metadata', 'namespace') == NAMESPACE
        fail('E1', "data source renders a #{d['kind']}") if %w[Secret Ingress].include?(d['kind'])
        containers(d).each { |c| check_image('edc-datasource', d, c['image'].to_s) }
      end
      dep = docs.find { |d| d['kind'] == 'Deployment' }
      return fail('E8', 'no data source Deployment') unless dep

      c = containers(dep).first || {}
      fail('E8', 'data source does not run as non-root') unless pod_spec(dep).dig('securityContext', 'runAsNonRoot') == true
      fail('E8', 'data source root filesystem is writable') unless c.dig('securityContext', 'readOnlyRootFilesystem') == true
      fail('E8', 'data source mounts a ServiceAccount token') unless pod_spec(dep)['automountServiceAccountToken'] == false
      payload = docs.find { |d| d['kind'] == 'ConfigMap' }&.dig('data', 'payload.json')
      return fail('E8', 'data source has no payload.json') if payload.to_s.empty?

      @notes << "payload.json: #{payload.bytesize} bytes, sha256 #{Digest::SHA256.hexdigest(payload)} (the fetched bytes must match)"
      self
    end

    def operands(node, acc = [])
      case node
      when Hash then node.each { |k, v| k == 'leftOperand' ? acc << v : operands(v, acc) }
      when Array then node.each { |v| operands(v, acc) }
      end
      acc
    end

    # every atomic constraint ({leftOperand, operator, rightOperand}) anywhere in a policy
    def constraints(node, acc = [])
      case node
      when Hash then node.key?('leftOperand') ? acc << node : node.each_value { |v| constraints(v, acc) }
      when Array then node.each { |v| constraints(v, acc) }
      end
      acc
    end

    def check_objects(objects)
      access = objects.dig('accessPolicy', 'policy')
      ops = operands(access)
      fail('E8', "accessPolicy uses #{(ops - ACCESS_OPERANDS).uniq.inspect} (only #{ACCESS_OPERANDS.join(', ')})") unless (ops - ACCESS_OPERANDS).empty?
      fail('E8', 'accessPolicy has no Membership constraint') unless ops.include?('Membership')
      bpn = constraints(access).find { |c| c['leftOperand'] == 'BusinessPartnerNumber' }
      fail('E8', "access policy BPN #{bpn&.dig('rightOperand').inspect}, expected [\"BPNL000000000GUC\"]") unless bpn&.dig('rightOperand') == ['BPNL000000000GUC']

      contract = objects.dig(ACTIVE_CONTRACT_POLICY, 'policy')
      return fail('E8', "no #{ACTIVE_CONTRACT_POLICY}") unless contract

      cs = constraints(contract)
      ops = cs.map { |c| c['leftOperand'] }
      fail('E8', "#{ACTIVE_CONTRACT_POLICY} uses #{(ops - CONTRACT_OPERANDS).uniq.inspect} (only #{CONTRACT_OPERANDS.join(', ')})") unless (ops - CONTRACT_OPERANDS).empty?
      fail('E8', "#{ACTIVE_CONTRACT_POLICY} has no Membership constraint") unless ops.include?('Membership')
      fa = cs.select { |c| c['leftOperand'] == 'FrameworkAgreement' }
      unless fa.size == 1 && fa[0]['operator'] == 'eq' && fa[0]['rightOperand'] == FRAMEWORK_AGREEMENT
        fail('E8', "#{ACTIVE_CONTRACT_POLICY} needs exactly one FrameworkAgreement eq #{FRAMEWORK_AGREEMENT.inspect}, got #{fa.map { |c| [c['operator'], c['rightOperand']] }.inspect}")
      end
      up = cs.select { |c| c['leftOperand'] == 'UsagePurpose' }
      fail('E8', "#{ACTIVE_CONTRACT_POLICY} needs a UsagePurpose constraint (required by the connector's usage-policy validator)") if up.empty?
      up.reject { |c| c['operator'] == 'isAnyOf' }.each { |c| fail('E8', "#{ACTIVE_CONTRACT_POLICY} UsagePurpose operator #{c['operator'].inspect}, only isAnyOf is accepted") }

      url = objects.dig('asset', 'dataAddress', 'baseUrl')
      fail('E8', "asset baseUrl #{url.inspect}") unless url == 'http://be293-edc-datasource.be293.svc.cluster.local:8080/payload.json'
      cd = objects[ACTIVE_CONTRACT_DEFINITION] || {}
      fail('E8', "#{ACTIVE_CONTRACT_DEFINITION} does not link accessPolicy and #{ACTIVE_CONTRACT_POLICY}") unless cd['accessPolicyId'] == objects.dig('accessPolicy', '@id') && cd['contractPolicyId'] == objects.dig(ACTIVE_CONTRACT_POLICY, '@id')
      fail('E8', "#{ACTIVE_CONTRACT_DEFINITION} does not select the asset") unless cd.dig('assetsSelector', 0, 'operandRight') == objects.dig('asset', '@id')
      self
    end
  end

  def self.main(argv)
    opts = { mode: 'offline' }
    OptionParser.new do |o|
      o.on('--renders DIR') { |v| opts[:renders] = v }
      o.on('--mode MODE') { |v| opts[:mode] = v }
      o.on('--networkpolicies F') { |v| opts[:np] = v }
      o.on('--datasource F') { |v| opts[:ds] = v }
      o.on('--objects F') { |v| opts[:objects] = v }
    end.parse!(argv)
    renders = Dir[File.join(opts.fetch(:renders), '*.yaml')].to_h { |f| [File.basename(f, '.yaml'), Validator.load(File.read(f))] }
    v = Validator.new(mode: opts[:mode])
    v.check_renders(renders).check_networkpolicies(Validator.load(File.read(opts.fetch(:np))))
     .check_datasource(Validator.load(File.read(opts.fetch(:ds)))).check_objects(JSON.parse(File.read(opts.fetch(:objects))))
    v.notes.uniq.each { |n| puts "NOTE #{n}" }
    if v.failures.empty?
      puts "EDC RESULT PASS (mode #{opts[:mode]})"
      0
    else
      v.failures.each { |f| puts "FAIL #{f}" }
      puts "EDC RESULT FAIL (#{v.failures.size})"
      1
    end
  end
end

exit(EdcGates.main(ARGV)) if $PROGRAM_NAME == __FILE__
