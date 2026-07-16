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

{{/*
Differential Bundle metadata.name (ConfigMap name). Defaults to <primary-bundle-name>-differential.
*/}}
{{- define "vpProxyCa.differentialTrustBundleName" -}}
{{- $diff := .Values.trustManager.differentialBundle | default dict -}}
{{- if $diff.name -}}
{{- $diff.name -}}
{{- else -}}
{{- printf "%s-differential" (include "vpProxyCa.trustBundleName" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
by-label differential Bundle metadata.name. Defaults to <differential-bundle-name>-by-label.
*/}}
{{- define "vpProxyCa.differentialByLabelTrustBundleName" -}}
{{- $diff := .Values.trustManager.differentialBundle | default dict -}}
{{- $byLabel := $diff.byLabelBundle | default dict -}}
{{- if $byLabel.name -}}
{{- $byLabel.name -}}
{{- else -}}
{{- printf "%s-by-label" (include "vpProxyCa.differentialTrustBundleName" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Differential by-namespace-name Bundle namespaceSelector (explicit names; default [targetNamespace]).
*/}}
{{- define "vpProxyCa.differentialTrustBundleNamespaceSelector" -}}
{{- $diff := .Values.trustManager.differentialBundle | default dict -}}
{{- $nsCfg := $diff.byNamespaceNameBundle | default dict -}}
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

{{/*
Validate differential Bundle ConfigMap key has no '.' (avoids awkward YAML/jq path parsing).
*/}}
{{- define "vpProxyCa.differentialTrustBundleTargetKey" -}}
{{- $diff := .Values.trustManager.differentialBundle | default dict -}}
{{- $key := $diff.targetKey | default "cabundle" -}}
{{- if contains "." $key -}}
{{- fail (printf "trustManager.differentialBundle.targetKey %q must not contain '.'" $key) -}}
{{- end -}}
{{- $key -}}
{{- end -}}
