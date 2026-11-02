# Reads a multi-document Kubernetes YAML stream on stdin and writes a JSON inventory to stdout:
#   "Kind/name" => { hook, images[], env[] (NAMES only, "(ref)" when valueFrom), secretRefs[], vct[] }
# Secret data, ConfigMap data and env VALUES are never emitted.
# Usage: helm template ... | ruby tools/render_inventory.rb [--normalize-registry] > inventory.json
#   --normalize-registry  rewrites every private BE-293 image repository to the reserved example
#                         repository so DEV and example renders can be compared.
Encoding.default_external = Encoding::UTF_8 # tools must not depend on the caller locale (LANG may be unset in CI)
require 'yaml'; require 'json'
NORMALIZE = ARGV.include?('--normalize-registry')
EXAMPLE_REPO = 'registry.example.invalid/be293/be293-images'.freeze
def norm(img) NORMALIZE ? img.sub(%r{\A(?:[a-z0-9.\-]+(?::\d+)?/)?[a-z0-9._\-]+/be293-images(?=[:@])}, EXAMPLE_REPO) : img end
out = {}
YAML.load_stream($stdin.read) do |d|
  next unless d.is_a?(Hash) && d['kind']
  md = d['metadata'] || {}
  spec = d['spec'] || {}
  pod = spec.dig('template', 'spec') || spec.dig('jobTemplate', 'spec', 'template', 'spec') || (d['kind'] == 'Pod' ? spec : nil)
  imgs = []; envs = []; refs = []
  if pod
    (pod['imagePullSecrets'] || []).each { |s| refs << "pull:#{s['name']}" }
    (pod['volumes'] || []).each do |v|
      refs << "volume:#{v.dig('secret', 'secretName')}" if v.dig('secret', 'secretName')
      (v.dig('projected', 'sources') || []).each { |s| refs << "volume:#{s.dig('secret', 'name')}" if s.dig('secret', 'name') }
    end
    ((pod['containers'] || []) + (pod['initContainers'] || [])).each do |c|
      imgs << norm(c['image'].to_s)
      (c['env'] || []).each do |e|
        envs << "#{c['name']}:#{e['name']}#{e['valueFrom'] ? '(ref)' : ''}"
        r = e.dig('valueFrom', 'secretKeyRef'); refs << "env:#{r['name']}/#{r['key']}" if r
      end
      (c['envFrom'] || []).each { |e| refs << "envFrom:#{e.dig('secretRef', 'name')}" if e.dig('secretRef', 'name') }
    end
  end
  vct = (spec['volumeClaimTemplates'] || []).map { |v| "#{v.dig('metadata', 'name')}:#{v.dig('spec', 'resources', 'requests', 'storage')}:#{v.dig('spec', 'storageClassName')}" }
  out["#{d['kind']}/#{md['name']}"] = { 'hook' => (md['annotations'] || {})['helm.sh/hook'], 'images' => imgs.uniq.sort,
                                        'env' => envs.sort, 'secretRefs' => refs.uniq.sort, 'vct' => vct }
end
puts JSON.pretty_generate(out.sort.to_h)
