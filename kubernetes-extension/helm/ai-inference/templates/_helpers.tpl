{{- define "ai-inference.name" -}}
{{- .Chart.Name -}}
{{- end }}

{{- define "ai-inference.labels" -}}
app: {{ include "ai-inference.name" . }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
