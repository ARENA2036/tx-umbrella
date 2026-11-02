# Writes a SYNTHETIC secrets overlay for offline lint/render tests only.
# Every "<<SET-FROM-SECRET-STORE:label>>" placeholder becomes "synthetic-<sha256(label)[0,16]>".
# The output contains no real credential and must never be deployed.
# Usage: ruby tools/make_synthetic_secrets.rb values/values-be293-dev.secrets.example.yaml <out>.synthetic.secrets.yaml
Encoding.default_external = Encoding::UTF_8 # tools must not depend on the caller locale (LANG may be unset in CI)
require 'digest'
input, output = ARGV
abort 'usage: make_synthetic_secrets.rb <secrets.example.yaml> <out>.synthetic.secrets.yaml' unless input && output
abort 'output must end in .synthetic.secrets.yaml (git-ignored)' unless output.end_with?('.synthetic.secrets.yaml')
n = 0
text = File.read(input).gsub(/<<SET-FROM-SECRET-STORE:([^>]*)>>/) { n += 1; "synthetic-#{Digest::SHA256.hexdigest($1)[0, 16]}" }
File.write(output, "# SYNTHETIC TEST VALUES - NOT FOR DEPLOYMENT\n" + text, perm: 0o600)
puts "replaced #{n} placeholders -> #{output}"
