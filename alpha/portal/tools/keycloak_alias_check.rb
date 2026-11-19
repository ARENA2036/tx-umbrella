# frozen_string_literal: true

# Read-only proof that the BE-293 IdP alias prefix is unused in the SHARED Keycloaks before the Portal starts
# creating aliases with it. Uses the same service accounts and URLs as the live processes-worker (the caller
# passes them from the worker's env); sends only the client-credentials token request and GETs.
#
# For every n in 1..--to, alias = PREFIX + n (the backend names IdPs IdpPrefix + provisioning sequence):
#   central IdP   GET {central}/auth/admin/realms/{CentralRealm}/identity-provider/instances/{alias}  -> 404
#   shared realm  GET {shared}/auth/admin/realms/{alias}            -> 404 (Keycloak answers 404 before authz)
#   SA client     GET {shared}/auth/admin/realms/master/clients?clientId={SaPrefix}{alias}  -> 200 []
# Controls first, so a wrong URL or missing view right cannot pass as "absent":
#   the known existing central alias (--control-alias, e.g. idp2) -> 200; realm master -> 200;
#   the shared SA's own client is listed -> 200 [1 entry].
#
# stdin: `kubectl get secret <name> -o json`; --central-key/--shared-key name the data keys. Secrets and tokens
# are handed to curl through --config on stdin (never argv) and never printed.
# Exit: 0 all aliases absent; 1 any alias exists, a control failed, or the answer is not conclusive.

require 'base64'
require 'json'
require 'open3'
require 'optparse'

