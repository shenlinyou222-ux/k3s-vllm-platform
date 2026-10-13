{{/* ── 通用标签 ── */}}
{{- define "vllm-stack.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "vllm-stack.namespace" -}}
{{- if .Values.global.namespace }}{{ .Values.global.namespace }}{{ else }}{{ .Release.Namespace }}{{ end -}}
{{- end -}}

{{/* 所有 Deployment 共用的 env（原 10 号文件里的 vllm-observability-env 等价物） */}}
{{- define "vllm-stack.commonEnv" -}}
- name: VLLM_ATTENTION_BACKEND
  value: "FLASH_ATTN"
- name: HF_HUB_OFFLINE
  value: "1"
- name: TRANSFORMERS_OFFLINE
  value: "1"
{{- if .Values.observability.enabled }}
- name: VLLM_LOG_LEVEL
  value: {{ .Values.observability.logLevel | quote }}
- name: OTEL_SERVICE_NAME
  value: {{ .Chart.Name | quote }}
{{- end }}
{{- end -}}

{{/* vLLM 镜像（gen 与 embed 共用） */}}
{{- define "vllm-stack.vllmImage" -}}
{{ .Values.global.image.repository }}:{{ .Values.global.image.tag }}
{{- end -}}
