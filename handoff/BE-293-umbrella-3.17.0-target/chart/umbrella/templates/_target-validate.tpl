{{/*
be293-target deployment-profile contract.

A separate, render-time guard for the confirmed BE-293 target cluster. It is
active only when be293.deploymentProfile=be293-target and leaves the
k8s-dev-01 contract (_wallet-validate.tpl) untouched.

Confirmed by the target-cluster operator: namespace be293 (dedicated),
ClusterIssuer letsencrypt-prod, the cluster's default StorageClass. Every other
platform coordinate (DNS zone, ingress class, ExternalDNS, registry, pull
Secret, Vault, credentials) has no default: the guard fails closed until an
operator overlay supplies it. The guard reads only be293.target and rejects
the k8s-dev-01 `platform` block, so DEV coordinates cannot be inherited.
*/}}
{{- define "umbrella.be293Target.valueAt" -}}
{{- $cur := .root -}}
{{- $missing := false -}}
{{- range $seg := .path -}}
  {{- if not $missing -}}
    {{- if kindIs "map" $cur -}}
      {{- if hasKey $cur (toString $seg) -}}
        {{- $cur = index $cur (toString $seg) -}}
      {{- else -}}
        {{- $missing = true -}}
      {{- end -}}
    {{- else if kindIs "slice" $cur -}}
      {{- if lt (int $seg) (len $cur) -}}
        {{- $cur = index $cur (int $seg) -}}
      {{- else -}}
        {{- $missing = true -}}
      {{- end -}}
    {{- else -}}
      {{- $missing = true -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if and (not $missing) (not (kindIs "invalid" $cur)) -}}{{- toString $cur -}}{{- end -}}
{{- end -}}

{{/* Fails when a host name or zone is empty, malformed or under a reserved/example suffix (RFC 2606, RFC 6761). */}}
{{- define "umbrella.be293Target.requirePublicName" -}}
{{- $name := .value | default "" -}}
{{- if not (regexMatch "^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\\.)+[a-z]([-a-z0-9]{0,61}[a-z0-9])?$" $name) -}}
{{- fail (printf "be293-target requires be293.target.%s as a lower-case DNS name confirmed by the platform owner" .field) -}}
{{- end -}}
{{- range $suffix := (list "example" "invalid" "test" "localhost" "local" "example.com" "example.net" "example.org" "tx.test") -}}
{{- if or (eq $name $suffix) (hasSuffix (printf ".%s" $suffix) $name) -}}
{{- fail (printf "be293-target forbids the reserved or example name suffix .%s in be293.target.%s" $suffix $.field) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "umbrella.validateBe293TargetContract" -}}
{{- $be293 := .Values.be293 | default dict -}}
{{- if eq ($be293.deploymentProfile | default "local") "be293-target" -}}
{{- $t := $be293.target | default dict -}}
{{- $dns1123 := "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" -}}

{{/* 1. Confirmed namespace, issuer and storage policy. */}}
{{- if ne ($t.namespace | default "") "be293" -}}
{{- fail "be293-target requires be293.target.namespace=be293 (the confirmed dedicated namespace)" -}}
{{- end -}}
{{- if ne .Release.Namespace "be293" -}}
{{- fail "be293-target must be installed into the dedicated namespace be293; shared namespaces such as portal are not supported" -}}
{{- end -}}
{{- if ne ($t.clusterIssuer | default "") "letsencrypt-prod" -}}
{{- fail "be293-target requires the confirmed ClusterIssuer be293.target.clusterIssuer=letsencrypt-prod" -}}
{{- end -}}
{{- if ne ($t.storageClassPolicy | default "") "cluster-default" -}}
{{- fail "be293-target requires be293.target.storageClassPolicy=cluster-default (the confirmed default StorageClass)" -}}
{{- end -}}

{{/* 2. No inheritance from the k8s-dev-01 profile or the local profile. */}}
{{- range $key, $value := ($be293.platform | default dict) -}}
{{- if $value -}}
{{- fail (printf "be293-target must not carry the k8s-dev-01 be293.platform.%s value; use be293.target only" $key) -}}
{{- end -}}
{{- end -}}
{{- if (($be293.devVaultStaticTokens | default dict).enabled | default false) -}}
{{- fail "be293-target forbids the DEV switch be293.devVaultStaticTokens; set be293.target.vaultAuthMode instead" -}}
{{- end -}}
{{- $coreDnsPatch := $be293.coreDnsPatch | default dict -}}
{{- if or (not (hasKey $coreDnsPatch "enabled")) $coreDnsPatch.enabled -}}
{{- fail "be293-target requires be293.coreDnsPatch.enabled=false; the local CoreDNS mutation is forbidden" -}}
{{- end -}}

