# vp-manage-proxy-cluster-ca

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square)

Hub-side chart for OpenShift with ACM. Aggregates trusted CA PEMs from the hub and managed clusters (default: spoke push + hub ingress), de-duplicates them, materializes a cluster-wide ConfigMap for Proxy trustedCA, and applies the same bundle to spokes via ManifestWork. ACM Policy + PlacementBinding are enabled by default to enforce Proxy trustedCA on the Placement's clusters; override policy.placementRef to an existing Placement or disable policy.enabled until one exists.

## Overview

Helm chart for the **hub** cluster (OpenShift + ACM). It periodically aggregates PEM material from:

- the hub: `ConfigMap/openshift-config-managed/trusted-ca-bundle` (`ca-bundle.crt`), and optionally the ingress `router-ca` secret;
- each selected **ManagedCluster**:
  - **`managedClusterCaSource: spokePush`** (default): a **ManifestWork** deploys a CronJob on each spoke that reads `trusted-ca-bundle` (and optional ingress CA) and **writes** `ConfigMap/bundle-<cluster>` into **`spokePush.hubNamespace`** on the hub using a short-lived **hub token** plus **API URL** and **CA PEM** in a Secret (**no kubeconfig file**; spokes use `oc --server` / `--token` / `--certificate-authority`). The gather job mints credentials and **reads every** `bundle-*` ConfigMap in that namespace (nothing in your Git repo).
  - **`acm`**: `ManagedCluster.spec.managedClusterClientConfigs[].caBundle` on the hub (API trust only; does not mirror each spoke’s full `trusted-ca-bundle`).
  - **`spokeTrustedCaBundle`**: full spoke `openshift-config-managed/trusted-ca-bundle` via ACM import kubeconfig ([opp-policy-chart](https://github.com/validatedpatterns/opp-policy-chart)-style).

Certificates are **split and de-duplicated** by SHA-256 certificate fingerprint, then written to a single `ConfigMap` (`ca-bundle.crt`) in `openshift-config`. On the hub the job applies the ConfigMap and patches **`Proxy/cluster`**. On spokes (defaults) it applies **`ManifestWork`** objects in each managed cluster namespace so the **work agent** applies the same ConfigMap (and optionally a second ManifestWork for `Proxy` `trustedCA`) — still **no kubeconfig** in the chart or job for rollout. Set `distributeToSpokes: kubeconfig` to push via import secrets instead.

Optional **`additionalCaBundles`** in `values.yaml` are merged before de-duplication (see `values.yaml` for Vault-on-hub vs off-hub notes and a commented PEM example). ACM **Policy** + **PlacementBinding** are **on by default** (`policy.enabled`) to enforce `Proxy` `trustedCA`; ensure `policy.placementRef.name` names an existing **Placement** (default `vp-proxy-ca`) or override it. Set `policy.enabled: false` or align `manifestWork.patchClusterProxy` with your governance if Policy alone should own Proxy.

Defaults (**`spokePush`** + **`manifestwork`** + **`manifestWork.patchClusterProxy: true`**) avoid **kubeconfig files** in Git or in the gather pod for rollout; **`spokeTrustedCaBundle`** or **`distributeToSpokes: kubeconfig`** still read ACM import **kubeconfig Secrets on the hub** at runtime.

## Install

Target the hub API (in-cluster or kubeconfig). Install into a hub namespace that can run batch jobs (defaults to `openshift-config`, same as opp-policy’s extractor).

Tune **`managedClusterLabelSelector`** so only clusters in your pattern (or ClusterSet labels) are included. **`excludeManagedClusters`** is empty by default so every ManagedCluster is included; set space-separated names (e.g. `local-cluster`) only if you must skip rollout for specific clusters.

## Values highlights

| Value | Purpose |
|--------|---------|
| `configMapName` | ConfigMap in `openshift-config` holding `ca-bundle.crt` (default avoids clashing with `cluster-proxy-ca-bundle` if used elsewhere). |
| `managedClusterLabelSelector` | Passed to `oc get managedclusters --selector=…` (empty = all). |
| `excludeManagedClusters` | Space-separated names to skip (default empty = all clusters get bundle + Proxy ManifestWork). |
| `managedClusterCaSource` | `spokePush` (default): per-spoke `trusted-ca-bundle` pushed to hub. Or `acm` (API CA only), `spokeTrustedCaBundle` (import kubeconfig). Set `spokePush.hubApiServer` if spokes cannot use the gather pod’s API URL. |
| `spokePush.*` | Hub namespace, spoke sync namespace, CronJob schedule, token duration, optional hub API override (`hubApiServer`). |
| `distributeToSpokes` | `manifestwork` (default): `ManifestWork` in each cluster namespace. `kubeconfig`: apply/patch via import kubeconfig. |
| `manifestWork.patchClusterProxy` | Second ManifestWork for `Proxy` trustedCA (default true; set false if Policy owns Proxy). |
| `additionalCaBundles` | List of PEM strings appended before de-duplication. |
| `includeIngressCA` | Hub: `router-ca` when true. Spokes: `spokeTrustedCaBundle` (pull) or `spokePush` (push script appends ingress PEMs). |
| `cronJob` / `syncJob` | Scheduled refresh vs one-shot post-install/upgrade Job. |
| `policy` | Default **enabled**: ACM Policy + PlacementBinding for `Proxy` `trustedCA`. Default `placementRef.name` is `vp-proxy-ca` (create that Placement or override). |

## References

- CA extraction approach: [opp-policy-chart](https://github.com/validatedpatterns/opp-policy-chart) (`trusted-ca-bundle`, spoke kubeconfig pattern, `Proxy` trusted CA wiring).
- OpenShift proxy: [Configuring the cluster-wide proxy](https://docs.openshift.com/container-platform/latest/networking/configuring-a-custom-pki.html#nw-proxy-configure-cluster_configuring-a-custom-pki).

## Notable changes

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| additionalCaBundles | list | `[]` |  |
| clusterReadinessMaxAttempts | int | `150` |  |
| clusterReadinessSleepSeconds | int | `30` |  |
| configMapName | string | `"vp-pattern-proxy-ca-bundle"` |  |
| cronJob.concurrencyPolicy | string | `"Forbid"` |  |
| cronJob.enabled | bool | `true` |  |
| cronJob.failedJobsHistoryLimit | int | `3` |  |
| cronJob.schedule | string | `"0 */6 * * *"` |  |
| cronJob.successfulJobsHistoryLimit | int | `1` |  |
| cronJob.suspend | bool | `false` |  |
| distributeToSpokes | string | `"manifestwork"` |  |
| excludeManagedClusters | string | `""` |  |
| fullnameOverride | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"quay.io/validatedpatterns/imperative-container"` |  |
| image.tag | string | `"latest"` |  |
| includeIngressCA | bool | `true` |  |
| managedClusterCaSource | string | `"spokePush"` |  |
| managedClusterLabelSelector | string | `""` |  |
| manifestWork.nameOverride | string | `""` |  |
| manifestWork.patchClusterProxy | bool | `true` |  |
| manifestWork.proxyNameOverride | string | `""` |  |
| nameOverride | string | `""` |  |
| namespace | string | `"openshift-config"` |  |
| podSecurityContext.runAsNonRoot | bool | `true` |  |
| podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| policy.enabled | bool | `true` |  |
| policy.hubNamespace | string | `"open-cluster-management"` |  |
| policy.name | string | `""` |  |
| policy.placementRef.name | string | `"vp-proxy-ca"` |  |
| policy.placementRef.namespace | string | `""` |  |
| resources.limits.cpu | string | `"1"` |  |
| resources.limits.memory | string | `"1Gi"` |  |
| resources.requests.cpu | string | `"200m"` |  |
| resources.requests.memory | string | `"512Mi"` |  |
| securityContext.allowPrivilegeEscalation | bool | `false` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| spokePush.hubApiServer | string | `""` |  |
| spokePush.hubNamespace | string | `"vp-proxy-ca-bundles"` |  |
| spokePush.manifestWorkNameOverride | string | `""` |  |
| spokePush.schedule | string | `"15 */6 * * *"` |  |
| spokePush.spokeNamespace | string | `"vp-proxy-ca-sync"` |  |
| spokePush.tokenDuration | string | `"720h"` |  |
| syncJob.enabled | bool | `true` |  |
| targetNamespace | string | `"openshift-config"` |  |
| waitForManagedClusterAvailable | bool | `true` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
