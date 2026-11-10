# frozen_string_literal: true

# Tests for tools/check_package.rb and the secret-reference gate in tools/validate_render.rb.
# Run: ruby alpha/portal/tests/test_check_package.rb

require 'minitest/autorun'
require 'yaml'
require_relative '../tools/check_package'
require_relative '../tools/validate_render'

class CheckPackageTest < Minitest::Test
  PKG = File.expand_path('..', __dir__)

  def test_real_package_passes
    count, findings = PortalPackageCheck.run(PKG)
    assert_operator count, :>=, 6
    assert_empty findings
  end

  def test_duplicate_keys_detected_with_path_and_lines
    findings = PortalPackageCheck.duplicate_keys("a:\n  b: 1\n  b: 2\nc: [1]\n", 'x.yaml')
    assert_equal 1, findings.size
    assert_match(/x.yaml: duplicate key a.b \(lines 2 and 3\)/, findings.first)
  end

  def workflow(over = {})
    base = {
      'on' => { 'workflow_dispatch' => { 'inputs' => { 'push' => { 'default' => false } } } },
      'permissions' => { 'contents' => 'read' }
    }
    base.merge(over)
  end

  def test_workflow_guardrails_flag_latest_unpinned_and_triggers
    text = "uses: docker/build-push-action@v6\ntags: reg/x:latest\n"
    findings = PortalPackageCheck.workflow_guardrails(text, workflow('on' => { 'push' => {} }, 'permissions' => { 'contents' => 'write' }))
    msg = findings.join("\n")
    assert_match(/workflow_dispatch only/, msg)
    assert_match(/latest tag/, msg)
    assert_match(/not pinned to a full SHA: docker\/build-push-action@v6/, msg)
    assert_match(/contents: read only/, msg)
  end

  def test_workflow_guardrails_accept_pinned_manual_workflow
    text = "uses: actions/checkout@#{'a' * 40}\n"
    assert_empty PortalPackageCheck.workflow_guardrails(text, workflow)
  end

  def test_workflow_static_flags_bad_references_and_shell
    wf = workflow('jobs' => { 'b' => {
      'strategy' => { 'matrix' => { 'include' => [{ 'image' => 'x' }] } },
      'steps' => [
        { 'name' => 'a', 'id' => 'push', 'run' => 'echo ${{ matrix.image }} ${{ matrix.nope }} ${{ inputs.missing }}' },
        { 'name' => 'b', 'run' => 'if then fi' },
        { 'name' => 'c', 'if' => '${{ steps.ghost.outputs.x }}', 'uses' => 'x/y@' + 'a' * 40, 'run' => 'true' },
        { 'name' => 'd', 'run' => 'echo ${{ secretz.X }}' }
      ]
    } })
    msg = PortalPackageCheck.workflow_static(wf).join("\n")
    assert_match(/undefined matrix key nope/, msg)
    assert_match(/undefined input missing/, msg)
    assert_match(/'b' shell syntax error/, msg)
    assert_match(/undefined step id ghost/, msg)
    assert_match(/'c' must have exactly one of uses\/run/, msg)
    assert_match(/unknown expression context secretz/, msg)
    refute_match(/matrix key image/, msg)
  end

  def test_push_gating_flags_ungated_registry_steps_and_caches
    wf = { 'jobs' => { 'b' => { 'steps' => [
      { 'name' => 'login', 'uses' => 'docker/login-action@x' },
      { 'name' => 'release', 'uses' => 'docker/build-push-action@x', 'with' => { 'push' => true } },
      { 'name' => 'buildonly', 'if' => '${{ !inputs.push }}', 'uses' => 'docker/build-push-action@x', 'with' => { 'push' => true } },
      { 'name' => 'scan', 'uses' => 'aquasecurity/trivy-action@x', 'with' => {} },
      { 'name' => 'ok', 'if' => '${{ inputs.push }}', 'uses' => 'docker/login-action@x' }
    ] } } }
    msg = PortalPackageCheck.push_gating(wf).join("\n")
    assert_match(/'login' touches the registry but is not gated/, msg)
    assert_match(/'release' touches the registry but is not gated/, msg)
    assert_match(/build-only step 'buildonly' must set push: false/, msg)
    assert_match(/trivy step 'scan' must set cache/, msg)
    assert_match(/trivy step 'scan' must pin version/, msg)
    refute_match(/'ok'/, msg)
  end

  def test_trivy_version_pin_accepts_explicit_release_only
    step = ->(v) { { 'jobs' => { 'b' => { 'steps' => [{ 'name' => 's', 'uses' => 'aquasecurity/trivy-action@x', 'with' => { 'cache' => 'false', 'version' => v } }] } } } }
    assert_empty PortalPackageCheck.push_gating(step.('v0.76.1'))
    refute_empty PortalPackageCheck.push_gating(step.('latest'))
    refute_empty PortalPackageCheck.push_gating(step.(nil))
  end

  def test_lock_workflow_values_mismatch_detected
    lock = { 'source' => { 'commit' => 'c1' }, 'rebuilt' => [{ 'image' => 'portal-a', 'dockerfile' => 'docker/A' }] }
    wf = { 'env' => { 'SOURCE_COMMIT' => 'c2' },
           'jobs' => { 'build' => { 'strategy' => { 'matrix' => { 'include' => [{ 'image' => 'portal-b', 'dockerfile' => 'docker/B' }] } } } } }
    msg = PortalPackageCheck.lock_vs_workflow_vs_values(lock, wf, { 'x' => { 'name' => 'reg/portal-z' } }).join("\n")
    assert_match(/workflow matrix != images.lock rebuilt/, msg)
    assert_match(/SOURCE_COMMIT != images.lock/, msg)
    assert_match(/no image for portal-a/, msg)
  end

  def test_undeclared_secret_names_detected
    values = { 'backend' => { 'keycloak' => { 'secret' => 'kc' }, 'x' => { 'image' => { 'pullSecrets' => [{ 'name' => 'pull' }] } } } }
    contract = { 'secrets' => [{ 'name' => 'kc' }] }
    assert_equal ['values reference Secret pull not declared in secrets-contract.yaml'], PortalPackageCheck.secret_names_declared(values, contract)
  end

  # --- render-level secret references ---------------------------------------------------------
  def pod(env: [], pull: [])
    { 'kind' => 'Deployment', 'metadata' => { 'name' => 'd', 'namespace' => 'be293' },
      'spec' => { 'template' => { 'spec' => { 'imagePullSecrets' => pull, 'containers' => [{ 'name' => 'c', 'env' => env }] } } } }
  end

  def ref(name, key)
    { 'name' => 'X', 'valueFrom' => { 'secretKeyRef' => { 'name' => name, 'key' => key } } }
  end

  def test_secret_refs_against_contract
    contract = { 'secrets' => [{ 'name' => 'ok', 'keys' => { 'k' => {} } }, { 'name' => 'pull', 'keys' => {} }] }
    v = PortalRenderGates::Validator.new(mode: 'offline')
    v.check_secret_refs([pod(env: [ref('ok', 'k')], pull: [{ 'name' => 'pull' }])], contract)
    assert_empty v.result.failures
    v2 = PortalRenderGates::Validator.new(mode: 'offline')
    v2.check_secret_refs([pod(env: [ref('ok', 'typo'), ref('missing', 'k')], pull: [{ 'name' => 'nope' }])], contract)
    msg = v2.result.failures.join("\n")
    assert_match(/key typo not declared for Secret ok/, msg)
    assert_match(/Secret missing not declared/, msg)
    assert_match(/imagePullSecret nope not declared/, msg)
  end
end
