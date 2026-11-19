#!/usr/bin/env ruby
# frozen_string_literal: true

# Helm 4 post-renderer for the be293-portal release (zero automatic data deletion). Reads the rendered
# manifest stream on stdin, writes it to stdout with exactly these changes:
#   1. CronJob be293-portal-portal-maintenance: spec.suspend = true (the chart cannot disable it)
#   2. Secrets be293-portal-postgres / -keycloak / -interfaces: metadata.annotations
#      "helm.sh/resource-policy": keep (database credentials, owner credentials, Portal encryption keys
#      survive `helm uninstall`; Helm reads the policy from the stored, post-rendered release manifest)
#   3. Deployments be293-portal-marketplace-app-service / -services-service: every chart env entry
#      <PREFIX>__CATENAADMINROLES__* is kept and duplicated as <PREFIX>__ARENAADMINROLES__* with the same value,
#      inserted right after it. The pinned ARENA2036 backend (commit ad459ee7, "chore:ARENA branding") renamed
#      the [Required] setting CatenaAdminRoles to ArenaAdminRoles; the upstream portal-2.6.0 chart only renders
#      the old name, and the services refuse to start without the new one. Values stay single-sourced in the
#      chart values (centralidp.clients.portal, backend.<service>.catenaAdminRoles.role0).
#   4. Deployment be293-portal-administration-service and CronJob be293-portal-processes-worker: one env entry
#      PROVISIONING__IDPPREFIX=IDP_PREFIX, inserted right after PROVISIONING__CENTRALREALM. Both generate new
#      Keycloak IdP aliases as Provisioning:IdpPrefix + provisioning.identity_provider_sequences (ad459ee7:
#      IdpManagement / IdentityProviderManager GetNextCentralIdentityProviderNameAsync). The chart cannot render
#      the setting and the backend default "idp" collides with the release26-09 Portal, which shares CentralIDP
#      CX-Central and SharedIDP: be293's own sequence restarted at 1, so invitations failed with
#      "Identity Provider idp2 already exists". The alias also names the shared realm and the service account
#      client (ServiceAccountClientPrefix + alias), so a BE-293-only prefix keeps all three collision-free.
# Every other document is passed through byte-for-byte. Fail-closed: if the input is empty, a target is
# missing or duplicated, or anything cannot be parsed, it writes NOTHING to stdout and exits 1, which makes
# the Helm command fail (verified with Helm 4.3: empty post-renderer output aborts).

require 'yaml'

