{{/*
Shared export container and volumes for ESO export CronJob and one-shot export Job.
*/}}
{{- define "vpProxyCa.esoExportContainer" }}
- name: export
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
  imagePullPolicy: {{ .Values.image.pullPolicy }}
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
  securityContext:
    {{- toYaml .Values.securityContext | nindent 4 }}
{{- end }}

{{- define "vpProxyCa.esoExportVolumes" }}
- name: exportsh
  configMap:
    name: {{ include "vpProxyCa.fullname" . }}-export-run
    defaultMode: 0555
{{- end }}

{{/*
OpenShift restricted-v3 requires hostUsers: false on Pod specs.
*/}}
{{- define "vpProxyCa.podHostUsers" -}}
hostUsers: false
{{- end }}
