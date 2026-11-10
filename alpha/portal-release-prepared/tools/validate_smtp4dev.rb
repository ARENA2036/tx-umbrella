# frozen_string_literal: true

# Offline gate for the smtp4dev test mail sink (smtp4dev-be293.alpha.yaml) and, with --render, for the Portal
# mail settings in the final release render. Reads files only.
#
#   S1 every object in be293; only PVC/Deployment/Service/NetworkPolicy (no Ingress, no Route)
#   S2 Service is ClusterIP and exposes only SMTP 25 -> smtp; no nodePort/externalIPs/loadBalancer
#   S3 image is the official rnwood/smtp4dev 3.15.0 pinned by sha256 digest (no unresolved pin)
#   S4 no relay: RelayOptions SmtpServer/AutomaticRelayExpression empty, no relay login/emails, LockSettings=true
#   S5 IMAP and POP3 disabled; web UI not exposed by the Service
#   S6 non-root, read-only root FS, no capabilities, no privilege escalation, no host network/ports, no SA token
#   S7 one replica, Recreate, mailbox database on the PVC
#   S8 NetworkPolicy: smtp4dev pods, Ingress only, from be293 pods only, SMTP container port only
#   S9 (--render) processes-worker Portal mail (MAILINGSERVICE__MAIL__*) goes to the sink Service; the shared-realm
#      SMTP of processes-worker and administration keeps the approved live Alpha configuration (decision
#      2026-11-08: smtp.office365.com:587, password only as a reference to the be293-portal-mailing Secret); the
#      office365 host appears nowhere else
#
# Usage: ruby tools/validate_smtp4dev.rb --manifest smtp4dev-be293.alpha.yaml [--render RENDER.yaml]

require 'optparse'
require 'yaml'

