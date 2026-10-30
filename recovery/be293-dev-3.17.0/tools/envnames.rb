# Writes "Kind/name container ENV_NAME source" lines; source is value|secretKeyRef|configMapKeyRef|fieldRef. Values never written.
require 'yaml'
out = []
YAML.load_stream(STDIN.read) do |d|
  next unless d.is_a?(Hash) && d['kind']
  id = "#{d['kind']}/#{d.dig('metadata', 'name')}"
  spec = d.dig('spec', 'template', 'spec') || d.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
  next unless spec
  ((spec['initContainers'] || []) + (spec['containers'] || [])).each do |c|
    (c['env'] || []).each { |e| src = e.key?('valueFrom') ? e['valueFrom'].keys.first : 'value'; out << "#{id} #{c['name']} #{e['name']} #{src}" }
  end
end
File.write(ARGV[0], out.sort.uniq.join("\n") + "\n")
