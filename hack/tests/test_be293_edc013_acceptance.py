"""Offline-only acceptance contract tests using synthetic data."""
from __future__ import annotations

import copy
import unittest

from hack.be293_edc013_acceptance import (
    AcceptanceInputError,
    build_catalog_request,
    build_http_pull_transfer_request,
    build_negotiation_request,
    credential_inventory_failures,
    payload_matches,
    require_finalized_agreement,
    select_catalog_offer,
)


PROVIDER_DID = "did:web:provider.synthetic.example"
CONSUMER_DID = "did:web:consumer.synthetic.example"
DSP = "https://provider.synthetic.example/api/v1/dsp/2025-1"
DATASET = "synthetic-dataset-001"
ISSUER_DID = "did:web:issuer.synthetic.example"
REQUIRED_TYPES = (
    "MembershipCredential",
    "BpnCredential",
    "DataExchangeGovernance",
)


def synthetic_catalog() -> dict:
    return {
        "@type": "Catalog",
        "dataset": {
            "@id": DATASET,
            "hasPolicy": {
                "@id": "synthetic-offer-001",
                "@type": "Offer",
                "permission": [{"action": "use", "constraint": {"synthetic": True}}],
                "prohibition": [],
                "obligation": [],
            },
            "distribution": [{"format": "HttpData-PULL"}],
        },
    }


class CatalogContractTests(unittest.TestCase):
    def test_catalog_request_is_read_only_dsp_2025_1_contract(self) -> None:
        request = build_catalog_request(PROVIDER_DID, DSP, asset_id=DATASET)
        self.assertEqual(request["@type"], "CatalogRequest")
        self.assertEqual(request["counterPartyId"], PROVIDER_DID)
        self.assertEqual(request["counterPartyAddress"], DSP)
        self.assertEqual(request["protocol"], "dataspace-protocol-http:2025-1")
        self.assertEqual(
            request["querySpec"]["filterExpression"][0]["operandRight"], DATASET
        )

    def test_catalog_rejects_http_wrong_dsp_path_and_non_did_id(self) -> None:
        for provider, endpoint in (
            (PROVIDER_DID, "http://provider.synthetic.example/api/v1/dsp/2025-1"),
            (PROVIDER_DID, "https://provider.synthetic.example/api/v1/dsp"),
            ("BPNL000000000001", DSP),
        ):
            with self.subTest(provider=provider, endpoint=endpoint):
                with self.assertRaises(AcceptanceInputError):
                    build_catalog_request(provider, endpoint)

    def test_catalog_empty_offer_is_a_precondition_failure(self) -> None:
        with self.assertRaisesRegex(AcceptanceInputError, "absent from catalog"):
            select_catalog_offer(
                {"dataset": []},
                dataset_id=DATASET,
                offer_id="synthetic-offer-001",
                provider_id=PROVIDER_DID,
                transfer_type="HttpData-PULL",
            )

    def test_offer_requires_an_advertised_transfer_format(self) -> None:
        with self.assertRaisesRegex(AcceptanceInputError, "not advertised"):
            select_catalog_offer(
                synthetic_catalog(),
                dataset_id=DATASET,
                offer_id="synthetic-offer-001",
                provider_id=PROVIDER_DID,
                transfer_type="AmazonS3-PUSH",
            )


class NegotiationContractTests(unittest.TestCase):
    def test_negotiation_preserves_policy_and_does_not_mutate_catalog_offer(self) -> None:
        original = synthetic_catalog()
        selected = select_catalog_offer(
            original,
            dataset_id=DATASET,
            offer_id="synthetic-offer-001",
            provider_id=PROVIDER_DID,
            transfer_type="HttpData-PULL",
        )
        before = copy.deepcopy(selected["offer"])
        request = build_negotiation_request(
            selected["offer"], counter_party_address=DSP
        )
        self.assertEqual(request["@type"], "ContractRequest")
        self.assertEqual(request["policy"], before)
        self.assertEqual(request["policy"]["assigner"], PROVIDER_DID)
        self.assertEqual(request["policy"]["target"], DATASET)
        self.assertEqual(selected["offer"], before)
        self.assertEqual(request["callbackAddresses"], [])

    def test_negotiation_rejects_incomplete_or_inconsistent_policy(self) -> None:
        for offer in (
            {"@id": "offer", "assigner": PROVIDER_DID, "target": DATASET},
            {
                "@id": "offer",
                "assigner": PROVIDER_DID,
                "target": DATASET,
                "permission": [],
                "obligation": [],
            },
        ):
            with self.subTest(offer=offer):
                with self.assertRaises(AcceptanceInputError):
                    build_negotiation_request(offer, counter_party_address=DSP)

    def test_negotiation_rejects_wrong_endpoint_protocol_pair(self) -> None:
        offer = select_catalog_offer(
            synthetic_catalog(),
            dataset_id=DATASET,
            offer_id="synthetic-offer-001",
            provider_id=PROVIDER_DID,
            transfer_type="HttpData-PULL",
        )["offer"]
        with self.assertRaises(AcceptanceInputError):
            build_negotiation_request(
                offer, counter_party_address="https://provider.synthetic.example/api/v1/dsp"
            )


