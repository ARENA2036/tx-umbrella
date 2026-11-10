# frozen_string_literal: true

# Zero-automatic-data-deletion gate for the be293-portal release (offline; reads rendered manifests only).
# Run it on the FINAL (post-rendered) manifest; with --baseline it also proves the post-renderer changed
# nothing except the four reviewed fields.
#
# Gates (D1-D10):
#   D1 portal-maintenance CronJob is suspended and both intervals are >= MIN_INTERVAL_DAYS (no row can match)
#   D2 every other CronJob is suspended unless allow-listed (processes-worker: user-initiated process engine)
#   D3 database credentials, owner credentials and encryption keys carry helm.sh/resource-policy: keep
#   D4 no Helm-managed PersistentVolumeClaim (uninstall would delete it) unless it carries keep
#   D5 PostgreSQL keeps its data on the volumeClaimTemplate `data` with retention Retain/Retain
#   D6 no hook-delete-policy, no ttlSecondsAfterFinished, no delete-phase hooks
#   D7 seeding: reviewed data paths only, no test data, seed-owned rows pinned by hash
#   D8 (--baseline) post-renderer diff limited to the reviewed fields, same object set
#   D9 fork compatibility: marketplace/services render <PREFIX>__ARENAADMINROLES__* equal to the chart's
#      <PREFIX>__CATENAADMINROLES__* (pinned backend ad459ee7 only reads ArenaAdminRoles, [Required])
#   D10 IdP alias prefix: administration-service and processes-worker (the only IdP alias generators) render
#      exactly one PROVISIONING__IDPPREFIX = IDP_PREFIX; no workload renders any other IdpPrefix. The default
#      "idp" collides with release26-09 in the shared CentralIDP/SharedIDP ("idp2 already exists").
#
# Usage: ruby tools/validate_retention.rb --render POST_RENDERED.yaml [--baseline PLAIN.yaml]
# For D8, POST_RENDERED must be post-render.rb applied to the SAME plain render (offline renders regenerate
# chart-random Secret values on every run). Note: Helm 4 itself trims trailing whitespace of every manifest
# before any post-renderer (verified with a pure `cat` renderer), e.g. the final newline of 02-init-db.sql.

require 'digest'
require 'json'
require 'optparse'
require 'yaml'

