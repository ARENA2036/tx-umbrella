# frozen_string_literal: true

# Static integrity checks for the alpha/portal package files (no rendering, no network):
#   1. duplicate mapping keys in every YAML file (Psych silently keeps the last one)
#   2. images.lock `rebuilt` entries == CI workflow matrix (image + Dockerfile) == values image names
#   3. CI workflow guardrails: manual trigger only, pinned commit, no `latest`, SHA-pinned actions
#   4. every Secret name referenced by the values file is declared in secrets-contract.yaml
#
# Usage: ruby tools/check_package.rb [PACKAGE_DIR]   (exit 0 = pass, 1 = findings, 2 = input error)

require 'yaml'
require 'open3'

module PortalPackageCheck
  module_function

  def duplicate_keys(text, file)
    findings = []
    Psych.parse_stream(text).children.each do |doc|
      walk(doc.root, file, findings)
    end
    findings
  end

  def walk(node, file, findings, path = [])
    case node
    when Psych::Nodes::Mapping
      seen = {}
      node.children.each_slice(2) do |k, v|
        key = k.respond_to?(:value) ? k.value : k.class.name
        if seen.key?(key)
          findings << "#{file}: duplicate key #{(path + [key]).join('.')} (lines #{seen[key] + 1} and #{k.start_line + 1})"
        else
          seen[key] = k.start_line
        end
        walk(v, file, findings, path + [key])
      end
    when Psych::Nodes::Sequence
      node.children.each_with_index { |c, i| walk(c, file, findings, path + [i.to_s]) }
    end
  end

  def lock_vs_workflow_vs_values(lock, workflow, values)
    findings = []
    locked = (lock['rebuilt'] || []).map { |i| [i['image'], i['dockerfile']] }.sort
    matrix = workflow.dig('jobs', 'build', 'strategy', 'matrix', 'include') || []
    built = matrix.map { |i| [i['image'], i['dockerfile']] }.sort
    findings << "workflow matrix != images.lock rebuilt: #{(built - locked) | (locked - built)}" unless built == locked
    commit = lock.dig('source', 'commit')
    findings << 'workflow SOURCE_COMMIT != images.lock source.commit' unless workflow.dig('env', 'SOURCE_COMMIT') == commit
    value_images = []
    collect_image_names(values, value_images)
    locked.map(&:first).each do |img|
      findings << "values file has no image for #{img}" unless value_images.any? { |n| n.end_with?("/#{img}") }
    end
    findings
  end

  def collect_image_names(node, acc)
    case node
    when Hash
      node.each do |k, v|
        acc << v if k == 'name' && v.is_a?(String) && v.include?('/')
        collect_image_names(v, acc)
      end
    when Array then node.each { |v| collect_image_names(v, acc) }
    end
  end

  def workflow_guardrails(text, workflow)
    findings = []
    triggers = workflow['on'] || workflow[true] # YAML 1.1 reads bare `on` as true
    findings << 'workflow must be workflow_dispatch only' unless triggers.is_a?(Hash) && triggers.keys == ['workflow_dispatch']
    findings << 'workflow push input must default to false' unless triggers.dig('workflow_dispatch', 'inputs', 'push', 'default') == false
    findings << 'workflow references a latest tag' if text.match?(/:latest\b|value=latest/) && !text.include?('*:latest)')
    text.scan(/uses:\s*(\S+)/).flatten.each do |u|
      findings << "action not pinned to a full SHA: #{u}" unless u.match?(/@[0-9a-f]{40}\z/)
    end
    findings << 'workflow permissions must be contents: read only' unless workflow['permissions'] == { 'contents' => 'read' }
    findings
  end

  ALLOWED_CONTEXTS = %w[github inputs vars secrets env matrix steps runner job needs strategy].freeze

  # actionlint is not available locally; this covers the subset that matters for this workflow:
  # expression contexts, references to defined inputs/matrix keys/step ids, step shape, and shell syntax.
  def workflow_static(workflow)
    findings = []
    inputs = (workflow.dig('on', 'workflow_dispatch', 'inputs') || workflow.dig(true, 'workflow_dispatch', 'inputs') || {}).keys
    (workflow['jobs'] || {}).each do |job_id, job|
      matrix_keys = (job.dig('strategy', 'matrix', 'include') || []).flat_map(&:keys).uniq
      steps = job['steps'] || []
      step_ids = steps.map { |s| s['id'] }.compact
      dup_ids = step_ids.select { |i| step_ids.count(i) > 1 }.uniq
      findings << "job #{job_id}: duplicate step ids #{dup_ids}" unless dup_ids.empty?
      exprs = YAML.dump(job).scan(/\$\{\{\s*(.*?)\s*\}\}/m).flatten
      exprs += steps.map { |s| s['if'] }.compact.map(&:to_s)
      exprs.each do |e|
        e.scan(/(?<![\w.'])([a-z_]+)((?:\.[A-Za-z0-9_-]+)+)/).each do |root, rest|
          next if %w[true false null].include?(root)

          parts = rest.split('.').reject(&:empty?)
          findings << "job #{job_id}: unknown expression context #{root} in '#{e}'" unless ALLOWED_CONTEXTS.include?(root)
          findings << "job #{job_id}: undefined input #{parts.first}" if root == 'inputs' && !inputs.include?(parts.first)
          findings << "job #{job_id}: undefined matrix key #{parts.first}" if root == 'matrix' && !matrix_keys.include?(parts.first)
          findings << "job #{job_id}: reference to undefined step id #{parts.first}" if root == 'steps' && !step_ids.include?(parts.first)
        end
      end
      steps.each_with_index do |s, i|
        label = s['name'] || "step #{i + 1}"
        findings << "job #{job_id}: '#{label}' must have exactly one of uses/run" unless s.key?('uses') ^ s.key?('run')
        next unless s['run']

        script = s['run'].gsub(/\$\{\{.*?\}\}/m, 'EXPR')
        _out, err, status = Open3.capture3('bash', '-n', stdin_data: script)
        findings << "job #{job_id}: '#{label}' shell syntax error: #{err.lines.first&.strip}" unless status.success?
      end
    end
    findings
  end

  # push=false must make no external writes: every step that logs in to, inspects or pushes to a registry
  # must be gated on inputs.push; the build-only step must not push; caches must not be written.
  def push_gating(workflow)
    findings = []
    (workflow['jobs'] || {}).each_value do |job|
      (job['steps'] || []).each do |s|
        label = s['name'] || s['uses'] || s['run'].to_s[0, 30]
        cond = s['if'].to_s.delete(' ')
        gated = cond.include?('inputs.push') && !cond.include?('!inputs.push')
        writes = s['uses'].to_s.start_with?('docker/login-action') ||
                 s.dig('with', 'push') == true || s.dig('with', 'push').to_s == 'true' ||
                 s['run'].to_s.include?('imagetools')
        findings << "step '#{label}' touches the registry but is not gated on inputs.push" if writes && !gated
        if cond.include?('!inputs.push') && s.dig('with', 'push') != false
          findings << "build-only step '#{label}' must set push: false"
        end
        findings << "step '#{label}' writes a cache (cache-to)" if s.dig('with', 'cache-to')
        findings << "step '#{label}' uses an Actions cache" if s['uses'].to_s.start_with?('actions/cache')
        if s['uses'].to_s.start_with?('aquasecurity/trivy-action')
          if s.dig('with', 'cache').to_s != 'false'
            findings << "trivy step '#{label}' must set cache: \"false\" (default writes the Actions cache)"
          end
          # The action's default Trivy version can point at a removed GitHub release (v0.64.1 did); pin explicitly.
          unless s.dig('with', 'version').to_s.match?(/\Av\d+\.\d+\.\d+\z/)
            findings << "trivy step '#{label}' must pin version to an explicit vX.Y.Z release"
          end
        end
      end
    end
    findings
  end

  def secret_names_declared(values, contract)
    declared = (contract['secrets'] || []).map { |s| s['name'] }
    referenced = []
    collect_secret_names(values, referenced)
    (referenced.uniq - declared).map { |n| "values reference Secret #{n} not declared in secrets-contract.yaml" }
  end

  def collect_secret_names(node, acc)
    case node
    when Hash
      node.each do |k, v|
        acc << v if %w[secret existingSecret].include?(k) && v.is_a?(String) && !v.empty?
        if k == 'pullSecrets' && v.is_a?(Array)
          v.each { |p| acc << p['name'] if p.is_a?(Hash) && p['name'] }
        end
        collect_secret_names(v, acc)
      end
    when Array then node.each { |v| collect_secret_names(v, acc) }
    end
  end

  def run(dir)
    files = Dir[File.join(dir, '**', '*.{yaml,yml}')].sort
    findings = []
    files.each { |f| findings.concat(duplicate_keys(File.read(f), f.sub("#{dir}/", ''))) }
    lock = YAML.safe_load(File.read(File.join(dir, 'images.lock.yaml')))
    wf_text = File.read(File.join(dir, 'ci', 'be293-portal-images.yml'))
    workflow = YAML.safe_load(wf_text)
    values = YAML.safe_load(File.read(File.join(dir, 'values-be293-portal.yaml')))
    contract = YAML.safe_load(File.read(File.join(dir, 'secrets-contract.yaml')))
    findings.concat(lock_vs_workflow_vs_values(lock, workflow, values))
    findings.concat(workflow_guardrails(wf_text, workflow))
    findings.concat(workflow_static(workflow))
    findings.concat(push_gating(workflow))
    findings.concat(secret_names_declared(values, contract))
    [files.size, findings]
  end
end

if $PROGRAM_NAME == __FILE__
  dir = File.expand_path(ARGV[0] || File.join(__dir__, '..'))
  begin
    count, findings = PortalPackageCheck.run(dir)
  rescue Psych::Exception, Errno::ENOENT => e
    warn "input error: #{e.message}"
    exit 2
  end
  puts "yaml files=#{count}"
  findings.each { |f| puts "FAIL #{f}" }
  puts(findings.empty? ? 'PACKAGE PASS' : "PACKAGE FAIL (#{findings.size})")
  exit(findings.empty? ? 0 : 1)
end
