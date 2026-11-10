# frozen_string_literal: true

# Plain env-entry patches for be293 workloads (CronJob or Deployment JSON from `kubectl get -o json`), offline.
#
#   ruby tools/env_patch.rb values RENDER.yaml KIND NAME ENV...       # NAME=VALUE of plain env entries in the gated render
#   ruby tools/env_patch.rb container LIVE.json ENV                   # the one container that has ENV
#   ruby tools/env_patch.rb patch KIND CONTAINER NAME=VALUE...        # strategic merge patch JSON (env merges by name)
#   ruby tools/env_patch.rb assert LIVE.json AFTER.json NAME=VALUE... # dry-run result = live + exactly these entries
#   ruby tools/env_patch.rb show LIVE.json ENV...                     # current values (valueFrom shown as <secretRef>)
#
# Only plain values are handled; a secret-bearing entry (valueFrom) is never read, written or replaced.

require 'json'
require 'yaml'

module EnvPatch
  class Error < StandardError; end

  PATHS = { 'CronJob' => %w[spec jobTemplate spec template spec containers], 'Deployment' => %w[spec template spec containers] }.freeze

  def self.kind_of(doc)
    PATHS.key?(doc['kind']) ? doc['kind'] : raise(Error, "unsupported kind #{doc['kind'].inspect}")
  end

  def self.containers(doc)
    doc.dig(*PATHS.fetch(kind_of(doc))) || []
  end

  def self.pairs(args)
    args.map do |a|
      name, sep, value = a.partition('=')
      raise Error, "expected NAME=VALUE, got #{name.inspect}" if sep.empty? || name.empty?

      [name, value]
    end
  end

  def self.values(render_text, kind, name, envs)
    doc = YAML.load_stream(render_text).compact.find { |d| d['kind'] == kind && d.dig('metadata', 'name') == name }
    raise Error, "#{kind}/#{name} not in render" unless doc

    all = containers(doc).flat_map { |c| c['env'] || [] }
    envs.map do |n|
      hits = all.select { |e| e['name'] == n }
      raise Error, "#{kind}/#{name} #{n}: #{hits.size} entries" unless hits.size == 1
      raise Error, "#{kind}/#{name} #{n} is not a plain value" unless hits[0].keys.sort == %w[name value]

      "#{n}=#{hits[0]['value']}"
    end
  end

  def self.container(doc, env)
    hits = containers(doc).select { |c| (c['env'] || []).any? { |e| e['name'] == env } }
    raise Error, "#{env} in #{hits.size} containers (expected 1)" unless hits.size == 1

    hits[0]['name']
  end

  def self.patch(kind, container, pairs)
    body = { 'name' => container, 'env' => pairs.map { |n, v| { 'name' => n, 'value' => v } } }
    PATHS.fetch(kind).reverse.reduce([body]) { |inner, key| { key => inner } }
  end

  def self.assert(live, after, pairs)
    names = pairs.map(&:first)
    got = containers(after).flat_map { |c| (c['env'] || []).select { |e| names.include?(e['name']) } }
    want = pairs.map { |n, v| { 'name' => n, 'value' => v } }
    raise Error, "dry run: #{names.join(', ')} = #{got.inspect}, expected #{want.inspect}" unless got.sort_by { |e| e['name'] } == want.sort_by { |e| e['name'] }

    strip = lambda do |doc|
      copy = Marshal.load(Marshal.dump(doc['spec']))
      (copy.dig(*PATHS.fetch(kind_of(doc)).drop(1)) || []).each { |c| c['env']&.reject! { |e| names.include?(e['name']) } }
      copy
    end
    raise Error, "dry run changes more than #{names.join(', ')}" unless strip.call(live) == strip.call(after)

    true
  end

  def self.show(doc, envs)
    all = containers(doc).flat_map { |c| c['env'] || [] }
    envs.map do |n|
      e = all.find { |x| x['name'] == n }
      "#{n}=#{e.nil? ? '<unset>' : (e.key?('valueFrom') ? '<secretRef>' : e['value'])}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  cmd, *args = ARGV
  begin
    case cmd
    when 'values' then puts EnvPatch.values(File.read(args[0]), args[1], args[2], args[3..])
    when 'container' then puts EnvPatch.container(JSON.parse(File.read(args[0])), args[1])
    when 'patch' then puts JSON.generate(EnvPatch.patch(args[0], args[1], EnvPatch.pairs(args[2..])))
    when 'assert' then EnvPatch.assert(JSON.parse(File.read(args[0])), JSON.parse(File.read(args[1])), EnvPatch.pairs(args[2..]))
    when 'show' then puts EnvPatch.show(JSON.parse(File.read(args[0])), args[1..])
    else abort('usage: values|container|patch|assert|show ...')
    end
  rescue EnvPatch::Error, JSON::ParserError, Psych::Exception, Errno::ENOENT => e
    warn "env_patch: #{e.message.lines.first}"
    exit 1
  end
end
