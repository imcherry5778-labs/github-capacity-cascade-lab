{{- define "auth-sim.name" -}}
auth-sim
{{- end }}

{{- define "auth-sim.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "auth-sim.selectorLabels" -}}
app.kubernetes.io/name: {{ include "auth-sim.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "auth-sim.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "auth-sim.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
