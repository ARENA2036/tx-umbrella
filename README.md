# BE-293 Umbrella 3.17.0 baseline

This branch is a sanitized reference baseline of the BE-293 Tractus-X Umbrella
3.17.0 configuration: IdentityHub, IssuerService, BDRS, EDC connectors, Portal,
Central/Shared IDP, BPDM and the discovery services. Start here:

- [`recovery/be293-dev-3.17.0/README.md`](recovery/be293-dev-3.17.0/README.md): chart layout, how to supply environment values and credentials securely, and limitations
- [`recovery/be293-dev-3.17.0/VALIDATION.md`](recovery/be293-dev-3.17.0/VALIDATION.md): validation and secret-scan report

Nothing here is deployable as committed:
- Credentials are `<<SET-FROM-SECRET-STORE:...>>` placeholders.
- Environment identifiers use the reserved, never-resolving `example.invalid`
  domain.

The chart and most dependency packages are based on Eclipse Tractus-X charts,
licensed under Apache-2.0 (see `LICENSE`, `LICENSE_non-code` and `NOTICE.md`).
Several dependency packages carry local modifications; `VALIDATION.md` lists
them.
