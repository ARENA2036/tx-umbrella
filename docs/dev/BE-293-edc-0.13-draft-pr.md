# BE-293 EDC Connector 0.13.0 migration — Draft PR notes

## Scope

This change prepares the ARENA Umbrella for the EDC Connector 0.13.0 configuration contract from Tractus-X 26.09. It is **not** a complete Tractus-X 26.09 Umbrella upgrade and is not approved for deployment.

The reviewable migration scope is limited to:

- DCP/DIV configuration in place of the prior IATP configuration names.
- The Connector 0.13 credential-service environment variable name.
- Mapping the existing DID and BPN into the 0.13 participant fields without changing identity values.
- A version-specific SecretRef patch for Connector secret inputs, with required references and no literal fallback.
- Regression coverage for those mappings and fail-closed rendering.

The DTR TLS correction is outside this EDC migration scope. Existing credential-bearing files and identity values must not be regenerated or rotated as part of this change.

## Validation evidence

Record the exact local dependency-lock, strict chart lint/render, and focused EDC 0.13 regression-test results in any eventual PR description. The regression tests verify configuration shape and stable identity mappings; they do not prove Secret payload equality, runtime compatibility, or database migration safety.

## Required decisions before merge or deployment

1. **PostgreSQL/Vault topology:** Connector subchart dependencies are disabled, but the parent bundle separately declares Bitnami PostgreSQL 15.2.1 and Vault 0.27.0, both enabled by the bundle's current defaults. Confirm intended topology and data/PVC ownership before changing versions or dependencies.
2. **Federated-catalog data:** choose discard or retention/export. If the existing `edc_federated_catalog` table must be retained, assess and test the documented pre-migration setting `tx.edc.postgresql.migration.federatedcatalog.enabled=false`; do not infer that this preserves the removed feature.
3. **Identity:** the identity owner must confirm canonical participant context IDs and DID/BPN bindings. The migration preserves the checked-in values; it must not generate replacement IDs.
4. **Secret ownership:** security/infrastructure must specify Secret names/keys, provisioning owner, runtime access policy, and rotation lifecycle for each SecretRef.
5. **Historical key material:** classify the key material in prior Git history and decide whether history remediation or another response is required. The new SecretRef path does not erase past exposure.
6. **Release baseline:** obtain an approved full Umbrella component baseline. Connector 0.13.0 and the 26.09 matrix do not establish that all other pinned components are 26.09-compatible.

## Review request

Request review from the EDC/chart maintainer for the 0.13 values and SecretRef patch, identity owner for preserved DID/BPN/context IDs, database/data owner for PostgreSQL and federated-catalog handling, and security/infrastructure for historical key classification and Secret lifecycle. Keep the PR marked **Draft** until these decisions and migration tests are complete.

## Explicit exclusions

- No Helm upgrade or environment deployment.
- No Kubernetes, Vault, or database writes.
- No Secret provisioning or payload changes.
- No key, DID, BPN, participant, or context-ID rotation/recreation.
- No claim of a complete 26.09 Umbrella migration.
