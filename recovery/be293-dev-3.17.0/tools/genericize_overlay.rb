# Turns the private DEV overlay into a non-deployable example by replacing internal environment
# identifiers with reserved example values (RFC 6761 ".invalid" never resolves).
# Usage: ruby genericize_overlay.rb <in> <out>. Prints replacement counts only.
SRC_ZONE = ENV.fetch('SRC_DNS_SUFFIX'); SRC_REPO = ENV.fetch('SRC_IMAGE_REPO')     # supplied at run time, not stored here
DST_ZONE = 'example.invalid'; DST_REGISTRY = 'registry.example.invalid'; DST_REPO = "#{DST_REGISTRY}/be293/be293-images"
src_ns_repo = SRC_REPO.sub(%r{\A[^/]+/}, '')                     # repository without registry host
lines = File.readlines(ARGV[0]); counts = Hash.new(0)
lines.each_with_index do |l, i|
  ind = l[/\A */].size
  sibling = ->(rx) { (([i - 3, 0].max)..[i + 3, lines.size - 1].min).any? { |j| j != i && lines[j][/\A */].size == ind && lines[j] =~ rx } }
  if l =~ /\A\s*registry:\s*docker\.io\s*\z/ && sibling.(/repository:\s*#{Regexp.escape(src_ns_repo)}/)
    l.sub!('docker.io', DST_REGISTRY); counts['registry field of private image'] += 1
  elsif l =~ /\A\s*(registryHost|registry):\s*docker\.io\s*\z/ && (lines[i - 3..i + 3] || []).any? { |x| x =~ /pullSecretName|privateImages|clusterIssuer|storageClass|repository:\s*#{Regexp.escape(SRC_REPO)}/ }
    l.sub!('docker.io', DST_REGISTRY); counts["#{$1} (be293 platform/privateImages)"] += 1
  end
  n = l.scan(SRC_REPO).size; (l.gsub!(SRC_REPO, DST_REPO); counts['private image repository (with registry)'] += n) if n > 0
  n = l.scan(src_ns_repo).size; (l.gsub!(src_ns_repo, 'be293/be293-images'); counts['private image repository (without registry)'] += n) if n > 0
  n = l.scan(SRC_ZONE).size; (l.gsub!(SRC_ZONE, DST_ZONE); counts['DNS suffix (hosts, URLs, DIDs)'] += n) if n > 0
end
File.write(ARGV[1], lines.join)
counts.each { |k, v| puts "  #{k}: #{v}" }
