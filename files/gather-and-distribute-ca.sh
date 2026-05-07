#!/bin/bash
# Aggregates trust material on the hub, de-duplicates PEM certs, applies a
# ConfigMap + cluster Proxy trustedCA on the hub, then on each ManagedCluster when ACM_ENABLED is true.
# When ACM_ENABLED is false, only hub material is merged and the hub Proxy is updated (no multicluster APIs).
#
# Managed cluster CA sources:
# - acm: ManagedCluster.spec.managedClusterClientConfigs[].caBundle (if INCLUDE_API_CA) plus, when import kubeconfig exists,
#   spoke kube-apiserver-server-ca (if INCLUDE_API_CA), optional ingress router-ca, and optional system trusted-ca-bundle.
# - spokeTrustedCaBundle: kube-apiserver-server-ca (if INCLUDE_API_CA), optional ingress, and optional system trust via import kubeconfig.
# - spokePush: each spoke CronJob merges kube-apiserver-server-ca (or in-cluster API CA) when INCLUDE_API_CA,
#   optional router-ca (ingress), and optional system trust, then pushes to hub ConfigMaps (bundle-<cluster>).
#
# Spoke rollout: ManifestWork (default) or kubeconfig.
# spokePush: spokes receive only token + server + CA in a Secret (no kubeconfig file);
# hub calls use oc --server --token --certificate-authority.
set -euo pipefail
shopt -s nullglob

WORK_DIR="${WORK_DIR:-/tmp/vp-proxy-ca-work}"
mkdir -p "$WORK_DIR"
RAW_DIR="$WORK_DIR/raw"
PEM_DIR="$WORK_DIR/pem"
UNIQ_DIR="$WORK_DIR/uniq"

CONFIG_MAP_NAME="${CONFIG_MAP_NAME:?}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-openshift-config}"
MANAGED_CLUSTER_LABEL_SELECTOR="${MANAGED_CLUSTER_LABEL_SELECTOR:-}"
EXCLUDE_CLUSTERS="${EXCLUDE_CLUSTERS:-}"
INCLUDE_INGRESS_CA="${INCLUDE_INGRESS_CA:-false}"
INCLUDE_API_CA="${INCLUDE_API_CA:-true}"
INCLUDE_SYSTEM_TRUST_STORE="${INCLUDE_SYSTEM_TRUST_STORE:-false}"
ADDITIONAL_CA_FILE="${ADDITIONAL_CA_FILE:-}"
WAIT_FOR_AVAILABLE="${WAIT_FOR_AVAILABLE:-true}"
CLUSTER_READINESS_MAX_ATTEMPTS="${CLUSTER_READINESS_MAX_ATTEMPTS:-150}"
CLUSTER_READINESS_SLEEP_SECONDS="${CLUSTER_READINESS_SLEEP_SECONDS:-30}"

# acm | spokeTrustedCaBundle | spokePush
MANAGED_CLUSTER_CA_SOURCE="${MANAGED_CLUSTER_CA_SOURCE:-acm}"
DISTRIBUTE_TO_SPOKES="${DISTRIBUTE_TO_SPOKES:-manifestwork}"
MANIFEST_WORK_NAME="${MANIFEST_WORK_NAME:?}"
MANIFEST_WORK_PROXY_NAME="${MANIFEST_WORK_PROXY_NAME:?}"
MANIFESTWORK_PATCH_CLUSTER_PROXY="${MANIFESTWORK_PATCH_CLUSTER_PROXY:-true}"
MANIFESTWORK_GRANT_KLUSTERLET_PROXY_RBAC="${MANIFESTWORK_GRANT_KLUSTERLET_PROXY_RBAC:-true}"
KLUSTERLET_WORK_SA_NAMESPACE="${KLUSTERLET_WORK_SA_NAMESPACE:-open-cluster-management-agent}"
KLUSTERLET_WORK_SA_NAME="${KLUSTERLET_WORK_SA_NAME:-klusterlet-work-sa}"
ACM_ENABLED="${ACM_ENABLED:-true}"

