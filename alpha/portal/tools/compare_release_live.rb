# frozen_string_literal: true

# Compares the would-be release (`helm upgrade --dry-run=server -o json` on stdin) with the LIVE objects in
# be293, field by field for what an upgrade would change. Read-only: live objects are fetched with
# `kubectl get` only. Prints kinds, names, field paths and env/key NAMES. A value is printed only when both
# sides are plainly non-secret (http(s) URL without credentials or query, hostname, port, boolean, number) and
# the name is not secret-like; everything else is "values hidden". Rendered Secret data is kept in memory only.
#
# Compared (API-server defaults normalized, so only real differences are reported):
#   Deployment/StatefulSet/CronJob  replicas, suspend, schedule, selector; pod serviceAccountName,
#                                   automountServiceAccountToken, securityContext, imagePullSecrets, volumes;
#                                   per container image, env (name -> value or valueFrom ref), envFrom, ports,
#                                   probes, securityContext, resources, volumeMounts
#                                   + field ownership of changed images/env (managedFields): a field owned by a
#                                   manager other than helm with a different value is an SSA CONFLICT
#   Secret                          per key: identical / DIFFERS / only-live / only-rendered (SHA-256 in memory)
#   ConfigMap                       per key: identical / DIFFERS
#   Service                         type, selector, ports (protocol TCP and targetPort=port defaults, null fields)
#   Ingress                         rules, tls, ingressClassName, annotations by key (Helm/kubectl bookkeeping
#                                   annotations ignored)
#   anything rendered but absent    "missing live" (an upgrade would CREATE it)
# It also runs the release checks of tools/verify_release_retention.rb on the same in-memory manifest.
# Exit: 0 no Secret drift, no SSA conflict and release checks pass; 1 a Secret key would change (an upgrade
# would rotate a credential or key: STOP), an SSA conflict, or a release check fails; 2 usage/input error.
# Other drift is reported for review and does not change the exit code.
#
# Usage: helm upgrade ... --dry-run=server -o json | ruby tools/compare_release_live.rb --kubeconfig KC --context alpha

require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'yaml'
require_relative 'verify_release_retention'

