
# vp-manage-proxy-cluster-ca

![Version: 0.2.1](https://img.shields.io/badge/Version-0.2.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square)

OpenShift chart for cluster-wide Proxy trusted CA bundles. Each cluster exports CAs via ESO PushSecret to Vault; ExternalSecret and trust-manager Bundle merge labeled Secrets into openshift-config. Hub CronJob writes hub-export material and patches Proxy/cluster. No ACM or ManifestWork required.

**At a glance:** Deploy this chart on **every cluster** (hub and spokes) via GitOps. Each cluster runs **ESO PushSecret** export to Vault (**`pushsecrets/cluster-ca`**, property = cluster name), **ExternalSecret** import into **`trustManager.trustNamespace`**, and a **trust-manager `Bundle`** that merges labeled **Secrets** into the **Proxy** **`ConfigMap`** in **`openshift-config`**. The **hub** CronJob writes a **`hub-export`** labeled **Secret** from local API/ingress CAs and patches **`Proxy/cluster`**. **No ACM, ManifestWork, or Policy** resources are required.

## Overview

### trust-manager Bundle (OpenShift cert-manager operator)

When **`trustManager.enabled`** is **true** (default), this chart renders:

| Resource | Purpose |
|----------|---------|
| **`TrustManager`** (`trustManager.operator.enabled`, default **true**) | Installs trust-manager operand (**`metadata.name: cluster`**) |
| **`Bundle`** | Merges labeled **Secrets** in **`trustManager.trustNamespace`** into target **ConfigMaps** |

Prerequisites on each cluster:

1. **cert-manager Operator** Subscription with **`UNSUPPORTED_ADDON_FEATURES=TrustManager=true`** (pattern **`values-*.yaml`** / clustergroup — not rendered by this chart).
2. **`trustManager.trustNamespace`** (default **`cert-manager`**) must match **`TrustManager.spec.trustManagerConfig.trustNamespace`**.

**Bundle target namespaces:**

| Bundle | Values | ConfigMap in target namespaces |
|--------|--------|--------------------------------|
| **by-namespace-name** (default) | **`trustManager.byNamespaceNameBundle`** | **`configMapName`** in namespaces listed in **`byNamespaceNameBundle.namespaces`** (defaults to **`[targetNamespace]`**, **`openshift-config`**) |
| **by-label** (optional) | **`trustManager.byLabelBundle.enabled: true`** | **`<configMapName>-by-label`** (or **`byLabelBundle.name`**) in namespaces matching **`byLabelBundle.namespaceSelector`** |
| **differential by-namespace-name** | **`trustManager.differentialBundle`** + **`byNamespaceNameBundle`** | **`<configMapName>-differential`** (or **`differentialBundle.name`**) — private/export CAs only, key **`cabundle`** (no dots) |
| **differential by-label** | **`trustManager.differentialBundle.byLabelBundle`** | **`<configMapName>-differential-by-label`** in namespaces matching **`cluster-ca.vp.io/differential-ca-target: "true"`** |

Use **by-label** for namespaces you create yourself in the pattern GitOps (label them with **`cluster-ca.vp.io/trust-bundle-target: "true"`**). Use **by-namespace-name** for OpenShift system namespaces such as **`openshift-config`** that you cannot label — list them explicitly under **`byNamespaceNameBundle.namespaces`**. This chart does not manage **Namespace** objects.

Example — Proxy **ConfigMap** in **`openshift-config`** plus by-label app namespaces:

```yaml
trustManager:
  byNamespaceNameBundle:
    namespaces:
      - openshift-config
  byLabelBundle:
    enabled: true
    namespaceSelector:
      matchLabels:
        cluster-ca.vp.io/trust-bundle-target: "true"
```

Label workload namespaces with **`cluster-ca.vp.io/trust-bundle-target: "true"`**. They receive **`ConfigMap/<configMapName>-by-label`** with the same **`ca-bundle.crt`** PEM as **`openshift-config`**.

### Differential CA Bundle (no system trust store)

When **`trustManager.differentialBundle.enabled`** is **true**, the chart renders additional **Bundle**(s) that merge the same export / hub-export **Secrets** (and optionally **`additionalCaBundles`**) **without** **`useDefaultCAs`**. The result is only the differential CA material outside the platform trust store — suitable for apps that need private cluster CAs without replacing or duplicating the full system CA package.

| Property | Value |
|----------|-------|
| **Proxy / system trust** | Not used — **`Proxy/cluster.trustedCA`** still points at the primary **`configMapName`** bundle only |
| **ConfigMap data key** | **`cabundle`** by default (**`differentialBundle.targetKey`**); must not contain **`.`** |
| **by-namespace-name** | Explicit names under **`differentialBundle.byNamespaceNameBundle.namespaces`** (defaults to **`[targetNamespace]`**) |
| **by-label** | Label **`cluster-ca.vp.io/differential-ca-target: "true"`** (distinct from the full trust-bundle label) |

Example:

```yaml
trustManager:
  differentialBundle:
    enabled: true
    byNamespaceNameBundle:
      namespaces:
        - my-app
    byLabelBundle:
      enabled: true
      namespaceSelector:
        matchLabels:
          cluster-ca.vp.io/differential-ca-target: "true"
```

Mount **`ConfigMap.data.cabundle`** (not **`ca-bundle.crt`**) in workloads that need only the differential PEMs.

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
| Export **CronJob** | Normalizes API/ingress CAs into a local **Secret** |
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
        key: pushsecrets/cluster-ca
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

When **`trustManager.enabled`** (default), the merged **Proxy** **ConfigMap** is:

**`useDefaultCAs`** (platform trust store) + cluster export/hub-export **Secrets** + **`additionalCaBundles`** (**`inLine`**).

| Source | Where merged | Purpose |
|--------|--------------|---------|
| **`trustManager.bundle.useDefaultCAs: true`** (default) | trust-manager **Bundle** | System/public CAs at Bundle merge time |
| Export / hub-export **Secrets** | **Bundle** | Per-cluster API/ingress CAs |
| **`additionalCaBundles`** | **Bundle** **`inLine`** | Your extra PEMs, additive to the above |

The optional **differential** **Bundle** (**`trustManager.differentialBundle`**) merges export / hub-export (and **`additionalCaBundles`** when **`includeAdditionalCaBundles`** is true) **without** **`useDefaultCAs`**, into a separate **ConfigMap** key (**`cabundle`**). It is never referenced by **`Proxy/cluster.trustedCA`**.

When **`trustManager.enabled`** is **false**, the hub job merges **`additionalCaBundles`** with hub CAs before writing **`configMapName`** (no **Bundle**).

### Optional TLS trust verification (`trustTest`)

When **`trustTest.enabled`** is **true** and **`trustTest.namespaces`** lists one or more namespaces, the chart renders a **CronJob** in each namespace that:

1. Mounts the merged CA bundle **`ConfigMap`** (default: **`configMapName`**, the same **`ConfigMap`** written by **by-namespace-name** / **Proxy** — list the namespace under **`trustManager.byNamespaceNameBundle.namespaces`**). Set **`trustTest.caBundle.configMapName`** to the by-label Bundle name only when using labeled distribution.
2. Waits until **`ca-bundle.crt`** is non-empty.
3. Runs **`curl --cacert`** against discovered or configured **API** (`https://api.<cluster>.<base>:6443/readyz`, no **`apps.`** segment) and **ingress** endpoints on the cluster **`apps.<cluster>.<base>`** domain for the local cluster, hub, clusters listed as keys in the ESO import **Secret** (**`pushsecrets/cluster-ca`** properties), and ACM **ManagedClusters** (when present). The default ingress check is the **OpenShift console** (`console-openshift-console.<apps-domain>`); on the local cluster the **`console`** **Route** in **`openshift-console`** is used when discoverable.

Target namespaces must receive **`configMapName`** (via **`byNamespaceNameBundle.namespaces`**) or set an explicit **`caBundle.configMapName`**. Example:

```yaml
trustManager:
  byNamespaceNameBundle:
    enabled: true
    namespaces:
      - openshift-config
      - openshift-adp
trustTest:
  enabled: true
  namespaces:
    - openshift-adp
  ingress:
    console:
      enabled: true
    additional:
      - name: config-demo
        hostTemplate: "config-demo-config-demo.%s"
        path: "/index.html"
```

Per-namespace extra checks: add **`additionalIngress`** on a namespace entry. Fixed URLs (not tied to a cluster domain) use **`url`** instead of **`hostTemplate`**. Explicit targets via **`trustTest.targets`** also support **`additionalIngress`** per target.

Set **`trustTest.requireRemoteReachable: true`** to fail when remote clusters are unreachable (default: unreachable endpoints log a warning; TLS verification failures always fail the job).

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
| `trustManager.differentialBundle.*` | Optional **Bundle**(s) with private/export CAs only (**no** **`useDefaultCAs`**), key **`cabundle`**. |
| `eso.export.*` | Export namespace, **CronJob** schedule, **PushSecret** local **Secret**, Vault property. |
| `eso.externalSecret.*` | Vault import into trust namespace on every cluster. |
| `eso.hubExport.secretName` | Hub-only **Secret** written by hub **CronJob** (`hub-export` label). |
| `includeApiCA` / `includeIngressCA` | CA inputs for export **CronJob** and hub gather. |
| `additionalCaBundles` | Extra PEMs as **Bundle** **`inLine`** sources. |
| `cronJob` / `syncJob` | Hub periodic **hub-export** + **Proxy** patch; all clusters one-shot **Proxy** patch. |

### Troubleshooting: PushSecret `could not get source secret`

**PushSecret** reads the local **`cluster-ca-export`** **Secret** in **`eso.export.namespace`**. That **Secret** is created by **`export-cron.sh`**, not by **PushSecret** itself.

Sync order (Argo CD waves):

| Wave | Resource |
|------|----------|
| 8 | Export namespace, RBAC, ConfigMap, CronJob |
| 9 | **Export sync Job** (Argo **`hook: Sync`**) — creates **`cluster-ca-export`** |
| 10 | **PushSecret** (needs local **Secret** + **`vault-backend`**) — writes **`pushsecrets/cluster-ca#<clusterDomain>`** |
| 11 | **ExternalSecret** (needs **`vault-backend`** Ready + at least one **PushSecret** write) |
| 12 | **Proxy patch sync Job** (Argo **`hook: Sync`**) — hub **`hub-export`** + **`Proxy/cluster`** |

If **PushSecret** shows **`could not get source secret`**, the export Job has not succeeded yet (see export Job logs). Export Jobs use **`registry.redhat.io/openshift4/ose-cli`** by default — not **`imperative-container`** (root USER + **`hostUsers: false`** causes **`setgroups: Invalid argument`** on restricted-v3).

### Troubleshooting: Argo CD `one or more synchronization tasks completed unsuccessfully`

This message is generic — expand the failed **Sync** operation in the Argo CD UI (**App details → Sync → Operation**) or use the CLI to see which resource failed:

```bash
# Replace APP with your Application name (e.g. vp-manage-proxy-cluster-ca on the cluster)
oc get application APP -n openshift-gitops -o jsonpath='{range .status.operationState.syncResult.resources[*]}{.kind}/{.namespace}/{.name}: {.hookPhase} {.status} {.message}{"\n"}{end}'

oc get jobs -n vp-proxy-ca-sync -l app.kubernetes.io/component=eso-export
oc get jobs -n vp-manage-proxycluster-ca -l app.kubernetes.io/component=sync-proxy-ca
oc logs -n vp-proxy-ca-sync job/$(oc get jobs -n vp-proxy-ca-sync -o name 2>/dev/null | grep export | head -1 | cut -d/ -f2) 2>/dev/null
oc logs -n vp-manage-proxycluster-ca job/$(oc get jobs -n vp-manage-proxycluster-ca -o name 2>/dev/null | grep sync | head -1 | cut -d/ -f2) 2>/dev/null
```

Common causes after export succeeds:

| Symptom | Likely cause |
|---------|----------------|
| **`batch/Job/...-export` hook Failed** | Export hook Job exited non-zero (see Job pod logs). |
| **`batch/Job/...-sync` hook Failed** | Proxy patch Job failed; previously **`spec.template: field is immutable`** when the Job was left from an earlier sync — fixed by **`hook-delete-policy: BeforeHookCreation,HookSucceeded`**. |
| **`ExternalSecret` / `PushSecret` apply error** | Missing CRD, wrong **`apiVersion`**, or **`cert-manager`** namespace absent — install **openshift-external-secrets** / **cert-manager-operator** first. |
| **`Bundle` apply error** | **trust-manager** CRD not installed — set **`trustManager.enabled: false`** until **cert-manager-operator** is Healthy, or order Applications so operator syncs first. |
| Resources **Synced** but app **Degraded** | **`vault-backend` not Ready** — sync may still retry; see below. |

Sync hook Jobs use **`HookSucceeded`** deletion so Argo CD does not patch immutable Job **`spec.template`** when removing hook finalizers.

```bash
oc get secret cluster-ca-export -n vp-proxy-ca-sync
oc get jobs -n vp-proxy-ca-sync -l app.kubernetes.io/component=eso-export
oc logs -n vp-proxy-ca-sync job/$(oc get jobs -n vp-proxy-ca-sync -o name | grep export | head -1 | cut -d/ -f2)
```

**`apiVersion: external-secrets.io/v1alpha1`** for **PushSecret** is expected (upstream ESO API). **ExternalSecret** uses **`v1`**.

### Troubleshooting: Argo CD OutOfSync on ExternalSecret / PushSecret

This chart sets ESO **1.0**-compatible CRD defaults in Git so desired and live match:

| Resource | Field | Value |
|----------|-------|-------|
| ExternalSecret `dataFrom.extract` | `conversionStrategy` | `Default` |
| ExternalSecret `dataFrom.extract` | `decodingStrategy` | `None` |
| ExternalSecret `dataFrom.extract` | `metadataPolicy` | `None` |
| PushSecret `data[]` | `conversionStrategy` | `None` |

Do **not** set `nullBytePolicy` in the chart — it is newer than ESO 1.0. If a newer operator
defaults it on the live object (`Ignore`), add only this Application ignore (with
`RespectIgnoreDifferences=true`):

```yaml
ignoreDifferences:
  - group: external-secrets.io
    kind: ExternalSecret
    jqPathExpressions:
      - .spec.dataFrom[].extract.nullBytePolicy
```

### Troubleshooting: ExternalSecret `Secret does not exist`

```text
error processing spec.dataFrom[0].extract, err: Secret does not exist
```

Two common causes:

1. **PushSecret has not written yet** — **ExternalSecret** runs at sync **wave 11**, after **PushSecret** (wave **10**). On first sync, confirm **PushSecret** is **Synced** and check Vault:

```bash
oc get pushsecret cluster-ca-export -n vp-proxy-ca-sync
oc describe pushsecret cluster-ca-export -n vp-proxy-ca-sync
# Hub Vault (adjust namespace/pod): property name = global.clusterDomain
oc exec -n vault vault-0 -- vault kv get secret/pushsecrets/cluster-ca
```

2. **Wrong Vault path in ExternalSecret** — **`dataFrom.extract.key`** must match **PushSecret** **`remoteKey`** (**`pushsecrets/cluster-ca`**, relative to the **`vault-backend`** mount **`secret`**). Do **not** use **`secret/data/pushsecrets/cluster-ca`** unless your **ClusterSecretStore** is configured differently.

After **PushSecret** succeeds, force **ExternalSecret** reconciliation:

```bash
oc annotate externalsecret cluster-ca-pushsecrets-import -n cert-manager \
  force-sync=$(date +%s) --overwrite
```

### Troubleshooting: `ClusterSecretStore vault-backend is not ready`

**ExternalSecret** and **PushSecret** stay **Degraded** until the platform **ClusterSecretStore** is **Ready**. This chart does not create **vault-backend**; the **openshift-external-secrets** Application does.

1. Confirm the store exists and inspect its status:

```bash
oc get clustersecretstore vault-backend
oc describe clustersecretstore vault-backend
```

2. Ensure **openshift-external-secrets** is **Synced/Healthy** before this chart (**PushSecret** wave **10**, **ExternalSecret** wave **11**).

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

### v0.2.1

- Set ESO 1.0-compatible ExternalSecret extract and PushSecret `conversionStrategy` defaults in
  Git so Argo CD stays Synced without broad ignoreDifferences. Document ignoring only
  `nullBytePolicy` when a newer ESO defaults it on the live object.

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
| eso.argoCDSyncWave | int | `11` | Default Argo CD sync-wave for ExternalSecret when externalSecret.argoCDSyncWave is unset (after PushSecret). |
| eso.export.argoCDSyncWave | int | `8` | Argo CD sync-wave for export namespace/RBAC/CronJob (before export sync Job). |
| eso.export.enabled | bool | `true` | When true, render export namespace, CronJob, sync Job, and PushSecret on this cluster. |
| eso.export.image | object | `{"pullPolicy":"IfNotPresent","repository":"registry.redhat.io/openshift4/ose-cli","tag":"latest"}` | Image for export Jobs (ose-cli avoids setgroups errors from root-based imperative-container). |
| eso.export.key | string | `"ca-bundle.crt"` |  |
| eso.export.namespace | string | `"vp-proxy-ca-sync"` |  |
| eso.export.schedule | string | `"*/10 * * * *"` |  |
| eso.export.secretName | string | `"cluster-ca-export"` |  |
| eso.export.serviceAccountName | string | `"vp-proxy-ca-exporter"` |  |
| eso.export.syncJob.argoCDSyncWave | int | `9` |  |
| eso.export.syncJob.enabled | bool | `true` | One-shot Job (Argo Sync hook) that creates cluster-ca-export before PushSecret reconciles. |
| eso.export.vaultProperty | string | `""` | Vault property name (defaults to global.clusterDomain). |
| eso.externalSecret.argoCDSyncWave | int | `11` | Argo CD sync-wave (after PushSecret writes this cluster's property to Vault). |
| eso.externalSecret.enabled | bool | `true` | ExternalSecret in trustManager.trustNamespace importing all spoke CAs from Vault. |
| eso.externalSecret.name | string | `"cluster-ca-pushsecrets-import"` |  |
| eso.externalSecret.refreshInterval | string | `"1m30s"` |  |
| eso.externalSecret.targetSecretName | string | `"cluster-ca-pushsecrets-import"` |  |
| eso.externalSecret.vaultKey | string | `""` | Vault KV path for dataFrom.extract. Empty: use eso.vault.remoteKey (pushsecrets/cluster-ca). Do not use secret/data/ prefix when ClusterSecretStore path is already "secret" (KV v2). |
| eso.hubExport.secretName | string | `"cluster-ca-hub"` | Hub-only Secret in trustNamespace written by the gather CronJob (labels.hubExport). |
| eso.pushSecret.argoCDSyncWave | int | `10` | Argo CD sync-wave (after export sync Job creates the local Secret; before ExternalSecret). |
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
| image.tag | string | `"v1"` |  |
| includeApiCA | bool | `true` | Include API CA PEMs in hub-export and spoke export (default true). |
| includeIngressCA | bool | `true` | Include default ingress router-ca PEMs when API access allows. |
| nameOverride | string | `""` |  |
| namespace | string | `"vp-manage-proxy-cluster-ca"` |  |
| podHostUsers | bool | `false` |  |
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
| syncJob.argoCDSyncWave | int | `12` |  |
| syncJob.enabled | bool | `true` |  |
| syncJob.image | object | `{"pullPolicy":"IfNotPresent","repository":"registry.redhat.io/openshift4/ose-cli","tag":"latest"}` | ose-cli avoids setgroups errors from root-based imperative-container on restricted SCC. |
| targetNamespace | string | `"openshift-config"` |  |
| trustManager.bundle.argoCDSyncWave | int | `7` |  |
| trustManager.bundle.sources | list | `[{"secret":{"includeAllKeys":true,"selector":{"matchLabels":{"cluster-ca.vp.io/component":"export"}}}},{"secret":{"key":"ca-bundle.crt","selector":{"matchLabels":{"cluster-ca.vp.io/component":"hub-export"}}}}]` | trust-manager Bundle spec.sources. Spoke PushSecrets label hub Secrets with labels.export; hub gather job labels hub-export Secret with labels.hubExport. |
| trustManager.bundle.useDefaultCAs | bool | `true` | Prepend useDefaultCAs to Bundle sources (platform CA package). Merged at trust-manager reconcile time. |
| trustManager.bundleName | string | `""` | Bundle metadata.name and target ConfigMap name in targetNamespace (defaults to configMapName). |
| trustManager.byLabelBundle | object | `{"argoCDSyncWave":7,"enabled":true,"name":"","namespaceSelector":{"matchLabels":{"cluster-ca.vp.io/trust-bundle-target":"true"}},"targetKey":""}` | by-label Bundle: same sources/target key as by-namespace-name, namespaceSelector matchLabels. Use for workload namespaces you create and label in the pattern GitOps. |
| trustManager.byNamespaceNameBundle | object | `{"argoCDSyncWave":7,"enabled":true,"namespaces":[]}` | by-namespace-name Bundle: injects configMapName into explicit OpenShift system namespaces. Use for openshift-config and other platform namespaces you cannot label in GitOps. |
| trustManager.byNamespaceNameBundle.namespaces | list | `[]` | Namespace names (defaults to [targetNamespace] when empty). |
| trustManager.differentialBundle | object | `{"argoCDSyncWave":7,"byLabelBundle":{"argoCDSyncWave":7,"enabled":true,"name":"","namespaceSelector":{"matchLabels":{"cluster-ca.vp.io/differential-ca-target":"true"}},"targetKey":""},"byNamespaceNameBundle":{"argoCDSyncWave":7,"enabled":true,"namespaces":[]},"enabled":false,"includeAdditionalCaBundles":true,"name":"","sources":[],"targetKey":"cabundle"}` | Differential CA Bundle: export/hub-export (+ additionalCaBundles) only — no useDefaultCAs / platform trust store. Not wired to Proxy/cluster.trustedCA. ConfigMap key has no dots (YAML-safe). |
| trustManager.differentialBundle.byLabelBundle | object | `{"argoCDSyncWave":7,"enabled":true,"name":"","namespaceSelector":{"matchLabels":{"cluster-ca.vp.io/differential-ca-target":"true"}},"targetKey":""}` | by-label differential Bundle (namespaceSelector). Distinct label from the full trust bundle. |
| trustManager.differentialBundle.byNamespaceNameBundle | object | `{"argoCDSyncWave":7,"enabled":true,"namespaces":[]}` | by-namespace-name differential Bundle (explicit namespace names). |
| trustManager.differentialBundle.byNamespaceNameBundle.namespaces | list | `[]` | Namespace names (defaults to [targetNamespace] when empty). |
| trustManager.differentialBundle.includeAdditionalCaBundles | bool | `true` | When true, append additionalCaBundles as inLine sources. |
| trustManager.differentialBundle.name | string | `""` | Bundle/ConfigMap name (defaults to <trustBundleName>-differential). |
| trustManager.differentialBundle.sources | list | `[]` | Optional override of Bundle sources. Empty: reuse trustManager.bundle.sources (without useDefaultCAs). |
| trustManager.differentialBundle.targetKey | string | `"cabundle"` | ConfigMap data key (must not contain '.'). |
| trustManager.enabled | bool | `true` | When true, render trust.cert-manager.io/v1alpha1 Bundle and write merged PEM to the trust source ConfigMap. |
| trustManager.labels.clusterGroup | string | `"cluster-ca.vp.io/cluster-group"` |  |
| trustManager.labels.component | string | `"cluster-ca.vp.io/component"` |  |
| trustManager.labels.export | string | `"export"` |  |
| trustManager.labels.hubExport | string | `"hub-export"` |  |
| trustManager.labels.managedCluster | string | `"cluster-ca.vp.io/managed-cluster"` |  |
| trustManager.labels.static | string | `"static"` |  |
| trustManager.operator | object | `{"argoCDSyncWave":6,"defaultCAPackage":{"policy":"Enabled"},"enabled":true,"filterExpiredCertificates":"Enabled","name":"cluster"}` | OpenShift TrustManager CR (requires cert-manager Subscription with UNSUPPORTED_ADDON_FEATURES=TrustManager=true). |
| trustManager.sourceConfigMapName | string | `""` |  |
| trustManager.sourceKey | string | `"ca-bundle.crt"` |  |
| trustManager.targetKey | string | `"ca-bundle.crt"` |  |
| trustManager.trustNamespace | string | `"cert-manager"` | Namespace where trust-manager reads Bundle sources (must match TrustManager.spec.trustManagerConfig.trustNamespace). |
| trustTest.activeDeadlineSeconds | int | `900` |  |
| trustTest.argoCDSyncWave | int | `13` |  |
| trustTest.caBundle.configMapName | string | `""` | Empty: configMapName (by-namespace-name / Proxy bundle). Set to the by-label Bundle name to use labeled distribution. |
| trustTest.caBundle.key | string | `"ca-bundle.crt"` |  |
| trustTest.caBundle.mountPath | string | `"/etc/pki/trust"` |  |
| trustTest.caWaitSeconds | int | `300` |  |
| trustTest.discoverExportSecret | bool | `true` | Discover cluster domains from ESO import Secret keys (Vault pushsecrets/cluster-ca properties). |
| trustTest.discoverManagedClusters | bool | `true` |  |
| trustTest.enabled | bool | `false` | When true, render trust-test CronJobs in trustTest.namespaces (requires non-empty list). |
| trustTest.exportSecret.name | string | `""` | Import Secret name (defaults to eso.externalSecret.targetSecretName). |
| trustTest.exportSecret.namespace | string | `""` | Namespace of the import Secret (defaults to trustManager.trustNamespace). |
| trustTest.failedJobsHistoryLimit | int | `3` |  |
| trustTest.image.pullPolicy | string | `"IfNotPresent"` |  |
| trustTest.image.repository | string | `"registry.redhat.io/openshift4/ose-cli"` | ose-cli includes oc and curl; avoids setgroups errors from root-based imperative-container. |
| trustTest.image.tag | string | `"latest"` |  |
| trustTest.includeLocalCluster | bool | `true` |  |
| trustTest.ingress.additional | list | `[]` | Extra ingress checks expanded per cluster apps domain (hostTemplate) or fixed url. - name: config-demo   hostTemplate: "config-demo-config-demo.%s"   path: "/index.html" - name: vault   url: "https://vault.example.com/v1/sys/health" |
| trustTest.ingress.console | object | `{"enabled":true,"hostTemplate":"console-openshift-console.%s","path":"/","routeName":"console","routeNamespace":"openshift-console"}` | Default ingress TLS check uses the OpenShift console on the cluster apps domain. |
| trustTest.ingress.console.hostTemplate | string | `"console-openshift-console.%s"` | %s is the ingress domain (apps.<cluster>.<base>) from Ingress.config or derived from the API URL. |
| trustTest.namespaces | list | `[]` | Namespaces to install the tester. Each must receive configMapName via byNamespaceNameBundle (list the namespace there) or set per-namespace caBundle.configMapName. By-label distribution is optional; set trustTest.caBundle.configMapName to the by-label Bundle name to use it. Each entry may be a string namespace name or an object with name, optional additionalIngress, optional caBundle.configMapName. |
| trustTest.requireRemoteReachable | bool | `false` | When false, unreachable remote endpoints log a warning instead of failing the job. |
| trustTest.resources.limits.cpu | string | `"500m"` |  |
| trustTest.resources.limits.memory | string | `"256Mi"` |  |
| trustTest.resources.requests.cpu | string | `"50m"` |  |
| trustTest.resources.requests.memory | string | `"128Mi"` |  |
| trustTest.schedule | string | `"0 */6 * * *"` |  |
| trustTest.successfulJobsHistoryLimit | int | `3` |  |
| trustTest.suspend | bool | `false` |  |
| trustTest.targets | list | `[]` | Optional explicit targets merged with ACM/local discovery (supports additionalIngress per target). |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
