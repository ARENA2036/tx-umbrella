# Generates chart/umbrella/files/be293-target-credentials.json, the credential contract the
# be293-target guard enforces at render time. It contains paths and labels only, no values.
#
# One entry per "<<SET-FROM-SECRET-STORE:label>>" leaf of the secrets example:
#   path       value path (strings = map keys, integers = list indexes)
#   label      placeholder label
#   altPath    optional path whose non-empty value means the credential is delivered by a
#              Kubernetes Secret reference instead (values-be293-identityhub-superuser-secretref.yaml)
#   minLength  minimum accepted length
# The vendored chart defaults are sanitized placeholders, so "still the chart default" is
# covered by the placeholder rule.
#
# Usage: ruby tools/gen_credential_checks.rb <secrets.example.yaml> <out.json>
Encoding.default_external = Encoding::UTF_8 # tools must not depend on the caller locale (LANG may be unset in CI)
require 'yaml'
require 'json'

secrets_example, output = ARGV
abort 'usage: gen_credential_checks.rb <secrets.example.yaml> <out.json>' unless output

PLACEHOLDER = /\A<<SET-FROM-SECRET-STORE:([^>]*)>>\z/.freeze
MIN_LENGTH = 16
# Vault key names are identifiers, not secrets; only the placeholder rule applies.
IDENTIFIER_KEYS = %w[secret_alias].freeze

def leaves(node, path = [], &block)
  case node
  when Hash then node.each { |k, v| leaves(v, path + [k.to_s], &block) }
  when Array then node.each_with_index { |v, i| leaves(v, path + [i], &block) }
  else yield path, node
  end
end

def alt_path(path)
  if path[-2] == 'env'
    path[0..-3] + ['envValueFrom', path[-1], 'secretKeyRef', 'name']
  elsif path[0, 4] == %w[portal backend processesworker identityHub] && %w[apiKey issuerAdminApiKey].include?(path[-1])
    path[0..-2] + ['existingSecret']
  end
end

entries = []
leaves(YAML.safe_load(File.read(secrets_example), aliases: true)) do |path, value|
  next unless value.is_a?(String) && (m = PLACEHOLDER.match(value))
  entry = { 'path' => path, 'label' => m[1], 'minLength' => IDENTIFIER_KEYS.include?(path[-1]) ? 1 : MIN_LENGTH }
  alt = alt_path(path)
  entry['altPath'] = alt if alt
  entries << entry
end
abort 'no credential placeholders found' if entries.empty?
File.write(output, JSON.pretty_generate(entries) + "\n")
puts "credentials=#{entries.size} secretref-alternatives=#{entries.count { |e| e['altPath'] }} -> #{output}"
