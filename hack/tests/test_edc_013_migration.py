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

    def test_local_chart_dependency_versions_are_consistent(self) -> None:
        provider = current_text("charts/tx-data-provider/Chart.yaml")
        umbrella = current_text("charts/umbrella/Chart.yaml")
        self.assertRegex(provider, r"(?m)^version: 0\.4\.3$")
        self.assertRegex(
            provider,
            r"(?ms)name: dataspace-connector-bundle\n\s+repository: file://\.\./dataspace-connector-bundle\n\s+version: 1\.2\.2$",
        )
        self.assertRegex(umbrella, r"(?m)^version: 3\.14\.1$")
        self.assertEqual(len(re.findall(r"(?m)^\s*- name: tx-data-provider$", umbrella)), 3)
        self.assertEqual(len(re.findall(r"(?m)^\s+version: 0\.4\.3$", umbrella)), 3)

    def test_relevant_dependency_locks_pin_published_artifacts(self) -> None:
        connector_lock = current_text("charts/dataspace-connector-bundle/Chart.lock")
        provider_lock = current_text("charts/tx-data-provider/Chart.lock")
        umbrella_lock = current_text("charts/umbrella/Chart.lock")
        self.assertRegex(connector_lock, r"(?m)^  version: 0\.13\.0$")
        self.assertRegex(connector_lock, r"(?m)^  version: 15\.2\.1$")
        self.assertRegex(provider_lock, r"(?m)^  version: 1\.2\.2$")
        self.assertRegex(umbrella_lock, r"(?m)^  version: 0\.4\.3$")
        self.assertRegex(umbrella_lock, r"(?m)^  version: 1\.25\.3$")

    def test_nested_bundle_dependencies_are_locked_for_complete_render(self) -> None:
        dtr_lock = current_text("charts/digital-twin-bundle/Chart.lock")
        persistence_lock = current_text("charts/data-persistence-layer-bundle/Chart.lock")
        identity_lock = current_text("charts/identity-and-trust-bundle/Chart.lock")
        self.assertRegex(dtr_lock, r"(?m)^  version: 0\.9\.0$")
        self.assertRegex(dtr_lock, r"(?m)^  version: 15\.2\.1$")
        self.assertRegex(persistence_lock, r"(?m)^  version: 0\.1\.0$")
        self.assertRegex(identity_lock, r"(?m)^  version: 0\.1\.14$")

    def test_connector_optional_services_are_distinct_from_bundle_services(self) -> None:
        """Disabling Connector-owned dependencies does not disable bundle services."""
        chart = current_text("charts/dataspace-connector-bundle/Chart.yaml")
        values = current_text("charts/dataspace-connector-bundle/values.yaml")
        self.assertRegex(
            chart,
            r"(?ms)- name: tractusx-connector\n.*?condition: tractusx-connector.enabled\n\n"
            r"\s*- name: postgresql\n\s+version: 15\.2\.1\n"
            r"\s+repository: https://charts\.bitnami\.com/bitnami\n"
            r"\s+condition: postgresql\.enabled",
        )
        self.assertRegex(
            chart,
            r"(?ms)- name: vault\n\s+version: 0\.27\.0\n"
            r"\s+repository: https://helm\.releases\.hashicorp\.com\n"
            r"\s+condition: vault\.enabled",
        )
        connector = re.search(
            r"(?ms)^tractusx-connector:\n(.*?)(?=^postgresql:\n)", values
        )
        self.assertIsNotNone(connector)
        self.assertRegex(connector.group(1), r"(?m)^\s+postgresql: false$")
        self.assertRegex(connector.group(1), r"(?m)^\s+vault: false$")
        self.assertRegex(values, r"(?ms)^postgresql:\n.*?^  enabled: true$")
        self.assertRegex(values, r"(?ms)^vault:\n.*?^  enabled: true$")

    def test_connector_013_helm_render_uses_dcp_variable_and_secret_refs(self) -> None:
        """Exercise the pinned chart; never include its rendered output in failures."""
        references = [
            ("controlplane.endpoints.management.authKeySecretRef", "management-key"),
            ("dataplane.endpoints.proxy.authKeySecretRef", "proxy-key"),
            ("vault.hashicorp.tokenSecretRef", "vault-token"),
            ("postgresql.auth.passwordSecretRef", "db-password"),
        ]
        command = [
            "helm", "template", "be293-validation",
            "charts/dataspace-connector-bundle", "--namespace", "be293",
        ]
        for path, key in references:
            prefix = f"tractusx-connector.{path}"
            command.extend(("--set-string", f"{prefix}.name=synthetic-edc-runtime"))
            command.extend(("--set-string", f"{prefix}.key={key}"))
        result = subprocess.run(
            command, cwd=ROOT, capture_output=True, text=True, check=False
        )
        if result.returncode:
            self.fail("pinned Connector 0.13 chart render failed")
        rendered = result.stdout
        for expected in (
            "TX_EDC_IAM_DCP_CREDENTIALSERVICE_URL",
            "secretKeyRef:",
            "synthetic-edc-runtime",
            "management-key",
            "proxy-key",
            "vault-token",
            "db-password",
        ):
            if expected not in rendered:
                self.fail(f"render omitted expected 0.13 mapping/reference marker: {expected}")
        if "TX_IAM_IATP_CREDENTIALSERVICE_URL" in rendered:
            self.fail("render contains the removed IATP credential-service variable")

    def test_connector_013_helm_render_fails_closed_without_secretrefs(self) -> None:
        result = subprocess.run(
            [
                "helm", "template", "be293-validation",
                "charts/dataspace-connector-bundle", "--namespace", "be293",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            self.fail("Connector 0.13 chart rendered without required SecretRefs")

    def test_federated_catalog_retention_gate_is_explicit_and_unset(self) -> None:
        """Do not choose discard or preservation before the data owner decides."""
        blocker_doc = current_text("docs/dev/BE-293-edc-0.13-migration-blockers.md")
        self.assertIn("edc_federated_catalog", blocker_doc)
        self.assertIn("tx.edc.postgresql.migration.federatedcatalog.enabled=false", blocker_doc)
        self.assertRegex(blocker_doc, r"(?is)data owner must decide.*?(discard|retain|retention)")
        draft_doc = current_text("docs/dev/BE-293-edc-0.13-draft-pr.md")
        self.assertIn("is **not** a complete Tractus-X 26.09", draft_doc)
        self.assertIn("PostgreSQL/Vault topology", draft_doc)
        self.assertIn("Historical key material", draft_doc)
        active = [
            "charts/dataspace-connector-bundle/values.yaml",
            *PROFILE_CONTEXTS,
            "charts/values-test-data-exchange.yaml",
        ]
        for path in active:
            with self.subTest(path=path):
                self.assertNotIn(
                    "tx.edc.postgresql.migration.federatedcatalog.enabled",
                    current_text(path),
                )

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

    def test_connector_secretrefs_fail_closed_without_literal_fallback(self) -> None:
        patch = current_text("hack/patches/tractusx-connector-0.13.0-secret-refs.patch")
        added = "\n".join(
            line[1:] for line in patch.splitlines()
            if line.startswith("+") and not line.startswith("+++")
        )
        self.assertIn("fail (printf", added)
        self.assertIn("SecretRef.name is required", added)
        self.assertIn("SecretRef.key is required", added)
        self.assertIn("secretKeyRef:", added)
        self.assertNotIn("value: {{ .value", added)
        self.assertNotIn('"value" .Values.', added)

    def test_provider_vault_seed_uses_secret_refs_for_all_secret_material(self) -> None:
        job = current_text("charts/tx-data-provider/templates/post-install-vault-setup.yaml")
        configmap = current_text("charts/tx-data-provider/templates/vault-edc-configmap.yaml")
        self.assertIn("$tokenSecretRef.name | required", job)
        self.assertIn("$tokenSecretRef.key | required", job)
        self.assertIn("$keyMaterialSecretRef.name | required", job)
        self.assertIn("$keyMaterialSecretRef.privateKeyKey | required", job)
        self.assertIn("$keyMaterialSecretRef.aesSecretKey | required", job)
        self.assertIn("vaultSetup.seedPayloadSecretRefs", job)
        self.assertIn("vaultSetup.seedPayloadSecretRefs.%s.name is required", job)
        self.assertIn("vaultSetup.seedPayloadSecretRefs.%s.key is required", job)
        self.assertIn("--post-file=/opt/secret-seeds/", job)
        self.assertNotIn("$value", job)
        self.assertNotIn("{{ $value }}", job)
        self.assertNotIn("--post-data", job)
        self.assertNotRegex(job, r"(?m)^\s*(?:cat|echo)\b")
        self.assertNotIn("set -x", job)
        self.assertIn("--post-file=/opt/secret-seeds/", job)
        self.assertIn("readOnly: true", job)
        self.assertIn("defaultMode: 0400", job)
        self.assertIn("/opt/key-material/key.json", job)
        self.assertIn("/opt/key-material/aes-secret.json", job)
        self.assertNotIn("key.json: |-", configmap)
        self.assertNotIn("aes-secret.json: |-", configmap)
        self.assertNotIn("BEGIN PRIVATE KEY", configmap)
        self.assertNotIn("$vaultToken", job)
        self.assertIn("$vaultSetup.tokenSecretRef | default dict", job)
        self.assertIn("$vaultSetup.keyMaterialSecretRef | default dict", job)
        self.assertIn("$vaultSetup.seedPayloadSecretRefs | default dict", job)

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
