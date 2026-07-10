{{/*
Shared container definition for CronJob and sync Job.
*/}}
{{- define "vpProxyCa.gatherContainer" }}
{{- $hasAdditional := gt (len .Values.additionalCaBundles) 0 }}
{{- $writeHubExport := eq (include "vpProxyCa.isHubCluster" .) "true" }}
- name: sync-proxy-ca
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command:
    - /bin/bash
    - /scripts/sync-proxy-ca.sh
  env:
    - name: HOME
      value: /tmp
    - name: CONFIG_MAP_NAME
      value: {{ .Values.configMapName | quote }}
    - name: TARGET_NAMESPACE
      value: {{ .Values.targetNamespace | quote }}
    - name: WRITE_HUB_EXPORT
      value: {{ $writeHubExport | toString | quote }}
    - name: INCLUDE_INGRESS_CA
      value: {{ .Values.includeIngressCA | quote }}
    - name: INCLUDE_API_CA
      value: {{ .Values.includeApiCA | quote }}
    - name: INCLUDE_SYSTEM_TRUST_STORE
      value: {{ .Values.includeSystemTrustStore | quote }}
    - name: TRUST_MANAGER_ENABLED
      value: {{ .Values.trustManager.enabled | toString | quote }}
    - name: TRUST_NAMESPACE
      value: {{ .Values.trustManager.trustNamespace | quote }}
    - name: TRUST_BUNDLE_NAME
      value: {{ include "vpProxyCa.trustBundleName" . | quote }}
    - name: TRUST_TARGET_KEY
      value: {{ .Values.trustManager.targetKey | quote }}
    - name: ESO_HUB_EXPORT_SECRET_NAME
      value: {{ .Values.eso.hubExport.secretName | quote }}
    - name: ESO_EXPORT_SECRET_KEY
      value: {{ .Values.eso.export.key | quote }}
    - name: ESO_LABEL_COMPONENT_KEY
      value: {{ .Values.trustManager.labels.component | quote }}
    - name: ESO_LABEL_HUB_EXPORT_VALUE
      value: {{ .Values.trustManager.labels.hubExport | quote }}
    {{- if $hasAdditional }}
    - name: ADDITIONAL_CA_FILE
      value: /extra/ca.pem
    {{- end }}
  volumeMounts:
    - name: script
      mountPath: /scripts/sync-proxy-ca.sh
      subPath: sync-proxy-ca.sh
      readOnly: true
    {{- if $hasAdditional }}
    - name: additional-ca
      mountPath: /extra
      readOnly: true
    {{- end }}
  resources:
    {{- toYaml .Values.resources | nindent 4 }}
  securityContext:
    {{- toYaml .Values.securityContext | nindent 4 }}
{{- end }}

{{- define "vpProxyCa.gatherVolumes" }}
{{- $hasAdditional := gt (len .Values.additionalCaBundles) 0 }}
- name: script
  configMap:
    name: {{ include "vpProxyCa.fullname" . }}-script
    defaultMode: 0444
{{- if $hasAdditional }}
- name: additional-ca
  secret:
    secretName: {{ include "vpProxyCa.fullname" . }}-additional-ca
{{- end }}
{{- end }}
