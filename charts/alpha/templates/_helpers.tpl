{{/*
Labels of the resources this chart renders itself. Call with (dict "root" $ "name" "<component>").
*/}}
{{- define "alpha.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{- define "alpha.labels" -}}
{{ include "alpha.selectorLabels" . }}
app.kubernetes.io/part-of: {{ .root.Chart.Name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" }}
{{- end }}

{{/*
Restricted pod and container security settings shared by the chart's own workloads.
*/}}
{{- define "alpha.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}
