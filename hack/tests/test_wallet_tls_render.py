"""Regression coverage for the pinned Wallet stub 0.1.14 TLS ingress."""
from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text()


class WalletTlsRenderTests(unittest.TestCase):
    def test_patch_is_version_pinned_and_applied_by_dependency_build(self) -> None:
        chart_lock = read("charts/identity-and-trust-bundle/Chart.lock")
        patch = read("hack/patches/ssi-dim-wallet-stub-0.1.14-ingress-annotations.patch")
        dependency_script = read("hack/helm-dependencies.bash")

        self.assertRegex(chart_lock, r"(?m)^  version: 0\.1\.14$")
        self.assertIn("ssi-dim-wallet-stub-0.1.14.tgz", dependency_script)
        self.assertIn("Wallet ingress patch requires chart 0.1.14", dependency_script)
        self.assertIn("$WALLET_INGRESS_PATCH", dependency_script)
        self.assertIn("nindent 4", patch)
        self.assertIn("| indent 4", patch)

    def test_tls_ingress_with_multiple_annotations_renders_valid_yaml(self) -> None:
        command = [
            "helm",
            "template",
            "wallet-tls-regression",
            "charts/identity-and-trust-bundle",
            "--namespace",
            "be293",
            "--set",
            "ssi-dim-wallet-stub.enabled=true",
            "--set",
            "ssi-dim-wallet-stub.wallet.ingress.enabled=true",
            "--set-string",
            "ssi-dim-wallet-stub.wallet.host=wallet.synthetic.test",
            "--set",
            "ssi-dim-wallet-stub.wallet.ingress.tls.enabled=true",
            "--set-string",
            "ssi-dim-wallet-stub.wallet.ingress.tls.name=wallet-synthetic-tls",
            "--set-string",
            "ssi-dim-wallet-stub.wallet.ingress.annotations.alpha=first",
            "--set-string",
            "ssi-dim-wallet-stub.wallet.ingress.annotations.beta=second",
        ]
        result = subprocess.run(
            command, cwd=ROOT, capture_output=True, text=True, check=False
        )
        self.assertEqual(result.returncode, 0, "Wallet TLS chart output must be valid YAML")
        self.assertIn("wallet-synthetic-tls", result.stdout)
        self.assertIn("wallet.synthetic.test", result.stdout)
        self.assertIn("alpha: first", result.stdout)
        self.assertIn("beta: second", result.stdout)


if __name__ == "__main__":
    unittest.main()
