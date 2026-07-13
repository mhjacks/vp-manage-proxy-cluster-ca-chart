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
Shared Vault remoteKey for PushSecret and ExternalSecret dataFrom.extract (relative to ClusterSecretStore mount).
*/}}
{{- define "vpProxyCa.esoVaultRemoteKey" -}}
{{- .Values.eso.vault.remoteKey | default "pushsecrets/cluster-ca" -}}
{{- end }}

{{/*
Vault KV path for ExternalSecret dataFrom.extract (relative to ClusterSecretStore mount, same as PushSecret remoteKey).
Do not prefix with secret/data/ when the store path is already "secret" (KV v2).
*/}}
{{- define "vpProxyCa.esoVaultExtractKey" -}}
{{- if .Values.eso.externalSecret.vaultKey -}}
{{- .Values.eso.externalSecret.vaultKey -}}
{{- else -}}
{{- include "vpProxyCa.esoVaultRemoteKey" . -}}
{{- end -}}
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
Argo CD sync-wave for ESO export infrastructure (namespace, CronJob, etc.).
*/}}
{{- define "vpProxyCa.esoExportSyncWaveAnnotations" -}}
{{- $wave := .Values.eso.export.argoCDSyncWave | default 8 }}
argocd.argoproj.io/sync-wave: {{ $wave | quote }}
{{- end }}

{{/*
Argo CD sync-wave for ExternalSecret (after vault-backend and export Job).
*/}}
{{- define "vpProxyCa.esoExternalSecretSyncWaveAnnotations" -}}
{{- $wave := .Values.eso.externalSecret.argoCDSyncWave | default .Values.eso.argoCDSyncWave | default 10 }}
argocd.argoproj.io/sync-wave: {{ $wave | quote }}
{{- end }}

{{/*
Argo CD sync-wave for PushSecret (after local export Secret exists).
*/}}
{{- define "vpProxyCa.esoPushSecretSyncWaveAnnotations" -}}
{{- $wave := .Values.eso.pushSecret.argoCDSyncWave | default 11 }}
argocd.argoproj.io/sync-wave: {{ $wave | quote }}
{{- end }}

{{/*
Image for gather/sync Job (ose-cli by default; imperative-container optional via syncJob.image).
*/}}
{{- define "vpProxyCa.syncJobImageRepository" -}}
{{- .Values.syncJob.image.repository | default "registry.redhat.io/openshift4/ose-cli" -}}
{{- end }}

{{- define "vpProxyCa.syncJobImageTag" -}}
{{- .Values.syncJob.image.tag | default "latest" -}}
{{- end }}

{{- define "vpProxyCa.syncJobImagePullPolicy" -}}
{{- .Values.syncJob.image.pullPolicy | default .Values.image.pullPolicy -}}
{{- end }}

{{/*
Argo CD sync-wave for hub/spoke Proxy patch Job (after Bundle / ESO resources).
*/}}
{{- define "vpProxyCa.syncJobSyncWaveAnnotations" -}}
{{- $wave := .Values.syncJob.argoCDSyncWave | default 12 }}
argocd.argoproj.io/sync-wave: {{ $wave | quote }}
{{- end }}

{{/*
Image for trust-test CronJobs. Defaults to ose-cli (includes oc and curl).
*/}}
{{- define "vpProxyCa.trustTestImageRepository" -}}
{{- .Values.trustTest.image.repository | default "registry.redhat.io/openshift4/ose-cli" -}}
{{- end }}

{{- define "vpProxyCa.trustTestImageTag" -}}
{{- .Values.trustTest.image.tag | default "latest" -}}
{{- end }}

{{- define "vpProxyCa.trustTestImagePullPolicy" -}}
{{- .Values.trustTest.image.pullPolicy | default .Values.image.pullPolicy -}}
{{- end }}

{{/*
trustTest.namespaces entry: string name or { name, additionalIngress?, caBundle? }.
*/}}
{{- define "vpProxyCa.trustTestNamespaceName" -}}
{{- if kindIs "string" . -}}
{{- . -}}
{{- else -}}
{{- .name -}}
{{- end -}}
{{- end }}

{{/*
ConfigMap name for the mounted CA bundle in a trustTest namespace.
*/}}
{{- define "vpProxyCa.trustTestCaBundleConfigMapName" -}}
{{- $root := index . 0 -}}
{{- $entry := index . 1 -}}
{{- if and (not (kindIs "string" $entry)) $entry.caBundle $entry.caBundle.configMapName -}}
{{- $entry.caBundle.configMapName -}}
{{- else if $root.Values.trustTest.caBundle.configMapName -}}
{{- $root.Values.trustTest.caBundle.configMapName -}}
{{- else if and $root.Values.trustManager.enabled $root.Values.trustManager.labeledBundle.enabled -}}
{{- include "vpProxyCa.labeledTrustBundleName" $root -}}
{{- else -}}
{{- $root.Values.configMapName -}}
{{- end -}}
{{- end }}

{{/*
Merged global + per-namespace additional ingress checks for trust-test CronJob env JSON.
*/}}
{{- define "vpProxyCa.trustTestAdditionalIngressJson" -}}
{{- $root := index . 0 -}}
{{- $entry := index . 1 -}}
{{- $global := ($root.Values.trustTest.ingress.additional | default list) -}}
{{- $local := list -}}
{{- if and (not (kindIs "string" $entry)) $entry.additionalIngress -}}
{{- $local = $entry.additionalIngress -}}
{{- end -}}
{{- concat $global $local | toJson -}}
{{- end -}}
