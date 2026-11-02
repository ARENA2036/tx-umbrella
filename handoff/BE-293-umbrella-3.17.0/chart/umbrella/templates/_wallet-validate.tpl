{{/*
*****************************************************************************
* Copyright (c) 2026 Contributors to the Eclipse Foundation
*
* SPDX-License-Identifier: Apache-2.0
*****************************************************************************
*/}}

{{/*
Wallet mutual-exclusion validator.

Fails the Helm render if more than one wallet implementation is enabled
inside identity-and-trust-bundle. Also cross-checks .Values.wallet.mode
against which wallet chart is enabled.

Call from any rendered template with: {{ include "umbrella.validateWallet" . }}
*/}}
{{- define "umbrella.validateWallet" -}}
{{- $iatBundle := (index .Values "identity-and-trust-bundle") | default dict -}}
{{- $stubMap := (index $iatBundle "ssi-dim-wallet-stub") | default dict -}}
{{- $ihMap := (index $iatBundle "identity-hub") | default dict -}}
{{- $ihPgMap := (index $iatBundle "identity-hub-postgres") | default dict -}}
{{- $stubEnabled := $stubMap.enabled | default false -}}
{{- $ihEnabled := $ihMap.enabled | default false -}}
{{- $ihPgEnabled := $ihPgMap.enabled | default false -}}
{{/* At most ONE wallet implementation may be enabled. */}}
{{- $enabledCount := 0 -}}
{{- if $stubEnabled -}}{{- $enabledCount = add1 $enabledCount -}}{{- end -}}
{{- if $ihEnabled -}}{{- $enabledCount = add1 $enabledCount -}}{{- end -}}
{{- if $ihPgEnabled -}}{{- $enabledCount = add1 $enabledCount -}}{{- end -}}
{{- if gt $enabledCount 1 -}}
{{- fail "identity-and-trust-bundle: only ONE wallet may be enabled at a time — pick exactly one of `ssi-dim-wallet-stub.enabled`, `identity-hub.enabled` (in-memory) or `identity-hub-postgres.enabled` (persistent)" -}}
{{- end -}}
{{- $wallet := .Values.wallet | default dict -}}
{{- $mode := $wallet.mode | default "stub" -}}
{{- $anyIh := or $ihEnabled $ihPgEnabled -}}
{{- if and (eq $mode "stub") $anyIh -}}
{{- fail "wallet.mode=stub but an Identity Hub variant (identity-hub / identity-hub-postgres) is enabled; set wallet.mode=identityHub or disable it" -}}
{{- end -}}
{{- if and (eq $mode "identityHub") $stubEnabled -}}
{{- fail "wallet.mode=identityHub but ssi-dim-wallet-stub is enabled; set wallet.mode=stub or disable the stub" -}}
{{- end -}}
{{/* identityHub mode requires exactly one IH variant — guard the zero case too. */}}
{{- if and (eq $mode "identityHub") (not $anyIh) -}}
{{- fail "wallet.mode=identityHub but no Identity Hub variant is enabled; enable exactly one of `identity-hub.enabled` (in-memory) or `identity-hub-postgres.enabled` (persistent)" -}}
{{- end -}}
{{- end -}}

