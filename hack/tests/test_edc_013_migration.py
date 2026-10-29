"""Regression coverage for the local EDC 0.13.0 migration preparation."""
from __future__ import annotations

import re
import subprocess
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROFILE_CONTEXTS = {
    "charts/umbrella/values.yaml": {
        "BPNL00000003AZQP": "00000000-0000-0000-0000-000000000001",
        "BPNL00000003AYRE": "00000000-0000-0000-0000-000000000002",
        "BPNL00000003AVTH": "00000000-0000-0000-0000-000000000003",
    },
    "charts/umbrella/values-prod.yaml": {
        "BPNL00000003AZQP": "40d5eb27-f571-5d50-a9fa-220a762fc8be",
        "BPNL00000003AYRE": "42033a6c-4b19-5c08-96f1-d3fa62fc73c6",
        "BPNL00000003AVTH": "2bc25b20-e1ae-5696-a986-b05b5e8a8ab0",
    },
    "charts/umbrella/values-edcs-prod.yaml": {
        "BPNL00000003AZQP": "40d5eb27-f571-5d50-a9fa-220a762fc8be",
        "BPNL00000003AYRE": "42033a6c-4b19-5c08-96f1-d3fa62fc73c6",
        "BPNL00000003AVTH": "2bc25b20-e1ae-5696-a986-b05b5e8a8ab0",
    },
    "charts/umbrella/values-staging.yaml": {
        "BPNL00000003AZQP": "23a298c4-b18e-5660-891c-b82e6ce13aa0",
        "BPNL00000003AYRE": "4a27791c-c676-5e8e-85ea-56897913eb2f",
        "BPNL00000003AVTH": "a020cbf3-30ae-507e-9748-59124afe6bef",
    },
    "charts/umbrella/values-edcs-staging.yaml": {
        "BPNL00000003AZQP": "23a298c4-b18e-5660-891c-b82e6ce13aa0",
        "BPNL00000003AYRE": "4a27791c-c676-5e8e-85ea-56897913eb2f",
        "BPNL00000003AVTH": "a020cbf3-30ae-507e-9748-59124afe6bef",
    },
}
DID_PROFILES = [*PROFILE_CONTEXTS, "charts/values-test-data-exchange.yaml"]


def baseline_text(relative_path: str) -> str:
    return subprocess.run(
        ["git", "show", f"HEAD:{relative_path}"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def current_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text()


class Connector013MigrationTests(unittest.TestCase):
    def test_chart_pins_connector_013_and_bumps_local_bundle_revision(self) -> None:
        chart = current_text("charts/dataspace-connector-bundle/Chart.yaml")
        self.assertRegex(chart, r"(?m)^version: 1\.2\.2$")
        self.assertRegex(chart, r"(?m)^\s+version: 0\.13\.0$")
        self.assertNotRegex(chart, r"(?m)^\s+version: 0\.12\.0$")

    def test_active_profiles_use_dcp_div_and_renamed_credential_service_key(self) -> None:
        active = [
            "charts/dataspace-connector-bundle/values.yaml",
            *PROFILE_CONTEXTS,
            "charts/umbrella/values-tls.yaml",
            "charts/values-test-data-exchange.yaml",
        ]
        for path in active:
            with self.subTest(path=path):
                text = current_text(path)
                self.assertNotRegex(text, r"(?m)^\s+iatp:\s*$")
                self.assertNotIn("TX_IAM_IATP_CREDENTIALSERVICE_URL", text)
                self.assertIn("TX_EDC_IAM_DCP_CREDENTIALSERVICE_URL", text)
                self.assertRegex(text, r"(?m)^\s+dcp:\s*$")
                self.assertRegex(text, r"(?m)^\s+div:\s*$")

    def test_configured_dids_are_preserved_from_clean_baseline(self) -> None:
        for path in DID_PROFILES:
            with self.subTest(path=path):
                before = set(re.findall(r"did:web:[^\s\"']+", baseline_text(path)))
                after = set(re.findall(r"did:web:[^\s\"']+", current_text(path)))
                self.assertEqual(before, after)

    def test_context_ids_are_existing_values_and_unique_within_profiles(self) -> None:
        for path, expected in PROFILE_CONTEXTS.items():
            with self.subTest(path=path):
                text = current_text(path)
                for bpnl, context_id in expected.items():
                    # The profile uses repeated nested participant maps; check each
                    # identity tuple directly instead of assuming map order.
                    self.assertRegex(
                        text,
                        rf"(?ms)participant:\s*\n\s+id: did:web:[^\n]*{bpnl}\s*\n\s+contextId: \"{re.escape(context_id)}\"\s*\n\s+bpnl: {bpnl}",
                    )
                    uuid.UUID(context_id)
                self.assertEqual(len(set(expected.values())), len(expected))

    def test_test_data_overlay_overrides_did_without_replacing_context_or_bpnl(self) -> None:
        text = current_text("charts/values-test-data-exchange.yaml")
        self.assertRegex(text, r"(?ms)participant:\s*\n\s+id: did:web:ssi-dim-wallet-service:BPNL00000003AZQP")
        self.assertRegex(text, r"(?ms)participant:\s*\n\s+id: did:web:ssi-dim-wallet-service:BPNL00000003AYRE")
        self.assertNotRegex(text, r"(?m)^\s+dcp:\s*\n\s+id:")

    def test_ap6_profile_is_untouched(self) -> None:
        path = "charts/umbrella/values-edcs-dev-ap6.yaml"
        self.assertEqual(current_text(path), baseline_text(path))

    def test_secretref_patch_is_connector_013_only_and_least_scope(self) -> None:
        patch = current_text("hack/patches/tractusx-connector-0.13.0-secret-refs.patch")
        self.assertIn("txdc.secretEnvValue", patch)
        for required in ("authKeySecretRef", "passwordSecretRef", "tokenSecretRef"):
            self.assertIn(required, patch)
        for reference in (
            ".Values.controlplane.endpoints.management.authKeySecretRef",
            ".Values.dataplane.endpoints.proxy.authKeySecretRef",
            ".Values.vault.hashicorp.tokenSecretRef",
            ".Values.postgresql.auth.passwordSecretRef",
        ):
            self.assertIn(reference, patch)
        self.assertNotIn("WEB_HTTP_CATALOG", patch)
        script = current_text("hack/helm-dependencies.bash")
        self.assertIn("tractusx-connector-0.13.0-secret-refs.patch", script)
        self.assertIn("tractusx-connector-0.13.0.tgz", script)
        self.assertNotIn("tractusx-connector-0.12.0", script)
        test_template = current_text(
            "hack/patches/tractusx-connector-0.13.0-secret-refs.patch"
        )
        added_lines = "\n".join(
            line[1:]
            for line in test_template.splitlines()
            if line.startswith("+") and not line.startswith("+++")
        )
        self.assertIn('"x-api-key: ${MANAGEMENT_AUTH_KEY}"', added_lines)
        self.assertIn('name: MANAGEMENT_AUTH_KEY', added_lines)
        self.assertNotIn('printf "x-api-key: %s"', added_lines)


if __name__ == "__main__":
    unittest.main()
