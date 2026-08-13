{{- define "common.serviceMonitor" -}}
{{- if and (.Values.enabled | default true) (.Values.serviceMonitor.enabled | default false) -}}
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "common.fullname" . }}
  namespace: {{ include "common.namespace" . }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ include "common.name" . }}
  endpoints:
    - port: {{ .Values.serviceMonitor.port | default "http" }}
      path: {{ .Values.serviceMonitor.path | default "/metrics" | quote }}
      interval: {{ .Values.serviceMonitor.interval | default "30s" | quote }}
      scrapeTimeout: {{ .Values.serviceMonitor.scrapeTimeout | default "10s" | quote }}
{{- end -}}