class TransferAndIdentityTests(unittest.TestCase):
    def test_transfer_gate_requires_finalized_agreement_response(self) -> None:
        self.assertEqual(
            require_finalized_agreement(
                {"state": "FINALIZED", "contractAgreementId": "synthetic-agreement-001"}
            ),
            "synthetic-agreement-001",
        )
        for negotiation in (
            {"state": "REQUESTED", "contractAgreementId": "not-final"},
            {"state": "FINALIZED"},
        ):
            with self.subTest(negotiation=negotiation):
                with self.assertRaises(AcceptanceInputError):
                    require_finalized_agreement(negotiation)

    def test_pull_transfer_requires_agreement_id_and_uses_http_proxy(self) -> None:
        request = build_http_pull_transfer_request(
            negotiation={
                "state": "FINALIZED",
                "contractAgreementId": "synthetic-agreement-001",
            },
            counter_party_address=DSP,
            transfer_type="HttpData-PULL",
        )
        self.assertEqual(request["@type"], "TransferRequest")
        self.assertEqual(request["contractId"], "synthetic-agreement-001")
        self.assertEqual(request["dataDestination"], {"type": "HttpProxy"})

    def test_transfer_rejects_missing_contract_or_unadvertised_mode(self) -> None:
        with self.assertRaises(AcceptanceInputError):
            build_http_pull_transfer_request(
                negotiation={"state": "REQUESTED", "contractAgreementId": "agreement"},
                counter_party_address=DSP,
                transfer_type="HttpData-PULL",
            )
        with self.assertRaises(AcceptanceInputError):
            build_http_pull_transfer_request(
                negotiation={"state": "FINALIZED", "contractAgreementId": "agreement"},
                counter_party_address=DSP,
                transfer_type="AmazonS3-PUSH",
            )

    def test_dcp_credential_inventory_checks_holder_issuer_status_and_required_types(self) -> None:
        credentials = [
            {
                "holder": CONSUMER_DID,
                "issuer": ISSUER_DID,
                "types": [kind],
                "status": "active",
                "expires_at": 200,
            }
            for kind in REQUIRED_TYPES
        ]
        self.assertEqual(
            credential_inventory_failures(
                participant_did=CONSUMER_DID,
                trusted_issuer_dids=[ISSUER_DID],
                credential_inventory=credentials,
                required_types=REQUIRED_TYPES,
                now_epoch=100,
            ),
            (),
        )
        credentials[0]["issuer"] = "did:web:untrusted.synthetic.example"
        credentials[1]["holder"] = PROVIDER_DID
        credentials[2]["status"] = "expired"
        credentials[2]["expires_at"] = 50
        failures = credential_inventory_failures(
            participant_did=CONSUMER_DID,
            trusted_issuer_dids=[ISSUER_DID],
            credential_inventory=credentials,
            required_types=REQUIRED_TYPES + ("OtherRequiredCredential",),
            now_epoch=100,
        )
        self.assertIn("credential[0]:untrusted_issuer", failures)
        self.assertIn("credential[1]:holder_mismatch", failures)
        self.assertIn("credential[2]:not_active", failures)
        self.assertIn("credential[2]:expired_or_invalid_expiry", failures)
        self.assertIn("missing_required_type:OtherRequiredCredential", failures)

    def test_payload_verification_compares_bytes_not_status_only(self) -> None:
        expected = b"synthetic BE-293 acceptance payload\n"
        self.assertTrue(payload_matches(expected, bytes(expected)))
        self.assertFalse(payload_matches(expected, b"different payload\n"))


if __name__ == "__main__":
    unittest.main()
