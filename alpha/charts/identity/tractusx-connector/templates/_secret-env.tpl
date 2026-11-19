{{/*
This program and the accompanying materials are made available under the
terms of the Apache License, Version 2.0 which is available at
https://www.apache.org/licenses/LICENSE-2.0.

SPDX-License-Identifier: Apache-2.0
*/}}

{{/*
Read a sensitive environment variable only from an existing Kubernetes Secret.
Fail closed when the Secret name or key is not configured.
*/}}
{{- define "txdc.secretEnvValue" -}}
{{- if not .secretRef -}}
{{- fail (printf "%sSecretRef is required" .path) -}}
{{- end -}}
{{- if not .secretRef.name -}}
{{- fail (printf "%sSecretRef.name is required" .path) -}}
{{- end -}}
{{- if not .secretRef.key -}}
{{- fail (printf "%sSecretRef.key is required" .path) -}}
{{- end -}}
valueFrom:
  secretKeyRef:
    name: {{ .secretRef.name | quote }}
    key: {{ .secretRef.key | quote }}
{{- end -}}
