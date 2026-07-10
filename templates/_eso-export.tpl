{{/*
Image for ESO export Jobs/CronJobs. Defaults to ose-cli (non-root, OpenShift-compatible).
Hub gather/sync Jobs continue to use values.image (imperative-container).
*/}}
{{- define "vpProxyCa.esoExportImageRepository" -}}
{{- .Values.eso.export.image.repository | default "registry.redhat.io/openshift4/ose-cli" -}}
{{- end }}

{{- define "vpProxyCa.esoExportImageTag" -}}
{{- .Values.eso.export.image.tag | default "latest" -}}
{{- end }}

{{- define "vpProxyCa.esoExportImagePullPolicy" -}}
{{- .Values.eso.export.image.pullPolicy | default .Values.image.pullPolicy -}}
{{- end }}

{{/*
Shared export container and volumes for ESO export CronJob and one-shot export Job.
No pod/container securityContext by default — matches clustergroup imperative Jobs; SCC assigns UID.
Do not set hostUsers: false with root-based images (causes setgroups EINVAL under user namespaces).
*/}}
{{- define "vpProxyCa.esoExportContainer" }}
- name: export
  image: {{ printf "%s:%s" (include "vpProxyCa.esoExportImageRepository" .) (include "vpProxyCa.esoExportImageTag" .) | quote }}
  imagePullPolicy: {{ include "vpProxyCa.esoExportImagePullPolicy" . }}
  env:
    - name: CLUSTER_NAME
      value: {{ include "vpProxyCa.esoVaultProperty" . | quote }}
    - name: EXPORT_NAMESPACE
      value: {{ include "vpProxyCa.esoExportNamespace" . | quote }}
    - name: EXPORT_SECRET_NAME
      value: {{ .Values.eso.export.secretName | quote }}
    - name: EXPORT_SECRET_KEY
      value: {{ .Values.eso.export.key | quote }}
    - name: INCLUDE_INGRESS_CA
      value: {{ .Values.includeIngressCA | quote }}
    - name: INCLUDE_API_CA
      value: {{ .Values.includeApiCA | quote }}
    - name: INCLUDE_SYSTEM_TRUST_STORE
      value: {{ .Values.includeSystemTrustStore | quote }}
  command:
    - /bin/bash
    - /scripts/export-cron.sh
  volumeMounts:
    - name: exportsh
      mountPath: /scripts/export-cron.sh
      subPath: export-cron.sh
      readOnly: true
  resources:
    {{- toYaml .Values.resources | nindent 4 }}
{{- end }}

{{- define "vpProxyCa.esoExportVolumes" }}
- name: exportsh
  configMap:
    name: {{ include "vpProxyCa.fullname" . }}-export-run
    defaultMode: 0555
{{- end }}

{{/*
Optional hostUsers: false for restricted-v3 (opt-in only; breaks root-based images).
*/}}
{{- define "vpProxyCa.podHostUsers" -}}
{{- if eq (.Values.podHostUsers | toString) "true" -}}
hostUsers: false
{{- end -}}
{{- end }}
