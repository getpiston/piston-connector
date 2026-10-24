{{- define "piston-connector.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "piston-connector.selectorLabels" -}}
app.kubernetes.io/name: piston-connector
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "piston-connector.labels" -}}
{{ include "piston-connector.selectorLabels" . }}
app.kubernetes.io/version: {{ include "piston-connector.tag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "piston-connector.tag" -}}
{{- .Values.image.tag | default .Chart.AppVersion }}
{{- end }}

{{/*
The Secret the connector reads its private key from: the customer's own, or
the one this chart renders from `privateKey`. Exactly one of the two is set.
*/}}
{{- define "piston-connector.secretName" -}}
{{- if and .Values.privateKey .Values.existingSecret }}
{{- fail "set privateKey or existingSecret, not both" }}
{{- end }}
{{- if not (or .Values.privateKey .Values.existingSecret) }}
{{- fail "privateKey or existingSecret is required" }}
{{- end }}
{{- .Values.existingSecret | default (include "piston-connector.name" .) }}
{{- end }}
