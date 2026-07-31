{{- define "headwind-mdm.name" -}}
headwind-mdm
{{- end -}}

{{- define "headwind-mdm.labels" -}}
app.kubernetes.io/name: {{ include "headwind-mdm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "headwind-mdm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "headwind-mdm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
