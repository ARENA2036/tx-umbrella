# frozen_string_literal: true

# Derives the BPDM API version prefix from a live OpenAPI document (stdin) by matching every request the pinned
# Portal backend (ad459ee7) sends to that API, then checks the request/response fields the backend writes or
# reads against that version's schemas. Offline; reads only the document.
#
#   Gate (BpdmService, base APPLICATIONCHECKLIST__BPDM__BASEADDRESS) - BPN Creation:
#     PUT input/business-partners · POST sharing-state/ready · POST output/business-partners/search · GET sharing-state
#   Pool (BpdmService "Pool" client and BpnAccess, base ...BUSINESSPARTNERPOOLBASEADDRESS / BPNACCESS__BASEADDRESS):
#     PUT cx-memberships (application activation) · GET legal-entities/{bpn} (BPN lookup)
#
# Field paths: "a.b" nests objects, "[]" steps into array items; $ref and allOf are resolved.
#
# Usage: ruby tools/bpdm_openapi.rb --api gate|pool < api-docs.json
# Prints "OK <api> prefix=/vN title=... version=..." and one "SCHEMA <OK|MISMATCH> <call> ..." line per checked
# body. Exits 1 if no single version prefix serves every call, or if a call used by BPN Creation mismatches.

require 'json'
require 'optparse'

