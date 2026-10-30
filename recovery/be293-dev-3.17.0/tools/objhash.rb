# Emits "Kind/name sha256" per non-Secret object (canonicalized), for content comparison. Nothing else is written.
require 'yaml'; require 'json'; require 'digest'
def c(o) o.is_a?(Hash) ? o.keys.sort.map { |k| [k, c(o[k])] }.to_h : (o.is_a?(Array) ? o.map { |x| c(x) } : o) end
out = []
YAML.load_stream(STDIN.read) { |d| next unless d.is_a?(Hash) && d['kind'] && d['kind'] != 'Secret'; out << "#{d['kind']}/#{d.dig('metadata','name')} #{Digest::SHA256.hexdigest(JSON.generate(c(d)))[0,16]}" }
File.write(ARGV[0], out.sort.join("\n") + "\n")
