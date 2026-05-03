{{/*
Expand the name of the chart.
*/}}
{{- define "vpProxyCa.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "vpProxyCa.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Service account name
*/}}
{{- define "vpProxyCa.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "vpProxyCa.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Stable ManifestWork object name (<=63 chars) for each managed cluster namespace.
*/}}
{{- define "vpProxyCa.manifestWorkName" -}}
{{- $base := .Values.manifestWork.nameOverride | default (printf "%s-proxy-ca" (include "vpProxyCa.fullname" .)) }}
{{- $base | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "vpProxyCa.manifestWorkProxyName" -}}
{{- $base := .Values.manifestWork.proxyNameOverride | default (printf "%s-proxy-ca-proxy" (include "vpProxyCa.fullname" .)) }}
{{- $base | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "vpProxyCa.manifestWorkPushAgentName" -}}
{{- $base := .Values.spokePush.manifestWorkNameOverride | default (printf "%s-push-agent" (include "vpProxyCa.fullname" .)) }}
{{- $base | trunc 63 | trimSuffix "-" }}
{{- end }}
