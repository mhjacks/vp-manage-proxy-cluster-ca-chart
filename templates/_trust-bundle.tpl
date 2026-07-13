{{/*
by-namespace-name Bundle namespaceSelector: explicit namespace names (default [targetNamespace]),
unless trustManager.bundle.namespaceSelector is set for backward compatibility.
*/}}
{{- define "vpProxyCa.trustBundleNamespaceSelector" -}}
{{- $bundleCfg := .Values.trustManager.bundle | default dict -}}
{{- if hasKey $bundleCfg "namespaceSelector" -}}
{{- $bundleCfg.namespaceSelector | toYaml -}}
{{- else -}}
{{- $nsCfg := .Values.trustManager.byNamespaceNameBundle | default dict -}}
{{- $namespaces := $nsCfg.namespaces -}}
{{- if not $namespaces -}}
{{- $namespaces = list .Values.targetNamespace -}}
{{- end -}}
matchExpressions:
  - key: kubernetes.io/metadata.name
    operator: In
    values:
{{- range $namespaces }}
      - {{ . | quote }}
{{- end }}
{{- end -}}
{{- end -}}

{{- define "vpProxyCa.trustBundleNamespaceSelectorJson" -}}
{{- $bundleCfg := .Values.trustManager.bundle | default dict -}}
{{- if hasKey $bundleCfg "namespaceSelector" -}}
{{- $bundleCfg.namespaceSelector | toJson -}}
{{- else -}}
{{- $nsCfg := .Values.trustManager.byNamespaceNameBundle | default dict -}}
{{- $namespaces := $nsCfg.namespaces -}}
{{- if not $namespaces -}}
{{- $namespaces = list .Values.targetNamespace -}}
{{- end -}}
{{- dict "matchExpressions" (list (dict "key" "kubernetes.io/metadata.name" "operator" "In" "values" $namespaces)) | toJson -}}
{{- end -}}
{{- end -}}

{{/*
by-label Bundle metadata.name (ConfigMap name in matched namespaces). Defaults to <primary-bundle-name>-by-label.
*/}}
{{- define "vpProxyCa.byLabelTrustBundleName" -}}
{{- if .Values.trustManager.byLabelBundle.name -}}
{{- .Values.trustManager.byLabelBundle.name -}}
{{- else -}}
{{- printf "%s-by-label" (include "vpProxyCa.trustBundleName" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
