# Copies a values YAML, replacing every inline credential with a labeled placeholder
# "<<SET-FROM-SECRET-STORE:dotted.path>>". Secret *reference* names/keys and URLs are kept.
require 'yaml'
load File.expand_path('redact_lib.rb', __dir__)
def label(o, path, hits)
  case o
  when Hash then o.each_with_object({}) { |(k, v), h| h[k] = label(v, path + [k], hits) }
  when Array then o.each_with_index.map { |v, i| label(v, path + [i], hits) }
  else
    return o unless payload?(path, o)
    p = path.join('.'); hits << p; "<<SET-FROM-SECRET-STORE:#{p}>>"
  end
end
src = YAML.safe_load(File.read(ARGV[0]), aliases: true); hits = []
body = label(src, [], hits).to_yaml.sub(/\A---\n/, '')
header = <<~H
  # BE-293 DEV overrides for Helm release be293-app (namespace be293), revision 21, chart umbrella-3.17.0.
  # Sanitized copy: #{hits.size} inline credentials were replaced with "<<SET-FROM-SECRET-STORE:...>>" placeholders.
  # The placeholders are NOT valid values. Get the real values from the secret owner; never commit them.
  # Existing Kubernetes Secret references (names/keys) are kept unchanged. See README.md.
H
File.write(ARGV[1], header + body)
STDERR.puts "placeholders=#{hits.size}"; hits.each { |h| STDERR.puts "  #{h}" }
