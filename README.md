
# vp-manage-proxy-cluster-ca

![Version: 0.2.0](https://img.shields.io/badge/Version-0.2.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square)

OpenShift chart for cluster-wide Proxy trusted CA bundles. Each cluster exports CAs via ESO PushSecret to Vault; ExternalSecret and trust-manager Bundle merge labeled Secrets into openshift-config. Hub CronJob writes hub-export material and patches Proxy/cluster. No ACM or ManifestWork required.

**At a glance:** Deploy this chart on **every cluster** (hub and spokes) via GitOps. Each cluster runs **ESO PushSecret** export to Vault (**`pushsecrets/cluster-ca`**, property = cluster name), **ExternalSecret** import into **`trustManager.trustNamespace`**, and a **trust-manager `Bundle`** that merges labeled **Secrets** into the **Proxy** **`ConfigMap`** in **`openshift-config`**. The **hub** CronJob writes a **`hub-export`** labeled **Secret** from local API/ingress CAs and patches **`Proxy/cluster`**. **No ACM, ManifestWork, or Policy** resources are required.

## Overview

### trust-manager Bundle (OpenShift cert-manager operator)

When **`trustManager.enabled`** is **true** (default), this chart renders a cluster-scoped **`Bundle`** CR (`trust.cert-manager.io/v1alpha1`). Prerequisites on each cluster:

1. **cert-manager Operator** with **TrustManager** addon enabled.
2. **`trustManager.trustNamespace`** (default **`cert-manager`**) must match **`TrustManager.spec.trustManagerConfig.trustNamespace`**.

Default **`trustManager.bundle.sources`**:

| Source | Selector | Key |
|--------|----------|-----|
| Spoke exports (ESO PushSecret → ExternalSecret) | `cluster-ca.vp.io/component: export` | all keys (`includeAllKeys`) |
| Hub local export (hub CronJob) | `cluster-ca.vp.io/component: hub-export` | `ca-bundle.crt` |

**`additionalCaBundles`** entries are appended as **`inLine`** Bundle sources.

### Vault paths ([rhvp.cluster_utils](https://github.com/validatedpatterns/rhvp.cluster_utils))

| Vault path | Used by this chart |
|------------|-------------------|
| **`secret/pushsecrets/*`** | **Yes** — **PushSecret** writes; **ExternalSecret** reads |

Platform **`openshift-external-secrets`** and **`vault-backend`** **`ClusterSecretStore`** are expected (e.g. multicloud-gitops). Do not store cluster CA PEMs under **`secret/global`**, **`secret/hub`**, or spoke FQDN prefixes.

### ESO PushSecret flow

Each cluster (hub and spokes) renders:

| Resource | Purpose |
|----------|---------|
| Export **CronJob** | Normalizes API/ingress/system-trust CAs into a local **Secret** |
| **PushSecret** | Pushes **`ca-bundle.crt`** to Vault **`pushsecrets/cluster-ca#<cluster>`** |
| **ExternalSecret** | Imports all cluster properties from Vault into **`trustManager.trustNamespace`** |
| **Bundle** | Merges **`export`** + **`hub-export`** labeled **Secrets** into **`configMapName`** |

Hub-only **CronJob** (in **`namespace`**, default **`openshift-config`**) writes the **`hub-export`** **Secret** and patches **`Proxy/cluster`**. Spokes rely on **syncJob** (post-install) for the initial **Proxy** patch; ongoing **ConfigMap** updates come from **trust-manager**.

**PushSecret** example (rendered by Helm on each cluster):

```yaml
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: cluster-ca-export
  namespace: vp-proxy-ca-sync
spec:
  refreshInterval: 1h
  updatePolicy: Replace
  secretStoreRefs:
    - name: vault-backend
      kind: ClusterSecretStore
  selector:
    secret:
      name: cluster-ca-export
  data:
    - match:
        secretKey: ca-bundle.crt
        remoteRef:
          remoteKey: pushsecrets/cluster-ca
          property: ocp-primary   # eso.export.vaultProperty / global.clusterDomain
```

**ExternalSecret** (same on every cluster):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cluster-ca-pushsecrets-import
  namespace: cert-manager
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: cluster-ca-pushsecrets-import
    template:
      metadata:
        labels:
          cluster-ca.vp.io/component: export
  dataFrom:
    - extract:
        key: secret/data/pushsecrets/cluster-ca
```

Set **`hubCluster: true|false`** when auto-detection from **`global.localClusterDomain`** / **`global.hubClusterDomain`** is unavailable.

### GitOps — Argo CD `OutOfSync` and `ignoreDifferences`

**trust-manager** owns live **`ConfigMap`** data in **`openshift-config`**. The hub job patches **`Proxy/cluster`**. Use **`spec.ignoreDifferences`** on the **Application** so Argo CD does not fight runtime reconciliation.

**`ca-bundle.crt` and jq:** Use **`.data["ca-bundle.crt"]`** in **`jqPathExpressions`**, not **`.data.ca-bundle.crt`**.

```yaml
spec:
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: ""
      kind: ConfigMap
      name: vp-pattern-proxy-ca-bundle
      namespace: openshift-config
      jqPathExpressions:
        - .data["ca-bundle.crt"]
    - group: config.openshift.io
      kind: Proxy
      name: cluster
      jqPathExpressions:
        - .status
```

### Injecting extra CA material (`additionalCaBundles`)

When **`trustManager.enabled`** is **true**, each **`additionalCaBundles`** entry is a **Bundle** **`inLine`** source. The hub job does not re-merge those PEMs into **`hub-export`**.

When **`trustManager.enabled`** is **false**, the hub job merges **`additionalCaBundles`** with hub CAs before writing **`configMapName`**.

### Example: init container TLS precheck for workload HTTPS

If your application calls an HTTPS endpoint (for example **HashiCorp Vault**) and must use the **same CA material** as the cluster-wide proxy bundle, mount **`ca-bundle.crt`** into the pod and optionally run an **init container** before the main containers start. Typical sources for that file are:

- this chart's merged bundle: copy or sync **`configMapName`** / **`ca-bundle.crt`** from **`openshift-config`** into your workload namespace, or
- a **namespace** `ConfigMap` whose contents **CNO** populates via **`inject-trusted-cabundle`**, if you merge the cluster trust store that way.

An init container can **wait** until the mounted path is non-empty (injection and **`Proxy`** rollout can lag pod schedule) and **verify TLS** with **`curl --cacert`**. For Vault, **`GET /v1/sys/health`** is enough to prove the TLS handshake; avoid **`curl -f`** because sealed or uninitialized Vault often returns a non-2xx **HTTP** status while TLS still succeeds.

Below is an **illustrative** fragment: replace the **`ConfigMap`** name, mount path, image, and **`VAULT_ADDR`** with your own values; wire the same volume into your application container if it needs the bundle at runtime.

```yaml
spec:
  template:
    spec:
      initContainers:
        - name: tls-precheck
          image: registry.access.redhat.com/ubi9/ubi:latest
          imagePullPolicy: IfNotPresent
          env:
            - name: HTTPS_ENDPOINT
              value: "https://vault.example.com"
            - name: CA_BUNDLE_PATH
              value: "/etc/pki/custom-ca/ca-bundle.crt"
            - name: CA_WAIT_SECONDS
              value: "120"
          command:
            - /bin/bash
            - -ec
            - |
              echo "Waiting up to ${CA_WAIT_SECONDS}s for CA bundle at ${CA_BUNDLE_PATH}"
              for ((i=0; i<CA_WAIT_SECONDS; i++)); do
                if [[ -s "${CA_BUNDLE_PATH}" ]]; then
                  break
                fi
                sleep 1
              done
              if [[ ! -s "${CA_BUNDLE_PATH}" ]]; then
                echo "ERROR: CA bundle missing or empty at ${CA_BUNDLE_PATH}" >&2
                exit 1
              fi
              echo "Verifying TLS to ${HTTPS_ENDPOINT} using ${CA_BUNDLE_PATH}"
              if ! curl -g -sS --cacert "${CA_BUNDLE_PATH}" --connect-timeout 15 --max-time 45 \
                  -o /dev/null "${HTTPS_ENDPOINT}/v1/sys/health"; then
                echo "ERROR: could not complete TLS connection (check CA bundle vs server certificate)" >&2
                exit 1
              fi
              echo "TLS precheck passed."
          volumeMounts:
            - name: custom-ca-bundle
              mountPath: /etc/pki/custom-ca
              readOnly: true
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
      volumes:
        - name: custom-ca-bundle
          projected:
            defaultMode: 420
            sources:
              - configMap:
                  name: my-workload-trusted-ca
                  optional: true
                  items:
                    - key: ca-bundle.crt
                      path: ca-bundle.crt
```

## Install

Deploy via OpenShift GitOps on **each cluster** in the pattern (hub and managed clusters). Set **`eso.export.vaultProperty`** (or **`global.clusterDomain`**) to the cluster identity used as the Vault property name. Set **`hubCluster`** on the hub release so the hub **CronJob** renders.

Example hub **`applications`** entry:

```yaml
applications:
  vp-manage-proxy-cluster-ca:
    name: vp-manage-proxy-cluster-ca
    namespace: openshift-config
```

Example spoke entry (same chart, spoke **`vaultProperty`** / **`global.clusterDomain`**, **`hubCluster: false`**):

```yaml
applications:
  vp-manage-proxy-cluster-ca:
    name: vp-manage-proxy-cluster-ca
    namespace: openshift-config
```

| Namespace | Purpose |
|-----------|---------|
| **`openshift-config`** | Hub **CronJob**/Job, **Proxy** patch (**syncJob** on all clusters) |
| **`eso.export.namespace`** (default **`vp-proxy-ca-sync`**) | Export **CronJob**, local export **Secret**, **PushSecret** |
| **`trustManager.trustNamespace`** (default **`cert-manager`**) | **ExternalSecret**, **Bundle** sources, **`hub-export`** **Secret** |

## Values highlights

| Value | Purpose |
|--------|---------|
| `hubCluster` | **true** on hub (default when domains match); **false** on spokes. Gates hub **CronJob**. |
| `configMapName` | **Proxy** **`trustedCA`** **ConfigMap** name (and **Bundle** name when **`trustManager.enabled`**). |
| `trustManager.*` | **Bundle**, trust namespace, label contract, **`spec.sources`**. |
| `eso.export.*` | Export namespace, **CronJob** schedule, **PushSecret** local **Secret**, Vault property. |
| `eso.externalSecret.*` | Vault import into trust namespace on every cluster. |
| `eso.hubExport.secretName` | Hub-only **Secret** written by hub **CronJob** (`hub-export` label). |
| `includeApiCA` / `includeIngressCA` / `includeSystemTrustStore` | CA inputs for export **CronJob** and hub gather. |
| `additionalCaBundles` | Extra PEMs as **Bundle** **`inLine`** sources. |
| `cronJob` / `syncJob` | Hub periodic **hub-export** + **Proxy** patch; all clusters one-shot **Proxy** patch. |

### Troubleshooting: `ClusterSecretStore vault-backend is not ready`

**ExternalSecret** and **PushSecret** stay **Degraded** until the platform **ClusterSecretStore** is **Ready**. This chart does not create **vault-backend**; the **openshift-external-secrets** Application does.

1. Confirm the store exists and inspect its status:

```bash
oc get clustersecretstore vault-backend
oc describe clustersecretstore vault-backend
```

2. Ensure **openshift-external-secrets** is **Synced/Healthy** before this chart (this chart sets **`eso.argoCDSyncWave: 10`** on **ExternalSecret** / **PushSecret** for that reason).

3. **Hub:** **vault** Application must be running; **ClusterSecretStore** uses **`https://vault-vault.<hubClusterDomain>`** with Kubernetes auth **`hub`** mount / **`hub-role`**.

4. **Spokes:** run **`make load-secrets`** ( **`rhvp.cluster_utils.load_secrets`** ) so Vault Kubernetes auth exists for **`global.clusterDomain`** / **`<clusterDomain>-role`**. The store also needs **`external-secrets/hub-ca`** (hub API CA) for TLS to hub Vault.

5. After fixing the store, ESO may take several minutes to requeue. Force reconciliation:

```bash
oc annotate externalsecret cluster-ca-pushsecrets-import -n cert-manager \
  force-sync=$(date +%s) --overwrite
oc annotate pushsecret cluster-ca-export -n vp-proxy-ca-sync \
  force-sync=$(date +%s) --overwrite
```

If **vault-backend** stays **NotReady**, the root cause is in platform Vault/ESO setup, not this chart's **remoteKey** / **vaultKey** paths.

- CA extraction approach: [opp-policy-chart](https://github.com/validatedpatterns/opp-policy-chart).
- Vault layout: [rhvp.cluster_utils](https://github.com/validatedpatterns/rhvp.cluster_utils).
- OpenShift proxy: [Configuring the cluster-wide proxy](https://docs.openshift.com/container-platform/latest/networking/configuring-a-custom-pki.html#nw-proxy-configure-cluster_configuring-a-custom-pki).

## Notable changes

### v0.2.0 (trust-manager + ESO PushSecret)

- **trust-manager `Bundle`**: merges labeled **Secrets** in **`cert-manager`** into the **Proxy** **ConfigMap** in **`openshift-config`**. Requires **TrustManager** addon on each cluster.
- **ESO PushSecret + ExternalSecret**: each cluster exports CAs to Vault **`secret/pushsecrets/*`** and imports the merged vault object. Platform **`vault-backend`** must exist (multicloud-gitops).
- **No ACM dependency**: no **ManifestWork**, **Policy**, **Placement**, or **ManagedCluster** APIs. Spoke resources are static Helm templates deployed per cluster via GitOps.
- **`additionalCaBundles`**: rendered as **Bundle** **`inLine`** sources when **`trustManager.enabled`**.

### Earlier releases

- **v0.1.3**: Init container TLS precheck documentation.
- Prior **0.1.x** releases included ACM **ManifestWork** spoke rollout; removed in **0.2.0**.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| additionalCaBundles | list | `[]` |  |
| configMapName | string | `"vp-pattern-proxy-ca-bundle"` |  |
| cronJob.concurrencyPolicy | string | `"Forbid"` |  |
| cronJob.enabled | bool | `true` |  |
| cronJob.failedJobsHistoryLimit | int | `3` |  |
| cronJob.schedule | string | `"*/10 * * * *"` |  |
| cronJob.successfulJobsHistoryLimit | int | `1` |  |
| cronJob.suspend | bool | `false` |  |
| eso.argoCDSyncWave | int | `10` | Argo CD sync-wave for ExternalSecret/PushSecret (defer until platform ESO creates vault-backend). |
| eso.export.enabled | bool | `true` | When true, render export namespace, CronJob, and PushSecret on this cluster. |
| eso.export.key | string | `"ca-bundle.crt"` |  |
| eso.export.namespace | string | `"vp-proxy-ca-sync"` |  |
| eso.export.schedule | string | `"*/10 * * * *"` |  |
| eso.export.secretName | string | `"cluster-ca-export"` |  |
| eso.export.serviceAccountName | string | `"vp-proxy-ca-exporter"` |  |
| eso.export.vaultProperty | string | `""` | Vault property name (defaults to global.clusterDomain). |
| eso.externalSecret.enabled | bool | `true` | ExternalSecret in trustManager.trustNamespace importing all spoke CAs from Vault. |
| eso.externalSecret.name | string | `"cluster-ca-pushsecrets-import"` |  |
| eso.externalSecret.refreshInterval | string | `"1h"` |  |
| eso.externalSecret.targetSecretName | string | `"cluster-ca-pushsecrets-import"` |  |
| eso.externalSecret.vaultKey | string | `"secret/data/pushsecrets/cluster-ca"` |  |
| eso.hubExport.secretName | string | `"cluster-ca-hub"` | Hub-only Secret in trustNamespace written by the gather CronJob (labels.hubExport). |
| eso.pushSecret.deletionPolicy | string | `"None"` |  |
| eso.pushSecret.name | string | `"cluster-ca-export"` |  |
| eso.pushSecret.refreshInterval | string | `"1m30s"` |  |
| eso.pushSecret.updatePolicy | string | `"Replace"` |  |
| eso.secretStore.kind | string | `"ClusterSecretStore"` |  |
| eso.secretStore.name | string | `""` | ClusterSecretStore name. Empty: use secretStore.name (clustergroup), global.secretStore.name, else vault-backend. |
| eso.vault.remoteKey | string | `"pushsecrets/cluster-ca"` | PushSecret remoteKey (KV v2 path relative to ClusterSecretStore mount). |
| fullnameOverride | string | `""` |  |
| hubCluster | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"quay.io/validatedpatterns/imperative-container"` |  |
| image.tag | string | `"latest"` |  |
| includeApiCA | bool | `true` | Include API CA PEMs in hub-export and spoke export (default true). |
| includeIngressCA | bool | `true` | Include default ingress router-ca PEMs when API access allows. |
| includeSystemTrustStore | bool | `false` | Include cluster system trust store (trusted-ca-bundle) in export merges. |
| nameOverride | string | `""` |  |
| namespace | string | `"vp-manage-proxycluster-ca"` |  |
| podSecurityContext.runAsGroup | int | `0` |  |
| podSecurityContext.runAsNonRoot | bool | `true` |  |
| podSecurityContext.runAsUser | int | `1000690001` |  |
| podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| resources.limits.cpu | string | `"1"` |  |
| resources.limits.memory | string | `"1Gi"` |  |
| resources.requests.cpu | string | `"200m"` |  |
| resources.requests.memory | string | `"512Mi"` |  |
| secretStore.kind | string | `"ClusterSecretStore"` |  |
| secretStore.name | string | `""` |  |
| securityContext.allowPrivilegeEscalation | bool | `false` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| syncJob.enabled | bool | `true` |  |
| targetNamespace | string | `"openshift-config"` |  |
| trustManager.bundle.sources | list | `[{"secret":{"includeAllKeys":true,"selector":{"matchLabels":{"cluster-ca.vp.io/component":"export"}}}},{"secret":{"key":"ca-bundle.crt","selector":{"matchLabels":{"cluster-ca.vp.io/component":"hub-export"}}}}]` | trust-manager Bundle spec.sources. Spoke PushSecrets label hub Secrets with labels.export; hub gather job labels hub-export Secret with labels.hubExport. |
| trustManager.bundleName | string | `""` | Bundle metadata.name and target ConfigMap name in targetNamespace (defaults to configMapName). |
| trustManager.enabled | bool | `true` | When true, render trust.cert-manager.io/v1alpha1 Bundle and write merged PEM to the trust source ConfigMap. |
| trustManager.labels.clusterGroup | string | `"cluster-ca.vp.io/cluster-group"` |  |
| trustManager.labels.component | string | `"cluster-ca.vp.io/component"` |  |
| trustManager.labels.export | string | `"export"` |  |
| trustManager.labels.hubExport | string | `"hub-export"` |  |
| trustManager.labels.managedCluster | string | `"cluster-ca.vp.io/managed-cluster"` |  |
| trustManager.labels.static | string | `"static"` |  |
| trustManager.sourceConfigMapName | string | `""` |  |
| trustManager.sourceKey | string | `"ca-bundle.crt"` |  |
| trustManager.targetKey | string | `"ca-bundle.crt"` |  |
| trustManager.trustNamespace | string | `"cert-manager"` | Namespace where trust-manager reads Bundle sources (must match TrustManager.spec.trustManagerConfig.trustNamespace). |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