{{/* 3. Storage: the default StorageClass must provision every PVC. An empty
value renders no storageClassName; "-" would render storageClassName: "" and
disable dynamic provisioning, a named class would bypass the default.
The list is every value that sets the class of one of the 14 rendered
volumeClaimTemplates (verified by probing each path), plus global.storageClass
and the two DEV keys the IdentityHub/IssuerService charts ignore. */}}
{{- $storagePaths := list
    (list "global" "storageClass")
    (list "bdrs-server" "postgresql" "persistence" "storageClass")
    (list "bpdm" "postgres" "primary" "persistence" "storageClass")
    (list "bpndiscovery" "postgresql" "primary" "persistence" "storageClass")
    (list "centralidp" "keycloak" "postgresql" "primary" "persistence" "storageClass")
    (list "sharedidp" "keycloak" "postgresql" "primary" "persistence" "storageClass")
    (list "dataconsumerOne" "dataspace-connector-bundle" "postgresql" "primary" "persistence" "storageClass")
    (list "dataconsumerTwo" "dataspace-connector-bundle" "postgresql" "primary" "persistence" "storageClass")
    (list "tx-data-provider" "dataspace-connector-bundle" "postgresql" "primary" "persistence" "storageClass")
    (list "tx-data-provider" "data-persistence-layer-bundle" "simple-data-backend" "postgresql" "primary" "persistence" "storageClass")
    (list "tx-data-provider" "digital-twin-bundle" "postgresql" "primary" "persistence" "storageClass")
    (list "discoveryfinder" "postgresql" "primary" "persistence" "storageClass")
    (list "portal" "postgresql" "primary" "persistence" "storageClass")
    (list "identity-and-trust-bundle" "identity-hub-postgres" "postgresql" "persistence" "storageClass")
    (list "identity-and-trust-bundle" "identity-hub-postgres" "postgresql" "primary" "persistence" "storageClass")
    (list "identity-and-trust-bundle" "issuer-service" "postgresql" "persistence" "storageClass")
    (list "identity-and-trust-bundle" "issuer-service" "postgresql" "primary" "persistence" "storageClass") -}}
{{- range $path := $storagePaths -}}
{{- if include "umbrella.be293Target.valueAt" (dict "root" $.Values "path" $path) -}}
{{- fail (printf "be293-target uses the cluster default StorageClass; %s must be empty" (join "." $path)) -}}
{{- end -}}
{{- end -}}
{{- $serializedValues := toYaml .Values -}}
{{- if regexMatch "(?m)^\\s*storageClass: ['\"]?-['\"]?\\s*$" $serializedValues -}}
{{- fail "be293-target forbids storageClass \"-\" (renders storageClassName: \"\" and disables default provisioning)" -}}
{{- end -}}
{{- /* Disabled subcharts keep upstream defaults (e.g. "standard") that render
nothing; tools/check_target_render.rb verifies that no rendered PVC or
volumeClaimTemplate carries a storageClassName at all. */ -}}

