{{- define "mural.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "mural.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 40 | trimSuffix "-" -}}
{{- else if contains (include "mural.name" .) .Release.Name -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "mural.name" .) | trunc 40 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mural.labels" -}}
app.kubernetes.io/name: {{ include "mural.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
{{- end -}}

{{- define "mural.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mural.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "mural.secretName" -}}
{{- default (printf "%s-database" (include "mural.fullname" .)) .Values.postgres.existingSecret -}}
{{- end -}}

{{- define "mural.databaseEnv" -}}
- name: PGHOST
  valueFrom:
    configMapKeyRef:
      name: {{ include "mural.fullname" . }}-config
      key: PGHOST
- name: PGPORT
  valueFrom:
    configMapKeyRef:
      name: {{ include "mural.fullname" . }}-config
      key: PGPORT
- name: PGUSER
  valueFrom:
    configMapKeyRef:
      name: {{ include "mural.fullname" . }}-config
      key: POSTGRES_USER
- name: PGDATABASE
  valueFrom:
    configMapKeyRef:
      name: {{ include "mural.fullname" . }}-config
      key: POSTGRES_DB
- name: PGPASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "mural.secretName" . }}
      key: password
{{- end -}}
