# frozen_string_literal: true

# Tests for helm-plugins/be293-idp-switch/post-render.rb on a real offline render of the patched chart: the output is the
# be293-retention output plus spec.suspend: true on the processes-worker CronJob and nothing else, and be293-retention
# itself (used by upgrade-be293.sh) still leaves the worker unsuspended.
#
# Run: ruby tests/test_idp_switch_post_renderer.rb

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'
require_relative '../helm-plugins/be293-idp-switch/post-render'

class IdpSwitchPostRendererTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  CHART = File.expand_path('../charts/portal-2.6.0-patched/portal-2.6.0.tgz', HERE)
  VALUES = %w[values-be293-portal.yaml values-be293-portal.alpha-release.yaml values-be293-portal.alpha-retention.yaml
              values-be293-portal.alpha-smtp4dev.yaml].freeze
  WORKER = 'be293-portal-processes-worker'
  MAINTENANCE = 'be293-portal-portal-maintenance'

  def plain
    @plain ||= Dir.mktmpdir do |dir|
      env = { 'KUBECONFIG' => '/dev/null', 'HELM_CACHE_HOME' => "#{dir}/c", 'HELM_CONFIG_HOME' => "#{dir}/cfg", 'HELM_DATA_HOME' => "#{dir}/d" }
      args = ['helm', 'template', 'be293-portal', CHART, '--namespace', 'be293'] + VALUES.flat_map { |v| ['-f', File.join(HERE, v)] }
      out, err, st = Open3.capture3(env, *args)
      assert st.success?, err
      out
    end
  end

  def docs(text)
    YAML.load_stream(text).compact.to_h { |d| ["#{d['kind']}/#{d.dig('metadata', 'name')}", d] }
  end

  def setup
    skip 'helm not installed' unless system('command -v helm >/dev/null 2>&1')
    skip 'patched chart package missing' unless File.exist?(CHART)
  end

  def test_only_difference_to_retention_is_the_suspended_worker
    retention = docs(Be293Retention.transform(plain))
    switch = docs(Be293IdpSwitch.transform(plain))
    assert_equal retention.keys.sort, switch.keys.sort
    assert_equal true, switch["CronJob/#{WORKER}"]['spec']['suspend']
    assert_equal true, switch["CronJob/#{MAINTENANCE}"]['spec']['suspend']
    retention["CronJob/#{WORKER}"]['spec']['suspend'] = true
    retention.each_key { |k| assert_equal retention[k], switch[k], "#{k} differs beyond the worker suspend" }
  end

  def test_retention_alone_keeps_the_worker_unsuspended
    w = docs(Be293Retention.transform(plain))["CronJob/#{WORKER}"]
    refute_equal true, w['spec']['suspend']
  end

  def test_missing_worker_fails_closed
    without = YAML.load_stream(plain).compact.reject { |d| d['kind'] == 'CronJob' && d.dig('metadata', 'name') == WORKER }
                  .map { |d| YAML.dump(d) }.join
    # be293-retention also targets the worker (IdP prefix), so either module refuses; nothing is written.
    assert_raises(Be293Retention::Error, Be293IdpSwitch::Error) { Be293IdpSwitch.transform(without) }
  end

  def test_helm_runs_the_plugin_end_to_end
    Dir.mktmpdir do |dir|
      env = { 'KUBECONFIG' => '/dev/null', 'HELM_PLUGINS' => File.join(HERE, 'helm-plugins'), 'HELM_CACHE_HOME' => "#{dir}/c",
              'HELM_CONFIG_HOME' => "#{dir}/cfg", 'HELM_DATA_HOME' => "#{dir}/d" }
      args = ['helm', 'template', 'be293-portal', CHART, '--namespace', 'be293', '--post-renderer', 'be293-idp-switch'] +
             VALUES.flat_map { |v| ['-f', File.join(HERE, v)] }
      out, err, st = Open3.capture3(env, *args)
      assert st.success?, err
      assert_equal true, docs(out)["CronJob/#{WORKER}"]['spec']['suspend']
    end
  end
end
