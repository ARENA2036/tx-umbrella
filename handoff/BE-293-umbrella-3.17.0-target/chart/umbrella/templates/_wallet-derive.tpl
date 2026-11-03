{{/*
  -----------------------------------------------------------------------------
  Wallet derive helpers — single source of truth (Phase A of #1609 plan).

  Usage in other templates:

    {{ include "umbrella.wallet.didFor"                (dict "ctx" . "pid" "provider") }}
    {{ include "umbrella.wallet.participantIdFor"      (dict "ctx" . "pid" "provider") }}
    {{ include "umbrella.wallet.base64ParticipantId"   (dict "ctx" . "pid" "provider") }}
    {{ include "umbrella.wallet.credentialServiceUrl"  (dict "ctx" . "pid" "provider") }}
    {{ include "umbrella.wallet.stsUrl"                (dict "ctx" . "pid" "provider") }}
    {{ include "umbrella.wallet.issuerAdminUrl"        (dict "ctx" .) }}
    {{ include "umbrella.wallet.identityApiUrlFor"     (dict "ctx" . "pid" "provider") }}

  The `ctx` key carries the root context ($ or .) so we can read .Values.wallet.
  -----------------------------------------------------------------------------
*/}}

{{/* ---------------- base64url of participantId = role-bpn-lower ------------- */}}
{{- define "umbrella.wallet.participantIdFor" -}}
{{- $ctx := .ctx -}}
{{- $pid := .pid -}}
{{- $p := index $ctx.Values.wallet.participants $pid -}}
{{- if not $p -}}
{{- fail (printf "umbrella.wallet: unknown participant key %q" $pid) -}}
{{- end -}}
{{- printf "%s-%s" $p.role (lower $p.bpn) -}}
{{- end -}}

{{- define "umbrella.wallet.base64ParticipantId" -}}
{{- include "umbrella.wallet.participantIdFor" . | b64enc | replace "=" "" | replace "+" "-" | replace "/" "_" -}}
{{- end -}}

{{/* ---------------- DID ----------------------------------------------------- */}}
{{- define "umbrella.wallet.didFor" -}}
{{- $ctx := .ctx -}}
{{- $pid := .pid -}}
{{- $w := $ctx.Values.wallet -}}
{{- $p := index $w.participants $pid -}}
{{- if eq $w.mode "stub" -}}
{{- printf "%s:%s" $w.stub.didBase $p.bpn -}}
{{- else if eq $w.mode "identityHub" -}}
{{-   if eq $w.identityHub.topology "shared" -}}
{{-     printf "%s:%s" $w.identityHub.shared.didBase $p.bpn -}}
{{-   else -}}
{{-     $host := index $w.identityHub.perParticipant.hosts $pid -}}
{{-     if not $host -}}{{- fail (printf "umbrella.wallet: no perParticipant host for participant %s" $pid) -}}{{- end -}}
{{-     printf "did:web:%s:%s" $host $p.bpn -}}
{{-   end -}}
{{- else -}}
{{-   fail (printf "umbrella.wallet: unsupported mode %q" $w.mode) -}}
{{- end -}}
{{- end -}}

{{/* ---------------- IH endpoints (mode=identityHub only) ------------------- */}}
{{- define "umbrella.wallet.ihBaseUrlFor" -}}
{{- $ctx := .ctx -}}
{{- $pid := .pid -}}
{{- $w := $ctx.Values.wallet -}}
{{- if ne $w.mode "identityHub" -}}{{- fail "umbrella.wallet: ihBaseUrlFor requires wallet.mode=identityHub" -}}{{- end -}}
{{- if eq $w.identityHub.topology "shared" -}}
{{-   $w.identityHub.shared.baseUrl -}}
{{- else -}}
{{-   $host := index $w.identityHub.perParticipant.hosts $pid -}}
{{-   if not $host -}}{{- fail (printf "umbrella.wallet: no perParticipant host for participant %s" $pid) -}}{{- end -}}
{{-   printf "http://%s" $host -}}
{{- end -}}
{{- end -}}

