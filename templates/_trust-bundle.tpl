{{/*
Primary Bundle namespaceSelector: targetNamespace (openshift-config) unless trustManager.bundle.namespaceSelector is set.
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
Opt-in Bundle metadata.name (ConfigMap name in matched namespaces). Defaults to <primary-bundle-name>-opt-in.
*/}}
{{- define "vpProxyCa.labeledTrustBundleName" -}}
{{- if .Values.trustManager.labeledBundle.name -}}
{{- .Values.trustManager.labeledBundle.name -}}
{{- else -}}
{{- printf "%s-opt-in" (include "vpProxyCa.trustBundleName" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
