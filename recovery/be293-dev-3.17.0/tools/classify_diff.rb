# Compares leaves of selected objects (live on stdin, render in ARGV[1]); classifies each differing leaf.
# Prints object, path and cause only. Values are never printed.
require 'yaml'
ids = File.readlines(ARGV[0]).map(&:strip)
def leaves(stream, ids) out = {}; YAML.load_stream(stream) { |d| next unless d.is_a?(Hash); id = "#{d['kind']}/#{d.dig('metadata','name')}"; next unless ids.include?(id)
  f = lambda { |o, p| case o when Hash then o.each { |k, v| f.(v, "#{p}.#{k}") } when Array then o.each_with_index { |v, i| f.(v, "#{p}[#{v.is_a?(Hash) && v['name'] ? v['name'] : i}]") } else out["#{id} #{p}"] = o.to_s end }; f.(d, '') }; out end
live = leaves(STDIN.read, ids); ren = leaves(File.read(ARGV[1]), ids)
(live.keys | ren.keys).sort.each do |k|
  a = live[k]; b = ren[k]; next if a == b
  cause = if b.to_s.include?('<<SET-FROM-SECRET-STORE') then 'placeholder'
          elsif b.nil? && k =~ /controller-uid|job-name|backoffLimit|completion|parallelism|suspend|manualSelector|podReplacementPolicy|terminationMessage|dnsPolicy|schedulerName|restartPolicy|securityContext|ephemeral|imagePullPolicy|creationTimestamp/ then 'server-defaulted(lookup copy)'
          elsif k =~ /checksum/ then 'checksum-of-secret-input'
          else 'OTHER' end
  puts "#{cause.ljust(30)} #{k}"
end
