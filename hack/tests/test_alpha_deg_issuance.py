"""Regression coverage for the manually applied DataExchangeGovernanceCredential issuance Job of charts/alpha."""
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = "templates/deg-issuance.yaml"
DEG_TYPE = "DataExchangeGovernanceCredential"
# Test fixtures only: not a real participant and not a real approval.
FIXTURE_BPN = "BPNL00000000TEST"
FIXTURE_APPROVAL = "fixture-approval-1"
OTHER_CTX = "bpnl00000000othr"

# Stand-in for curl inside the Job: serves IdentityHub-shaped responses from fixture files and logs every call.
STUB_CURL = r'''#!/usr/bin/env python3
import os, sys
fix = os.environ["FIX"]
args = sys.argv[1:]
out = args[args.index("-o") + 1] if "-o" in args else None
url = args[-1]
post = "-X" in args and args[args.index("-X") + 1] == "POST"
with open(os.path.join(fix, "calls.log"), "a") as log:
    log.write(("POST " if post else "GET ") + url + "\n")
if post:
    code = open(os.path.join(fix, "post_code")).read().strip()
    sys.stdout.write(code)
    sys.exit(7 if code == "000" else 0)
if "/credentials/request/" in url:
    body = open(os.path.join(fix, "status")).read()
else:
    counter = os.path.join(fix, "lookup_count")
    n = int(open(counter).read()) if os.path.exists(counter) else 0
    open(counter, "w").write(str(n + 1))
    names = sorted(f for f in os.listdir(fix) if f.startswith("lookup_") and f != "lookup_count")
    body = open(os.path.join(fix, names[min(n, len(names) - 1)])).read()
if body == "FAIL":
    sys.exit(22)
open(out, "w").write(body)
'''


def render(*set_args: str, show_only: str | None = TEMPLATE) -> subprocess.CompletedProcess[str]:
    command = ["helm", "template", "alpha", "charts/alpha", "--namespace", "validation"]
    if show_only:
        command.extend(("--show-only", show_only))
    for arg in set_args:
        command.extend(("--set-string", arg))
    return subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)


def chart_values() -> dict:
    return yaml.safe_load((ROOT / "charts/alpha/values.yaml").read_text())


def rendered_job() -> dict:
    result = render(f"degIssuance.bpn={FIXTURE_BPN}", f"degIssuance.approvalReference={FIXTURE_APPROVAL}")
    if result.returncode:
        raise AssertionError("deg-issuance render failed")
    return yaml.safe_load(result.stdout)


def iso(delta: timedelta) -> str:
    return (datetime.now(timezone.utc) + delta).strftime("%Y-%m-%dT%H:%M:%S.123456789Z")


