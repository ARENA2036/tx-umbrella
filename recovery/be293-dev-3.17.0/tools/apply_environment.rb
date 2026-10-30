# Builds a private, environment-specific overlay from values/values-be293-dev.example.yaml.
#
# The example overlay uses reserved, non-resolvable identifiers (RFC 6761):
#   DNS suffix        example.invalid
#   registry host     registry.example.invalid
#   image repository  registry.example.invalid/be293/be293-images
# This tool substitutes the real values, supplied as environment variables, and writes the result
# to a file that must stay outside Git (the recovery .gitignore ignores *.private.yaml).
#
# Usage:
#   BE293_DNS_SUFFIX=<dns suffix> BE293_REGISTRY_HOST=<registry host> \
#   BE293_IMAGE_REPOSITORY=<registry host>/<namespace>/<repository> \
#   ruby tools/apply_environment.rb values/values-be293-dev.example.yaml <output>.private.yaml
#
# Credentials are NOT handled here; they stay placeholders and come from the secrets overlay.
EXAMPLE_SUFFIX = 'example.invalid'.freeze
EXAMPLE_REGISTRY = 'registry.example.invalid'.freeze
EXAMPLE_REPOSITORY = "#{EXAMPLE_REGISTRY}/be293/be293-images".freeze
EXAMPLE_REPOSITORY_PATH = 'be293/be293-images'.freeze

suffix = ENV.fetch('BE293_DNS_SUFFIX') { abort 'BE293_DNS_SUFFIX is required' }
registry = ENV.fetch('BE293_REGISTRY_HOST') { abort 'BE293_REGISTRY_HOST is required' }
repository = ENV.fetch('BE293_IMAGE_REPOSITORY') { abort 'BE293_IMAGE_REPOSITORY is required' }
abort 'BE293_IMAGE_REPOSITORY must start with BE293_REGISTRY_HOST/' unless repository.start_with?("#{registry}/")
[suffix, registry, repository].each { |v| abort 'values must not contain example.invalid' if v.include?(EXAMPLE_SUFFIX) }
input, output = ARGV
abort 'usage: apply_environment.rb <example.yaml> <output.private.yaml>' unless input && output
abort 'output file name must end in .private.yaml (git-ignored)' unless output.end_with?('.private.yaml')

text = File.read(input)
counts = Hash.new(0)
# Order matters: the most specific example identifiers are replaced first.
text = text.gsub(EXAMPLE_REPOSITORY) { counts['image repository'] += 1; repository }
text = text.gsub(/(?<=repository: )#{Regexp.escape(EXAMPLE_REPOSITORY_PATH)}/) { counts['image repository path'] += 1; repository.sub("#{registry}/", '') }
text = text.gsub(/(?<=: )#{Regexp.escape(EXAMPLE_REGISTRY)}$/) { counts['registry host'] += 1; registry }
text = text.gsub(EXAMPLE_SUFFIX) { counts['dns suffix'] += 1; suffix }
abort 'unreplaced example identifier left in output' if text.include?(EXAMPLE_SUFFIX)

File.write(output, text, perm: 0o600)
counts.each { |k, v| puts "#{k}: #{v}" }
puts "wrote #{output} (mode 600). Keep it out of Git and shared folders."