module Be293Retention
  RELEASE = 'be293-portal'
  NAMESPACE = 'be293'
  SUSPEND_CRONJOBS = ["#{RELEASE}-portal-maintenance"].freeze
  KEEP_SECRETS = ["#{RELEASE}-postgres", "#{RELEASE}-keycloak", "#{RELEASE}-interfaces"].freeze
  KEEP = 'helm.sh/resource-policy'
  ADMIN_ROLE_ALIASES = { "#{RELEASE}-marketplace-app-service" => 'APPMARKETPLACE',
                         "#{RELEASE}-services-service" => 'SERVICES' }.freeze
  # Never change this once IdPs exist with it: existing aliases keep working, but a different prefix would
  # restart naming in a new namespace of names. Keycloak-safe characters only (realm name, client id, alias).
  IDP_PREFIX = 'be293-alpha-idp-'
  IDP_PREFIX_ENV = 'PROVISIONING__IDPPREFIX'
  IDP_PREFIX_ANCHOR = 'PROVISIONING__CENTRALREALM'
  IDP_PREFIX_TARGETS = { 'Deployment' => ["#{RELEASE}-administration-service"],
                         'CronJob' => ["#{RELEASE}-processes-worker"] }.freeze
  SEPARATOR = /^---[ \t]*\r?\n/.freeze

  class Error < StandardError; end

  # Adds PROVISIONING__IDPPREFIX after PROVISIONING__CENTRALREALM in the one container that renders the
  # Provisioning section; fails if the chart (in any spelling, .NET keys are case-insensitive) already sets it.
  def self.set_idp_prefix!(doc)
    spec = doc.dig('spec', 'jobTemplate', 'spec', 'template', 'spec') || doc.dig('spec', 'template', 'spec') || {}
    added = 0
    (spec['containers'] || []).each do |c|
      env = c['env'] || []
      raise Error, "#{doc['metadata']['name']} already renders #{IDP_PREFIX_ENV}" if env.any? { |e| e['name'].to_s.casecmp?(IDP_PREFIX_ENV) }

      at = env.index { |e| e['name'] == IDP_PREFIX_ANCHOR }
      next unless at

      env.insert(at + 1, { 'name' => IDP_PREFIX_ENV, 'value' => IDP_PREFIX })
      c['env'] = env
      added += 1
    end
    raise Error, "#{doc['metadata']['name']}: #{IDP_PREFIX_ANCHOR} rendered in #{added} containers (expected 1)" unless added == 1
  end

  # Inserts an ARENAADMINROLES copy after each CATENAADMINROLES entry; fails if there is none or the chart
  # already renders the new name (then this compatibility shim must be reviewed and removed).
  def self.alias_admin_roles!(doc, prefix)
    catena = "#{prefix}__CATENAADMINROLES__"
    arena = "#{prefix}__ARENAADMINROLES__"
    added = 0
    (doc.dig('spec', 'template', 'spec', 'containers') || []).each do |c|
      env = c['env'] || []
      raise Error, "#{doc['metadata']['name']} already renders #{arena}*" if env.any? { |e| e['name'].to_s.start_with?(arena) }

      c['env'] = env.flat_map do |e|
        next [e] unless e['name'].to_s.start_with?(catena) && e.key?('value') && e.keys.sort == %w[name value]

        added += 1
        [e, { 'name' => e['name'].sub(catena, arena), 'value' => e['value'] }]
      end
    end
    raise Error, "#{doc['metadata']['name']} renders no #{catena}* entry" if added.zero?
  end

  def self.transform(input)
    raise Error, 'empty input' if input.strip.empty?

    seen = Hash.new(0)
    chunks = input.split(SEPARATOR, -1)
    out = chunks.map do |chunk|
      doc = chunk.strip.empty? ? nil : YAML.safe_load(chunk)
      next chunk unless doc.is_a?(Hash)

      kind = doc['kind']
      name = doc.dig('metadata', 'name')
      suspend = kind == 'CronJob' && SUSPEND_CRONJOBS.include?(name)
      keep = kind == 'Secret' && KEEP_SECRETS.include?(name)
      roles = kind == 'Deployment' && ADMIN_ROLE_ALIASES.key?(name)
      prefix = (IDP_PREFIX_TARGETS[kind] || []).include?(name)
      next chunk unless suspend || keep || roles || prefix

      ns = doc.dig('metadata', 'namespace')
      raise Error, "#{kind}/#{name} namespace #{ns.inspect} != #{NAMESPACE}" unless ns == NAMESPACE

      seen["#{kind}/#{name}"] += 1
      doc['spec'] = (doc['spec'] || {}).merge('suspend' => true) if suspend
      doc['metadata']['annotations'] = (doc['metadata']['annotations'] || {}).merge(KEEP => 'keep') if keep
      alias_admin_roles!(doc, ADMIN_ROLE_ALIASES.fetch(name)) if roles
      set_idp_prefix!(doc) if prefix
      header = chunk.lines.take_while { |l| l.start_with?('#') }.join
      header + YAML.dump(doc).sub(/\A---[ \t]*\n/, '')
    end

    expected = SUSPEND_CRONJOBS.map { |n| "CronJob/#{n}" } + KEEP_SECRETS.map { |n| "Secret/#{n}" } +
               ADMIN_ROLE_ALIASES.keys.map { |n| "Deployment/#{n}" } +
               IDP_PREFIX_TARGETS.flat_map { |k, names| names.map { |n| "#{k}/#{n}" } }
    missing = expected.reject { |t| seen[t] == 1 }
    raise Error, "targets missing or duplicated: #{missing.map { |t| "#{t}=#{seen[t]}" }.join(', ')}" unless missing.empty?

    out.join("---\n")
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    $stdout.write(Be293Retention.transform($stdin.read))
  rescue Be293Retention::Error, Psych::Exception => e
    # Message names objects only; Secret data is never echoed.
    warn "be293-retention post-renderer refused: #{e.class}: #{e.message.lines.first}"
    exit 1
  end
end