module KeycloakAliasCheck
  ALIAS = /\A[a-z0-9][a-z0-9-]*\z/.freeze

  class Error < StandardError; end

  Target = Struct.new(:base, :realm, :client_id, :secret)

  # Minimal HTTPS client on top of curl; replaceable in tests.
  class Curl
    def call(method, url, token: nil, form: nil)
      cfg = ["url = \"#{q(url)}\"", "request = \"#{method}\""]
      cfg << "header = \"Authorization: Bearer #{q(token)}\"" if token
      form&.each { |k, v| cfg << "data-urlencode = \"#{q("#{k}=#{v}")}\"" }
      out, _err, st = Open3.capture3('curl', '-sS', '--proto', '=https', '--max-time', '20', '-o', '-', '-w', "\n%{http_code}",
                                     '--config', '-', stdin_data: "#{cfg.join("\n")}\n")
      raise Error, "request failed: #{method} #{url.split('?').first}" unless st.success?

      body, _, code = out.rpartition("\n")
      [code.to_i, body]
    end

    private

    def q(value)
      raise Error, 'control character in curl config value' if value.to_s.match?(/[[:cntrl:]]/)

      value.to_s.gsub('\\') { '\\\\' }.gsub('"') { '\\"' }
    end
  end

  class Checker
    attr_reader :lines, :failures

    def initialize(http: Curl.new)
      @http = http
      @lines = []
      @failures = []
    end

    def run(central:, shared:, central_realm:, sa_prefix:, prefix:, upto:, control_alias:)
      raise Error, "prefix #{prefix.inspect} is not Keycloak-safe" unless prefix.match?(ALIAS) && prefix.end_with?('-')
      raise Error, "control alias #{control_alias.inspect} invalid" unless control_alias.match?(ALIAS)

      ct = token(central)
      st = token(shared)
      control(ct, st, central, shared, central_realm, control_alias)
      return self unless @failures.empty?

      (1..upto).each do |n|
        name = "#{prefix}#{n}"
        probe('central IdP', name, get(central, ct, "/admin/realms/#{central_realm}/identity-provider/instances/#{name}"), absent: [404], exists: [200])
        probe('shared realm', name, get(shared, st, "/admin/realms/#{name}"), absent: [404], exists: [200, 403])
        client = "#{sa_prefix}#{name}"
        code, body = get(shared, st, "/admin/realms/master/clients?clientId=#{client}")
        if code == 200 && list(body)&.empty?
          next
        elsif code == 200 && list(body)
          @failures << "EXISTS shared master client #{client}"
        else
          @failures << "UNKNOWN shared master client #{client} (HTTP #{code})"
        end
      end
      @lines << "OK   absent in shared Keycloaks: #{prefix}1..#{prefix}#{upto} (central IdP alias, shared realm, master client #{sa_prefix}<alias>)" if @failures.empty?
      self
    end

    private

    def token(t)
      code, body = @http.call('POST', "#{t.base}/auth/realms/#{t.realm}/protocol/openid-connect/token",
                              form: { 'grant_type' => 'client_credentials', 'client_id' => t.client_id, 'client_secret' => t.secret })
      tok = code == 200 && (JSON.parse(body)['access_token'] rescue nil)
      raise Error, "token request for #{t.client_id} at #{t.base} realm #{t.realm} failed (HTTP #{code})" unless tok.is_a?(String) && !tok.empty?

      tok
    end

    def get(t, tok, path)
      @http.call('GET', "#{t.base}/auth#{path}", token: tok)
    end

    def list(body)
      v = JSON.parse(body)
      v.is_a?(Array) ? v : nil
    rescue JSON::ParserError
      nil
    end

    def control(ct, st, central, shared, central_realm, control_alias)
      code, = get(central, ct, "/admin/realms/#{central_realm}/identity-provider/instances/#{control_alias}")
      @failures << "CONTROL central IdP #{control_alias} -> HTTP #{code} (expected 200: probe cannot see existing aliases)" unless code == 200
      code, = get(shared, st, '/admin/realms/master')
      @failures << "CONTROL shared realm master -> HTTP #{code} (expected 200)" unless code == 200
      code, body = get(shared, st, "/admin/realms/master/clients?clientId=#{shared.client_id}")
      @failures << "CONTROL shared master client #{shared.client_id} -> HTTP #{code} (expected 200 with 1 entry)" unless code == 200 && list(body)&.size == 1
      @lines << 'OK   controls: existing central alias visible, master realm and its clients readable' if @failures.empty?
    end

    def probe(what, name, result, absent:, exists:)
      code, = result
      return if absent.include?(code)

      @failures << (exists.include?(code) ? "EXISTS #{what} #{name} (HTTP #{code})" : "UNKNOWN #{what} #{name} (HTTP #{code})")
    end
  end

  def self.secret_value(secret_json, key)
    data = JSON.parse(secret_json).fetch('data', {})
    raise Error, "secret key #{key} missing" unless data[key]

    v = Base64.strict_decode64(data[key])
    raise Error, "secret key #{key} empty or contains control characters" if v.empty? || v.match?(/[[:cntrl:]]/)

    v
  end
end

if $PROGRAM_NAME == __FILE__
  o = {}
  OptionParser.new do |p|
    %w[central-url central-auth-realm central-client shared-url shared-auth-realm shared-client central-realm
       sa-prefix prefix control-alias central-key shared-key].each { |k| p.on("--#{k} V") { |v| o[k] = v } }
    p.on('--to N', Integer) { |v| o['to'] = v }
  end.parse!
  missing = %w[central-url central-auth-realm central-client shared-url shared-auth-realm shared-client central-realm
               sa-prefix prefix control-alias central-key shared-key to].reject { |k| o[k] }
  abort("missing: #{missing.map { |k| "--#{k}" }.join(' ')}") unless missing.empty?
  abort('--to must be 1..200') unless (1..200).cover?(o['to'])
  %w[central-url shared-url].each { |k| abort("#{k} must be https://") unless o[k].match?(%r{\Ahttps://[a-z0-9.-]+\z}) }

  begin
    secret = $stdin.read
    central = KeycloakAliasCheck::Target.new(o['central-url'], o['central-auth-realm'], o['central-client'],
                                             KeycloakAliasCheck.secret_value(secret, o['central-key']))
    shared = KeycloakAliasCheck::Target.new(o['shared-url'], o['shared-auth-realm'], o['shared-client'],
                                            KeycloakAliasCheck.secret_value(secret, o['shared-key']))
    secret = nil
    c = KeycloakAliasCheck::Checker.new.run(central: central, shared: shared, central_realm: o['central-realm'], sa_prefix: o['sa-prefix'],
                                            prefix: o['prefix'], upto: o['to'], control_alias: o['control-alias'])
  rescue KeycloakAliasCheck::Error, JSON::ParserError, ArgumentError, KeyError => e
    puts "FAIL keycloak alias check: #{e.class}: #{e.message.lines.first}"
    exit 1
  end
  c.lines.each { |l| puts l }
  c.failures.each { |f| puts "FAIL #{f}" }
  exit(c.failures.empty? ? 0 : 1)
end