{{/*
*****************************************************************************
* TEMPORARY image-overlay guard (#1609 demonstration era).
*
* The full DCP data-transfer flow is validated ONLY on the EDC-0.17.0-aligned
* stack (tractusx-edc main + tractusx-identityhub PR #309), which is built from
* source and pinned by the local-image overlay
* `charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml`. The bundle
* Chart.yaml files still pin the released 0.16.0 line, which CANNOT complete the
* transfer. To stop anyone silently running the non-working stack, fail the
* render when wallet.mode=identityHub is selected WITHOUT that overlay (it sets
* the `wallet.identityHub.imagesOverridden` sentinel).
*
* REMOVE this guard (and the sentinel) once tractusx-connector 0.13.0 and
* IdentityHub/IssuerService 0.17.0 are released and the bundle pins are bumped.
*****************************************************************************
*/}}
{{- define "umbrella.validateIdentityHubImageOverlay" -}}
{{- $wallet := .Values.wallet | default dict -}}
{{- $mode := $wallet.mode | default "stub" -}}
{{- if eq $mode "identityHub" -}}
{{- $ih := $wallet.identityHub | default dict -}}
{{- if not $ih.imagesOverridden -}}
{{- fail "wallet.mode=identityHub needs the EDC-0.17.0-aligned images, which are not yet on a public registry. Layer the local-image overlay `-f charts/values-test-data-exchange-identity-hub-local-0.17.0.yaml` (it pre-loads the built images and sets wallet.identityHub.imagesOverridden=true). See docs/user/common/guides/data-exchange-identity-hub.md. This guard is removed once connector 0.13.0 + IH/IS 0.17.0 are released." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
*****************************************************************************
* Portal onboarding wallet-provider guard (BE-293).
*
* The Portal backend's Onboarding:WalletProvider is [Required] with NO default
* (it replaced the per-feature UseDimWallet flags). An empty or unknown value
* passes `helm template` but fails the worker at STARTUP ("The WalletProvider
* field is required" / a config-convert error) — a late, opaque failure. When
* the portal is enabled, fail the render instead unless
* portal.backend.walletProvider is exactly one of Dim | Custodian | IdentityHub.
*****************************************************************************
*/}}
{{- define "umbrella.validatePortalWalletProvider" -}}
{{- $portal := .Values.portal | default dict -}}
{{- if $portal.enabled -}}
{{- $backend := $portal.backend | default dict -}}
{{- $wp := $backend.walletProvider | default "" -}}
{{- if not (has $wp (list "Dim" "Custodian" "IdentityHub")) -}}
{{- fail (printf "portal.backend.walletProvider must be one of Dim|Custodian|IdentityHub when portal.enabled=true (got %q). The Portal backend's Onboarding:WalletProvider is [Required] with no default; an empty/invalid value passes `helm template` but fails worker startup at runtime. Set it explicitly in your portal overlay." $wp) -}}
{{- end -}}
{{- end -}}
{{- end -}}


{{/*
AP6 has no default platform configuration. This deliberate contract prevents a
shared-cluster deployment from inheriting local .tx.test, CoreDNS, Vault or
registry assumptions. It verifies only non-secret platform coordinates; the
actual values are supplied in an approved private/operator overlay.
*/}}
{{- define "umbrella.validateAp6PlatformContract" -}}
{{- $be293 := .Values.be293 | default dict -}}
{{- if eq ($be293.deploymentProfile | default "local") "ap6" -}}
{{- $coreDnsPatch := $be293.coreDnsPatch | default dict -}}
{{- $coreDnsPatchEnabled := true -}}
{{- if hasKey $coreDnsPatch "enabled" -}}
{{- $coreDnsPatchEnabled = $coreDnsPatch.enabled -}}
{{- end -}}
{{- if $coreDnsPatchEnabled -}}
{{- fail "AP6 deployment requires be293.coreDnsPatch.enabled=false; the local CoreDNS mutation is forbidden on a shared cluster" -}}
{{- end -}}
{{- $platform := $be293.platform | default dict -}}
{{- $_ := required "AP6 deployment requires be293.platform.dnsZone from the platform owner" ($platform.dnsZone | default "") -}}
{{- $_ := required "AP6 deployment requires be293.platform.ingressClass from the platform owner" ($platform.ingressClass | default "") -}}
{{- $_ := required "AP6 deployment requires be293.platform.tlsMode from the platform owner" ($platform.tlsMode | default "") -}}
{{- $_ := required "AP6 deployment requires be293.platform.storageClass from the platform owner" ($platform.storageClass | default "") -}}
{{- $_ := required "AP6 deployment requires be293.platform.vaultAddress from the platform owner" ($platform.vaultAddress | default "") -}}
{{- $_ := required "AP6 deployment requires be293.platform.vaultAuthMode from the platform owner" ($platform.vaultAuthMode | default "") -}}
{{- $_ := required "AP6 deployment requires be293.platform.secretDelivery from the platform owner" ($platform.secretDelivery | default "") -}}
{{- $_ := required "AP6 deployment requires be293.platform.registryHost from the platform owner" ($platform.registryHost | default "") -}}
{{- $wallet := .Values.wallet | default dict -}}
{{- $identityHub := $wallet.identityHub | default dict -}}
{{- if hasSuffix ".tx.test" ($identityHub.host | default "") -}}
{{- fail "AP6 deployment forbids the local .tx.test IdentityHub host; supply the approved AP6 DNS profile" -}}
{{- end -}}
{{- $provider := index .Values "tx-data-provider" | default dict -}}
{{- $bundle := index $provider "dataspace-connector-bundle" | default dict -}}
{{- $vault := $bundle.vault | default dict -}}
{{- $vaultServer := $vault.server | default dict -}}
{{- if $vaultServer.postStart -}}
{{- fail "AP6 deployment forbids the local Vault postStart bootstrap; use the platform-owned Vault lifecycle" -}}
{{- end -}}
{{- $connector := index $bundle "tractusx-connector" | default dict -}}
{{- $controlPlane := $connector.controlplane | default dict -}}
{{- $controlPlaneImage := $controlPlane.image | default dict -}}
{{- if eq ($controlPlaneImage.pullPolicy | default "") "Never" -}}
{{- fail "AP6 deployment forbids local connector images with imagePullPolicy=Never; use approved immutable registry digests" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Kubernetes development-cluster contract.

Unlike the local Kind profile, k8s-dev-01 is a shared, remotely operated
environment.  This validator deliberately rejects the local-only inputs that
would otherwise be inherited through the BE-293 acceptance stack.  It is a
render-time guard: an operator must supply a separate private overlay with
approved DNS, registry images and Secret references before Helm can produce a
manifest for this profile.
*/}}
{{- define "umbrella.validateK8sDev01PlatformContract" -}}
{{- $be293 := .Values.be293 | default dict -}}
{{- if eq ($be293.deploymentProfile | default "local") "k8s-dev-01" -}}
{{- $coreDnsPatch := $be293.coreDnsPatch | default dict -}}
{{- if $coreDnsPatch.enabled | default false -}}
{{- fail "k8s-dev-01 deployment requires be293.coreDnsPatch.enabled=false; the local CoreDNS mutation is forbidden" -}}
{{- end -}}
{{- if ne .Release.Namespace "be293" -}}
{{- fail "k8s-dev-01 deployment must use namespace be293" -}}
{{- end -}}
{{- $platform := $be293.platform | default dict -}}
{{- $_ := required "k8s-dev-01 deployment requires be293.platform.dnsZone from the platform owner" ($platform.dnsZone | default "") -}}
{{- $_ := required "k8s-dev-01 deployment requires be293.platform.ingressClass from the platform owner" ($platform.ingressClass | default "") -}}
{{- $_ := required "k8s-dev-01 deployment requires be293.platform.vaultAddress from the platform owner" ($platform.vaultAddress | default "") -}}
{{- $_ := required "k8s-dev-01 deployment requires be293.platform.vaultAuthMode from the platform owner" ($platform.vaultAuthMode | default "") -}}
{{- $_ := required "k8s-dev-01 deployment requires be293.platform.registryHost from the platform owner" ($platform.registryHost | default "") -}}
{{- if ne ($platform.tlsMode | default "") "cert-manager" -}}
{{- fail "k8s-dev-01 deployment requires platform-managed cert-manager TLS" -}}
{{- end -}}
{{- if ne ($platform.clusterIssuer | default "") "letsencrypt-dev" -}}
{{- fail "k8s-dev-01 deployment requires the approved letsencrypt-dev ClusterIssuer" -}}
{{- end -}}
{{- if ne ($platform.storageClass | default "") "premium-perf1-stackit" -}}
{{- fail "k8s-dev-01 deployment requires StorageClass premium-perf1-stackit" -}}
{{- end -}}
{{- if ne ($platform.secretDelivery | default "") "preprovisioned-kubernetes-secrets" -}}
{{- fail "k8s-dev-01 has no External Secrets controller; use preprovisioned-kubernetes-secrets" -}}
{{- end -}}
{{- if not ($platform.helmHooksApproved | default false) -}}
{{- fail "k8s-dev-01 deployment requires explicit approval for Helm hooks and their upgrade semantics" -}}
{{- end -}}
{{- $privateImages := $be293.privateImages | default dict -}}
{{- if not ($privateImages.enabled | default false) -}}
{{- fail "k8s-dev-01 deployment requires approved private image configuration" -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" ($privateImages.pullSecretName | default "")) -}}
{{- fail "k8s-dev-01 deployment requires a valid pre-provisioned imagePullSecret name" -}}
{{- end -}}
{{- $approvedRepository := required "k8s-dev-01 deployment requires be293.privateImages.approvedRepository from the platform owner" ($privateImages.approvedRepository | default "") -}}
{{- if ne ($privateImages.repository | default "") $approvedRepository -}}
{{- fail "k8s-dev-01 private images must use the approved image repository (be293.privateImages.approvedRepository)" -}}
{{- end -}}
{{- if index .Values "external-secrets" "enabled" -}}
{{- fail "k8s-dev-01 has no External Secrets CRDs; external-secrets.enabled must remain false" -}}
{{- end -}}
{{- $serializedValues := toYaml .Values -}}
{{- if contains ".tx.test" $serializedValues -}}
{{- fail "k8s-dev-01 forbids local .tx.test routing; provide an approved coherent DNS/DID/ingress overlay" -}}
{{- end -}}
{{- if or (contains "pullPolicy: Never" $serializedValues) (contains "imagePullPolicy: Never" $serializedValues) -}}
{{- fail "k8s-dev-01 forbids local-only images; use approved immutable registry digests" -}}
{{- end -}}
{{/* Disabled connector chart defaults retain a local postStart fixture. Check
the active lifecycle switch instead: enabling any embedded Vault is forbidden. */}}
{{- range $name := (list "tx-data-provider" "dataconsumerOne" "dataconsumerTwo") -}}
  {{- $component := index $.Values $name | default dict -}}
  {{- $bundle := index $component "dataspace-connector-bundle" | default dict -}}
  {{- $vault := $bundle.vault | default dict -}}
  {{- if $vault.enabled | default false -}}
  {{- fail (printf "k8s-dev-01 forbids embedded connector Vault for %s; use the existing namespace Vault lifecycle" $name) -}}
  {{- end -}}
{{- end -}}
{{- $issuerBundle := index .Values "identity-and-trust-bundle" | default dict -}}
{{- $issuer := index $issuerBundle "issuer-service" | default dict -}}
{{- $issuerInstall := $issuer.install | default dict -}}
{{- if $issuerInstall.vault | default false -}}
{{- fail "k8s-dev-01 forbids IssuerService's embedded Vault; use the existing namespace Vault lifecycle" -}}
{{- end -}}
{{- $bdrs := index .Values "bdrs-server" | default dict -}}
{{- $bdrsInstall := $bdrs.install | default dict -}}
{{- if $bdrsInstall.vault | default false -}}
{{- fail "k8s-dev-01 forbids BDRS's embedded Vault; use the existing namespace Vault lifecycle" -}}
{{- end -}}
{{- $wallet := .Values.wallet | default dict -}}
{{- $identityHub := $wallet.identityHub | default dict -}}
{{- $shared := $identityHub.shared | default dict -}}
{{- $devStaticTokens := $be293.devVaultStaticTokens | default dict -}}
{{- if $devStaticTokens.enabled | default false -}}
  {{- if $shared.vaultToken | default "" -}}
  {{- fail "k8s-dev-01 DEV static-token mode requires wallet.identityHub.shared.vaultToken to remain empty; Secret-backed connector tokens must never enter the wallet ConfigMap" -}}
  {{- end -}}
  {{- range $participantName, $participant := ($wallet.participants | default dict) -}}
  {{- if $participant.vaultToken | default "" -}}
  {{- fail (printf "k8s-dev-01 DEV static-token mode requires wallet.participants.%s.vaultToken to remain empty; Secret-backed connector tokens must never enter the wallet ConfigMap" $participantName) -}}
  {{- end -}}
  {{- end -}}
  {{- range $entry := (list
      (dict "name" "dataprovider" "connector" (index (index (index .Values "tx-data-provider") "dataspace-connector-bundle") "tractusx-connector"))
      (dict "name" "dataconsumer-1" "connector" (index (index (index .Values "dataconsumerOne") "dataspace-connector-bundle") "tractusx-connector"))
      (dict "name" "dataconsumer-2" "connector" (index (index (index .Values "dataconsumerTwo") "dataspace-connector-bundle") "tractusx-connector"))
    ) -}}
    {{- $connector := $entry.connector | default dict -}}
    {{- range $planeName := (list "controlplane" "dataplane") -}}
      {{- $plane := index $connector $planeName | default dict -}}
      {{- $from := $plane.envValueFrom | default dict -}}
      {{- $tokenRef := index $from "EDC_VAULT_HASHICORP_TOKEN" | default dict -}}
      {{- $secretRef := $tokenRef.secretKeyRef | default dict -}}
      {{- if or (not ($secretRef.name | default "")) (not ($secretRef.key | default "")) -}}
      {{- fail (printf "k8s-dev-01 DEV static-token mode requires %s %s EDC_VAULT_HASHICORP_TOKEN SecretKeyRef" $entry.name $planeName) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- else -}}
  {{- if $shared.vaultToken | default "" -}}
  {{- fail "k8s-dev-01 forbids a configured shared Vault token; use approved workload authentication" -}}
  {{- end -}}
  {{- range $participantName, $participant := ($wallet.participants | default dict) -}}
  {{- if $participant.vaultToken | default "" -}}
  {{- fail "k8s-dev-01 forbids configured participant Vault tokens; use approved workload authentication" -}}
  {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