{{/* ---- per-participant IH in-cluster reach (service base / pod label / internal APIs) ----
     `serviceBase` = the Helm dependency alias of the participant's IdentityHub.
     The upstream chart renders Service `<release>-<base>` and pod label
     `app.kubernetes.io/name=<base>`. Ports are chart-invariant, so we reuse the
     `shared.ports` map for both topologies. */}}
{{- define "umbrella.wallet.ihServiceBaseFor" -}}
{{- $ctx := .ctx -}}
{{- $pid := .pid -}}
{{- $w := $ctx.Values.wallet -}}
{{- if eq $w.identityHub.topology "shared" -}}
{{-   $w.identityHub.shared.internalIdentityHubService -}}
{{- else -}}
{{-   $b := index $w.identityHub.perParticipant.serviceBase $pid -}}
{{-   if not $b -}}{{- fail (printf "umbrella.wallet: no perParticipant serviceBase for participant %s" $pid) -}}{{- end -}}
{{-   $b -}}
{{- end -}}
{{- end -}}

{{- define "umbrella.wallet.ihPodLabelFor" -}}
{{- printf "app.kubernetes.io/name=%s" (include "umbrella.wallet.ihServiceBaseFor" .) -}}
{{- end -}}

{{- define "umbrella.wallet.ihIdentityApiInternalFor" -}}
{{- $ctx := .ctx -}}
{{- $base := include "umbrella.wallet.ihServiceBaseFor" . -}}
{{- $ports := $ctx.Values.wallet.identityHub.shared.ports -}}
{{- printf "http://%s-%s:%d/api/identity" $ctx.Release.Name $base (int $ports.ihIdentity) -}}
{{- end -}}

{{- define "umbrella.wallet.ihCredentialsApiInternalFor" -}}
{{- $ctx := .ctx -}}
{{- $base := include "umbrella.wallet.ihServiceBaseFor" . -}}
{{- $ports := $ctx.Values.wallet.identityHub.shared.ports -}}
{{- printf "http://%s-%s:%d/api/credentials" $ctx.Release.Name $base (int $ports.ihCredentials) -}}
{{- end -}}

{{- define "umbrella.wallet.credentialServiceUrl" -}}
{{- $base := include "umbrella.wallet.ihBaseUrlFor" . -}}
{{/* IdentityHub 0.17 uses plain participantContextId path segments; retain
     base64url only for older profiles that have not selected the new contract. */}}
{{- $ctxId := include "umbrella.wallet.participantIdFor" . -}}
{{- $encoding := .ctx.Values.wallet.identityHub.shared.credentialServiceParticipantContextIdEncoding | default "base64url" -}}
{{- if eq $encoding "base64url" -}}
{{-   $ctxId = include "umbrella.wallet.base64ParticipantId" . -}}
{{- else if ne $encoding "plain" -}}
{{-   fail "umbrella.wallet: credentialServiceParticipantContextIdEncoding must be plain or base64url" -}}
{{- end -}}
{{- printf "%s/api/credentials/v1/participants/%s" $base $ctxId -}}
{{- end -}}

{{- define "umbrella.wallet.stsUrl" -}}
{{- $base := include "umbrella.wallet.ihBaseUrlFor" . -}}
{{- printf "%s/api/sts" $base -}}
{{- end -}}

{{- define "umbrella.wallet.identityApiUrlFor" -}}
{{- $ctx := .ctx -}}
{{- $w := $ctx.Values.wallet -}}
{{- if eq $w.identityHub.topology "shared" -}}
{{- printf "http://%s/api/identity" $w.identityHub.shared.host -}}
{{- else -}}
{{- include "umbrella.wallet.ihBaseUrlFor" . -}}{{- "/api/identity" -}}
{{- end -}}
{{- end -}}

{{- define "umbrella.wallet.issuerAdminUrl" -}}
{{- $w := .ctx.Values.wallet -}}
{{- printf "http://%s/api/admin" $w.identityHub.shared.issuerServiceHost -}}
{{- end -}}

{{- define "umbrella.wallet.issuerIdentityUrl" -}}
{{- $w := .ctx.Values.wallet -}}
{{- printf "http://%s/api/identity" $w.identityHub.shared.issuerServiceHost -}}
{{- end -}}

{{- define "umbrella.wallet.issuerDid" -}}
{{- $w := .ctx.Values.wallet -}}
{{- if eq $w.mode "identityHub" -}}
{{- printf "did:web:%s:%s" $w.identityHub.shared.issuerServiceHost $w.operatorBpn -}}
{{- else -}}
{{- printf "%s:%s" $w.stub.didBase $w.operatorBpn -}}
{{- end -}}
{{- end -}}