module BpdmOpenApi
  CALLS = {
    'gate' => [%w[put input/business-partners], %w[post sharing-state/ready], %w[post output/business-partners/search], %w[get sharing-state]],
    'pool' => [%w[put cx-memberships], ['get', 'legal-entities/{}']]
  }.freeze

  ADDR = '[].address.physicalPostalAddress'
  # [verb, rel, :request|:response, fields, blocks_bpn_creation]
  FIELDS = {
    'gate' => [
      ['put', 'input/business-partners', :request,
       ['[].externalId', '[].nameParts', '[].identifiers[].type', '[].identifiers[].value', '[].states', '[].roles',
        '[].legalEntity.legalName', '[].legalEntity.shortName', "#{ADDR}.country", "#{ADDR}.postalCode", "#{ADDR}.city",
        "#{ADDR}.district", "#{ADDR}.street.name", "#{ADDR}.street.houseNumber", '[].isOwnCompanyData'], true],
      ['post', 'sharing-state/ready', :request, ['externalIds'], true],
      ['post', 'output/business-partners/search', :response,
       ['content[].externalId', 'content[].legalEntity.legalEntityBpn', 'content[].address.addressBpn'], true],
      ['get', 'sharing-state', :response,
       ['content[].externalId', 'content[].sharingStateType', 'content[].sharingErrorCode', 'content[].sharingErrorMessage',
        'content[].sharingProcessStarted'], true]
    ],
    'pool' => [
      ['put', 'cx-memberships', :request, ['memberships[].bpnL', 'memberships[].isArenaXMember'], false],
      ['get', 'legal-entities/{}', :response, %w[bpnl legalName identifiers states legalAddress], false]
    ]
  }.freeze

  # Returns [prefix, missing_calls, found]. Path templates match any {param} at a {} position.
  def self.resolve(doc, api)
    paths = doc.fetch('paths', {})
    found = CALLS.fetch(api).map do |verb, rel|
      re = path_re(rel)
      prefixes = paths.select { |p, ops| p.match?(re) && ops.is_a?(Hash) && ops.key?(verb) }.keys.map { |p| p[re, 1].to_s }
      [verb, rel, prefixes.uniq]
    end
    missing = found.select { |_, _, p| p.empty? }.map { |v, r, _| "#{v.upcase} #{r}" }
    common = found.map(&:last).reduce { |a, b| a & b } || []
    [common.size == 1 ? common.first : nil, missing, found]
  end

  def self.path_re(rel)
    Regexp.new("\\A(/v\\d+)?/#{Regexp.escape(rel).gsub('\\{\\}', '\\{[^/}]+\\}')}\\z")
  end

  # Returns [[label, missing_fields, blocks_bpn_creation], ...] for the given version prefix.
  def self.check_fields(doc, api, prefix)
    FIELDS.fetch(api).map do |verb, rel, side, fields, blocking|
      label = "#{verb.upcase} #{prefix}/#{rel}"
      op = operation(doc, prefix, verb, rel)
      root = op && body_schema(doc, op, side)
      missing = root ? fields.reject { |f| field?(doc, root, f) } : ["<no #{side} schema>"]
      [label, missing, blocking]
    end
  end

  def self.operation(doc, prefix, verb, rel)
    re = Regexp.new("\\A#{Regexp.escape(prefix)}/#{Regexp.escape(rel).gsub('\\{\\}', '\\{[^/}]+\\}')}\\z")
    _, ops = doc.fetch('paths', {}).find { |p, _| p.match?(re) }
    ops.is_a?(Hash) ? ops[verb] : nil
  end

  def self.body_schema(doc, op, side)
    content = if side == :request
                op.dig('requestBody', 'content')
              else
                (op['responses'] || {}).select { |code, _| code.to_s.start_with?('2') }.values.map { |r| r['content'] }.compact.first
              end
    return nil unless content.is_a?(Hash) && !content.empty?

    media = content['application/json'] || content['*/*'] || content.values.first
    media.is_a?(Hash) ? deref(doc, media['schema']) : nil
  end

  # Resolves $ref, allOf (properties merged) and oneOf/anyOf. Null alternatives ({"type": "null"}, as springdoc
  # emits for nullable references) are dropped; with several non-null alternatives a property or array item
  # counts only if EVERY alternative has it (fail closed). Returns nil for an unresolvable or null-only schema.
  def self.deref(doc, schema, depth = 0)
    return nil unless schema.is_a?(Hash) && depth < 32

    if schema['$ref']
      name = schema['$ref'][%r{\A#/components/schemas/(.+)\z}, 1]
      return name && deref(doc, doc.dig('components', 'schemas', name), depth + 1)
    end
    union = schema['oneOf'] || schema['anyOf']
    return deref_union(doc, union, depth) if union.is_a?(Array)
    return nil if null_schema?(schema)
    return schema unless schema['allOf'].is_a?(Array)

    parts = schema['allOf'].map { |s| deref(doc, s, depth + 1) || {} }
    { 'type' => 'object', 'properties' => parts.map { |s| s['properties'] || {} }.reduce({}, :merge) }
  end

  def self.deref_union(doc, union, depth)
    alts = union.reject { |s| null_schema?(s) }.map { |s| deref(doc, s, depth + 1) }
    return nil if alts.empty? || alts.include?(nil)
    return alts.first if alts.size == 1

    merged = {}
    props = alts.map { |s| s['properties'] || {} }
    common = props.map(&:keys).reduce(:&)
    merged['properties'] = common.map { |k| [k, { 'oneOf' => props.map { |p| p[k] } }] }.to_h unless common.empty?
    merged['items'] = { 'oneOf' => alts.map { |s| s['items'] } } if alts.all? { |s| s['items'] }
    merged
  end

  def self.null_schema?(schema)
    schema.is_a?(Hash) && (schema['type'] == 'null' || schema['type'] == ['null'])
  end

  def self.field?(doc, schema, path)
    path.scan(/\[\]|[^.\[\]]+/).reduce(schema) do |s, seg|
      s = deref(doc, s)
      return false unless s

      seg == '[]' ? s['items'] : (s['properties'] || {})[seg]
    end.then { |s| !deref(doc, s).nil? }
  end
end

if $PROGRAM_NAME == __FILE__
  api = nil
  OptionParser.new { |o| o.on('--api NAME', %w[gate pool]) { |v| api = v } }.parse!
  abort('usage: --api gate|pool < api-docs.json') unless api
  begin
    doc = JSON.parse($stdin.read)
  rescue JSON::ParserError
    puts "FAIL #{api}: OpenAPI document is not JSON"
    exit 1
  end
  prefix, missing, found = BpdmOpenApi.resolve(doc, api)
  title = "title=#{doc.dig('info', 'title').inspect} version=#{doc.dig('info', 'version').inspect}"
  unless prefix && missing.empty?
    puts "FAIL #{api}: no single version prefix serves every backend call (missing: #{missing.join(', ')}; " \
         "found: #{found.map { |v, r, p| "#{v.upcase} #{r}=#{p.inspect}" }.join('; ')}) #{title}"
    exit 1
  end
  puts "OK #{api} prefix=#{prefix.empty? ? '<none>' : prefix} #{title}"
  blocking = false
  BpdmOpenApi.check_fields(doc, api, prefix).each do |label, miss, blocks|
    if miss.empty?
      puts "SCHEMA OK #{label}"
    else
      blocking ||= blocks
      puts "SCHEMA MISMATCH #{label}: missing #{miss.join(', ')}#{blocks ? ' (blocks BPN Creation)' : ' (not used by BPN Creation)'}"
    end
  end
  exit(blocking ? 1 : 0)
end
