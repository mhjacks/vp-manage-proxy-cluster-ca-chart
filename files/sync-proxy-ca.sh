#!/bin/bash
# Collect hub-local CA material, write hub-export Secret for trust-manager (hub only),
# and point Proxy/cluster at the merged trust bundle ConfigMap.
set -euo pipefail
shopt -s nullglob

WORK_DIR="${WORK_DIR:-/tmp/vp-proxy-ca-work}"
mkdir -p "$WORK_DIR"
RAW_DIR="$WORK_DIR/raw"
PEM_DIR="$WORK_DIR/pem"
UNIQ_DIR="$WORK_DIR/uniq"

CONFIG_MAP_NAME="${CONFIG_MAP_NAME:?}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-openshift-config}"
INCLUDE_INGRESS_CA="${INCLUDE_INGRESS_CA:-false}"
INCLUDE_API_CA="${INCLUDE_API_CA:-true}"
ADDITIONAL_CA_FILE="${ADDITIONAL_CA_FILE:-}"

WRITE_HUB_EXPORT="${WRITE_HUB_EXPORT:-true}"
TRUST_MANAGER_ENABLED="${TRUST_MANAGER_ENABLED:-true}"
TRUST_NAMESPACE="${TRUST_NAMESPACE:-cert-manager}"
TRUST_BUNDLE_NAME="${TRUST_BUNDLE_NAME:-}"
TRUST_TARGET_KEY="${TRUST_TARGET_KEY:-ca-bundle.crt}"
ESO_HUB_EXPORT_SECRET_NAME="${ESO_HUB_EXPORT_SECRET_NAME:-cluster-ca-hub}"
ESO_EXPORT_SECRET_KEY="${ESO_EXPORT_SECRET_KEY:-ca-bundle.crt}"
ESO_LABEL_COMPONENT_KEY="${ESO_LABEL_COMPONENT_KEY:-cluster-ca.vp.io/component}"
ESO_LABEL_HUB_EXPORT_VALUE="${ESO_LABEL_HUB_EXPORT_VALUE:-hub-export}"

log() { echo "[vp-proxy-ca] $*"; }

trust_manager_enabled() {
  case "${TRUST_MANAGER_ENABLED:-true}" in
    true|True|TRUE|yes|Yes|YES|1) return 0 ;;
    *) return 1 ;;
  esac
}

write_hub_export_enabled() {
  case "${WRITE_HUB_EXPORT:-true}" in
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

extract_ingress_ca() {
  local dest="$1"
  if oc get secret router-ca -n openshift-ingress-operator \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d >"$dest" && [[ -s "$dest" ]]; then
    log "ingress tls.crt"
    return 0
  fi
  if oc get secret router-ca -n openshift-ingress-operator \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d >"$dest" && [[ -s "$dest" ]]; then
    log "ingress ca.crt"
    return 0
  fi
  return 1
}

extract_kube_apiserver_ca() {
  local dest="$1"
  if oc get configmap kube-apiserver-server-ca -n openshift-config-managed \
    -o jsonpath='{.data.ca-bundle\.crt}' >"$dest" 2>/dev/null && [[ -s "$dest" ]]; then
    log "kube-apiserver-server-ca ($(wc -c <"$dest") bytes)"
    return 0
  fi
  if oc get configmap kube-root-ca.crt -n openshift-config \
    -o jsonpath='{.data.ca\.crt}' >"$dest" 2>/dev/null && [[ -s "$dest" ]]; then
    log "kube-root-ca.crt ($(wc -c <"$dest") bytes)"
    return 0
  fi
  if [[ -r /var/run/secrets/kubernetes.io/serviceaccount/ca.crt ]]; then
    cp /var/run/secrets/kubernetes.io/serviceaccount/ca.crt "$dest"
    log "API CA from in-cluster service account"
    return 0
  fi
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
    [[ -z "$fp" ]] && continue
    [[ -n "${FP_SEEN[$fp]:-}" ]] && continue
    FP_SEEN[$fp]=1
    cat "$f" >>"$final_out"
    printf '\n' >>"$final_out"
  done
}

apply_ca_configmap() {
  local bundle="$1"
  oc create configmap "$CONFIG_MAP_NAME" -n "$TARGET_NAMESPACE" \
    --from-file=ca-bundle.crt="$bundle" \
    --dry-run=client -o yaml | oc apply --server-side --force-conflicts \
    --field-manager=vp-manage-proxy-cluster-ca -f -
  log "ConfigMap ${TARGET_NAMESPACE}/${CONFIG_MAP_NAME} applied"
}

apply_hub_export_secret() {
  local bundle="$1"
  if [[ ! -s "$bundle" ]]; then
    log "skip hub export Secret (empty bundle)"
    return 1
  fi
  oc create secret generic "$ESO_HUB_EXPORT_SECRET_NAME" -n "$TRUST_NAMESPACE" \
    --from-file="${ESO_EXPORT_SECRET_KEY}=${bundle}" \
    --dry-run=client -o yaml | oc apply --server-side --force-conflicts \
    --field-manager=vp-manage-proxy-cluster-ca -f -
  oc label secret "$ESO_HUB_EXPORT_SECRET_NAME" -n "$TRUST_NAMESPACE" \
    "${ESO_LABEL_COMPONENT_KEY}=${ESO_LABEL_HUB_EXPORT_VALUE}" \
    app.kubernetes.io/name=vp-proxy-ca-hub-export \
    --overwrite
  log "hub export Secret ${TRUST_NAMESPACE}/${ESO_HUB_EXPORT_SECRET_NAME} applied"
}

patch_proxy_trusted_ca() {
  local proxy_ca_name="${CONFIG_MAP_NAME}"
  if trust_manager_enabled; then
    proxy_ca_name="${TRUST_BUNDLE_NAME:-$CONFIG_MAP_NAME}"
  fi
  oc patch proxy cluster --type=merge \
    -p "{\"spec\":{\"trustedCA\":{\"name\":\"${proxy_ca_name}\"}}}" || {
    log "warning: proxy patch failed"
    return 0
  }
  log "Proxy trustedCA set to ${proxy_ca_name}"
}

if write_hub_export_enabled; then
  rm -rf "$RAW_DIR" "$PEM_DIR"
  mkdir -p "$RAW_DIR" "$PEM_DIR"

  if include_api_ca_enabled; then
    extract_kube_apiserver_ca "$RAW_DIR/hub-api.crt" || true
  fi
  if [[ "$INCLUDE_INGRESS_CA" == "true" ]]; then
    extract_ingress_ca "$RAW_DIR/hub-ingress.crt" || true
  fi

  n=0
  for rf in "$RAW_DIR"/*.crt; do
    [[ -e "$rf" ]] || continue
    [[ -s "$rf" ]] || continue
    n=$((n + 1))
    split_pem_file_to_dir "$rf" "$PEM_DIR/batch-${n}"
  done

  if [[ -n "$ADDITIONAL_CA_FILE" && -f "$ADDITIONAL_CA_FILE" && -s "$ADDITIONAL_CA_FILE" ]]; then
    if trust_manager_enabled; then
      log "skip additional CA file (trust-manager Bundle inLine sources from additionalCaBundles)"
    else
      split_pem_file_to_dir "$ADDITIONAL_CA_FILE" "$PEM_DIR/additional"
    fi
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

  log "deduped hub bundle size $(wc -c <"$BUNDLE_OUT") bytes"

  if trust_manager_enabled; then
    apply_hub_export_secret "$BUNDLE_OUT" || true
  else
    apply_ca_configmap "$BUNDLE_OUT"
  fi
fi

patch_proxy_trusted_ca
log "done"
