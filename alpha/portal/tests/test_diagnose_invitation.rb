# frozen_string_literal: true

# Behavioural tests for tools/diagnose-invitation-be293.sh with a stub kubectl (no cluster).
#   read-only   only get/logs/exec; SQL is a READ ONLY transaction with SELECTs only, ending in ROLLBACK
#   privacy     e-mail addresses in worker logs are masked; the DB password is never on the command line
#   scope       explicit kubeconfig, context alpha, namespace be293; only Jobs owned by the worker CronJob
#
# Run: ruby tests/test_diagnose_invitation.rb

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'

class DiagnoseInvitationTest < Minitest::Test
  HERE = File.expand_path('..', __dir__)
  SCRIPT = File.join(HERE, 'tools/diagnose-invitation-be293.sh')

  def setup
    @dir = Dir.mktmpdir('be293-diag-test')
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
        puts 'be293-portal-processes-worker-2 be293-portal-processes-worker'
        exit 0
      end
      if a.include?(' logs ')
        puts 'info: Mailing process started'
        puts 'error: INVITATION_CREATE_CENTRAL_IDP Call failed with status code 409 (Conflict) for jane.doe@example.com'
        exit 0
      end
      warn "stub kubectl: unexpected \#{a}"; exit 3
    RUBY
    FileUtils.chmod(0o755, File.join(@bin, 'kubectl'))
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def run_script(bash: 'bash')
    Open3.capture2e({ 'PATH' => "#{@bin}:#{ENV['PATH']}", 'ALPHA_KUBECONFIG' => @kc }, bash, SCRIPT, stdin_data: '')
  end

  def log
    File.read("#{@dir}/kubectl.log")
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

  def test_logs_only_from_worker_jobs_and_emails_masked
    out, st = run_script
    assert st.success?, out
    assert_includes log, 'logs job/be293-portal-processes-worker-1'
    assert_includes log, 'logs job/be293-portal-processes-worker-2'
    refute_includes log, 'other-job-1'
    assert_includes out, '409 (Conflict) for <email>'
    refute_includes out, 'jane.doe@example.com'
  end

  def test_runs_on_macos_system_bash
    skip 'no /bin/bash' unless File.executable?('/bin/bash')
    out, st = run_script(bash: '/bin/bash')
    assert st.success?, out
  end
end
