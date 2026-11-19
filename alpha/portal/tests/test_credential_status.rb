# frozen_string_literal: true

# Behavioural tests for tools/credential-status-be293.sh with a stub kubectl (no cluster).
#   read-only   only get/logs/exec; SQL is a READ ONLY transaction with SELECTs only, ending in ROLLBACK
#   input       the application id must be a UUID and reaches SQL only as a psql variable
#   privacy     e-mail addresses in worker logs are masked; the DB password is never on the command line
#   scope       explicit kubeconfig, context alpha, namespace be293; only Jobs owned by the worker CronJob
#
# Run: ruby tests/test_credential_status.rb

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'

class CredentialStatusTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  SCRIPT = File.join(HERE, 'tools/credential-status-be293.sh')
  REFERENCE_APP = 'c5182556-2376-4afd-9131-15423e8e5e3e'

  def setup
    @dir = Dir.mktmpdir('be293-cred-test')
    @bin = File.join(@dir, 'bin')
    FileUtils.mkdir_p(@bin)
    @kc = File.join(@dir, 'alpha.yaml')
    File.write(@kc, '')
    File.write(File.join(@bin, 'kubectl'), <<~RUBY)
      #!/usr/bin/env ruby
      a = ARGV.join(' ')
      File.open('#{@dir}/kubectl.log', 'a') { |f| f.puts a }
      if a.include?('config get-contexts') then puts 'alpha'; exit 0 end
      if a.include?(' exec ') then File.write('#{@dir}/sql.txt', $stdin.read); puts 'psql-output'; exit 0 end
      if a.include?('get jobs')
        puts 'be293-portal-processes-worker-1 be293-portal-processes-worker'
        puts 'other-job-1 something-else'
        exit 0
      end
      if a.include?(' logs ')
        puts 'warn: IdentityHub reports the BPN credential request for application #{REFERENCE_APP} as ERROR. owner ops@example.com'
        puts 'warn: IdentityHub reports the BPN credential request for application 00000000-0000-0000-0000-000000000000 as ERROR.'
        puts 'info: application #{REFERENCE_APP} BPDM push done'
        exit 0
      end
      warn "stub kubectl: unexpected \#{a}"; exit 3
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'kubectl'))
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def run_script(*args, bash: 'bash')
    Open3.capture2e({ 'PATH' => "#{@bin}:#{ENV['PATH']}", 'ALPHA_KUBECONFIG' => @kc }, bash, SCRIPT, *args, stdin_data: '')
  end

  def log
    File.exist?("#{@dir}/kubectl.log") ? File.read("#{@dir}/kubectl.log") : ''
  end

  def test_only_read_only_kubectl_verbs_with_explicit_scope
    out, st = run_script
    assert st.success?, out
    verbs = log.lines.reject { |l| l.include?('config get-contexts') }
    refute_empty verbs
    verbs.each do |l|
      assert_includes l, "--kubeconfig #{@kc} --context alpha -n be293"
      assert_match(/ (get jobs |logs job\/|exec -i be293-portal-postgresql-0 )/, l)
    end
    refute_match(/ (apply|create|patch|delete|replace|scale|annotate|label|rollout|edit) /, log)
  end

  def test_sql_is_select_only_in_a_read_only_transaction
    _, st = run_script
    assert st.success?
    sql = File.read("#{@dir}/sql.txt")
    assert_match(/\ABEGIN READ ONLY;/, sql.lstrip)
    assert_match(/ROLLBACK;\s*\z/, sql)
    statements = sql.gsub(/^\\echo.*$/, '').split(';').map(&:strip).reject(&:empty?)
    statements.each { |s| assert_match(/\A(BEGIN READ ONLY|ROLLBACK|SELECT|WITH)\b/, s) }
    refute_match(/\b(INSERT|UPDATE|DELETE|TRUNCATE|ALTER|DROP|CREATE|GRANT|COPY|nextval|setval)\b/i, sql.gsub(/'[^']*'/, ''))
    assert_includes log, 'default_transaction_read_only=on'
    refute_match(/PGPASSWORD=[^"$]/, log, 'password must be expanded inside the pod, never passed literally')
  end

  def test_application_id_is_passed_as_psql_variable_not_interpolated
    _, st = run_script
    assert st.success?
    sql = File.read("#{@dir}/sql.txt")
    refute_includes sql, REFERENCE_APP
    assert_includes sql, ":'app'::uuid"
    assert_includes log, "-v app=#{REFERENCE_APP}"
  end

  def test_verdict_names_the_mismatch_and_both_credentials
    _, st = run_script
    assert st.success?
    sql = File.read("#{@dir}/sql.txt")
    assert_includes sql, "entry_status = 'IN_PROGRESS' AND last_await = 'FAILED' AND retrigger_todo AND NOT active AND NOT locked"
    %w[BPNL_CREDENTIAL MEMBERSHIP_CREDENTIAL RETRIGGER_REQUEST_BPN_CREDENTIAL RETRIGGER_REQUEST_MEMBERSHIP_CREDENTIAL].each do |label|
      assert_includes sql, "'#{label}'"
    end
  end

  def test_rejects_a_non_uuid_application_id_before_any_cluster_call
    ["x'; DROP TABLE portal.processes; --", 'C5182556-2376-4AFD-9131-15423E8E5E3E', ''].each do |bad|
      out, st = run_script(bad)
      if bad.empty?
        assert st.success?, 'an empty argument falls back to the reference application'
        next
      end
      assert_equal 2, st.exitstatus, out
      assert_includes out, 'usage:'
    end
    refute_includes log, 'DROP'
  end

  def test_logs_only_this_applications_credential_lines_from_worker_jobs_masked
    out, st = run_script
    assert st.success?, out
    assert_includes log, 'logs job/be293-portal-processes-worker-1'
    refute_includes log, 'other-job-1'
    assert_includes out, "BPN credential request for application #{REFERENCE_APP} as ERROR. owner <email>"
    refute_includes out, 'ops@example.com'
    refute_includes out, '00000000-0000-0000-0000-000000000000'
    refute_includes out, 'BPDM push done'
  end

  def test_runs_on_macos_system_bash
    skip 'no /bin/bash' unless File.executable?('/bin/bash')
    out, st = run_script(bash: '/bin/bash')
    assert st.success?, out
  end
end
