# frozen_string_literal: true

# Checks ONE live Secret (as `kubectl get secret -o json` on stdin; empty stdin = Secret absent) against
# secrets-contract.yaml. Prints only names, key presence, byte lengths and format verdicts. NEVER prints,
# logs or writes a secret value; decoded values exist only in memory for the format check.
#
# Usage: kubectl ... get secret NAME -o json | ruby tools/check_secret_contract.rb --contract FILE --name NAME [--mail-disabled]
# Exit: 0 no FAIL, 1 at least one FAIL, 2 usage/input error.

require 'base64'
require 'json'
require 'optparse'
require 'yaml'

module SecretContract
  HELM_RELEASE = 'be293-portal'
  NAMESPACE = 'be293'
  REQUIRED_CLASSES = %w[owner-provisioned operator-generated].freeze
  HEX64 = /\A\h{64}\z/.freeze
  # Registry the rebuilt images are pulled from (values-be293-portal.yaml); a host name, not a credential.
  PULL_REGISTRY = 'harbor-hub-shared.arena.3ascloud.de'

  # Returns [[level, message], ...]; level is OK, WARN or FAIL.
  def self.check(spec, secret, mail_disabled: false)
    name = spec['name']
    keys = spec['keys'] || {}
    out = []
    if secret.nil?
      if keys.values.all? { |k| k['class'] == 'chart-generated' }
        out << ['OK', "#{name} absent; chart generates it on first install"]
      elsif mail_disabled && name.end_with?('-mailing')
        out << ['OK', "#{name} absent; mail disabled, chart fills random fail-closed passwords"]
      else
        out << ['FAIL', "#{name} missing (required before install)"]
      end
      return out
    end

    meta = secret['metadata'] || {}
    ns = meta['namespace']
    out << ['FAIL', "#{name} namespace #{ns.inspect} != #{NAMESPACE}"] unless ns == NAMESPACE
    if spec['type'] && secret['type'] != spec['type']
      out << ['FAIL', "#{name} type #{secret['type'].inspect} != #{spec['type']}"]
    end
    check_adoption(spec, meta, out)
    out << ['WARN', "#{name} pre-exists although mail is disabled; confirm it holds no live SMTP credential"] if mail_disabled && name.end_with?('-mailing')
    if keys.values.all? { |k| k['class'] == 'chart-generated' }
      out << ['WARN', "#{name} pre-exists: Helm lookup will REUSE its credentials; on a first install it is expected absent"]
    end

    data = secret['data'] || {}
    keys.each do |key, k|
      out.concat(check_key(name, key, k, data[key]))
    end
    extra = data.keys - keys.keys
    out << ['WARN', "#{name} has undeclared keys #{extra.sort.inspect}"] unless extra.empty?
    out
  end

  def self.check_adoption(spec, meta, out)
    return unless spec['adoptedByChart']

    labels = meta['labels'] || {}
    ann = meta['annotations'] || {}
    ok = labels['app.kubernetes.io/managed-by'] == 'Helm' &&
         ann['meta.helm.sh/release-name'] == HELM_RELEASE &&
         ann['meta.helm.sh/release-namespace'] == NAMESPACE
    out << (ok ? ['OK', "#{spec['name']} carries Helm adoption metadata for #{HELM_RELEASE}"] :
                 ['FAIL', "#{spec['name']} lacks Helm adoption metadata (helm install would refuse it)"])
  end

  def self.check_key(name, key, k, b64)
    cls = k['class']
    if b64.nil? || b64.empty?
      return [] if cls == 'unused' && b64.nil?

      return [[REQUIRED_CLASSES.include?(cls) ? 'FAIL' : 'WARN', "#{name}/#{key} (#{cls}) missing or empty"]]
    end

    value = Base64.strict_decode64(b64)
    # A NUL byte cannot be passed as an environment variable: the container fails to start.
    return [['FAIL', "#{name}/#{key} (#{cls}) contains a NUL byte (container creation fails)"]] if value.include?("\0")
    return [['OK', "#{name}/#{key} (unused) present, #{value.bytesize} bytes, no NUL"]] if cls == 'unused'

    res = [['OK', "#{name}/#{key} (#{cls}) present, #{value.bytesize} bytes"]]
    res << ['FAIL', "#{name}/#{key} is not 64 hex characters"] if k['format'] == '64 hex chars' && !value.match?(HEX64)
    res << ['FAIL', "#{name}/#{key} has leading/trailing whitespace"] if value != value.strip
    res.concat(check_dockerconfig(name, value)) if key == '.dockerconfigjson'
    res
  rescue ArgumentError
    [['FAIL', "#{name}/#{key} is not valid base64"]]
  end

  def self.check_dockerconfig(name, value)
    auths = JSON.parse(value)['auths'] || {}
    hit = auths.keys.any? { |h| h.sub(%r{\Ahttps?://}, '').split('/').first == PULL_REGISTRY }
    [[hit ? 'OK' : 'FAIL', "#{name} .dockerconfigjson #{hit ? 'has' : 'has NO'} entry for #{PULL_REGISTRY}"]]
  rescue JSON::ParserError
    [['FAIL', "#{name} .dockerconfigjson is not valid JSON"]]
  end
end

if $PROGRAM_NAME == __FILE__
  opts = { mail_disabled: false }
  OptionParser.new do |o|
    o.on('--contract FILE') { |v| opts[:contract] = v }
    o.on('--name NAME') { |v| opts[:name] = v }
    o.on('--mail-disabled') { opts[:mail_disabled] = true }
  end.parse!
  abort('usage: --contract FILE --name NAME') unless opts[:contract] && opts[:name]

  begin
    contract = YAML.safe_load(File.read(opts[:contract]))
    spec = (contract['secrets'] || []).find { |s| s['name'] == opts[:name] }
    abort("#{opts[:name]} is not declared in #{opts[:contract]}") unless spec
    raw = $stdin.read
    secret = raw.strip.empty? ? nil : JSON.parse(raw)
  rescue Psych::Exception, JSON::ParserError, Errno::ENOENT => e
    warn "input error: #{e.class}" # message could echo input; class only
    exit 2
  end

  results = SecretContract.check(spec, secret, mail_disabled: opts[:mail_disabled])
  results.each { |level, msg| puts "#{level.ljust(4)} #{msg}" }
  exit(results.any? { |l, _| l == 'FAIL' } ? 1 : 0)
end
