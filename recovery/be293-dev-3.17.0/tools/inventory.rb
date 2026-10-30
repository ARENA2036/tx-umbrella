# Reads multi-document Kubernetes YAML on stdin; writes "Kind/name" lines (ARGV[0]) and
# "Kind/name container image" lines (ARGV[1]). Secret data/env values are never written.
require 'yaml'
inv = []; imgs = []
YAML.load_stream(STDIN.read) do |d|
  next unless d.is_a?(Hash) && d['kind']
  id = "#{d['kind']}/#{d.dig('metadata', 'name')}"
  inv << id
  spec = d.dig('spec', 'template', 'spec') || d.dig('spec', 'jobTemplate', 'spec', 'template', 'spec') || (d['kind'] == 'Pod' ? d['spec'] : nil)
  next unless spec
  ((spec['initContainers'] || []) + (spec['containers'] || [])).each { |c| imgs << "#{id} #{c['name']} #{c['image']}" }
end
File.write(ARGV[0], inv.sort.uniq.join("\n") + "\n"); File.write(ARGV[1], imgs.sort.uniq.join("\n") + "\n")
STDERR.puts "documents=#{inv.size} unique=#{inv.uniq.size}"
