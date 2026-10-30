# Line-preserving sanitizer for Helm values files (keeps comments and key order).
# Replaces literal scalars (incl. block scalars) of credential-like keys with
#   "<<SET-FROM-SECRET-STORE:<label>:<yaml.path>>>"
# Usage: ruby sanitize_text_values.rb <in> <out> <label> [--dry-run]
# Prints replaced YAML paths only; values are never printed.
CRED_KEY = /(password|passwd|secret|token|api[_-]?key|apikey|private[_-]?key|client[_-]?secret|encryption[_-]?key|auth[_-]?key|x_api_key|superuser|\Akey\z|\Asatest\d+\z|\Asa-[a-z0-9-]+\z)/i
REF_KEY = /(existing|secretname|secretref|secret[_-]?alias|keyalias|alias\z|secretkey\z|passwordkey\z|\Aname\z|secretKeys|tokenurl|token_url|tokenuri|tokenaddress|path|type|enabled|file|length|ttl|expir|duration|header|policy|issuer|url\z|uri\z|address\z|endpoint|mount|annotations?|delivery\z|mode\z)/i
inp, outp, label, dry = ARGV
src = File.readlines(inp); out = []; stack = []; counters = Hash.new(-1); replaced = []; skip_ind = nil
src.each_with_index do |l, li|
  if skip_ind
    if l.strip.empty? || l[/\A */].size > skip_ind then next else skip_ind = nil end
  end
  m = (!l.strip.empty? && !l.lstrip.start_with?('#')) && l.match(/\A(\s*)(- )?([^\s:#'"][^:#]*?|"[^"]+"|'[^']+'):(\s+|\n|\z)(.*?)\s*(#.*)?\z/m)
  unless m then out << l; next end
  base = m[1].size; ind = base + (m[2] ? 2 : 0); key = m[3].strip.delete('"\'')
  stack.pop while stack.any? && stack.last[0] >= (m[2] ? base : ind)
  if m[2]
    parent = stack.map { |s| s[1] }.join('.') + "@#{base}"
    counters[parent] += 1
    stack << [base, "[#{counters[parent]}]", true]
  end
  stack << [ind, key, false]
  raw = m[5].to_s
  # Plain scalar continued on the next, more-indented line (e.g. "encryptionKey:\n  \"...\"").
  if raw.empty?
    nxt = src[(li + 1)..-1].find { |x| !x.strip.empty? && !x.lstrip.start_with?("#") }
    cont = nxt && nxt[/\A */].size > ind && nxt !~ /\A\s*-\s/ && nxt !~ /\A\s*[^\s:#"']+:(\s|\z)/
    raw = "|" if cont
  end
  path = stack.map { |s| s[1] }.join('.').gsub('.[', '[')
  if key =~ CRED_KEY && key !~ REF_KEY && !raw.empty?
    block = raw =~ /\A[|>][-+0-9]*\z/
    val = raw.sub(/\A(["'])(.*)\1\z/, '\2')
    unless !block && (val =~ /\A(true|false|null|~|\{\}|\[\]|""|'')\z/ || val.include?('{{') || val =~ %r{\A(https?|jdbc|did|file):} || val.start_with?('<<SET-FROM-SECRET-STORE'))
      replaced << path
      out << "#{m[1]}#{m[2]}#{m[3]}: \"<<SET-FROM-SECRET-STORE:#{label}:#{path}>>\"#{m[6] ? ' ' + m[6].rstrip : ''}\n"
      skip_ind = ind if block
      next
    end
  end
  out << l
end
File.write(outp, out.join) unless dry
puts "replaced=#{replaced.size} unique_labels=#{replaced.uniq.size}"; replaced.each { |p| puts "  #{p}" } if ENV['VERBOSE']
