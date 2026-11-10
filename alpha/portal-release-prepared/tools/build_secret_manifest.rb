# frozen_string_literal: true

# Builds ONE be293 Secret manifest (JSON on stdout) from secrets-contract.yaml:
#   owner-provisioned  prompted silently on /dev/tty (never echoed, never an argument or env var)
#   operator-generated generated here with SecureRandom (64 hex chars), never displayed
#   unused             fixed printable sentinel `disabled-<feature>-no-access` (not a credential)
#   chart-generated    omitted
# `unused` keys must NOT be omitted from a Secret the chart adopts: for a key missing from an EXISTING Secret,
# portal-2.6.0 writes `randAlphaNum 32` UNENCODED into `data:`, which Kubernetes base64-decodes into 24 random
# bytes; a NUL byte among them (~9% per key) makes container creation fail (Alpha, custodian-client-secret).
# Secrets the chart renders (adoptedByChart: true) get the Helm adoption metadata, so `helm install` adopts
# them instead of refusing them, and Helm `lookup` preserves their data.
#
# stdout must be a pipe (tools/create-be293-secret.sh); writing secret JSON to a terminal is refused.
# Usage: ruby tools/build_secret_manifest.rb --contract FILE --name NAME | <consumer>

require 'base64'
require 'io/console'
require 'json'
require 'optparse'
require 'securerandom'
require 'yaml'

module SecretManifest
  NAMESPACE = 'be293'
  RELEASE = 'be293-portal'
  # Not pre-created: postgres is chart-generated; mailing stays absent while outbound mail is disabled (M1);
  # the pull Secret already exists and is owned by the platform.
  REFUSED = {
    'be293-portal-postgres' => 'chart-generated on first install; must not be pre-created',
    'be293-portal-mailing' => 'mail is disabled on Alpha (M1); the chart fills fail-closed random passwords',
    'be293-portal-registry-pull' => 'platform-provisioned and already present'
  }.freeze

  # prompt: ->(label) { String } supplies owner-provisioned values.
  def self.build(spec, prompt:)
    name = spec['name']
    raise ArgumentError, "#{name}: #{REFUSED[name]}" if REFUSED.key?(name)

    data = {}
    (spec['keys'] || {}).each do |key, k|
      case k['class']
      when 'owner-provisioned'
        value = prompt.call("#{name}/#{key} (owner: #{k['owner']}#{k['clientId'] ? ", client #{k['clientId']}" : ''})")
        raise ArgumentError, "#{name}/#{key}: empty value" if value.empty?
        raise ArgumentError, "#{name}/#{key}: leading/trailing whitespace" if value != value.strip

        data[key] = Base64.strict_encode64(value)
      when 'operator-generated'
        raise ArgumentError, "#{name}/#{key}: unsupported format #{k['format'].inspect}" unless k['format'] == '64 hex chars'

        data[key] = Base64.strict_encode64(SecureRandom.hex(32))
      when 'unused'
        data[key] = Base64.strict_encode64(unused_sentinel(key))
      end
    end

    meta = { 'name' => name, 'namespace' => NAMESPACE, 'labels' => { 'app.kubernetes.io/part-of' => RELEASE } }
    if spec['adoptedByChart']
      meta['labels']['app.kubernetes.io/managed-by'] = 'Helm'
      meta['annotations'] = { 'meta.helm.sh/release-name' => RELEASE, 'meta.helm.sh/release-namespace' => NAMESPACE }
    end
    { 'apiVersion' => 'v1', 'kind' => 'Secret', 'metadata' => meta, 'type' => spec['type'] || 'Opaque', 'data' => data }
  end

  # custodian-client-secret -> disabled-custodian-no-access (the value applied on Alpha).
  def self.unused_sentinel(key)
    "disabled-#{key.sub(/-client-secret.*\z/, '')}-no-access"
  end

  # Opens /dev/tty only on the first prompt, so refusals and generated-only Secrets need no terminal.
  def self.tty_prompt
    tty = nil
    lambda do |label|
      tty ||= File.open('/dev/tty', 'r+')
      tty.print("#{label}: ")
      tty.flush
      value = tty.noecho(&:gets).to_s.chomp
      tty.puts
      value
    end
  end
end

if $PROGRAM_NAME == __FILE__
  opts = {}
  OptionParser.new do |o|
    o.on('--contract FILE') { |v| opts[:contract] = v }
    o.on('--name NAME') { |v| opts[:name] = v }
  end.parse!
  abort('usage: --contract FILE --name NAME') unless opts[:contract] && opts[:name]
  abort('refusing to write secret material to a terminal; pipe stdout') if $stdout.tty?

  begin
    spec = (YAML.safe_load(File.read(opts[:contract]))['secrets'] || []).find { |s| s['name'] == opts[:name] }
    abort("#{opts[:name]} is not declared in #{opts[:contract]}") unless spec
    $stdout.write(JSON.generate(SecretManifest.build(spec, prompt: SecretManifest.tty_prompt)))
  rescue ArgumentError, Errno::ENOENT, Errno::ENXIO => e
    warn "error: #{e.message}"
    exit 2
  end
end
