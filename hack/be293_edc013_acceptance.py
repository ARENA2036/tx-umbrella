"""Pure, offline request and evidence helpers for EDC 0.13 acceptance.

This module deliberately performs no HTTP, filesystem, Kubernetes, or Vault
operations. Callers must supply only the selected public catalog offer and
synthetic or explicitly approved test identifiers.
"""
from __future__ import annotations

from copy import deepcopy
from hashlib import sha256
from urllib.parse import urlsplit
from typing import Any, Mapping, Sequence


PROTOCOL_2025_1 = "dataspace-protocol-http:2025-1"
EDC_VOCAB = "https://w3id.org/edc/v0.0.1/ns/"


class AcceptanceInputError(ValueError):
    """Input is incomplete or inconsistent with the discovered offer."""


def _nonempty(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise AcceptanceInputError(f"{field} must be a non-empty string")
    return value


def _https_url(value: Any, field: str) -> str:
    value = _nonempty(value, field)
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise AcceptanceInputError(f"{field} must be an HTTPS URL without userinfo")
    return value.rstrip("/")


def _dsp_endpoint(value: Any, protocol: str) -> str:
    endpoint = _https_url(value, "counterPartyAddress")
    _nonempty(protocol, "protocol")
    if protocol == PROTOCOL_2025_1 and not urlsplit(endpoint).path.endswith(
        "/api/v1/dsp/2025-1"
    ):
        raise AcceptanceInputError("2025-1 endpoint must end in /api/v1/dsp/2025-1")
    return endpoint


def build_catalog_request(
    provider_did: str,
    counter_party_address: str,
    protocol: str = PROTOCOL_2025_1,
    asset_id: str | None = None,
) -> dict[str, Any]:
    """Build a read-only CatalogRequest body for the consumer management API."""
    provider_did = _nonempty(provider_did, "provider_did")
    if protocol == PROTOCOL_2025_1 and not provider_did.startswith("did:"):
        raise AcceptanceInputError("2025-1 counterPartyId must be a DID")
    endpoint = _dsp_endpoint(counter_party_address, protocol)
    request: dict[str, Any] = {
        "@context": [{"@vocab": EDC_VOCAB}],
        "@type": "CatalogRequest",
        "counterPartyId": provider_did,
        "counterPartyAddress": endpoint,
        "protocol": protocol,
    }
    if asset_id is not None:
        asset_id = _nonempty(asset_id, "asset_id")
        request["querySpec"] = {
            "@type": "QuerySpec",
            "offset": 0,
            "limit": 50,
            "filterExpression": [
                {
                    "operandLeft": f"{EDC_VOCAB}id",
                    "operator": "=",
                    "operandRight": asset_id,
                }
            ],
        }
    return request


def _as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def select_catalog_offer(
    catalog: Mapping[str, Any],
    *,
    dataset_id: str,
    offer_id: str,
    provider_id: str,
    transfer_type: str,
) -> dict[str, Any]:
    """Select one eligible offer and the requested transfer format.

    The offer's policy body is copied as returned. Only missing `assigner` and
    `target` fields are bound from the discovered provider and dataset.
    """
    dataset_id = _nonempty(dataset_id, "dataset_id")
    offer_id = _nonempty(offer_id, "offer_id")
    provider_id = _nonempty(provider_id, "provider_id")
    transfer_type = _nonempty(transfer_type, "transfer_type")
    datasets = _as_list(catalog.get("dataset"))
    dataset = next(
        (
            item
            for item in datasets
            if isinstance(item, Mapping)
            and (item.get("@id") or item.get("id")) == dataset_id
        ),
        None,
    )
    if dataset is None:
        raise AcceptanceInputError("requested dataset is absent from catalog")

    formats = {
        item.get("format")
        for item in _as_list(dataset.get("distribution"))
        if isinstance(item, Mapping)
    }
    if transfer_type not in formats:
        raise AcceptanceInputError("transfer_type is not advertised for the dataset")

    offers = [
        item
        for item in _as_list(dataset.get("hasPolicy"))
        if isinstance(item, Mapping)
        and "Offer" in _as_list(item.get("@type"))
        and item.get("@id") == offer_id
    ]
    if len(offers) != 1:
        raise AcceptanceInputError("selected Offer is absent or ambiguous")
    offer = deepcopy(dict(offers[0]))
    _nonempty(offer.get("@id"), "offer.@id")
    for field, expected in (("assigner", provider_id), ("target", dataset_id)):
        existing = offer.get(field)
        if existing is not None and existing != expected:
            raise AcceptanceInputError(f"offer.{field} conflicts with discovered metadata")
        offer[field] = expected
    return {"dataset_id": dataset_id, "transfer_type": transfer_type, "offer": offer}


def build_negotiation_request(
    selected_offer: Mapping[str, Any],
    *,
    counter_party_address: str,
    protocol: str = PROTOCOL_2025_1,
) -> dict[str, Any]:
    """Build a negotiation body using the exact catalog Offer policy clauses."""
    if not isinstance(selected_offer, Mapping):
        raise AcceptanceInputError("selected_offer must be an object")
    offer = deepcopy(dict(selected_offer))
    _nonempty(offer.get("@id"), "offer.@id")
    for field in ("assigner", "target"):
        _nonempty(offer.get(field), f"offer.{field}")
    for field in ("permission", "prohibition", "obligation"):
        if field not in offer:
            raise AcceptanceInputError(f"offer.{field} is required")
    endpoint = _dsp_endpoint(counter_party_address, protocol)
    return {
        "@context": [
            "https://w3id.org/dspace/2025/1/odrl-profile.jsonld",
            "https://w3id.org/catenax/2025/9/policy/context.jsonld",
            {"@vocab": EDC_VOCAB},
        ],
        "@type": "ContractRequest",
        "counterPartyAddress": endpoint,
        "protocol": protocol,
        "policy": offer,
        "callbackAddresses": [],
    }


def require_finalized_agreement(negotiation: Mapping[str, Any]) -> str:
    """Return the agreement ID only after the negotiation is FINALIZED."""
    if not isinstance(negotiation, Mapping) or negotiation.get("state") != "FINALIZED":
        raise AcceptanceInputError("contract negotiation is not FINALIZED")
    return _nonempty(negotiation.get("contractAgreementId"), "contractAgreementId")


def build_http_pull_transfer_request(
    *,
    negotiation: Mapping[str, Any],
    counter_party_address: str,
    protocol: str = PROTOCOL_2025_1,
    transfer_type: str,
) -> dict[str, Any]:
    """Build an HTTP PULL request; payload retrieval remains a separate check."""
    contract_id = require_finalized_agreement(negotiation)
    transfer_type = _nonempty(transfer_type, "transfer_type")
    if transfer_type != "HttpData-PULL":
        raise AcceptanceInputError("this helper supports only HttpData-PULL")
    endpoint = _dsp_endpoint(counter_party_address, protocol)
    return {
        "@context": {"@vocab": EDC_VOCAB},
        "@type": "TransferRequest",
        "contractId": contract_id,
        "counterPartyAddress": endpoint,
        "dataDestination": {"type": "HttpProxy"},
        "protocol": protocol,
        "transferType": transfer_type,
        "callbackAddresses": [],
    }


def credential_inventory_failures(
    *,
    participant_did: str,
    trusted_issuer_dids: Sequence[str],
    credential_inventory: Sequence[Mapping[str, Any]],
    required_types: Sequence[str],
    now_epoch: float,
) -> tuple[str, ...]:
    """Check credential inventory metadata, not signatures or credential values.

    DEV acceptance must separately establish cryptographic verification through
    the actual DCP/VC flow. This helper only checks holder/issuer/type metadata.
    """
    participant_did = _nonempty(participant_did, "participant_did")
    trusted = set(trusted_issuer_dids)
    if not trusted:
        raise AcceptanceInputError("trusted_issuer_dids must not be empty")
    requirements = set(required_types)
    if not requirements:
        raise AcceptanceInputError("required_types must not be empty")
    observed: set[str] = set()
    failures: list[str] = []
    for index, item in enumerate(credential_inventory):
        if item.get("holder") != participant_did:
            failures.append(f"credential[{index}]:holder_mismatch")
        if item.get("issuer") not in trusted:
            failures.append(f"credential[{index}]:untrusted_issuer")
        types = set(_as_list(item.get("types")))
        observed.update(types)
        if item.get("status") != "active":
            failures.append(f"credential[{index}]:not_active")
        expiry = item.get("expires_at")
        if expiry is not None and (
            not isinstance(expiry, (int, float)) or expiry <= now_epoch
        ):
            failures.append(f"credential[{index}]:expired_or_invalid_expiry")
    for credential_type in sorted(requirements - observed):
        failures.append(f"missing_required_type:{credential_type}")
    return tuple(failures)


def payload_matches(expected: bytes, received: bytes) -> bool:
    """Compare payload bytes through digests without returning payload content."""
    if not isinstance(expected, bytes) or not isinstance(received, bytes):
        raise TypeError("payloads must be bytes")
    return sha256(expected).digest() == sha256(received).digest()