module RetentionGates
  RELEASE = 'be293-portal'
  MAINTENANCE = "#{RELEASE}-portal-maintenance"
  # Cutoff now - 365000 days lies around the year 1026; the upper bound keeps DateTimeOffset.AddDays far from
  # its minimum (year 1), so the service neither matches rows nor fails into its exception path.
  MIN_INTERVAL_DAYS = 365_000
  MAX_INTERVAL_DAYS = 700_000
  INTERVAL_ENV = %w[BATCHPROCESSING_DELETEDOCUMENTSINTERVALINDAYS BATCHPROCESSING_RETRIGGERCLEARINGHOUSEINTERVALINDAYS].freeze
  ACTIVE_CRONJOB_ALLOWLIST = ["#{RELEASE}-processes-worker"].freeze
  KEEP_SECRETS = ["#{RELEASE}-postgres", "#{RELEASE}-keycloak", "#{RELEASE}-interfaces"].freeze
  KEEP = 'helm.sh/resource-policy'
  PG_STATEFULSET = "#{RELEASE}-postgresql"
  MIGRATION_JOB = "#{RELEASE}-portal-migrations"
  SEED_CONFIGMAP = "#{RELEASE}-initial-data"
  SEED_DATA_PATHS = ['Seeder/Data/', 'Seeder/Data/overwrite'].freeze
  # BatchUpdateSeeder re-applies these rows on EVERY migration run (install and upgrade): operator company
  # 2dc4249f-... and address b4db3945-... Any change to them must be a reviewed change of this hash.
  SEED_OVERWRITE_SHA256 = '4343873b52a5a551ab54f5a31ec734d5c4f714872b1af858fd198763246e421b'
  # D9 / D8: Deployments whose CATENAADMINROLES env the post-renderer duplicates as ARENAADMINROLES.
  ADMIN_ROLE_ALIASES = { "#{RELEASE}-marketplace-app-service" => 'APPMARKETPLACE',
                         "#{RELEASE}-services-service" => 'SERVICES' }.freeze
  # D10 / D8: the BE-293-only alias prefix and the workloads that generate aliases with it.
  IDP_PREFIX = 'be293-alpha-idp-'
  IDP_PREFIX_ENV = 'PROVISIONING__IDPPREFIX'
  IDP_PREFIX_WORKLOADS = [['Deployment', "#{RELEASE}-administration-service"], ['CronJob', "#{RELEASE}-processes-worker"]].freeze
  # D8: the only fields the post-renderer may add.
  ALLOWED_DIFF = {
    "CronJob/#{MAINTENANCE}" => [%w[spec suspend]],
    "Secret/#{RELEASE}-postgres" => [['metadata', 'annotations', KEEP]],
    "Secret/#{RELEASE}-keycloak" => [['metadata', 'annotations', KEEP]],
    "Secret/#{RELEASE}-interfaces" => [['metadata', 'annotations', KEEP]]
  }.freeze

  class Validator
    attr_reader :failures, :info

    def initialize
      @failures = []
      @info = []
    end

    def check(docs, baseline: nil)
      check_cronjobs(docs)
      check_keep_secrets(docs)
      check_pvcs(docs)
      check_postgres(docs)
      check_hooks_and_jobs(docs)
      check_seeding(docs)
      check_admin_role_aliases(docs)
      check_idp_prefix(docs)
      check_post_render_diff(baseline, docs) if baseline
      self
    end

    private

    def fail(gate, msg)
      @failures << "[#{gate}] #{msg}"
    end

    def id(doc)
      "#{doc['kind']}/#{doc.dig('metadata', 'name')}"
    end

    def find(docs, kind, name)
      docs.find { |d| d['kind'] == kind && d.dig('metadata', 'name') == name }
    end

    def pod_spec(doc)
      doc.dig('spec', 'jobTemplate', 'spec', 'template', 'spec') || doc.dig('spec', 'template', 'spec') || {}
    end

    def env_of(doc)
      (pod_spec(doc)['containers'] || []).flat_map { |c| c['env'] || [] }
    end

    def check_cronjobs(docs)
      maint = find(docs, 'CronJob', MAINTENANCE)
      if maint.nil?
        fail('D1', "CronJob/#{MAINTENANCE} not rendered (review whether the chart changed)")
      else
        fail('D1', "CronJob/#{MAINTENANCE} is not suspended") unless maint.dig('spec', 'suspend') == true
        INTERVAL_ENV.each do |name|
          e = env_of(maint).find { |x| x['name'] == name }
          days = e && e['value'].to_s.match?(/\A\d+\z/) ? e['value'].to_i : nil
          if days.nil? || days < MIN_INTERVAL_DAYS || days > MAX_INTERVAL_DAYS
            fail('D1', "CronJob/#{MAINTENANCE} #{name}=#{e && e['value'].inspect} outside [#{MIN_INTERVAL_DAYS}, #{MAX_INTERVAL_DAYS}]")
          end
        end
      end
      docs.select { |d| d['kind'] == 'CronJob' }.each do |cj|
        name = cj.dig('metadata', 'name')
        next if name == MAINTENANCE

        if ACTIVE_CRONJOB_ALLOWLIST.include?(name)
          @info << "active CronJob #{name} (allow-listed: user-initiated process engine) schedule=#{cj.dig('spec', 'schedule')}"
        elsif cj.dig('spec', 'suspend') != true
          fail('D2', "#{id(cj)} is active and not allow-listed (review for automatic deletion)")
        end
      end
    end

    def check_keep_secrets(docs)
      KEEP_SECRETS.each do |name|
        s = find(docs, 'Secret', name)
        if s.nil?
          fail('D3', "Secret/#{name} not rendered")
        elsif s.dig('metadata', 'annotations', KEEP) != 'keep'
          fail('D3', "Secret/#{name} lacks #{KEEP}: keep (uninstall would delete it)")
        end
      end
    end

    def check_pvcs(docs)
      docs.select { |d| d['kind'] == 'PersistentVolumeClaim' }.each do |p|
        fail('D4', "#{id(p)} is Helm-managed without #{KEEP}: keep") unless p.dig('metadata', 'annotations', KEEP) == 'keep'
      end
    end

    def check_postgres(docs)
      sts = find(docs, 'StatefulSet', PG_STATEFULSET)
      return fail('D5', "StatefulSet/#{PG_STATEFULSET} not rendered") if sts.nil?

      vcts = (sts.dig('spec', 'volumeClaimTemplates') || []).map { |v| v.dig('metadata', 'name') }
      fail('D5', "#{id(sts)} has no volumeClaimTemplate 'data' (persistence disabled?)") unless vcts.include?('data')
      vols = pod_spec(sts)['volumes'] || []
      if (v = vols.find { |x| x['name'] == 'data' })
        fail('D5', "#{id(sts)} volume 'data' is #{(v.keys - ['name']).join(',')} instead of the volumeClaimTemplate")
      end
      policy = sts.dig('spec', 'persistentVolumeClaimRetentionPolicy') || {}
      unless policy['whenDeleted'] == 'Retain' && policy['whenScaled'] == 'Retain'
        fail('D5', "#{id(sts)} persistentVolumeClaimRetentionPolicy #{policy.inspect} is not Retain/Retain")
      end
    end

    def check_hooks_and_jobs(docs)
      docs.each do |d|
        ann = d.dig('metadata', 'annotations') || {}
        fail('D6', "#{id(d)} sets helm.sh/hook-delete-policy=#{ann['helm.sh/hook-delete-policy']}") if ann.key?('helm.sh/hook-delete-policy')
        hook = ann['helm.sh/hook'].to_s
        fail('D6', "#{id(d)} is a #{hook} hook (runs at uninstall/rollback)") if hook.match?(/delete|rollback/)
        fail('D6', "#{id(d)} sets ttlSecondsAfterFinished (Job and logs deleted automatically)") if d['kind'] == 'Job' && d.dig('spec', 'ttlSecondsAfterFinished')
        if d['kind'] == 'CronJob' && d.dig('spec', 'jobTemplate', 'spec', 'ttlSecondsAfterFinished')
          fail('D6', "#{id(d)} job template sets ttlSecondsAfterFinished")
        end
      end
    end

    def check_seeding(docs)
      job = find(docs, 'Job', MIGRATION_JOB)
      return fail('D7', "Job/#{MIGRATION_JOB} not rendered") if job.nil?

      env = env_of(job)
      paths = env.select { |e| e['name'].to_s.match?(/\ASEEDING__DATAPATHS__\d+\z/) }
                 .sort_by { |e| e['name'][/\d+\z/].to_i }.map { |e| e['value'] }
      fail('D7', "seeding data paths #{paths.inspect} != reviewed #{SEED_DATA_PATHS.inspect}") unless paths == SEED_DATA_PATHS
      test_env = env.map { |e| e['name'].to_s }.grep(/\ASEEDING__TESTDATAENVIRONMENTS/)
      fail('D7', "test-data seeding enabled (#{test_env.join(', ')})") unless test_env.empty?
      mounts = (pod_spec(job)['containers'] || []).flat_map { |c| c['volumeMounts'] || [] }.map { |m| m['mountPath'] }
      extra = mounts.grep(%r{/Seeder/Data/import})
      fail('D7', "test-data seed mounts present: #{extra.inspect}") unless extra.empty?

      cm = find(docs, 'ConfigMap', SEED_CONFIGMAP)
      return fail('D7', "ConfigMap/#{SEED_CONFIGMAP} not rendered") if cm.nil?

      canon = (cm['data'] || {}).keys.sort.map { |k| [k, JSON.parse(cm['data'][k])] }
      digest = Digest::SHA256.hexdigest(JSON.generate(canon))
      fail('D7', "seed overwrite data changed (sha256 #{digest}); BatchUpdateSeeder would re-apply it on every migration run - review and re-pin") unless digest == SEED_OVERWRITE_SHA256
    rescue JSON::ParserError
      fail('D7', "ConfigMap/#{SEED_CONFIGMAP} contains invalid JSON")
    end

    def role_env(doc, prefix, kind)
      env_of(doc).select { |e| e['name'].to_s.start_with?("#{prefix}__#{kind}ADMINROLES__") }
                 .map { |e| [e['name'].sub("__#{kind}ADMINROLES__", '__ADMINROLES__'), e['value']] }
    end

    def check_admin_role_aliases(docs)
      ADMIN_ROLE_ALIASES.each do |name, prefix|
        d = find(docs, 'Deployment', name)
        next fail('D9', "Deployment/#{name} not rendered") if d.nil?

        catena = role_env(d, prefix, 'CATENA')
        arena = role_env(d, prefix, 'ARENA')
        fail('D9', "Deployment/#{name} renders no #{prefix}__CATENAADMINROLES__*") if catena.empty?
        fail('D9', "Deployment/#{name} #{prefix}__ARENAADMINROLES__* #{arena.inspect} != CATENA #{catena.inspect}") unless arena == catena
      end
    end

