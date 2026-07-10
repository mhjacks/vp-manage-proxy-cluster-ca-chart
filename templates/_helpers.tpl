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
Hub vs spoke detection for VP GitOps (global.localClusterDomain vs global.hubClusterDomain).
Override with hubCluster: true|false when auto-detection is unavailable.
*/}}
{{- define "vpProxyCa.isHubCluster" -}}
{{- if eq (.Values.hubCluster | toString) "true" -}}
true
{{- else if eq (.Values.hubCluster | toString) "false" -}}
false
{{- else if eq ((.Values.clusterGroup | default dict).isHubCluster | toString) "true" -}}
true
{{- else if eq ((.Values.clusterGroup | default dict).isHubCluster | toString) "false" -}}
false
{{- else if and .Values.global .Values.global.localClusterDomain .Values.global.hubClusterDomain -}}
{{- eq .Values.global.localClusterDomain .Values.global.hubClusterDomain | toString -}}
{{- else -}}
true
{{- end -}}
{{- end }}

{{- define "vpProxyCa.trustSourceConfigMapName" -}}
{{- .Values.trustManager.sourceConfigMapName | default (printf "%s-sources" (include "vpProxyCa.fullname" .)) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "vpProxyCa.trustBundleName" -}}
{{- .Values.trustManager.bundleName | default .Values.configMapName -}}
{{- end }}

{{/*
Bundle spec.target.namespaceSelector for trust-bundle.yaml. When trustManager.bundle.namespaceSelector
is omitted, default to matchLabels.kubernetes.io/metadata.name = targetNamespace. When set, use as-is.
*/}}
{{- define "vpProxyCa.trustBundleNamespaceSelector" -}}
{{- $bundleCfg := .Values.trustManager.bundle | default dict -}}
{{- if hasKey $bundleCfg "namespaceSelector" -}}
{{- $bundleCfg.namespaceSelector | toYaml -}}
{{- else -}}
matchLabels:
  kubernetes.io/metadata.name: {{ .Values.targetNamespace | quote }}
{{- end -}}
{{- end -}}

{{- define "vpProxyCa.trustBundleNamespaceSelectorJson" -}}
{{- $bundleCfg := .Values.trustManager.bundle | default dict -}}
{{- if hasKey $bundleCfg "namespaceSelector" -}}
{{- $bundleCfg.namespaceSelector | toJson -}}
{{- else -}}
{{- dict "matchLabels" (dict "kubernetes.io/metadata.name" .Values.targetNamespace) | toJson -}}
{{- end -}}
{{- end -}}

{{/*
Namespace for ESO export CronJob / PushSecret.
*/}}
{{- define "vpProxyCa.esoExportNamespace" -}}
{{- .Values.eso.export.namespace | default "vp-proxy-ca-sync" -}}
{{- end }}

{{/*
ServiceAccount for ESO export CronJob.
*/}}
{{- define "vpProxyCa.esoExportServiceAccountName" -}}
{{- .Values.eso.export.serviceAccountName | default "vp-proxy-ca-exporter" -}}
{{- end }}

{{/*
Vault property for PushSecret (cluster identity in pushsecrets/cluster-ca).
*/}}
{{- define "vpProxyCa.esoVaultProperty" -}}
{{- if .Values.eso.export.vaultProperty -}}
{{- .Values.eso.export.vaultProperty -}}
{{- else if and .Values.global .Values.global.clusterDomain -}}
{{- .Values.global.clusterDomain -}}
{{- else -}}
{{- .Release.Name -}}
{{- end -}}
{{- end }}

{{/*
Shared Vault remoteKey for spoke PushSecret / hub ExternalSecret dataFrom.extract.
*/}}
{{- define "vpProxyCa.esoVaultRemoteKey" -}}
{{- .Values.eso.vault.remoteKey | default "pushsecrets/cluster-ca" -}}
{{- end }}

{{/*
ESO ClusterSecretStore name (eso.secretStore, root secretStore, global.secretStore.name, or vault-backend).
Matches config-demo / clustergroup convention: secretStore.name at chart root.
*/}}
{{- define "vpProxyCa.esoSecretStoreName" -}}
{{- if .Values.eso.secretStore.name -}}
{{- .Values.eso.secretStore.name -}}
{{- else if and .Values.secretStore .Values.secretStore.name -}}
{{- .Values.secretStore.name -}}
{{- else if and .Values.global .Values.global.secretStore .Values.global.secretStore.name -}}
{{- .Values.global.secretStore.name -}}
{{- else -}}
vault-backend
{{- end -}}
{{- end }}

{{/*
ESO ClusterSecretStore kind.
*/}}
{{- define "vpProxyCa.esoSecretStoreKind" -}}
{{- if .Values.eso.secretStore.kind -}}
{{- .Values.eso.secretStore.kind -}}
{{- else if and .Values.secretStore .Values.secretStore.kind -}}
{{- .Values.secretStore.kind -}}
{{- else -}}
ClusterSecretStore
{{- end -}}
{{- end }}

{{/*
Argo CD sync-wave for ESO resources (defer until openshift-external-secrets creates vault-backend).
*/}}
{{- define "vpProxyCa.esoArgoSyncWaveAnnotations" -}}
{{- if .Values.eso.argoCDSyncWave }}
argocd.argoproj.io/sync-wave: {{ .Values.eso.argoCDSyncWave | quote }}
{{- end -}}
{{- end }}
