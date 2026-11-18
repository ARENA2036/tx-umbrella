#!/usr/bin/env ruby
# frozen_string_literal: true

# Helm 4 post-renderer for the be293-portal IdP switch ONLY (tools/switch-idp-be293.sh). It runs the be293-retention
# transform unchanged (same code, loaded from ../be293-retention/post-render.rb) and then makes exactly one more change:
#   CronJob be293-portal-processes-worker: spec.suspend = true
# The worker is suspended deliberately during the switch so it cannot write into the shared release26-09 IdPs. Rendering
# the field makes Helm own it instead of relying on server-side apply preserving a field set outside Helm. The
# worker-only upgrade (tools/upgrade-be293.sh) keeps using be293-retention and is not affected.
# Fail-closed like be293-retention: on any error (or a missing/duplicated worker) it writes NOTHING and exits 1.

require 'yaml'
require_relative '../be293-retention/post-render'

module Be293IdpSwitch
  WORKER = "#{Be293Retention::RELEASE}-processes-worker"

  class Error < StandardError; end

  module_function

  def transform(input)
    seen = 0
    out = Be293Retention.transform(input).split(Be293Retention::SEPARATOR, -1).map do |chunk|
      doc = chunk.strip.empty? ? nil : YAML.safe_load(chunk)
      next chunk unless doc.is_a?(Hash) && doc['kind'] == 'CronJob' && doc.dig('metadata', 'name') == WORKER

      ns = doc.dig('metadata', 'namespace')
      raise Error, "CronJob/#{WORKER} namespace #{ns.inspect} != #{Be293Retention::NAMESPACE}" unless ns == Be293Retention::NAMESPACE

      seen += 1
      doc['spec'] = (doc['spec'] || {}).merge('suspend' => true)
      header = chunk.lines.take_while { |l| l.start_with?('#') }.join
      header + YAML.dump(doc).sub(/\A---[ \t]*\n/, '')
    end
    raise Error, "target missing or duplicated: CronJob/#{WORKER}=#{seen}" unless seen == 1

    out.join("---\n")
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    $stdout.write(Be293IdpSwitch.transform($stdin.read))
  rescue Be293Retention::Error, Be293IdpSwitch::Error, Psych::Exception => e
    # Message names objects only; Secret data is never echoed.
    warn "be293-idp-switch post-renderer refused: #{e.class}: #{e.message.lines.first}"
    exit 1
  end
end
