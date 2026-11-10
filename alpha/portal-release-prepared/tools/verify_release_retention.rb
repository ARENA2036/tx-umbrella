# frozen_string_literal: true

# Verifies the retention protection of a be293-portal release manifest read from stdin, in memory only:
#   --json  stdin is `helm install ... -o json` (dry run): uses .manifest and .hooks[].name
#   --yaml  stdin is `helm get manifest` followed by `helm get hooks` (the STORED release)
# Checks: maintenance CronJob suspended; helm.sh/resource-policy: keep on postgres/keycloak/interfaces;
# postgres PVC retention Retain/Retain; hooks are exactly the two migration Jobs; marketplace/services carry
# ARENAADMINROLES equal to CATENAADMINROLES (pinned fork backend reads only the new name); administration-service
# and processes-worker carry PROVISIONING__IDPPREFIX = the BE-293-only IdP alias prefix.
# Prints verdicts only. The manifest can contain real Secret data (server-side lookup); it is never printed.

require 'json'
require 'optparse'
require 'yaml'

module ReleaseRetention
  RELEASE = 'be293-portal'
  KEEP_SECRETS = %w[postgres keycloak interfaces].map { |s| "#{RELEASE}-#{s}" }.freeze
  HOOKS = %w[portal-migrations provisioning-migrations].map { |s| "#{RELEASE}-#{s}" }.freeze
  ADMIN_ROLE_ALIASES = { "#{RELEASE}-marketplace-app-service" => 'APPMARKETPLACE', "#{RELEASE}-services-service" => 'SERVICES' }.freeze
  IDP_PREFIX = 'be293-alpha-idp-'
  IDP_PREFIX_WORKLOADS = [['Deployment', "#{RELEASE}-administration-service"], ['CronJob', "#{RELEASE}-processes-worker"]].freeze

  def self.idp_prefixes(doc)
    spec = doc.dig('spec', 'jobTemplate', 'spec', 'template', 'spec') || doc.dig('spec', 'template', 'spec') || {}
    (spec['containers'] || []).flat_map { |c| c['env'] || [] }.select { |e| e['name'].to_s.casecmp?('PROVISIONING__IDPPREFIX') }.map { |e| e['value'] }
  end

  def self.role_env(doc, prefix, kind)
    (doc.dig('spec', 'template', 'spec', 'containers') || []).flat_map { |c| c['env'] || [] }
      .select { |e| e['name'].to_s.start_with?("#{prefix}__#{kind}ADMINROLES__") }
      .map { |e| [e['name'].sub("__#{kind}ADMINROLES__", '__'), e['value']] }
  end

  def self.check(docs, hook_names)
    find = ->(k, n) { docs.find { |d| d['kind'] == k && d.dig('metadata', 'name') == n } }
    fails = []
    cj = find.call('CronJob', "#{RELEASE}-portal-maintenance")
    fails << 'maintenance CronJob missing' unless cj
    fails << 'maintenance CronJob not suspended' if cj && cj.dig('spec', 'suspend') != true
    KEEP_SECRETS.each do |n|
      s = find.call('Secret', n)
      fails << "#{n} missing" unless s
      fails << "#{n} lacks helm.sh/resource-policy: keep" if s && s.dig('metadata', 'annotations', 'helm.sh/resource-policy') != 'keep'
    end
    sts = find.call('StatefulSet', "#{RELEASE}-postgresql")
    pol = (sts && sts.dig('spec', 'persistentVolumeClaimRetentionPolicy')) || {}
    fails << 'postgres PVC retention not Retain/Retain' unless pol['whenDeleted'] == 'Retain' && pol['whenScaled'] == 'Retain'
    ADMIN_ROLE_ALIASES.each do |n, prefix|
      d = find.call('Deployment', n)
      next fails << "#{n} missing" unless d

      catena = role_env(d, prefix, 'CATENA')
      fails << "#{n} ARENAADMINROLES missing or != CATENAADMINROLES" if catena.empty? || role_env(d, prefix, 'ARENA') != catena
    end
    IDP_PREFIX_WORKLOADS.each do |k, n|
      d = find.call(k, n)
      next fails << "#{n} missing" unless d

      fails << "#{n} IdpPrefix #{idp_prefixes(d).inspect} != [#{IDP_PREFIX.inspect}]" unless idp_prefixes(d) == [IDP_PREFIX]
    end
    fails << "unexpected hooks #{hook_names.sort.inspect}" unless hook_names.sort == HOOKS.sort
    fails
  end

  def self.parse(input, mode)
    if mode == :json
      rel = JSON.parse(input)
      [YAML.load_stream(rel['manifest'].to_s).compact, (rel['hooks'] || []).map { |x| x['name'] }]
    else
      all = YAML.load_stream(input).compact.select { |d| d.is_a?(Hash) && d['kind'] }
      hooks, docs = all.partition { |d| d.dig('metadata', 'annotations', 'helm.sh/hook') }
      [docs, hooks.map { |d| d.dig('metadata', 'name') }]
    end
  end
end

if $PROGRAM_NAME == __FILE__
  mode = nil
  OptionParser.new do |o|
    o.on('--json') { mode = :json }
    o.on('--yaml') { mode = :yaml }
  end.parse!
  abort('usage: --json | --yaml (manifest on stdin)') unless mode

  begin
    docs, hooks = ReleaseRetention.parse($stdin.read, mode)
  rescue JSON::ParserError, Psych::Exception => e
    puts "FAIL release manifest unreadable (#{e.class})" # class only: input may contain Secret data
    exit 1
  end
  fails = ReleaseRetention.check(docs, hooks)
  if fails.empty?
    puts 'OK   release manifest: maintenance suspended; keep on postgres/keycloak/interfaces; PVC Retain/Retain; hooks = 2 migration Jobs; ArenaAdminRoles set; IdpPrefix set'
  else
    fails.each { |f| puts "FAIL #{f}" }
    exit 1
  end
end
