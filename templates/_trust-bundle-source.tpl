{{/*
Render one trust-manager Bundle spec.sources[] entry.
Each list item must contain exactly one of: secret, configMap, inLine (trust.cert-manager.io/v1alpha1).
Secret/configMap: name and selector are mutually exclusive; key and includeAllKeys are mutually exclusive.
*/}}
{{- define "vpProxyCa.trustBundleSourceItem" }}
{{- $src := . }}
{{- if $src.secret }}
- secret:
{{- if $src.secret.selector }}
    selector:
{{ toYaml $src.secret.selector | indent 6 }}
{{- else if $src.secret.name }}
    name: {{ $src.secret.name | quote }}
{{- else }}
{{- fail "trustManager.bundle.sources[].secret requires name or selector" }}
{{- end }}
{{- if $src.secret.includeAllKeys }}
    includeAllKeys: true
{{- else }}
    key: {{ $src.secret.key | default "ca-bundle.crt" | quote }}
{{- end }}
{{- else if $src.configMap }}
- configMap:
{{- if $src.configMap.selector }}
    selector:
{{ toYaml $src.configMap.selector | indent 6 }}
{{- else if $src.configMap.name }}
    name: {{ $src.configMap.name | quote }}
{{- else }}
{{- fail "trustManager.bundle.sources[].configMap requires name or selector" }}
{{- end }}
{{- if $src.configMap.includeAllKeys }}
    includeAllKeys: true
{{- else }}
    key: {{ $src.configMap.key | default "ca-bundle.crt" | quote }}
{{- end }}
{{- else if $src.inLine }}
- inLine: |
{{ $src.inLine | nindent 4 }}
{{- else }}
{{- fail "trustManager.bundle.sources[] entry requires secret, configMap, or inLine" }}
{{- end }}
{{- end }}

{{/*
All Bundle spec.sources entries: configured sources plus additionalCaBundles as inLine.
*/}}
{{- define "vpProxyCa.trustBundleSources" }}
{{- $root := . }}
{{- $bundle := .Values.trustManager.bundle | default dict }}
{{- $sources := $bundle.sources | default list }}
{{- if eq (len $sources) 0 }}
{{- fail "trustManager.bundle.sources must contain at least one entry (secret selector, configMap, or inLine)" }}
{{- end }}
{{- range $sources }}
{{ include "vpProxyCa.trustBundleSourceItem" . }}
{{- end }}
{{- range $root.Values.additionalCaBundles }}
{{ include "vpProxyCa.trustBundleSourceItem" (dict "inLine" .) }}
{{- end }}
{{- end }}