def idp_prefix_env(doc)
  env_of(doc).select { |e| e['name'].to_s.casecmp?(IDP_PREFIX_ENV) }
end

def check_idp_prefix(docs)
  fail('D10', "IDP_PREFIX #{IDP_PREFIX.inspect} is not a BE-293-only Keycloak-safe prefix") unless IDP_PREFIX.match?(/\Abe293-[a-z0-9-]*-\z/)
  IDP_PREFIX_WORKLOADS.each do |kind, name|
    d = find(docs, kind, name)
    next fail('D10', "#{kind}/#{name} not rendered") if d.nil?

    got = idp_prefix_env(d)
    ok = got.size == 1 && got[0].keys.sort == %w[name value] && got[0]['value'] == IDP_PREFIX
    fail('D10', "#{kind}/#{name} #{IDP_PREFIX_ENV} #{got.map { |e| e['value'] || '<valueFrom>' }.inspect} != [#{IDP_PREFIX.inspect}]") unless ok
  end
  docs.each do |d|
    next if IDP_PREFIX_WORKLOADS.include?([d['kind'], d.dig('metadata', 'name')])

    other = idp_prefix_env(d).reject { |e| e['value'] == IDP_PREFIX }
    fail('D10', "#{id(d)} renders a different IdpPrefix #{other.map { |e| e['value'] }.inspect}") unless other.empty?
  end
