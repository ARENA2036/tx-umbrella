"""Regression coverage for the DataExchangeGovernanceCredential definition of the charts/alpha identity seed."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEED = ROOT / "charts/alpha/files/identity-seed.sh"
DEG_ID = "dataExchangeGovernanceCredential-id"
DEG_SCHEMA = (
    "https://raw.githubusercontent.com/eclipse-tractusx/tractusx-profiles/1fec333861e64cd05d77d0fa3011f7f4ea1edf36"
    "/cx/credentials/schema/credentials/dataexchange.governance.credential.schema.json"
)
REQUIRED_ENV = (
    "NS", "IS_URL", "IH_URL", "ISSUER_ID", "ISSUER_DID", "ISSUANCE_URL", "PORTAL_ID", "PORTAL_DID", "SCHEMA_BASE",
    "BPN_DEFINITION_ID", "MEMBERSHIP_DEFINITION_ID", "PORTAL_SECRET", "IS_SUPERUSER_SECRET", "IH_SUPERUSER_SECRET",
    "DEG_DEFINITION_ID", "DEG_SCHEMA_URL",
)


class IdentitySeedGovernanceDefinitionTests(unittest.TestCase):
    def test_seed_job_receives_live_definition_id_and_pinned_schema(self) -> None:
        result = subprocess.run(
            ["helm", "template", "alpha", "charts/alpha", "--namespace", "validation",
             "--show-only", "templates/identity-seed.yaml", "--set", "identitySeed.enabled=true"],
            cwd=ROOT, capture_output=True, text=True, check=False,
        )
        if result.returncode:
            self.fail("alpha identity seed render failed")
        self.assertIn(f'- {{name: DEG_DEFINITION_ID, value: "{DEG_ID}"}}', result.stdout)
        self.assertIn(f'- {{name: DEG_SCHEMA_URL, value: "{DEG_SCHEMA}"}}', result.stdout)
        self.assertIn('"DataExchangeGovernanceCredential definition"', result.stdout)

    @unittest.skipUnless(shutil.which("jq"), "jq not installed")
    def test_definition_body_matches_live_definition(self) -> None:
        program = re.search(
            r"""jq -n --arg id "\$DEG_DEFINITION_ID" --arg schema "\$DEG_SCHEMA_URL" '(.*?)' > "\$W/body.json\"""",
            SEED.read_text(), re.S,
        )
        self.assertIsNotNone(program, "DEG definition body not found in identity-seed.sh")
        body = json.loads(subprocess.run(
            ["jq", "-n", "--arg", "id", DEG_ID, "--arg", "schema", DEG_SCHEMA, program.group(1)],
            capture_output=True, text=True, check=True,
        ).stdout)
        self.assertEqual(body["id"], DEG_ID)
        self.assertEqual(body["credentialType"], "DataExchangeGovernanceCredential")
        self.assertEqual(body["format"], "VC1_0_JWT")
        self.assertEqual(body["validity"], 31536000)
        self.assertEqual(body["jsonSchemaUrl"], DEG_SCHEMA)
        # Reuses both existing attestations; no new attestation mechanism.
        self.assertEqual(body["attestations"], ["holders-database-attestation", "holder-properties-attestation"])
        mappings = {m["output"]: m["input"] for m in body["mappings"]}
        self.assertEqual(mappings, {
            "credentialSubject.id": "did",
            "credentialSubject.holderIdentifier": "holder_id",
            "credentialSubject.contractVersion": "contractVersion",
        })
        self.assertTrue(all(m["required"] for m in body["mappings"]))

    def test_seed_stops_before_any_call_without_governance_settings(self) -> None:
        for missing in ("DEG_DEFINITION_ID", "DEG_SCHEMA_URL"):
            with self.subTest(missing=missing):
                env = {"PATH": os.environ["PATH"], **{k: "x" for k in REQUIRED_ENV if k != missing}}
                result = subprocess.run(["sh", str(SEED)], env=env, capture_output=True, text=True, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(missing, result.stderr)
                self.assertNotIn("[seed]", result.stdout)


if __name__ == "__main__":
    unittest.main()
