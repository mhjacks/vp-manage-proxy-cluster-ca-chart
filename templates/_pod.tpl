{{/*
Shared container definition for CronJob and sync Job.
*/}}
{{- define "vpProxyCa.gatherContainer" }}
{{- $hasAdditional := gt (len .Values.additionalCaBundles) 0 }}
{{- $spokePush := eq .Values.managedClusterCaSource "spokePush" }}
- name: gather-ca
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  command:
    - /bin/bash
    - /scripts/gather-and-distribute-ca.sh
  env:
    - name: HOME
      value: /tmp
    - name: CONFIG_MAP_NAME
      value: {{ .Values.configMapName | quote }}
    - name: TARGET_NAMESPACE
      value: {{ .Values.targetNamespace | quote }}
    - name: MANAGED_CLUSTER_LABEL_SELECTOR
      value: {{ .Values.managedClusterLabelSelector | quote }}
    - name: EXCLUDE_CLUSTERS
      value: {{ .Values.excludeManagedClusters | quote }}
    - name: MANAGED_CLUSTER_CA_SOURCE
      value: {{ .Values.managedClusterCaSource | quote }}
    - name: DISTRIBUTE_TO_SPOKES
      value: {{ .Values.distributeToSpokes | quote }}
    - name: MANIFEST_WORK_NAME
      value: {{ include "vpProxyCa.manifestWorkName" . | quote }}
    - name: MANIFEST_WORK_PROXY_NAME
      value: {{ include "vpProxyCa.manifestWorkProxyName" . | quote }}
    - name: MANIFESTWORK_PATCH_CLUSTER_PROXY
      value: {{ .Values.manifestWork.patchClusterProxy | toString | quote }}
    - name: SPOKE_PUSH_HUB_NAMESPACE
      value: {{ .Values.spokePush.hubNamespace | quote }}
    - name: SPOKE_PUSH_SPOKE_NAMESPACE
      value: {{ .Values.spokePush.spokeNamespace | quote }}
    - name: MANIFEST_WORK_PUSH_AGENT_NAME
      value: {{ include "vpProxyCa.manifestWorkPushAgentName" . | quote }}
    - name: SPOKE_PUSH_CRON_SCHEDULE
      value: {{ .Values.spokePush.schedule | quote }}
    - name: SPOKE_PUSH_TOKEN_DURATION
      value: {{ .Values.spokePush.tokenDuration | quote }}
    - name: SPOKE_PUSH_HUB_API_SERVER
      value: {{ .Values.spokePush.hubApiServer | quote }}
    - name: PUSH_AGENT_IMAGE
      value: {{ printf "%s:%s" .Values.image.repository .Values.image.tag | quote }}
    - name: INCLUDE_INGRESS_CA
      value: {{ .Values.includeIngressCA | quote }}
    - name: WAIT_FOR_AVAILABLE
      value: {{ .Values.waitForManagedClusterAvailable | quote }}
    - name: CLUSTER_READINESS_MAX_ATTEMPTS
      value: {{ .Values.clusterReadinessMaxAttempts | toString | quote }}
    - name: CLUSTER_READINESS_SLEEP_SECONDS
      value: {{ .Values.clusterReadinessSleepSeconds | toString | quote }}
    {{- if $hasAdditional }}
    - name: ADDITIONAL_CA_FILE
      value: /extra/ca.pem
    {{- end }}
    {{- if $spokePush }}
    - name: VP_SPOKE_PUSH_INCLUDE_DIR
      value: /includes/spoke-push
    {{- end }}
  volumeMounts:
    - name: script
      mountPath: /scripts/gather-and-distribute-ca.sh
      subPath: gather-and-distribute-ca.sh
      readOnly: true
    {{- if $hasAdditional }}
    - name: additional-ca
      mountPath: /extra
      readOnly: true
    {{- end }}
    {{- if $spokePush }}
    - name: spoke-push-includes
      mountPath: /includes/spoke-push
      readOnly: true
    {{- end }}
  resources:
    {{- toYaml .Values.resources | nindent 4 }}
  securityContext:
    {{- toYaml .Values.securityContext | nindent 4 }}
{{- end }}

{{- define "vpProxyCa.gatherVolumes" }}
{{- $hasAdditional := gt (len .Values.additionalCaBundles) 0 }}
{{- $spokePush := eq .Values.managedClusterCaSource "spokePush" }}
- name: script
  configMap:
    name: {{ include "vpProxyCa.fullname" . }}-script
    defaultMode: 0444
{{- if $hasAdditional }}
- name: additional-ca
  secret:
    secretName: {{ include "vpProxyCa.fullname" . }}-additional-ca
{{- end }}
{{- if $spokePush }}
- name: spoke-push-includes
  configMap:
    name: {{ include "vpProxyCa.fullname" . }}-spoke-push-includes
    defaultMode: 0555
{{- end }}
{{- end }}