module CompareReleaseLive
  NAMESPACE = 'be293'
  WORKLOADS = %w[Deployment StatefulSet CronJob].freeze
  HELM_MANAGERS = %w[helm].freeze
  # Written by Helm/kubectl themselves, never part of a rendered template.
  BOOKKEEPING_ANNOTATIONS = %w[meta.helm.sh/release-name meta.helm.sh/release-namespace
                               kubectl.kubernetes.io/last-applied-configuration].freeze
  SECRET_NAME = /PASSWORD|SECRET|TOKEN(?!ADDRESS)|APIKEY|API_KEY|ENCRYPTIONKEY|PRIVATE|CREDENTIAL/i.freeze

  module_function

  def pod_spec(doc)
    doc.dig('spec', 'jobTemplate', 'spec', 'template', 'spec') || doc.dig('spec', 'template', 'spec') || {}
  end

  def compact(hash)
    hash.reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
  end

  # --- normalization of API-server defaults -----------------------------------------------------------------
  def quantity(value)
    s = value.to_s
    return nil if s.empty?

    m = s.match(/\A([0-9.]+)(m|k|M|G|T|Ki|Mi|Gi|Ti)?\z/) or return s
    n = m[1].to_f
    factor = { nil => 1, 'm' => 0.001, 'k' => 1e3, 'M' => 1e6, 'G' => 1e9, 'T' => 1e12,
               'Ki' => 1024, 'Mi' => 1024**2, 'Gi' => 1024**3, 'Ti' => 1024**4 }[m[2]]
    (n * factor).round(6)
  end

  def resources(res)
    res ||= {}
    %w[requests limits].to_h { |k| [k, (res[k] || {}).to_h { |r, v| [r, quantity(v)] }] }.reject { |_, v| v.empty? }
  end

  def probe(pr)
    return nil unless pr

    p = { 'timeoutSeconds' => 1, 'periodSeconds' => 10, 'successThreshold' => 1, 'failureThreshold' => 3 }.merge(pr)
    p['httpGet'] = { 'scheme' => 'HTTP' }.merge(p['httpGet']) if p['httpGet']
    p
  end

  def ports(list)
    (list || []).map { |pt| compact({ 'protocol' => 'TCP' }.merge(pt).reject { |k, _| k == 'hostIP' }) }
                .sort_by { |pt| [pt['name'].to_s, pt['containerPort'] || pt['port']] }
  end

  def service_ports(list, type)
    (list || []).map do |pt|
      x = compact({ 'protocol' => 'TCP', 'targetPort' => pt['port'] }.merge(pt))
      x.delete('nodePort') unless %w[NodePort LoadBalancer].include?(type)
      x
    end.sort_by { |pt| [pt['name'].to_s, pt['port']] }
  end

  def volume(v)
    v = v.dup
    %w[secret configMap].each { |k| v[k] = { 'defaultMode' => 420 }.merge(v[k]) if v[k] }
    v['emptyDir'] = compact(v['emptyDir'] || {}).tap { |e| e['sizeLimit'] = quantity(e['sizeLimit']) if e['sizeLimit'] } if v.key?('emptyDir')
    v['projected'] = { 'defaultMode' => 420 }.merge(v['projected']) if v['projected']
    v
  end

  def mounts(list)
    (list || []).map { |m| compact({ 'readOnly' => false }.merge(m)).tap { |x| x.delete('readOnly') unless x['readOnly'] } }
                .sort_by { |m| [m['mountPath'].to_s, m['name'].to_s] }
  end

  def selector(doc)
    s = doc.dig('spec', 'selector')
    s.is_a?(Hash) && s.key?('matchLabels') && s.keys == ['matchLabels'] ? s['matchLabels'] : s
  end

  # Normalized, value-bearing view of a workload; compared but never printed except for paths/names.
  def workload_view(doc)
    spec = pod_spec(doc)
    containers = (spec['containers'] || []).to_h do |c|
      env = (c['env'] || []).to_h { |e| [e['name'], e.key?('valueFrom') ? { 'ref' => e['valueFrom'] } : e['value'].to_s] }
      [c['name'], { 'image' => c['image'], 'env' => env, 'envFrom' => c['envFrom'] || [],
                    'ports' => ports(c['ports']), 'livenessProbe' => probe(c['livenessProbe']),
                    'readinessProbe' => probe(c['readinessProbe']), 'startupProbe' => probe(c['startupProbe']),
                    'securityContext' => c['securityContext'] || {}, 'resources' => resources(c['resources']),
                    'volumeMounts' => mounts(c['volumeMounts']) }]
    end
    { 'replicas' => doc.dig('spec', 'replicas'), 'suspend' => doc.dig('spec', 'suspend') || false,
      'schedule' => doc.dig('spec', 'schedule'), 'selector' => selector(doc),
      'serviceAccountName' => spec['serviceAccountName'] || spec['serviceAccount'] || 'default',
      'automountServiceAccountToken' => spec['automountServiceAccountToken'],
      'podSecurityContext' => spec['securityContext'] || {},
      'imagePullSecrets' => (spec['imagePullSecrets'] || []).map { |s| s['name'] }.sort,
      'volumes' => (spec['volumes'] || []).map { |v| volume(v) }.sort_by { |v| v['name'].to_s },
      'containers' => containers }
  end

  # --- value disclosure (only plainly non-secret values) -----------------------------------------------------
  def public_value?(name, value)
    return false if name.to_s.match?(SECRET_NAME) || !value.is_a?(String)

    value.match?(%r{\Ahttps?://[A-Za-z0-9.-]+(:\d+)?(/[A-Za-z0-9._~/-]*)?\z}) ||
      value.match?(/\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\z/) && value.include?('.') ||
      value.match?(/\A(true|false|\d{1,6})\z/)
  end

  def values_note(name, rendered, live)
    return '' unless public_value?(name, rendered) && public_value?(name, live)

    " (live=#{live} rendered=#{rendered})"
  end

  # --- managedFields ownership --------------------------------------------------------------------------------
  def container_fields_path(kind)
    base = kind == 'CronJob' ? %w[f:spec f:jobTemplate f:spec f:template f:spec] : %w[f:spec f:template f:spec]
    base + ['f:containers']
  end

  # Managers that own `field` (e.g. ['f:env', 'k:{"name":"X"}', 'f:value']) of container `cname`.
  def owners(live, cname, field)
    path = container_fields_path(live['kind'])
    (live.dig('metadata', 'managedFields') || []).select do |mf|
      node = mf['fieldsV1']
      node &&= path.reduce(node) { |n, k| n.is_a?(Hash) ? n[k] : nil }
      node &&= node.find { |k, _| k.start_with?('k:') && (JSON.parse(k[2..-1]) rescue {})['name'] == cname }&.last
      node && field.reduce(node) { |n, k| n.is_a?(Hash) ? n[k] : nil }
    end.map { |mf| mf['manager'] }.uniq
  end

  def env_key(name)
    "k:#{JSON.generate('name' => name)}"
  end

  def ownership_note(live, cname, field)
    return ['', false] unless live.dig('metadata', 'managedFields')

    who = owners(live, cname, field)
    foreign = who - HELM_MANAGERS
    return [" [owner: #{who.empty? ? 'none recorded' : who.join(',')}]", false] if foreign.empty?

    [" [CONFLICT: owned by #{foreign.join(',')}, an SSA upgrade without --force-conflicts would FAIL]", true]
  end

  # --- per-kind diffs ----------------------------------------------------------------------------------------
  def diff_workload(rendered, live)
    r = workload_view(rendered)
    l = workload_view(live)
    out = []
    conflict = false
    %w[replicas suspend schedule selector serviceAccountName automountServiceAccountToken podSecurityContext
       imagePullSecrets volumes].each { |k| out << k unless r[k] == l[k] }
    (r['containers'].keys | l['containers'].keys).each do |cn|
      rc = r['containers'][cn]
      lc = l['containers'][cn]
      next out << "container #{cn} #{rc ? 'only rendered' : 'only live'}" unless rc && lc

      unless rc['image'] == lc['image']
        note, c = ownership_note(live, cn, ['f:image'])
        conflict ||= c
        out << "container #{cn} image#{note}"
      end
      %w[envFrom ports livenessProbe readinessProbe startupProbe securityContext resources volumeMounts].each do |k|
        out << "container #{cn} #{k}" unless rc[k] == lc[k]
      end
      (rc['env'].keys | lc['env'].keys).sort.each do |n|
        next if rc['env'][n] == lc['env'][n]

        state = if !lc['env'].key?(n) then 'only rendered'
                elsif !rc['env'].key?(n) then 'only live (manual change, upgrade keeps it unless Helm owned it)'
                else "value differs#{values_note(n, rc['env'][n], lc['env'][n])}" end
        note = ''
        if lc['env'].key?(n) && rc['env'].key?(n)
          note, c = ownership_note(live, cn, ['f:env', env_key(n)])
          conflict ||= c
        end
        out << "container #{cn} env #{n}: #{state}#{note}"
      end
    end
    [out, conflict]
  end

  def digests(secret)
    (secret['data'] || {}).transform_values { |v| Digest::SHA256.hexdigest(v.to_s) }
  end

  # Rendered Secrets may use stringData (first-install branch); normalize to base64 data for the digest.
  def rendered_secret_data(doc)
    data = (doc['data'] || {}).dup
    (doc['stringData'] || {}).each { |k, v| data[k] = [v.to_s].pack('m0') }
    { 'data' => data }
  end

  def diff_secret(rendered, live)
    r = digests(rendered_secret_data(rendered))
    l = digests(live)
    (r.keys | l.keys).sort.map do |k|
      state = if !l.key?(k) then 'only rendered (would be ADDED)'
              elsif !r.key?(k) then 'only live'
              elsif r[k] == l[k] then nil
              else 'DIFFERS (upgrade would CHANGE this credential/key)' end
      state && "key #{k}: #{state}"
    end.compact
  end

  def diff_configmap(rendered, live)
    r = rendered['data'] || {}
    l = live['data'] || {}
    (r.keys | l.keys).sort.reject { |k| r[k] == l[k] }.map { |k| "key #{k}: #{l.key?(k) ? (r.key?(k) ? 'differs' : 'only live') : 'only rendered'}" }
  end

  def diff_service(rendered, live)
    rt = rendered.dig('spec', 'type') || 'ClusterIP'
    lt = live.dig('spec', 'type') || 'ClusterIP'
    out = []
    out << "spec.type (live=#{lt} rendered=#{rt})" unless rt == lt
    out << 'spec.selector' unless (rendered.dig('spec', 'selector') || {}) == (live.dig('spec', 'selector') || {})
    out << 'spec.ports' unless service_ports(rendered.dig('spec', 'ports'), rt) == service_ports(live.dig('spec', 'ports'), lt)
    out
  end

  # Managers owning metadata.annotations[key] on the live object.
  def annotation_owners(live, key)
    (live.dig('metadata', 'managedFields') || []).select do |mf|
      mf.dig('fieldsV1', 'f:metadata', 'f:annotations')&.key?("f:#{key}")
    end.map { |mf| mf['manager'] }.uniq
  end

  # Returns [diffs, removed_by_upgrade]. Under server-side apply an annotation that only lives on the object is
  # kept unless Helm is one of its owners (then the upgrade, which no longer applies it, removes it).
  def diff_ingress(rendered, live)
    out = %w[rules tls ingressClassName].reject { |k| rendered.dig('spec', k) == live.dig('spec', k) }.map { |k| "spec.#{k}" }
    removed = false
    r = (rendered.dig('metadata', 'annotations') || {}).reject { |k, _| BOOKKEEPING_ANNOTATIONS.include?(k) }
    l = (live.dig('metadata', 'annotations') || {}).reject { |k, _| BOOKKEEPING_ANNOTATIONS.include?(k) }
    (r.keys | l.keys).sort.each do |k|
      next if r[k] == l[k]

      state = !l.key?(k) ? 'only rendered' : !r.key?(k) ? 'only live (upgrade keeps it unless Helm owned it)' : "differs#{values_note(k, r[k], l[k])}"
      if !r.key?(k) && live.dig('metadata', 'managedFields')
        who = annotation_owners(live, k)
        if who.any? { |m| HELM_MANAGERS.include?(m) }
          removed = true
          state += " [REMOVED BY UPGRADE: owned by #{who.join(',')}]"
        else
          state += " [owner: #{who.empty? ? 'none recorded' : who.join(',')}]"
        end
      end
      out << "annotation #{k}: #{state}"
    end
    [out, removed]
  end

  # --expected: every DRIFT item must match a reviewed entry ("Kind/name" => [exact item, or prefix ending in *]).
  def unexpected_items(results, expected)
    results.select { |level, _| level == 'DRIFT' }.flat_map do |_, msg|
      name, items = msg.split(': ', 2)
      allowed = Array(expected[name])
      items.split('; ').reject do |item|
        allowed.any? { |pat| pat.end_with?('*') ? item.start_with?(pat.chomp('*')) : item == pat }
      end.map { |item| "#{name}: #{item}" }
    end
  end

  # fetch: ->(kind, name) { Hash or nil }. Returns [[level, message], ...].
  def compare(docs, fetch)
    docs.map do |d|
      kind = d['kind']
      name = d.dig('metadata', 'name')
      live = fetch.call(kind, name)
      next ['DRIFT', "#{kind}/#{name}: missing live (an upgrade would CREATE it)"] if live.nil?

      conflict = false
      diffs = case kind
              when *WORKLOADS then diff_workload(d, live).tap { |_, c| conflict = c }.first
              when 'Secret' then diff_secret(d, live)
              when 'ConfigMap' then diff_configmap(d, live)
              when 'Service' then diff_service(d, live)
              when 'Ingress' then diff_ingress(d, live).tap { |_, c| conflict = c }.first
              else []
              end
      secret_change = kind == 'Secret' && diffs.any? { |x| x.include?('DIFFERS') || x.include?('would be ADDED') }
      next ['SAME', "#{kind}/#{name}"] if diffs.empty?

      [secret_change || conflict ? 'FAIL' : 'DRIFT', "#{kind}/#{name}: #{diffs.join('; ')}"]
    end
  end

  def kubectl_fetcher(kubeconfig, context)
    lambda do |kind, name|
      out, err, st = Open3.capture3('kubectl', '--kubeconfig', kubeconfig, '--context', context, '--request-timeout=20s',
                                    'get', kind, name, '-n', NAMESPACE, '--ignore-not-found', '--show-managed-fields', '-o', 'json')
      raise "kubectl get #{kind}/#{name} failed: #{err.lines.first}" unless st.success?

      out.strip.empty? ? nil : JSON.parse(out)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {}
  OptionParser.new do |o|
    o.on('--kubeconfig FILE') { |v| opts[:kc] = v }
    o.on('--context NAME') { |v| opts[:ctx] = v }
    o.on('--expected FILE') { |v| opts[:expected] = v }
  end.parse!
  abort('usage: --kubeconfig FILE --context NAME [--expected FILE] (dry-run JSON on stdin)') unless opts[:kc] && opts[:ctx]
  begin
    expected = opts[:expected] && (YAML.safe_load(File.read(opts[:expected])) || {})
  rescue Psych::Exception, Errno::ENOENT => e
    puts "FAIL expected-drift file unreadable (#{e.class})"
    exit 2
  end

  begin
    docs, hooks = ReleaseRetention.parse($stdin.read, :json)
    docs = docs.select { |d| d.is_a?(Hash) && d['kind'] }
    release_fails = ReleaseRetention.check(docs, hooks)
    results = CompareReleaseLive.compare(docs, CompareReleaseLive.kubectl_fetcher(opts[:kc], opts[:ctx]))
  rescue JSON::ParserError, Psych::Exception => e
    puts "FAIL dry-run output unreadable (#{e.class})" # class only: input holds Secret data
    exit 2
  rescue RuntimeError => e
    puts "FAIL #{e.message}"
    exit 2
  end
  release_fails.each { |f| puts "FAIL  release: #{f}" }
  puts 'OK    release manifest: maintenance suspended; keep on postgres/keycloak/interfaces; PVC Retain/Retain; hooks = 2 migration Jobs; ArenaAdminRoles set; IdpPrefix set' if release_fails.empty?
  results.each { |level, msg| puts "#{level.ljust(5)} #{msg}" }
  counts = results.group_by(&:first).transform_values(&:size)
  puts "COMPARE #{counts.sort.map { |k, v| "#{k}=#{v}" }.join(' ')}"
  unexpected = expected ? CompareReleaseLive.unexpected_items(results, expected) : []
  if expected
    unexpected.each { |u| puts "UNEXPECTED #{u}" }
    puts(unexpected.empty? ? "EXPECTED-DRIFT OK: every drift item is listed in #{File.basename(opts[:expected])}" : "EXPECTED-DRIFT FAIL: #{unexpected.size} unreviewed drift item(s)")
  end
  exit(release_fails.empty? && results.none? { |l, _| l == 'FAIL' } && unexpected.empty? ? 0 : 1)
end
