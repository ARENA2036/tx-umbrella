"""Regression coverage for hack/alpha-identity.py Kube.create_secret temp-file cleanup."""
from __future__ import annotations

import argparse
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("alpha_identity", ROOT / "hack/alpha-identity.py")
alpha_identity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(alpha_identity)


class CreateSecretCleanupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.kube = alpha_identity.Kube(argparse.Namespace(namespace="validation", kubeconfig=None, context=None))
        self.calls = []
        self.temp = tempfile.TemporaryDirectory(prefix="alpha-identity-test-")
        self.addCleanup(self.temp.cleanup)

    def record(self, *cmd):
        """Stand-in for kubectl: every --from-file path must exist while the command runs."""
        for arg in cmd:
            if arg.startswith("--from-file="):
                self.assertTrue(os.path.isfile(arg.split("=", 2)[2]))
        self.calls.append(cmd)
        return ""

    def test_removes_every_value_file_after_create(self) -> None:
        self.kube.run = self.record
        self.kube.create_secret("portal-identityhub", {"identityhub-api-key": "a", "issuerservice-admin-api-key": "b"},
                                self.temp.name)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(os.listdir(self.temp.name), [])

    def test_removes_value_files_when_kubectl_fails(self) -> None:
        def fail(*cmd):
            raise alpha_identity.Abort("kubectl create secret failed")

        self.kube.run = fail
        with self.assertRaises(alpha_identity.Abort):
            self.kube.create_secret("identity-db-users", {"ISSUERSERVICE_DB_PASSWORD": "a"}, self.temp.name)
        self.assertEqual(os.listdir(self.temp.name), [])


if __name__ == "__main__":
    unittest.main()
