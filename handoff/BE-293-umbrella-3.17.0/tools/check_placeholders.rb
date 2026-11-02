# Fails (exit 1) if a rendered manifest stream on stdin still contains credential placeholders
# or reserved example identifiers. Prints only placeholder LABELS and counts, never values.
# Usage: helm template ... | ruby tools/check_placeholders.rb [--allow-example-domain]
Encoding.default_external = Encoding::UTF_8 # tools must not depend on the caller locale (LANG may be unset in CI)
allow_example = ARGV.include?('--allow-example-domain')
text = $stdin.read
labels = text.scan(/<<SET-FROM-SECRET-STORE:([^>]*)>>/).flatten.group_by(&:itself).map { |k, v| [k, v.size] }.to_h
examples = allow_example ? 0 : text.scan(/example\.invalid/).size
labels.sort.each { |l, c| puts "PLACEHOLDER #{l} x#{c}" }
puts "placeholders=#{labels.size} example-identifiers=#{examples}"
exit(labels.empty? && examples.zero? ? 0 : 1)