{{/* 4. DNS, ingress, TLS. */}}
{{- include "umbrella.be293Target.requirePublicName" (dict "field" "dnsZone" "value" $t.dnsZone) -}}
{{- if not (regexMatch $dns1123 ($t.ingressClass | default "")) -}}
{{- fail "be293-target requires be293.target.ingressClass from the platform owner" -}}
{{- end -}}
{{- if not (kindIs "bool" $t.externalDns) -}}
{{- fail "be293-target requires be293.target.externalDns=true|false from the platform owner (whether ExternalDNS manages the Ingress hosts)" -}}
{{- end -}}
{{- $routing := $be293.routing | default dict -}}
{{- if and $routing.dnsZone (ne $routing.dnsZone $t.dnsZone) -}}
{{- fail "be293-target requires be293.routing.dnsZone to equal be293.target.dnsZone" -}}
{{- end -}}
{{- $shared := ((.Values.wallet | default dict).identityHub | default dict).shared | default dict -}}
{{- if ne ($shared.host | default "") (printf "identity-hub.%s" $t.dnsZone) -}}
{{- fail "be293-target requires wallet.identityHub.shared.host=identity-hub.<be293.target.dnsZone>" -}}
{{- end -}}
{{- if ne ($shared.issuerServiceHost | default "") (printf "issuer-service.%s" $t.dnsZone) -}}
{{- fail "be293-target requires wallet.identityHub.shared.issuerServiceHost=issuer-service.<be293.target.dnsZone>" -}}
{{- end -}}
{{- $bpns := (($t.externalIngresses | default dict).identityHubDidBpns) | default list -}}
{{- if not $bpns -}}
{{- fail "be293-target requires be293.target.externalIngresses.identityHubDidBpns (participant BPNs served as did:web documents)" -}}
{{- end -}}
{{- range $bpn := (append $bpns (.Values.wallet.operatorBpn | default "")) -}}
{{- if not (regexMatch "^BPNL[0-9A-Z]{12}$" (toString $bpn)) -}}
{{- fail (printf "be293-target: %q is not a valid BPNL" (toString $bpn)) -}}
{{- end -}}
{{- end -}}

{{/* 5. Images. */}}
{{- include "umbrella.be293Target.requirePublicName" (dict "field" "registryHost" "value" (regexReplaceAll ":[0-9]+$" ($t.registryHost | default "") "")) -}}
{{- $repository := $t.imageRepository | default "" -}}
{{- if or (not (hasPrefix (printf "%s/" $t.registryHost) $repository)) (not (regexMatch "^[a-z0-9.:-]+(/[a-z0-9._-]+)+$" $repository)) -}}
{{- fail "be293-target requires be293.target.imageRepository as <registryHost>/<path> from the platform owner" -}}
{{- end -}}
{{- if not (regexMatch $dns1123 ($t.pullSecretName | default "")) -}}
{{- fail "be293-target requires be293.target.pullSecretName (a pre-provisioned imagePullSecret) from the platform owner" -}}
{{- end -}}
{{- $privateImages := $be293.privateImages | default dict -}}
{{- if not ($privateImages.enabled | default false) -}}
{{- fail "be293-target requires be293.privateImages.enabled=true" -}}
{{- end -}}
{{- if or (ne ($privateImages.repository | default "") $repository) (ne ($privateImages.registry | default "") $t.registryHost) (ne ($privateImages.pullSecretName | default "") $t.pullSecretName) -}}
{{- fail "be293-target requires be293.privateImages.{registry,repository,pullSecretName} to equal be293.target.{registryHost,imageRepository,pullSecretName}" -}}
{{- end -}}
{{- if not ($privateImages.requireDigestReferences | default false) -}}
{{- fail "be293-target requires be293.privateImages.requireDigestReferences=true" -}}
{{- end -}}
{{- if or (contains "pullPolicy: Never" $serializedValues) (contains "imagePullPolicy: Never" $serializedValues) -}}
{{- fail "be293-target forbids local-only images (pullPolicy: Never)" -}}
{{- end -}}

{{/* 6. No example, local or placeholder identifiers anywhere in the values. */}}
{{- /* Credential placeholders are checked per active credential in section 8;
disabled subcharts keep sanitized chart-default placeholders that never render. */ -}}
{{- range $marker := (list "example.invalid" ".tx.test" "<<SET-BY-OPERATOR" "synthetic-" "premium-perf1-stackit" "letsencrypt-dev") -}}
{{- if contains $marker $serializedValues -}}
{{- fail (printf "be293-target values still contain %q (example, DEV-only or placeholder content); build them with tools/build_target_values.rb from confirmed inputs" $marker) -}}
{{- end -}}
{{- end -}}
{{- range $ref := (regexFindAll "\\.[a-z0-9-]+\\.svc\\.cluster\\.local" $serializedValues -1) -}}
{{- if ne $ref (printf ".%s.svc.cluster.local" $.Release.Namespace) -}}
{{- fail (printf "be293-target found an in-cluster address in another namespace (%s); only %s is supported" $ref $.Release.Namespace) -}}
{{- end -}}
{{- end -}}

