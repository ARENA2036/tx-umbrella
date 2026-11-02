# Usage: ruby scan.rb <dir> <report>. Reports "file:line rule shape" only; matched values are never written.
require 'find'
def entropy(s) f = s.chars.group_by(&:itself).values.map(&:size); n = s.length.to_f; -f.sum { |c| (c / n) * Math.log2(c / n) } end
def shape(v) "len=#{v.length} H=#{entropy(v).round(2)}" end
KEYRX = /\b([A-Za-z0-9_.\-]*(password|passwd|secret|token|api[_-]?key|apikey|private[_-]?key|privatekey|client[_-]?secret|encryption[_-]?key|encryptionkey|auth[_-]?key|authkey|x_api_key|superuser|credential|signing[_-]?key|aes)[A-Za-z0-9_.\-]*)\s*[:=]\s*["']?([^"'\s#{}][^"'\s#]*)["']?/i
SAFE_VAL = /\A(true|false|null|~|""|''|\{\{.*|<<SET-FROM-SECRET-STORE:.*|[A-Za-z0-9._\-\/]*(SecretRef|secretRef|existing|Key|key|alias|-key|-secret|-password|-token|_KEY|_SECRET|_PASSWORD|_TOKEN)|https?:\/\/.*|jdbc:.*|\$\{?[A-Za-z_].*|[a-z0-9]+([-_.][a-z0-9]+)*)\z/
hits = []
Find.find(ARGV[0]) do |path|
  next unless File.file?(path)
  data = File.binread(path); next if data.include?("\x00")
  data.force_encoding('UTF-8'); data = data.scrub('?')
  rel = path.sub(ARGV[0] + '/', '')
  data.each_line.with_index(1) do |l, i|
    hits << "#{rel}:#{i} PEM-PRIVATE-KEY" if l =~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/
    hits << "#{rel}:#{i} PEM-CERT(info)" if l =~ /-----BEGIN CERTIFICATE-----/
    l.scan(/eyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]*/) { |m| hits << "#{rel}:#{i} JWT #{shape(m)}" }
    hits << "#{rel}:#{i} JWK-PRIVATE-d" if l =~ /"d"\s*:\s*"[A-Za-z0-9_\-]{20,}"/
    hits << "#{rel}:#{i} DOCKER-AUTH" if l =~ /"auth"\s*:\s*"[A-Za-z0-9+\/=]{12,}"/
    hits << "#{rel}:#{i} CLOUD-TOKEN" if l =~ /(AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|github_pat_|xox[baprs]-|sk_live_|glpat-)/
    if (m = l.match(KEYRX)) && m[3] !~ SAFE_VAL && m[3].length >= 4
      hits << "#{rel}:#{i} KEYED-LITERAL key=#{m[1]} #{shape(m[3])}"
    end
    l.scan(/(?<![A-Za-z0-9+\/=_\-])[A-Za-z0-9+\/_\-]{32,}={0,2}(?![A-Za-z0-9+\/=_\-])/) do |m|
      next if m =~ /\A[0-9a-f]+\z/i || m =~ /\A[a-z\-_\/]+\z/i || entropy(m) < 4.3
      hits << "#{rel}:#{i} HIGH-ENTROPY #{shape(m)}"
    end
  end
end
File.write(ARGV[1], hits.join("\n") + "\n")
puts "total hits=#{hits.size}"; hits.map { |h| h.split(' ')[1] }.group_by(&:itself).map { |k, v| [k, v.size] }.sort_by { |k, v| -v }.each { |k, v| puts "  #{k}: #{v}" }
