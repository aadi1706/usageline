{{- define "usageline.fullname" -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{- define "usageline.labels" -}}
app.kubernetes.io/name: usageline
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "usageline.selectorLabels" -}}
app.kubernetes.io/name: usageline
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "usageline.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}

{{- define "usageline.dbHost" -}}
{{- if .Values.config.dbHost -}}
{{ .Values.config.dbHost }}
{{- else -}}
{{ include "usageline.fullname" . }}-postgres
{{- end -}}
{{- end -}}

{{- define "usageline.secretName" -}}
{{- if .Values.secret.existingSecret -}}
{{ .Values.secret.existingSecret }}
{{- else -}}
{{ include "usageline.fullname" . }}
{{- end -}}
{{- end -}}

{{/* Env shared by the API pods and the migration Job. Order matters: $(VAR) expansion needs earlier vars. */}}
{{- define "usageline.env" -}}
- name: DB_HOST
  valueFrom:
    configMapKeyRef:
      name: {{ include "usageline.fullname" . }}
      key: db-host
- name: DB_PORT
  valueFrom:
    configMapKeyRef:
      name: {{ include "usageline.fullname" . }}
      key: db-port
- name: DB_NAME
  valueFrom:
    configMapKeyRef:
      name: {{ include "usageline.fullname" . }}
      key: db-name
- name: DB_USER
  valueFrom:
    configMapKeyRef:
      name: {{ include "usageline.fullname" . }}
      key: db-user
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "usageline.secretName" . }}
      key: db-password
- name: DATABASE_URL
  value: "postgresql+psycopg2://$(DB_USER):$(DB_PASSWORD)@$(DB_HOST):$(DB_PORT)/$(DB_NAME)"
{{- end -}}
