# Compares two inventories written by render_inventory.rb (expected first, actual second).
# Prints differences in object set, images, env NAMES, Secret references and volumeClaimTemplates.
# Exit 0 when identical, 1 otherwise. Never prints values.
# Usage: ruby tools/compare_inventory.rb inventory/expected-rev21-inventory.json actual.json
Encoding.default_external = Encoding::UTF_8 # tools must not depend on the caller locale (LANG may be unset in CI)
require 'json'
a = JSON.parse(File.read(ARGV[0])); b = JSON.parse(File.read(ARGV[1]))
diffs = 0
only_a = a.keys - b.keys; only_b = b.keys - a.keys
puts "objects expected=#{a.size} actual=#{b.size} missing=#{only_a.size} extra=#{only_b.size}"
only_a.each { |k| puts "  MISSING #{k}" }; only_b.each { |k| puts "  EXTRA   #{k}" }
diffs += only_a.size + only_b.size
(a.keys & b.keys).each do |k|
  %w[images env secretRefs vct hook].each do |f|
    x = a[k][f]; y = b[k][f]; next if x == y
    diffs += 1
    if x.is_a?(Array)
      puts "  #{k} #{f}: -#{(x - y).join(' ')} +#{(y - x).join(' ')}"
    else
      puts "  #{k} #{f}: #{x.inspect} -> #{y.inspect}"
    end
  end
end
puts "differences=#{diffs}"
exit(diffs.zero? ? 0 : 1)
