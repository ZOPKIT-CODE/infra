{{/* Common naming + labels for the zopkit-backend chart. */}}

{{- define "zb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "zb.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "zb.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* The app short name (wrapper/crm/fa) — drives selectors + service name. */}}
{{- define "zb.app" -}}
{{- required "app is required (set .Values.app)" .Values.app -}}
{{- end -}}

{{- define "zb.labels" -}}
app.kubernetes.io/name: {{ include "zb.app" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: zopkit-suite
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "zb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "zb.app" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Web-only selector — adds component=web so the web Service/Deployment/PDB do NOT
     also match worker pods (which carry component=worker, e.g. the FA SQS consumer). */}}
{{- define "zb.webSelectorLabels" -}}
{{ include "zb.selectorLabels" . }}
app.kubernetes.io/component: web
{{- end -}}

{{- define "zb.serviceAccountName" -}}
{{- default (include "zb.app" .) .Values.serviceAccount.name -}}
{{- end -}}
