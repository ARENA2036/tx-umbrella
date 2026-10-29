"""Regression coverage for the pinned Portal 2.6.0 IdentityHub integration patch."""
from __future__ import annotations

import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "charts/umbrella/charts/portal-2.6.0.tgz"
PATCH = ROOT / "hack/patches/portal-2.6.0-identityhub-secret-refs.patch"
DEPENDENCY_SCRIPT = ROOT / "hack/helm-dependencies.bash"


class PortalIdentityHubChartTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory(prefix="portal-identityhub-chart-test-")
        cls.chart_dir = Path(cls.temp.name)
        with tarfile.open(PACKAGE, "r:gz") as archive:
            archive.extractall(cls.chart_dir)
        patch_command = ["patch", "-F", "0", "--batch", "--forward", "-p1", "-d", str(cls.chart_dir / "portal")]
        patch = subprocess.run(
            [*patch_command, "--dry-run"],
            input=PATCH.read_text(),
            text=True,
            capture_output=True,
            check=False,
        )
        if patch.returncode == 0:
            patch = subprocess.run(
                patch_command,
                input=PATCH.read_text(),
                text=True,
                capture_output=True,
                check=False,
            )
        else:
            already_patched = subprocess.run(
                [*patch_command, "--reverse", "--dry-run"],
                input=PATCH.read_text(),
                text=True,
                capture_output=True,
                check=False,
            )
            if already_patched.returncode:
                raise AssertionError("Portal 2.6.0 package matches neither side of the reviewed patch")
            patch = already_patched
        if patch.returncode:
            raise AssertionError("pinned Portal chart patch did not apply cleanly")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp.cleanup()

    def render(
        self,
        enabled: bool = False,
        incomplete: bool = False,
        wrong_wallet: bool = False,
        insecure_url: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        command = ["helm", "template", "portal-identityhub-test", str(self.chart_dir / "portal"), "--namespace", "synthetic"]
        if not enabled:
            return subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)

        values = {
            "backend.onboarding.walletProvider": "Dim" if wrong_wallet else "IdentityHub",
            "backend.identityHub.enabled": "true",
            "backend.identityHub.baseAddress": (
                "http://identityhub.synthetic.invalid/api/identity"
                if insecure_url
                else "https://identityhub.synthetic.invalid/api/identity"
            ),
            "backend.identityHub.didDocumentBaseLocation": "identityhub.synthetic.invalid",
            "backend.identityHub.universalResolverAddress": "https://resolver.synthetic.invalid/1.0/identifiers",
            "backend.identityHub.maxValidationTimeInDays": "30",
            "backend.identityHub.credentialServiceBaseAddress": "https://identityhub.synthetic.invalid/api/credentials",
            "backend.identityHub.issuerDid": "did:web:issuer.synthetic.invalid",
            "backend.identityHub.bpnCredentialType": "SyntheticBpnCredential",
            "backend.identityHub.bpnCredentialDefinitionId": "synthetic-bpn-definition",
            "backend.identityHub.membershipCredentialType": "SyntheticMembershipCredential",
            "backend.identityHub.membershipCredentialDefinitionId": "synthetic-membership-definition",
            "backend.identityHub.issuerAdminBaseAddress": "https://issuer.synthetic.invalid/api/admin",
            "backend.identityHub.issuerParticipantId": "synthetic-issuer-context",
            "backend.identityHub.apiKeySecretRef.name": "synthetic-identityhub-api",
            "backend.identityHub.apiKeySecretRef.key": "api-key",
            "backend.identityHub.issuerAdminApiKeySecretRef.name": "synthetic-issuer-admin-api",
            "backend.identityHub.issuerAdminApiKeySecretRef.key": "api-key",
        }
        if incomplete:
            values.pop("backend.identityHub.apiKeySecretRef.name")
        for path, value in values.items():
            command.extend(("--set-string", f"{path}={value}"))
        return subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)

    def test_dependency_patch_is_portal_260_pinned_and_fail_closed(self) -> None:
        chart_yaml = (self.chart_dir / "portal/Chart.yaml").read_text()
        values_yaml = (self.chart_dir / "portal/values.yaml").read_text()
        script = DEPENDENCY_SCRIPT.read_text()
        self.assertIn("name: portal", chart_yaml)
        self.assertRegex(chart_yaml, r"(?m)^version: 2\.6\.0$")
        self.assertIn("portal-2.6.0.tgz", script)
        self.assertIn("IdentityHub configuration patch requires Portal chart 2.6.0", script)
        self.assertIn("PORTAL_IDENTITYHUB_PATCH", script)
        self.assertIn("enabled: false", values_yaml)
        self.assertIn("apiKeySecretRef:", values_yaml)
        self.assertIn("issuerAdminApiKeySecretRef:", values_yaml)
        identityhub_values = values_yaml.split("  identityHub:\n", 1)[1].split("  processesworker:\n", 1)[0]
        self.assertNotIn("apiKey:", identityhub_values)
        self.assertNotIn("issuerAdminApiKey:", identityhub_values)

    def test_disabled_integration_preserves_legacy_profile(self) -> None:
        result = self.render()
        self.assertEqual(result.returncode, 0, "disabled Portal IdentityHub integration must render")
        self.assertTrue("ONBOARDING__WALLETPROVIDER" not in result.stdout, "disabled render changed wallet selection")
        self.assertTrue("APPLICATIONCHECKLIST__IDENTITYHUB__BASEADDRESS" not in result.stdout, "disabled render emitted IdentityHub settings")

    def test_enabled_integration_uses_secret_refs_and_all_three_wallet_selectors(self) -> None:
        result = self.render(enabled=True)
        self.assertEqual(result.returncode, 0, "synthetic Portal IdentityHub configuration must render")
        self.assertEqual(result.stdout.count('name: "ONBOARDING__WALLETPROVIDER"'), 3, "wallet selector must reach all onboarding processes")
        self.assertEqual(result.stdout.count('value: "IdentityHub"'), 3, "wallet selector must be consistent across processes")
        self.assertEqual(result.stdout.count('name: "APPLICATIONCHECKLIST__IDENTITYHUB__APIKEY"'), 2, "IdentityHub API key must reach Administration and Worker")
        self.assertEqual(result.stdout.count('name: "APPLICATIONCHECKLIST__IDENTITYHUB__ISSUERADMINAPIKEY"'), 2, "IssuerService key must reach Administration and Worker")
        self.assertTrue("synthetic-identityhub-api" in result.stdout, "IdentityHub Secret reference missing")
        self.assertTrue("synthetic-issuer-admin-api" in result.stdout, "IssuerService Secret reference missing")
        output_lines = result.stdout.splitlines()
        for secret_env in (
            '- name: "APPLICATIONCHECKLIST__IDENTITYHUB__APIKEY"',
            '- name: "APPLICATIONCHECKLIST__IDENTITYHUB__ISSUERADMINAPIKEY"',
        ):
            index = next(index for index, line in enumerate(output_lines) if line.strip() == secret_env)
            self.assertTrue(
                any("valueFrom:" in line for line in output_lines[index + 1 : index + 4]),
                "IdentityHub credentials must use Secret references",
            )

    def test_missing_secret_reference_fails_render(self) -> None:
        result = self.render(enabled=True, incomplete=True)
        self.assertNotEqual(result.returncode, 0, "missing external Secret reference must fail rendering")
        self.assertTrue("backend.identityHub.apiKeySecretRef.name is required" in result.stderr, "missing reference failure was not actionable")

    def test_identityhub_settings_reject_a_different_wallet_provider(self) -> None:
        result = self.render(enabled=True, wrong_wallet=True)
        self.assertNotEqual(result.returncode, 0, "IdentityHub settings must not be combined with another wallet")
        self.assertTrue(
            "backend.identityHub.enabled requires backend.onboarding.walletProvider=IdentityHub" in result.stderr,
            "wallet/provider mismatch must fail with a sanitized validation error",
        )

    def test_identityhub_admin_and_credential_endpoints_require_https(self) -> None:
        result = self.render(enabled=True, insecure_url=True)
        self.assertNotEqual(result.returncode, 0, "IdentityHub integration must not accept plaintext URLs")
        self.assertTrue(
            "backend.identityHub.baseAddress must use https" in result.stderr,
            "insecure URL rejection must be explicit and sanitized",
        )


if __name__ == "__main__":
    unittest.main()