end

# Post-rendered workloads may differ only by the reviewed env entries: ARENAADMINROLES copies of the
# CATENA ones (D9) and the IdP prefix (D10). Each is checked by its own gate.
def without_post_render_env(doc)
  roles = doc['kind'] == 'Deployment' && ADMIN_ROLE_ALIASES[doc.dig('metadata', 'name')]
  prefix = IDP_PREFIX_WORKLOADS.include?([doc['kind'], doc.dig('metadata', 'name')])
  return doc unless roles || prefix

  copy = Marshal.load(Marshal.dump(doc))
  (pod_spec(copy)['containers'] || []).each do |c|
    c['env']&.reject! { |e| roles && e['name'].to_s.start_with?("#{roles}__ARENAADMINROLES__") }
    c['env']&.reject! { |e| prefix && e['name'] == IDP_PREFIX_ENV && e['value'] == IDP_PREFIX }
  end
  copy
end

    def check_post_render_diff(baseline, docs)
      base = baseline.to_h { |d| [id(d), d] }
      post = docs.to_h { |d| [id(d), d] }
      (base.keys - post.keys).each { |k| fail('D8', "post-renderer dropped #{k}") }
      (post.keys - base.keys).each { |k| fail('D8', "post-renderer added #{k}") }
      (base.keys & post.keys).each do |k|
        diffs = diff_paths(base[k], without_post_render_env(post[k]))
        unexpected = diffs - (ALLOWED_DIFF[k] || [])
        fail('D8', "#{k} changed by post-renderer at #{unexpected.map { |p| p.join('.') }.join(', ')}") unless unexpected.empty?
      end
    end

    # A missing map on one side counts as empty, so an added annotation reports its own key path.
    def diff_paths(a, b, path = [])
      return [] if a == b

      a = {} if a.nil? && b.is_a?(Hash)
      b = {} if b.nil? && a.is_a?(Hash)
      return [path] unless a.is_a?(Hash) && b.is_a?(Hash)

      (a.keys | b.keys).flat_map { |k| diff_paths(a[k], b[k], path + [k]) }
    end
  end

  def self.load_docs(text)
    YAML.load_stream(text).compact.select { |d| d.is_a?(Hash) && d['kind'] }
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {}
  OptionParser.new do |o|
    o.on('--render FILE') { |v| opts[:render] = v }
    o.on('--baseline FILE') { |v| opts[:baseline] = v }
  end.parse!
  abort('usage: --render FILE [--baseline FILE]') unless opts[:render]

  begin
    docs = RetentionGates.load_docs(File.read(opts[:render]))
    base = opts[:baseline] && RetentionGates.load_docs(File.read(opts[:baseline]))
  rescue Psych::Exception, Errno::ENOENT => e
    warn "input error: #{e.class}"
    exit 2
  end
  v = RetentionGates::Validator.new.check(docs, baseline: base)
  v.info.each { |i| puts "info #{i}" }
  v.failures.each { |f| puts "FAIL #{f}" }
  puts(v.failures.empty? ? 'RETENTION RESULT PASS' : "RETENTION RESULT FAIL (#{v.failures.size})")
  exit(v.failures.empty? ? 0 : 1)
end
