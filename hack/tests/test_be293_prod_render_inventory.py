"""Protect the production-profile resource-count explanation with Helm renders."""
from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALUES = (
    "charts/umbrella/values.yaml",
    "charts/umbrella/values-prod.yaml",
    "charts/umbrella/values-tls.yaml",
    "charts/values-test-data-exchange.yaml",
)
CONNECTORS = ("tx-data-provider", "dataconsumerOne", "dataconsumerTwo")
CONNECTOR_SECRET_REFS = (
    ("controlplane.endpoints.management.authKeySecretRef", "management-key"),
    ("dataplane.endpoints.proxy.authKeySecretRef", "proxy-key"),
    ("vault.hashicorp.tokenSecretRef", "vault-token"),
    ("postgresql.auth.passwordSecretRef", "db-password"),
)
VAULT_SETUP_REFS = {
    "tokenSecretRef.name": "synthetic-vault-token",
    "tokenSecretRef.key": "token",
    "keyMaterialSecretRef.name": "synthetic-seed-material",
    "keyMaterialSecretRef.privateKeyKey": "private-key",
    "keyMaterialSecretRef.aesSecretKey": "aes-secret",
    "seedPayloadSecretRefs.edc-wallet-secret.name": "synthetic-seed-payload",
    "seedPayloadSecretRefs.edc-wallet-secret.key": "payload",
}


def render_count(enable_consumer_two: bool) -> int:
    command = [
        "helm",
        "template",
        "be293-inventory-test",
        "charts/umbrella",
        "--namespace",
        "be293",
    ]
    for values_file in VALUES:
        command.extend(("-f", values_file))
    if enable_consumer_two:
        command.extend(("--set", "dataconsumerTwo.enabled=true"))

    for alias in CONNECTORS:
        prefix = f"{alias}.dataspace-connector-bundle.tractusx-connector"
        for path, key in CONNECTOR_SECRET_REFS:
            command.extend(
                (
                    "--set-string",
                    f"{prefix}.{path}.name=synthetic-{alias}-runtime",
                    "--set-string",
                    f"{prefix}.{path}.key={key}",
                )
            )
        setup_prefix = f"{alias}.vaultSetup"
        for path, value in VAULT_SETUP_REFS.items():
            command.extend(("--set-string", f"{setup_prefix}.{path}={value}"))

    result = subprocess.run(
        command,
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise AssertionError("synthetic-reference Helm render failed")

    # Count only top-level Kubernetes documents. Rendered YAML remains in memory
    # and is never included in test output.
    return len(re.findall(r"(?m)^kind:\s+\S+\s*$", result.stdout))


class ProductionInventoryTests(unittest.TestCase):
    def test_consumer_two_is_the_only_276_to_308_profile_delta(self) -> None:
        self.assertEqual(render_count(enable_consumer_two=False), 276)
        self.assertEqual(render_count(enable_consumer_two=True), 308)


if __name__ == "__main__":
    unittest.main()
