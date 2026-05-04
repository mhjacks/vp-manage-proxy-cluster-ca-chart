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

{{/*
Namespace for ACM Policy, PlacementBinding, Placement, and ManagedClusterSetBinding.
When policy.placementRef.namespace is non-empty it overrides policy.hubNamespace so all
policy placement objects stay in one workspace (PlacementBinding has no cross-namespace placementRef).
*/}}
{{- define "vpProxyCa.policyWorkspaceNamespace" -}}
{{- .Values.policy.placementRef.namespace | default .Values.policy.hubNamespace -}}
{{- end }}

{{/*
ACM Policy validating webhook: len(policyNamespace) + len(policy.metadata.name) <= 62.
Default: vpca-<truncated Release.Name> to stay under the limit with long hub namespaces.
Explicit policy.name: must satisfy the same constraint or template fails.
*/}}
{{- define "vpProxyCa.policyResourceName" -}}
{{- $ns := include "vpProxyCa.policyWorkspaceNamespace" . }}
{{- $max := sub 62 (len $ns) | int }}
{{- $prefix := "vpca-" }}
{{- $prefixLen := len $prefix }}
{{- if lt $max (add $prefixLen 1) }}
{{- fail (printf "ACM Policy requires len(namespace)+len(name)<=62; namespace %q leaves only %d chars for the policy name" $ns $max) }}
{{- end }}
{{- $avail := sub $max $prefixLen | int }}
{{- $defaultName := printf "%s%s" $prefix (.Release.Name | trunc $avail | trimSuffix "-") }}
{{- if .Values.policy.name }}
{{- if gt (add (len $ns) (len .Values.policy.name)) 62 }}
{{- fail (printf "policy.name %q in namespace %q exceeds ACM limit (combined length must be <= 62); shorten policy.name or the policy workspace namespace" .Values.policy.name $ns) }}
{{- end }}
{{- .Values.policy.name }}
{{- else }}
{{- $defaultName }}
{{- end }}
{{- end }}