module Smtp4devGates
  NAMESPACE = 'be293'
  NAME = 'be293-smtp4dev'
  FQDN = "#{NAME}.#{NAMESPACE}.svc.cluster.local"
  IMAGE = %r{\Adocker\.io/rnwood/smtp4dev:3\.15\.0@sha256:\h{64}\z}.freeze
  KINDS = %w[PersistentVolumeClaim Deployment Service NetworkPolicy].freeze
  SMTP_PORT = 25
  DATA_DIR = '/smtp4dev'
  MAILING_SECRET = 'be293-portal-mailing'
  # Approved live Alpha shared-realm SMTP (non-secret settings only; decision 2026-11-08).
  SHARED_REALM = { 'PROVISIONING__SHAREDREALM__SMTPSERVER__HOST' => 'smtp.office365.com',
                   'PROVISIONING__SHAREDREALM__SMTPSERVER__PORT' => '587',
                   'PROVISIONING__SHAREDREALM__SMTPSERVER__AUTH' => 'true',
                   'PROVISIONING__SHAREDREALM__SMTPSERVER__STARTTLS' => 'true' }.freeze

  class Validator
    attr_reader :failures

    def initialize
      @failures = []
    end

    def fail(gate, msg)
      @failures << "[#{gate}] #{msg}"
    end

    def find(docs, kind)
      docs.select { |d| d['kind'] == kind }
    end

    def check(docs, render: nil)
      docs.each do |d|
        fail('S1', "#{d['kind']}/#{d.dig('metadata', 'name')} namespace #{d.dig('metadata', 'namespace').inspect}") unless d.dig('metadata', 'namespace') == NAMESPACE
        fail('S1', "unexpected kind #{d['kind']}") unless KINDS.include?(d['kind'])
      end
      KINDS.each { |k| fail('S1', "exactly one #{k} expected, found #{find(docs, k).size}") unless find(docs, k).size == 1 }
      return self unless @failures.empty?

      dep = find(docs, 'Deployment').first
      pod = dep.dig('spec', 'template', 'spec') || {}
      containers = pod['containers'] || []
      fail('S6', "exactly one container expected, found #{containers.size}") unless containers.size == 1
      c = containers.first || {}
      env = (c['env'] || []).to_h { |e| [e['name'].downcase, e['value']] }
      ports = (c['ports'] || []).to_h { |p| [p['name'], p['containerPort']] }
      check_service(find(docs, 'Service').first, ports)
      check_image(c)
      check_relay(env)
      check_protocols(env)
      check_security(pod, c)
      check_storage(dep, pod, c, env, find(docs, 'PersistentVolumeClaim').first)
      check_policy(find(docs, 'NetworkPolicy').first, dep, ports)
      check_render(render, find(docs, 'Service').first) if render
      self
    end

    private

    def check_service(svc, ports)
      spec = svc['spec'] || {}
      fail('S2', "Service type #{spec['type'].inspect} (must be ClusterIP)") unless spec['type'] == 'ClusterIP'
      %w[externalIPs loadBalancerIP loadBalancerSourceRanges externalName].each { |k| fail('S2', "Service sets #{k}") if spec.key?(k) }
      sp = spec['ports'] || []
      fail('S2', "Service ports #{sp.map { |p| p['port'] }.inspect} (only #{SMTP_PORT})") unless sp.size == 1 && sp[0]['port'] == SMTP_PORT
      fail('S2', 'Service port sets nodePort') if sp.any? { |p| p.key?('nodePort') }
      target = sp[0] && sp[0]['targetPort']
      fail('S5', "Service targets #{target.inspect}, not the smtp container port") unless target == 'smtp' || target == ports['smtp']
      svc_name = svc.dig('metadata', 'name')
      fail('S2', "Service name #{svc_name} != #{NAME}") unless svc_name == NAME
    end

    def check_image(c)
      fail('S3', "image #{c['image'].inspect} is not rnwood/smtp4dev:3.15.0 pinned by digest (run tools/smtp4dev-be293.sh --pin)") unless c['image'].to_s.match?(IMAGE)
    end

    def check_relay(env)
      %w[relayoptions__smtpserver relayoptions__automaticrelayexpression].each do |k|
        fail('S4', "#{k} must be set and empty (no relay)") unless env.key?(k) && env[k].to_s.empty?
      end
      bad = env.keys.grep(/\Arelayoptions__(login|password|automaticemails|senderaddress)/)
      fail('S4', "relay credentials/targets set: #{bad.inspect}") unless bad.empty?
      fail('S4', 'ServerOptions__LockSettings must be "true" (UI cannot enable relaying)') unless env['serveroptions__locksettings'] == 'true'
    end

    def check_protocols(env)
      %w[serveroptions__imapport serveroptions__pop3port].each do |k|
        fail('S5', "#{k} must be set and empty (disabled)") unless env.key?(k) && env[k].to_s.empty?
      end
    end

    def check_security(pod, c)
      psc = pod['securityContext'] || {}
      csc = c['securityContext'] || {}
      fail('S6', 'runAsNonRoot not true') unless psc['runAsNonRoot'] == true
      fail('S6', 'runAsUser must be non-zero') unless psc['runAsUser'].to_i.positive?
      fail('S6', 'readOnlyRootFilesystem not true') unless csc['readOnlyRootFilesystem'] == true
      fail('S6', 'allowPrivilegeEscalation not false') unless csc['allowPrivilegeEscalation'] == false
      fail('S6', 'capabilities not drop [ALL]') unless csc.dig('capabilities', 'drop') == ['ALL'] && !csc.dig('capabilities', 'add')
      fail('S6', 'automountServiceAccountToken not false') unless pod['automountServiceAccountToken'] == false
      %w[hostNetwork hostPID hostIPC].each { |k| fail('S6', "#{k} set") if pod[k] }
      fail('S6', 'hostPort set') if (c['ports'] || []).any? { |p| p.key?('hostPort') }
    end

    def check_storage(dep, pod, c, env, pvc)
      fail('S7', 'replicas must be 1') unless dep.dig('spec', 'replicas') == 1
      fail('S7', 'strategy must be Recreate (RWO volume)') unless dep.dig('spec', 'strategy', 'type') == 'Recreate'
      vol = (pod['volumes'] || []).find { |v| v.dig('persistentVolumeClaim', 'claimName') == pvc.dig('metadata', 'name') }
      mount = vol && (c['volumeMounts'] || []).find { |m| m['name'] == vol['name'] }
      fail('S7', "PVC not mounted at #{DATA_DIR}") unless mount && mount['mountPath'] == DATA_DIR
      fail('S7', "database #{env['serveroptions__database'].inspect} not on the PVC") unless env['serveroptions__database'].to_s.start_with?("#{DATA_DIR}/")
    end

    def check_policy(np, dep, ports)
      spec = np['spec'] || {}
      sel = spec.dig('podSelector', 'matchLabels') || {}
      tpl = dep.dig('spec', 'template', 'metadata', 'labels') || {}
      fail('S8', 'NetworkPolicy does not select the smtp4dev pods') if sel.empty? || !sel.all? { |k, v| tpl[k] == v }
      fail('S8', "policyTypes #{spec['policyTypes'].inspect} (Ingress only)") unless spec['policyTypes'] == ['Ingress']
      rules = spec['ingress'] || []
      fail('S8', "exactly one ingress rule expected, found #{rules.size}") unless rules.size == 1
      r = rules.first || {}
      fail('S8', 'ingress source must be podSelector {} only (be293 pods)') unless r['from'] == [{ 'podSelector' => {} }]
      fail('S8', "ingress ports #{r['ports'].inspect} (only TCP #{ports['smtp']})") unless r['ports'] == [{ 'protocol' => 'TCP', 'port' => ports['smtp'] }]
    end

    def env_of(doc)
      spec = doc.dig('spec', 'jobTemplate', 'spec', 'template', 'spec') || doc.dig('spec', 'template', 'spec') || {}
      (spec['containers'] || []).flat_map { |c| c['env'] || [] }.to_h { |e| [e['name'], e['value']] }
    end

    def secret_ref(doc, name)
      spec = doc.dig('spec', 'jobTemplate', 'spec', 'template', 'spec') || doc.dig('spec', 'template', 'spec') || {}
      e = (spec['containers'] || []).flat_map { |c| c['env'] || [] }.find { |x| x['name'] == name }
      e&.dig('valueFrom', 'secretKeyRef')
    end

    def check_render(render, svc)
      port = svc.dig('spec', 'ports', 0, 'port').to_s
      worker = render.find { |d| d['kind'] == 'CronJob' && d.dig('metadata', 'name') == 'be293-portal-processes-worker' }
      admin = render.find { |d| d['kind'] == 'Deployment' && d.dig('metadata', 'name') == 'be293-portal-administration-service' }
      return fail('S9', 'processes-worker or administration-service not rendered') unless worker && admin

      we = env_of(worker)
      fail('S9', "MAILINGSERVICE__MAIL__SMTPHOST #{we['MAILINGSERVICE__MAIL__SMTPHOST'].inspect} != #{FQDN}") unless we['MAILINGSERVICE__MAIL__SMTPHOST'] == FQDN
      fail('S9', "MAILINGSERVICE__MAIL__SMTPPORT #{we['MAILINGSERVICE__MAIL__SMTPPORT'].inspect} != #{port}") unless we['MAILINGSERVICE__MAIL__SMTPPORT'] == port
      [worker, admin].each do |d|
        e = env_of(d)
        n = d.dig('metadata', 'name')
        SHARED_REALM.each do |k, v|
          fail('S9', "#{n} #{k} #{e[k].inspect} != approved live value #{v.inspect}") unless e[k] == v
        end
        ref = secret_ref(d, 'PROVISIONING__SHAREDREALM__SMTPSERVER__PASSWORD')
        fail('S9', "#{n} shared-realm SMTP password must reference Secret #{MAILING_SECRET}, got #{ref.inspect}") unless ref && ref['name'] == MAILING_SECRET
      end
      leaks = render.flat_map do |d|
        env_of(d).select { |k, v| v.to_s.include?('office365') && k != 'PROVISIONING__SHAREDREALM__SMTPSERVER__HOST' }.keys.map { |k| "#{d['metadata']['name']}/#{k}" }
      end
      fail('S9', "real SMTP provider referenced outside the shared-realm setting: #{leaks.inspect}") unless leaks.empty?
    end
  end

  def self.load(file)
    load_string(File.read(file))
  end

  def self.load_string(text)
    YAML.load_stream(text).compact.select { |d| d.is_a?(Hash) && d['kind'] }
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {}
  OptionParser.new do |o|
    o.on('--manifest FILE') { |v| opts[:manifest] = v }
    o.on('--render FILE') { |v| opts[:render] = v }
  end.parse!
  abort('usage: --manifest FILE [--render FILE]') unless opts[:manifest]

  begin
    docs = Smtp4devGates.load(opts[:manifest])
    render = opts[:render] && Smtp4devGates.load(opts[:render])
  rescue Psych::Exception, Errno::ENOENT => e
    warn "input error: #{e.class}"
    exit 2
  end
  v = Smtp4devGates::Validator.new.check(docs, render: render)
  v.failures.each { |f| puts "FAIL #{f}" }
  puts(v.failures.empty? ? 'SMTP4DEV RESULT PASS' : "SMTP4DEV RESULT FAIL (#{v.failures.size})")
  exit(v.failures.empty? ? 0 : 1)
end
