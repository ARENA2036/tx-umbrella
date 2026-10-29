# BE-293 / ARENA EDC 0.13.0 preparation: unresolved decisions

This workspace is a local migration candidate based on clean ARENA `develop` commit
`f386f05e34d68d7753251d2b7fc009b7d1b738df`. It is not a complete Tractus-X 26.09 Umbrella lock and is not ready to deploy.

## Confirmed local migration

- Connector chart dependency is pinned to the 26.09 component-matrix version, `0.13.0`.
- Connector configuration uses `dcp.*`; `dcp.sts.dim` became `dcp.sts.div` and the credential service runtime variable uses the 0.13 `TX_EDC_IAM_DCP_CREDENTIALSERVICE_URL` name.
- Existing DID strings remain unchanged. BPNs move from `participant.id` to `participant.bpnl`; the existing DID moves into `participant.id`.
- Context IDs were copied verbatim from the separately preserved 0.12 candidate. They were not generated or replaced in this workspace. They have not been verified against live deployments and must be confirmed by the identity owner before any rollout.
- AP6 values remain byte-for-byte unchanged until its topology and identity mapping are established.
- A 0.13-specific chart patch provides optional Secret references for management API key, dataplane proxy key, Vault token, and external datasource password. It retains upstream literal-value behavior when no reference is configured. No Secret names or keys are set here.

The published 26.09 component matrix constrains EDC chart/application to 0.13.0, DTR to 0.13.0, BPDM chart/application to 7.1.0/7.5.0, and Holder Wallet and Issuer Service to 0.4.1. Those versions are not a complete Umbrella dependency lock; this change updates only the EDC wrapper's Connector dependency.

## Decisions required before a complete release candidate

1. **PostgreSQL:** Connector 0.13.0 changes its optional embedded database dependency from Bitnami PostgreSQL to Cloud Pirates PostgreSQL 0.18.3, whose upstream chart targets PostgreSQL 18. The wrapper chart still declares Bitnami PostgreSQL 15.2.1 and Vault 0.27.0. The 26.09 component matrix does not define the Umbrella's full database topology or migration. The database owner must choose an external/embedded topology and provide a tested, backed-up migration plan before updating wrapper dependencies or locks.
2. **Federated catalog data:** the 0.12-to-0.13 guide documents removal of the federated-catalog table/configuration during migration. The data owner must decide whether existing catalog state may be discarded or must be retained/exported, and approve the corresponding migration setting and recovery plan.
3. **Secret ownership and provisioning:** the version-specific patch adds SecretKeyRef capability, but no secret names/keys or provisioning owner are specified. Infrastructure/security must define who creates and rotates each referenced Secret and how all environments supply references. The candidate does not claim payload preservation or secure deployment wiring.
4. **Canonical context IDs:** values are copied from the 0.12 candidate, not derived anew. The identity owner must confirm those exact IDs are canonical and already bound to the intended operator/provider/consumer identities. A mismatch must block deployment; IDs must not be regenerated to resolve it.
5. **Complete 26.09 Umbrella baseline:** the published component matrix constrains component versions but is not a full dependency lock. Upstream Umbrella issue #436 remains open, and the published Umbrella baseline reviewed for this work is 26.03.02. The release owner must provide/approve a complete dependency matrix and generated lock files before calling this a 26.09 Umbrella migration.

## Validation boundary

Local tests, YAML parsing, patch-application checks, and any Helm checks possible with cached dependencies are preparation only. The exact published 0.13.0 dependency artifact and the complete Umbrella dependency set must be available for strict dependency build, full render, and package-level SecretRef verification. No live cluster, Vault, database, or identity operation is authorized by this document.

## Sources reviewed

- [Connector 0.12.x to 0.13.x migration guide](https://github.com/eclipse-tractusx/tractusx-edc/blob/main/docs/migration/2026_06-Version_0.12.x_0.13.x.md)
- [Tractus-X 26.09 component version matrix](https://eclipse-tractusx.github.io/blog-changelog/release-26-09/)
- [Connector 0.13.0 chart metadata](https://github.com/eclipse-tractusx/tractusx-edc/blob/0.13.0/charts/tractusx-connector/Chart.yaml)
- [Umbrella issue #436](https://github.com/eclipse-tractusx/tractus-x-umbrella/issues/436)