SPOKE_PUSH_HUB_NAMESPACE="${SPOKE_PUSH_HUB_NAMESPACE:-vp-proxy-ca-bundles}"
SPOKE_PUSH_SPOKE_NAMESPACE="${SPOKE_PUSH_SPOKE_NAMESPACE:-vp-proxy-ca-sync}"
MANIFEST_WORK_PUSH_AGENT_NAME="${MANIFEST_WORK_PUSH_AGENT_NAME:-}"
SPOKE_PUSH_CRON_SCHEDULE="${SPOKE_PUSH_CRON_SCHEDULE:-*/10 * * * *}"
SPOKE_PUSH_TOKEN_DURATION="${SPOKE_PUSH_TOKEN_DURATION:-720h}"
SPOKE_PUSH_HUB_API_SERVER="${SPOKE_PUSH_HUB_API_SERVER:-}"
PUSH_AGENT_IMAGE="${PUSH_AGENT_IMAGE:?}"

log() { echo "[vp-proxy-ca] $*"; }

hub_only_mode() {
  case "${ACM_ENABLED}" in
    false|False|FALSE|0|no|No|NO) return 0 ;;
    *) return 1 ;;
  esac
}

include_system_trust_store_enabled() {
  case "${INCLUDE_SYSTEM_TRUST_STORE:-false}" in
    true|True|TRUE|yes|Yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

include_api_ca_enabled() {
  case "${INCLUDE_API_CA:-true}" in
    true|True|TRUE|yes|Yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

# Default-on: spokes should get the same Proxy trustedCA wiring as the hub unless explicitly disabled.
manifestwork_proxy_patch_enabled() {
  case "${MANIFESTWORK_PATCH_CLUSTER_PROXY:-true}" in
    true|True|TRUE|yes|Yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

grant_klusterlet_proxy_rbac_enabled() {
  case "${MANIFESTWORK_GRANT_KLUSTERLET_PROXY_RBAC:-true}" in
    true|True|TRUE|yes|Yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

VP_SPOKE_PUSH_INCLUDE_DIR="${VP_SPOKE_PUSH_INCLUDE_DIR:-/includes/spoke-push}"
if [[ "$MANAGED_CLUSTER_CA_SOURCE" == "spokePush" ]] && ! hub_only_mode; then
  if [[ ! -f "${VP_SPOKE_PUSH_INCLUDE_DIR}/build-manifestwork.sh" ]]; then
    log "FATAL: spokePush requires include scripts at ${VP_SPOKE_PUSH_INCLUDE_DIR}/build-manifestwork.sh (ConfigMap volume)"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${VP_SPOKE_PUSH_INCLUDE_DIR}/build-manifestwork.sh"
fi
if hub_only_mode; then
  log "ACM disabled (ACM_ENABLED=false): hub-only — merge configured hub CA inputs (API/ingress/system-trust) and apply ${TARGET_NAMESPACE}/${CONFIG_MAP_NAME} + Proxy/cluster (no ManagedCluster / ManifestWork / spoke agents)"
  if [[ "$MANAGED_CLUSTER_CA_SOURCE" == "spokePush" ]]; then
    log "note: managedClusterCaSource spokePush requires ACM; ignoring spoke material in this run"
  fi
fi

is_excluded() {
  local c="$1"
  local x
  for x in $EXCLUDE_CLUSTERS; do
    if [[ "$c" == "$x" ]]; then
      return 0
    fi
  done
  return 1
}

wait_managed_cluster_available() {
  local cluster="$1"
  local attempt=0
  local status=""
  while [[ $attempt -lt "$CLUSTER_READINESS_MAX_ATTEMPTS" ]]; do
    status="$(oc get managedcluster "$cluster" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || true)"
    if [[ "$status" == "True" ]]; then
      return 0
    fi
    attempt=$((attempt + 1))
    log "waiting for ManagedCluster $cluster Available=True (${attempt}/${CLUSTER_READINESS_MAX_ATTEMPTS})"
    sleep "$CLUSTER_READINESS_SLEEP_SECONDS"
  done
  log "timeout: ManagedCluster $cluster never became Available"
  return 1
}

write_spoke_kubeconfig() {
  local cluster="$1"
  local out="/tmp/${cluster}-kubeconfig.yaml"
  rm -f "$out"
  local secret_name=""
  secret_name="$(oc get secrets -n "$cluster" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E 'admin-kubeconfig$' | head -1 || true)"
  if [[ -z "$secret_name" ]]; then
    secret_name="$(oc get secrets -n "$cluster" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -E 'kubeconfig$' | head -1 || true)"
  fi
  if [[ -z "$secret_name" ]]; then
    log "no kubeconfig-like secret in namespace ${cluster}"
    return 1
  fi
  if oc get secret "$secret_name" -n "$cluster" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d >"$out" && [[ -s "$out" ]]; then
    chmod 0600 "$out"
    echo "$out"
    return 0
  fi
  rm -f "$out"
  if oc get secret "$secret_name" -n "$cluster" -o jsonpath='{.data.raw-kubeconfig}' 2>/dev/null | base64 -d >"$out" && [[ -s "$out" ]]; then
    chmod 0600 "$out"
    echo "$out"
    return 0
  fi
  rm -f "$out"
  log "secret ${cluster}/${secret_name} has no kubeconfig or raw-kubeconfig data"
  return 1
}

extract_acm_client_ca_bundles() {
  local cluster="$1"
  local dest="$2"
  : >"$dest"
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '%s' "$line" | base64 -d >>"$dest" 2>/dev/null && printf '\n' >>"$dest" || true
  done < <(oc get managedcluster "$cluster" -o jsonpath='{range .spec.managedClusterClientConfigs[*]}{.caBundle}{"\n"}{end}' 2>/dev/null || true)
  if [[ ! -s "$dest" ]]; then
    log "no usable spec.managedClusterClientConfigs caBundle for ${cluster}"
    return 1
  fi
  log "ACM client caBundle(s) from ${cluster} ($(wc -c <"$dest") bytes)"
  return 0
}

extract_trusted_ca_bundle() {
  local label="$1"
  local dest="$2"
  local kc="${3:-}"
  local args=()
  if [[ -n "$kc" ]]; then
    args=(--kubeconfig "$kc")
  fi
  if oc "${args[@]}" get configmap trusted-ca-bundle -n openshift-config-managed \
    -o jsonpath='{.data.ca-bundle\.crt}' >"$dest" 2>/dev/null && [[ -s "$dest" ]]; then
    log "trusted-ca-bundle from ${label} ($(wc -c <"$dest") bytes)"
    return 0
  fi
  log "failed trusted-ca-bundle from ${label}"
  return 1
}

extract_ingress_ca() {
  local label="$1"
  local dest="$2"
  local kc="${3:-}"
  local args=()
  if [[ -n "$kc" ]]; then
    args=(--kubeconfig "$kc")
  fi
  if oc "${args[@]}" get secret router-ca -n openshift-ingress-operator \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d >"$dest" && [[ -s "$dest" ]]; then
    log "ingress tls.crt from ${label}"
    return 0
  fi
  if oc "${args[@]}" get secret router-ca -n openshift-ingress-operator \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d >"$dest" && [[ -s "$dest" ]]; then
    log "ingress ca.crt from ${label}"
    return 0
  fi
  return 1
}

# Kubernetes/OpenShift API server TLS CAs (distinct from platform trusted-ca-bundle and from ACM client caBundle).
# Order: openshift-config-managed/kube-apiserver-server-ca, openshift-config/kube-root-ca.crt,
# kubeconfig certificate-authority-data (remote/HyperShift-safe), in-cluster SA CA (hub/local).
extract_kube_apiserver_ca() {
  local label="$1"
  local dest="$2"
  local kc="${3:-}"
  local args=()
  if [[ -n "$kc" ]]; then
    args=(--kubeconfig "$kc")
  fi
  if oc "${args[@]}" get configmap kube-apiserver-server-ca -n openshift-config-managed \
    -o jsonpath='{.data.ca-bundle\.crt}' >"$dest" 2>/dev/null && [[ -s "$dest" ]]; then
    log "kube-apiserver-server-ca from ${label} ($(wc -c <"$dest") bytes)"
    return 0
  fi
  if oc "${args[@]}" get configmap kube-root-ca.crt -n openshift-config \
    -o jsonpath='{.data.ca\.crt}' >"$dest" 2>/dev/null && [[ -s "$dest" ]]; then
    log "kube-root-ca.crt from ${label} ($(wc -c <"$dest") bytes)"
    return 0
  fi
  if [[ -n "$kc" ]]; then
    local kc_ca_b64=""
    kc_ca_b64="$(oc config view --kubeconfig "$kc" --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)"
    if [[ -n "$kc_ca_b64" ]] && printf '%s' "$kc_ca_b64" | base64 -d >"$dest" 2>/dev/null && [[ -s "$dest" ]]; then
      log "API CA from kubeconfig cluster.certificate-authority-data (${label})"
      return 0
    fi
  fi
  if [[ -z "$kc" ]] && [[ -r /var/run/secrets/kubernetes.io/serviceaccount/ca.crt ]]; then
    cp /var/run/secrets/kubernetes.io/serviceaccount/ca.crt "$dest"
    chmod 0644 "$dest" 2>/dev/null || true
    log "API CA from in-cluster service account (${label})"
    return 0
  fi
  log "no kube-apiserver / root API CA from ${label}"
  return 1
}

gather_pushed_bundle_from_hub() {
  local cluster="$1"
  local dest="$2"
  if oc get configmap "bundle-${cluster}" -n "$SPOKE_PUSH_HUB_NAMESPACE" \
    -o jsonpath='{.data.ca-bundle\.crt}' >"$dest" 2>/dev/null && [[ -s "$dest" ]]; then
    log "pushed bundle from hub ns ${SPOKE_PUSH_HUB_NAMESPACE}/bundle-${cluster} ($(wc -c <"$dest") bytes)"
    return 0
  fi
  log "no bundle ConfigMap yet for ${cluster} in ${SPOKE_PUSH_HUB_NAMESPACE}"
  return 1
}

split_pem_file_to_dir() {
  local file="$1"
  local outdir="$2"
  mkdir -p "$outdir"
  local idx=0
  local dest=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
      idx=$((idx + 1))
      dest="${outdir}/part-$(printf '%05d' "$idx").pem"
      : >"$dest"
    fi
    if [[ -n "${dest:-}" ]]; then
      printf '%s\n' "$line" >>"$dest"
    fi
    if [[ "$line" == "-----END CERTIFICATE-----" ]]; then
      dest=""
    fi
  done <"$file"
}

fingerprint_cert_file() {
  local f="$1"
  openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | sed 's/^SHA256 Fingerprint=//' | tr -d ':'
}

dedupe_pem_collection() {
  local src_dir="$1"
  local final_out="$2"
  mkdir -p "$UNIQ_DIR"
  rm -f "$UNIQ_DIR"/*.pem 2>/dev/null || true
  declare -A FP_SEEN
  local f fp
  : >"$final_out"
  for f in "$src_dir"/*.pem; do
    [[ -e "$f" ]] || continue
    fp="$(fingerprint_cert_file "$f" || true)"
    if [[ -z "$fp" ]]; then
      continue
    fi
    if [[ -n "${FP_SEEN[$fp]:-}" ]]; then
      continue
    fi
    FP_SEEN[$fp]=1
    cat "$f" >>"$final_out"
    printf '\n' >>"$final_out"
  done
}

apply_ca_configmap() {
  local label="$1"
  local bundle="$2"
  local kc="${3:-}"
  local args=()
  if [[ -n "$kc" ]]; then
    args=(--kubeconfig "$kc")
  fi
  oc "${args[@]}" create configmap "$CONFIG_MAP_NAME" -n "$TARGET_NAMESPACE" \
    --from-file=ca-bundle.crt="$bundle" \
    --dry-run=client -o yaml | oc "${args[@]}" apply --server-side --force-conflicts \
    --field-manager=vp-manage-proxy-cluster-ca -f -
  log "ConfigMap ${TARGET_NAMESPACE}/${CONFIG_MAP_NAME} applied on ${label}"
}

patch_proxy_trusted_ca() {
  local label="$1"
  local kc="${2:-}"
  local args=()
  if [[ -n "$kc" ]]; then
    args=(--kubeconfig "$kc")
  fi
  oc "${args[@]}" patch proxy cluster --type=merge \
    -p "{\"spec\":{\"trustedCA\":{\"name\":\"${CONFIG_MAP_NAME}\"}}}" || {
    log "warning: proxy patch failed on ${label}"
    return 0
  }
  log "Proxy trustedCA set on ${label}"
}

# One ManifestWork per cluster so workload.manifests apply in list order: optional klusterlet RBAC,
# then ConfigMap, then Proxy (ConfigMap must exist before Proxy references it). Two separate
# ManifestWorks can reconcile out of order and leave spec.trustedCA unset or rejected on the spoke.
apply_manifestwork_spoke_rollout() {
  local cluster="$1"
  local bundle="$2"
  local bundle_block
  bundle_block="$(sed 's/^/            /' "$bundle")"
  local tmp="$WORK_DIR/mw-${cluster}.yaml"
  local rbac_block=""
  local log_suffix=""

  # Drop legacy split Proxy ManifestWork from older chart revisions (same Proxy field, unordered vs bundle).
  oc delete manifestwork "${MANIFEST_WORK_PROXY_NAME}" -n "${cluster}" --ignore-not-found

  if manifestwork_proxy_patch_enabled; then
    if grant_klusterlet_proxy_rbac_enabled; then
      rbac_block="$(cat <<EOF
      - apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRole
        metadata:
          name: vp-proxy-ca-klusterlet-proxy-patch
        rules:
          - apiGroups: ["config.openshift.io"]
            resources: ["proxies"]
            resourceNames: ["cluster"]
            verbs: ["get", "patch", "update"]
      - apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRoleBinding
        metadata:
          name: vp-proxy-ca-klusterlet-proxy-patch
        roleRef:
          apiGroup: rbac.authorization.k8s.io
          kind: ClusterRole
          name: vp-proxy-ca-klusterlet-proxy-patch
        subjects:
          - kind: ServiceAccount
            name: ${KLUSTERLET_WORK_SA_NAME}
            namespace: ${KLUSTERLET_WORK_SA_NAMESPACE}
EOF
)"
      log_suffix="klusterlet Proxy RBAC, "
    fi
    # ServerSideApply for cluster Proxy: avoids ApplyConflict / ignored trustedCA when other actors
    # (e.g. network/cluster operators) own other Proxy fields on the spoke.
    cat >"$tmp" <<EOF
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: ${MANIFEST_WORK_NAME}
  namespace: ${cluster}
spec:
  manifestConfigs:
    - resourceIdentifier:
        group: config.openshift.io
        resource: proxies
        name: cluster
      updateStrategy:
        type: ServerSideApply
        serverSideApply:
          force: true
  workload:
    manifests:
${rbac_block}
      - apiVersion: v1
        kind: ConfigMap
        metadata:
          name: ${CONFIG_MAP_NAME}
          namespace: ${TARGET_NAMESPACE}
        data:
          ca-bundle.crt: |
${bundle_block}
      - apiVersion: config.openshift.io/v1
        kind: Proxy
        metadata:
          name: cluster
        spec:
          trustedCA:
            name: ${CONFIG_MAP_NAME}
EOF
    log "ManifestWork ${cluster}/${MANIFEST_WORK_NAME} apply (${log_suffix}ConfigMap then Proxy trustedCA)"
  else
    cat >"$tmp" <<EOF
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: ${MANIFEST_WORK_NAME}
  namespace: ${cluster}
spec:
  workload:
    manifests:
      - apiVersion: v1
        kind: ConfigMap
        metadata:
          name: ${CONFIG_MAP_NAME}
          namespace: ${TARGET_NAMESPACE}
        data:
          ca-bundle.crt: |
${bundle_block}
EOF
    log "ManifestWork ${cluster}/${MANIFEST_WORK_NAME} apply (ConfigMap only)"
  fi
  # Server-side apply: client-side apply would set last-applied-configuration to the full
  # ManifestWork YAML and exceed metadata.annotations size limits (~256KiB) for large bundles.
  oc apply --server-side --force-conflicts --field-manager=vp-manage-proxy-cluster-ca -f "$tmp"
}

rm -rf "$RAW_DIR" "$PEM_DIR"
mkdir -p "$RAW_DIR" "$PEM_DIR"

# --- Hub ---
if include_api_ca_enabled; then
  log "extract hub API CA bundle"
  extract_kube_apiserver_ca "hub" "$RAW_DIR/hub-api.crt" "" || true
fi
if include_system_trust_store_enabled; then
  extract_trusted_ca_bundle "hub" "$RAW_DIR/hub-trusted.crt" "" || true
fi
if [[ "$INCLUDE_INGRESS_CA" == "true" ]]; then
  extract_ingress_ca "hub" "$RAW_DIR/hub-ingress.crt" "" || true
  if [[ ! -s "$RAW_DIR/hub-ingress.crt" ]]; then
    log "warning: hub ingress CA not merged (expected Secret openshift-ingress-operator/router-ca tls.crt or ca.crt); check RBAC get on that Secret and Secret presence"
  fi
fi

selector_args=()
if [[ -n "$MANAGED_CLUSTER_LABEL_SELECTOR" ]]; then
  selector_args=(--selector="$MANAGED_CLUSTER_LABEL_SELECTOR")
fi

CLUSTERS=()
if ! hub_only_mode; then
  while IFS= read -r cname; do
    [[ -n "$cname" ]] && CLUSTERS+=("$cname")
  done < <(oc get managedclusters "${selector_args[@]}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
fi

# --- spokePush: deploy/update push agents before reading bundles from hub ---
if [[ "$MANAGED_CLUSTER_CA_SOURCE" == "spokePush" ]] && ! hub_only_mode; then
  for cluster in "${CLUSTERS[@]}"; do
    [[ -n "$cluster" ]] || continue
    if is_excluded "$cluster"; then
      continue
    fi
    if [[ "$WAIT_FOR_AVAILABLE" == "true" ]]; then
      wait_managed_cluster_available "$cluster" || {
        log "skip push agent ${cluster} (not available)"
        continue
      }
    fi
    provision_spoke_push_manifestwork "$cluster" || log "skip push agent ${cluster} (provision failed)"
  done
fi

# --- Managed clusters (gather) ---
if ! hub_only_mode; then
  for cluster in "${CLUSTERS[@]}"; do
    [[ -n "$cluster" ]] || continue
    if is_excluded "$cluster"; then
      log "skip excluded cluster ${cluster}"
      continue
    fi
    if [[ "$WAIT_FOR_AVAILABLE" == "true" ]]; then
      wait_managed_cluster_available "$cluster" || {
        log "skip ${cluster} (not available)"
        continue
      }
    fi

    if [[ "$MANAGED_CLUSTER_CA_SOURCE" == "spokePush" ]]; then
      gather_pushed_bundle_from_hub "$cluster" "$RAW_DIR/${cluster}-pushed.crt" || true
    elif [[ "$MANAGED_CLUSTER_CA_SOURCE" == "acm" ]]; then
      if include_api_ca_enabled; then
        extract_acm_client_ca_bundles "$cluster" "$RAW_DIR/${cluster}-acm-client.crt" || true
      fi
      kc_path=""
      if kc_path="$(write_spoke_kubeconfig "$cluster")"; then
        if include_api_ca_enabled; then
          extract_kube_apiserver_ca "$cluster" "$RAW_DIR/${cluster}-api.crt" "$kc_path" || true
        fi
        if include_system_trust_store_enabled; then
          extract_trusted_ca_bundle "$cluster" "$RAW_DIR/${cluster}-trusted.crt" "$kc_path" || true
        fi
        if [[ "$INCLUDE_INGRESS_CA" == "true" ]]; then
          extract_ingress_ca "$cluster" "$RAW_DIR/${cluster}-ingress.crt" "$kc_path" || true
        fi
      else
        if [[ "$INCLUDE_INGRESS_CA" == "true" ]]; then
          log "note: ${cluster} spoke ingress and extra API CAs need import kubeconfig; using ACM client caBundle only"
        fi
      fi
    else
      kc_path=""
      if kc_path="$(write_spoke_kubeconfig "$cluster")"; then
        if include_api_ca_enabled; then
          extract_kube_apiserver_ca "$cluster" "$RAW_DIR/${cluster}-api.crt" "$kc_path" || true
        fi
        if include_system_trust_store_enabled; then
          extract_trusted_ca_bundle "$cluster" "$RAW_DIR/${cluster}-trusted.crt" "$kc_path" || true
        fi
        if [[ "$INCLUDE_INGRESS_CA" == "true" ]]; then
          extract_ingress_ca "$cluster" "$RAW_DIR/${cluster}-ingress.crt" "$kc_path" || true
        fi
      else
        log "skip ${cluster} (no kubeconfig for spokeTrustedCaBundle mode)"
      fi
    fi
  done
fi

n=0
for rf in "$RAW_DIR"/*.crt; do
  [[ -e "$rf" ]] || continue
  [[ -s "$rf" ]] || continue
  n=$((n + 1))
  split_pem_file_to_dir "$rf" "$PEM_DIR/batch-${n}"
done

if [[ -n "$ADDITIONAL_CA_FILE" && -f "$ADDITIONAL_CA_FILE" && -s "$ADDITIONAL_CA_FILE" ]]; then
  split_pem_file_to_dir "$ADDITIONAL_CA_FILE" "$PEM_DIR/additional"
fi

FLAT="$WORK_DIR/all-split"
mkdir -p "$FLAT"
i=0
while IFS= read -r -d '' pemf; do
  i=$((i + 1))
  cp "$pemf" "$FLAT/cert-$(printf '%06d' "$i").pem"
done < <(find "$PEM_DIR" -type f -name '*.pem' -print0 2>/dev/null || true)

BUNDLE_OUT="$WORK_DIR/ca-bundle-deduped.crt"
dedupe_pem_collection "$FLAT" "$BUNDLE_OUT"

if [[ ! -s "$BUNDLE_OUT" ]]; then
  log "no PEM material after merge/dedupe; exiting error"
  exit 1
fi

log "deduped bundle size $(wc -c <"$BUNDLE_OUT") bytes"

apply_ca_configmap "hub" "$BUNDLE_OUT" ""
patch_proxy_trusted_ca "hub" ""

if ! hub_only_mode; then
  for cluster in "${CLUSTERS[@]}"; do
    [[ -n "$cluster" ]] || continue
    if is_excluded "$cluster"; then
      continue
    fi
    if [[ "$DISTRIBUTE_TO_SPOKES" == "manifestwork" ]]; then
      # Hub is already updated above; ACM uses ManagedCluster "local-cluster" for the hub.
      # ManifestWork in local-cluster would make work-agent apply the same openshift-config
      # ConfigMap and Proxy, causing SSA conflicts with this job's apply_ca_configmap/patch_proxy.
      if [[ "$cluster" == "local-cluster" ]]; then
        log "skip ManifestWork for local-cluster (hub ConfigMap and Proxy already applied in-cluster)"
        continue
      fi
      apply_manifestwork_spoke_rollout "$cluster" "$BUNDLE_OUT"
    else
      kc_path=""
      if ! kc_path="$(write_spoke_kubeconfig "$cluster")"; then
        log "skip ${cluster} (no kubeconfig for distribution)"
        continue
      fi
      apply_ca_configmap "$cluster" "$BUNDLE_OUT" "$kc_path"
      patch_proxy_trusted_ca "$cluster" "$kc_path"
    fi
  done
fi

log "done"