{{/* 7. Secrets, hooks and Vault lifecycle. */}}
{{- if ne ($t.secretDelivery | default "") "preprovisioned-kubernetes-secrets" -}}
{{- fail "be293-target supports only be293.target.secretDelivery=preprovisioned-kubernetes-secrets" -}}
{{- end -}}
{{- if (index .Values "external-secrets" | default dict).enabled -}}
{{- fail "be293-target requires external-secrets.enabled=false" -}}
{{- end -}}
{{- if ne (toString $t.helmHooksApproved) "true" -}}
{{- fail "be293-target requires explicit approval be293.target.helmHooksApproved=true for the Helm hooks and their upgrade semantics" -}}
{{- end -}}
{{- if not ($t.vaultAddress | default "") -}}
{{- fail "be293-target requires be293.target.vaultAddress from the platform owner" -}}
{{- end -}}
{{- if ne ($t.vaultAuthMode | default "") "secret-backed-static-token" -}}
{{- fail "be293-target supports only be293.target.vaultAuthMode=secret-backed-static-token" -}}
{{- end -}}
{{- range $name := (list "tx-data-provider" "dataconsumerOne" "dataconsumerTwo") -}}
  {{- $bundle := index (index $.Values $name | default dict) "dataspace-connector-bundle" | default dict -}}
  {{- if ($bundle.vault | default dict).enabled | default false -}}
  {{- fail (printf "be293-target forbids the embedded connector Vault for %s" $name) -}}
  {{- end -}}
  {{- $connector := index $bundle "tractusx-connector" | default dict -}}
  {{- range $plane := (list "controlplane" "dataplane") -}}
    {{- $ref := include "umbrella.be293Target.valueAt" (dict "root" $connector "path" (list $plane "envValueFrom" "EDC_VAULT_HASHICORP_TOKEN" "secretKeyRef" "name")) -}}
    {{- $key := include "umbrella.be293Target.valueAt" (dict "root" $connector "path" (list $plane "envValueFrom" "EDC_VAULT_HASHICORP_TOKEN" "secretKeyRef" "key")) -}}
    {{- if or (not $ref) (not $key) -}}
    {{- fail (printf "be293-target requires a %s %s EDC_VAULT_HASHICORP_TOKEN SecretKeyRef" $name $plane) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if ((index (index .Values "identity-and-trust-bundle" | default dict) "issuer-service" | default dict).install | default dict).vault | default false -}}
{{- fail "be293-target forbids IssuerService's embedded Vault" -}}
{{- end -}}
{{- if ((index .Values "bdrs-server" | default dict).install | default dict).vault | default false -}}
{{- fail "be293-target forbids BDRS's embedded Vault" -}}
{{- end -}}
{{- if $shared.vaultToken | default "" -}}
{{- fail "be293-target requires wallet.identityHub.shared.vaultToken to stay empty (Secret-backed tokens only)" -}}
{{- end -}}
{{- range $participantName, $participant := ((.Values.wallet | default dict).participants | default dict) -}}
{{- if $participant.vaultToken | default "" -}}
{{- fail (printf "be293-target requires wallet.participants.%s.vaultToken to stay empty (Secret-backed tokens only)" $participantName) -}}
{{- end -}}
{{- end -}}

{{/* 8. Credentials: present, not a placeholder or weak value, long enough. Values are never printed. */}}
{{- $weak := "^(?i)(changeme|change-me|change_me|replaceme|replace-me|password|passw0rd|secret|admin|default|todo|test|none|null|xxx+|\\*+)$" -}}
{{- range $c := (.Files.Get "files/be293-target-credentials.json" | fromJsonArray) -}}
  {{- $value := include "umbrella.be293Target.valueAt" (dict "root" $.Values "path" $c.path) -}}
  {{- $alt := "" -}}
  {{- if $c.altPath -}}{{- $alt = include "umbrella.be293Target.valueAt" (dict "root" $.Values "path" $c.altPath) -}}{{- end -}}
  {{- if and (not $alt) (not $value) -}}
    {{- fail (printf "be293-target credential %s is missing; supply it in the secrets overlay" $c.label) -}}
  {{- end -}}
  {{- /* An inline value is checked even when a SecretRef alternative is configured. */ -}}
  {{- if $value -}}
    {{- if or (regexMatch $weak $value) (contains "<<" $value) (hasPrefix "synthetic-" $value) -}}
    {{- fail (printf "be293-target credential %s is a placeholder or a weak value" $c.label) -}}
    {{- end -}}
    {{- if lt (len $value) (int $c.minLength) -}}
    {{- fail (printf "be293-target credential %s is shorter than %d characters" $c.label (int $c.minLength)) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