class DegIssuanceJobTests(unittest.TestCase):
    def test_default_install_renders_no_issuance_job(self) -> None:
        result = render(show_only=None)
        if result.returncode:
            self.fail("alpha render failed")
        self.assertNotIn("deg-issuance", result.stdout)

    def test_approval_reference_is_required(self) -> None:
        result = render(f"degIssuance.bpn={FIXTURE_BPN}")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("degIssuance.approvalReference is required", result.stderr)

    def test_bpn_must_be_a_bpnl(self) -> None:
        result = render("degIssuance.bpn=not-a-bpn", f"degIssuance.approvalReference={FIXTURE_APPROVAL}")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("degIssuance.bpn must be a BPNL", result.stderr)

    def test_job_reads_only_the_existing_scoped_key_and_configured_values(self) -> None:
        job = rendered_job()
        values = chart_values()
        ih = values["portal"]["backend"]["processesworker"]["identityHub"]
        ctx = FIXTURE_BPN.lower()

        self.assertEqual(job["kind"], "Job")
        self.assertEqual(job["metadata"]["name"], f"deg-issuance-{ctx}")
        self.assertEqual(job["metadata"]["annotations"]["alpha/governance-approval"], FIXTURE_APPROVAL)
        self.assertNotIn("helm.sh/hook", job["metadata"].get("annotations", {}))
        pod = job["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertNotIn("serviceAccountName", pod)
        container = pod["containers"][0]
        env = {e["name"]: e["value"] for e in container["env"]}
        self.assertEqual(env, {
            "BPN_CTX": ctx,
            "IH": f"http://{values['identityhub']['fullnameOverride']}:8082/api/identity",
            "ISSUER_DID": ih["issuerDid"],
            "DEF_ID": values["identitySeed"]["governanceCredentialDefinitionId"],
        })
        # Only the Portal's scoped IdentityHub key, read-only; no super-user key, no other Secret.
        secrets = [v["secret"] for v in pod["volumes"] if "secret" in v]
        self.assertEqual(secrets, [{
            "secretName": ih["existingSecret"], "defaultMode": 0o440,
            "items": [{"key": "identityhub-api-key", "path": "identityhub-api-key"}],
        }])
        self.assertTrue(next(m for m in container["volumeMounts"] if m["name"] == "key")["readOnly"])


@unittest.skipUnless(shutil.which("jq"), "jq not installed")
class DegIssuanceScriptBehaviourTests(unittest.TestCase):
    """Runs the rendered script against a stub IdentityHub; only /keys, /work and the poll sleep are redirected."""

    def setUp(self) -> None:
        container = rendered_job()["spec"]["template"]["spec"]["containers"][0]
        self.env_values = {e["name"]: e["value"] for e in container["env"]}
        self.ctx = self.env_values["BPN_CTX"]
        self.issuer = self.env_values["ISSUER_DID"]
        self.tmp = Path(tempfile.mkdtemp(prefix="deg-issuance-test-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        for name in ("keys", "work", "bin", "fix"):
            (self.tmp / name).mkdir()
        (self.tmp / "keys/identityhub-api-key").write_text("fixture-key")
        curl = self.tmp / "bin/curl"
        curl.write_text(STUB_CURL)
        curl.chmod(curl.stat().st_mode | stat.S_IEXEC)
        self.script = (container["args"][0]
                       .replace("/keys/", f"{self.tmp}/keys/")
                       .replace("/work/", f"{self.tmp}/work/")
                       .replace("sleep 5", "sleep 0"))
        self.respond(post_code="201", status={"status": "REQUESTED"})

    def credential(self, **overrides) -> dict:
        resource = {
            "participantContextId": self.ctx, "state": 500, "issuerId": self.issuer,
            "verifiableCredential": {"credential": {"type": ["VerifiableCredential", DEG_TYPE],
                                                    "expirationDate": iso(timedelta(days=365))}},
        }
        resource.update(overrides)
        return resource

    def respond(self, *lookups, post_code=None, status=None) -> None:
        fix = self.tmp / "fix"
        for i, body in enumerate(lookups):
            (fix / f"lookup_{i:02d}").write_text(body if isinstance(body, str) else json.dumps(body))
        if post_code is not None:
            (fix / "post_code").write_text(post_code)
        if status is not None:
            (fix / "status").write_text(status if isinstance(status, str) else json.dumps(status))

    def run_job(self) -> tuple[int, str, list[str]]:
        env = {**self.env_values, "PATH": f"{self.tmp}/bin:{os.environ['PATH']}", "FIX": str(self.tmp / "fix")}
        result = subprocess.run(["sh", "-c", self.script], env=env, capture_output=True, text=True, timeout=60)
        log = self.tmp / "fix/calls.log"
        calls = log.read_text().splitlines() if log.exists() else []
        return result.returncode, result.stdout + result.stderr, calls

    def posts(self, calls: list[str]) -> list[str]:
        return [c for c in calls if c.startswith("POST")]

    def test_valid_credential_is_kept_and_nothing_is_requested(self) -> None:
        self.respond([self.credential()])
        code, out, calls = self.run_job()
        self.assertEqual(code, 0)
        self.assertIn("already issued", out)
        self.assertEqual(self.posts(calls), [])

    def test_unusable_credentials_do_not_count_and_a_new_one_is_verified(self) -> None:
        cases = {
            "expired by date while still ISSUED": self.credential(verifiableCredential={"credential": {
                "type": ["VerifiableCredential", DEG_TYPE], "expirationDate": iso(timedelta(seconds=-5))}}),
            "state EXPIRED": self.credential(state=800),
            "state REQUESTED": self.credential(state=300),
            "other issuer": self.credential(issuerId="did:web:other-issuer.test"),
            "other participant": self.credential(participantContextId=OTHER_CTX),
            "other type": self.credential(verifiableCredential={"credential": {
                "type": ["VerifiableCredential", "MembershipCredential"], "expirationDate": iso(timedelta(days=365))}}),
        }
        for name, existing in cases.items():
            with self.subTest(name):
                self.setUp()
                self.respond([existing], [existing, self.credential()])
                code, out, calls = self.run_job()
                self.assertEqual(code, 0, out)
                self.assertIn("issued: ", out)
                self.assertEqual(len(self.posts(calls)), 1)

    def test_lookup_problems_stop_the_job_without_requesting(self) -> None:
        cases = {
            "HTTP failure": ("FAIL", "credential lookup failed"),
            "malformed JSON": ("{not json", "unexpected credential lookup response"),
            "object instead of list": ({"error": "x"}, "unexpected credential lookup response"),
            "missing expirationDate": ([self.credential(verifiableCredential={"credential": {"type": [DEG_TYPE]}})],
                                       "unexpected credential lookup response"),
            "state not a number": ([self.credential(state="ISSUED")], "unexpected credential lookup response"),
            "missing issuerId": ([{k: v for k, v in self.credential().items() if k != "issuerId"}],
                                 "unexpected credential lookup response"),
        }
        for name, (body, message) in cases.items():
            with self.subTest(name):
                self.setUp()
                self.respond(body)
                code, out, calls = self.run_job()
                self.assertEqual(code, 1)
                self.assertIn(message, out)
                self.assertEqual(self.posts(calls), [])

    def test_rejected_or_unreachable_request_fails(self) -> None:
        for post_code, message in (("500", "request failed (500)"), ("000", "request failed (000)")):
            with self.subTest(post_code):
                self.setUp()
                self.respond([], post_code=post_code)
                code, out, _ = self.run_job()
                self.assertEqual(code, 1)
                self.assertIn(message, out)

    def test_existing_request_409_is_polled_until_issued(self) -> None:
        self.respond([], [], [self.credential()], post_code="409")
        code, out, calls = self.run_job()
        self.assertEqual(code, 0, out)
        self.assertEqual(len(self.posts(calls)), 1)

    def test_status_poll_problems_stop_the_job(self) -> None:
        cases = {
            "HTTP failure": ("FAIL", "request status lookup failed"),
            "malformed JSON": ("{not json", "unexpected request status response"),
            "missing status": ({"holderPid": "x"}, "unexpected request status response"),
            "request ERROR": ({"status": "ERROR"}, "is ERROR"),
        }
        for name, (status, message) in cases.items():
            with self.subTest(name):
                self.setUp()
                self.respond([], status=status)
                code, out, _ = self.run_job()
                self.assertEqual(code, 1)
                self.assertIn(message, out)

    def test_not_issued_within_the_budget_fails(self) -> None:
        self.respond([], status={"status": "REQUESTED"})
        code, out, calls = self.run_job()
        self.assertEqual(code, 1)
        self.assertIn("not issued after 5 minutes (request REQUESTED)", out)
        self.assertEqual(len(self.posts(calls)), 1)


if __name__ == "__main__":
    unittest.main()
