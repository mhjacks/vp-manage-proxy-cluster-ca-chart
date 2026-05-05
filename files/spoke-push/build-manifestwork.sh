#!/bin/bash
# shellcheck shell=bash
# Sourced by gather-and-distribute-ca.sh. Uses env: WORK_DIR, MANIFEST_WORK_PUSH_AGENT_NAME,
# SPOKE_PUSH_SPOKE_NAMESPACE, SPOKE_PUSH_HUB_NAMESPACE, SPOKE_PUSH_CRON_SCHEDULE, PUSH_AGENT_IMAGE,
# INCLUDE_INGRESS_CA, INCLUDE_SYSTEM_TRUST_STORE, VP_SPOKE_PUSH_INCLUDE_DIR (default /includes/spoke-push).

VP_SPOKE_PUSH_INCLUDE_DIR="${VP_SPOKE_PUSH_INCLUDE_DIR:-/includes/spoke-push}"

# Indent one Kubernetes object (stdin) as a ManifestWork manifests[] item.
vp_spoke_push_manifest_item_from_stdin() {
  sed '/^$/d' | sed 's/^/        /' | sed '1s/^        /      - /'
}

# Render full ManifestWork YAML for one managed cluster (hub namespace = cluster name).
# Requires gather script to have defined log() before this file is sourced.
provision_spoke_push_manifestwork() {
  local cluster="$1"
  local token
  token="$(oc create token vp-spoke-bundle-writer -n "$SPOKE_PUSH_HUB_NAMESPACE" --duration="$SPOKE_PUSH_TOKEN_DURATION" 2>/dev/null)" || {
    log "failed oc create token vp-spoke-bundle-writer in ${SPOKE_PUSH_HUB_NAMESPACE} (cluster=${cluster})"
    return 1
  }
  local hub_server="${SPOKE_PUSH_HUB_API_SERVER}"
  if [[ -z "$hub_server" ]]; then
    hub_server="$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  fi
  if [[ -z "$hub_server" ]]; then
    log "set SPOKE_PUSH_HUB_API_SERVER or ensure kubeconfig has cluster.server"
    return 1
  fi
  local ca_b64=""
  ca_b64="$(oc config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)"
  if [[ -z "$ca_b64" ]]; then
    if [[ -r /var/run/secrets/kubernetes.io/serviceaccount/ca.crt ]]; then
      ca_b64="$(base64 -w0 </var/run/secrets/kubernetes.io/serviceaccount/ca.crt 2>/dev/null || base64 </var/run/secrets/kubernetes.io/serviceaccount/ca.crt | tr -d '\n')"
    fi
  fi
  if [[ -z "$ca_b64" ]]; then
    log "could not determine hub API CA data"
    return 1
  fi
  local ca_pem
  ca_pem="${WORK_DIR}/hub-ca-${cluster}.pem"
  if ! printf '%s' "$ca_b64" | base64 -d >"$ca_pem" 2>/dev/null; then
    log "could not decode certificate-authority-data"
    return 1
  fi

  local out="$WORK_DIR/mw-push-${cluster}.yaml"
  local idir="$VP_SPOKE_PUSH_INCLUDE_DIR"

  {
    echo "apiVersion: work.open-cluster-management.io/v1"
    echo "kind: ManifestWork"
    echo "metadata:"
    echo "  name: ${MANIFEST_WORK_PUSH_AGENT_NAME}"
    echo "  namespace: ${cluster}"
    echo "spec:"
    echo "  workload:"
    echo "    manifests:"
    for frag in namespace.yaml serviceaccount.yaml role-trust.yaml rolebinding-trust.yaml role-ingress.yaml rolebinding-ingress.yaml; do
      sed "s|@@SPOKE_NAMESPACE@@|${SPOKE_PUSH_SPOKE_NAMESPACE}|g" "${idir}/${frag}" | vp_spoke_push_manifest_item_from_stdin
    done
    oc create secret generic vp-proxy-ca-hub-api -n "${SPOKE_PUSH_SPOKE_NAMESPACE}" \
      --from-literal=token="${token}" \
      --from-literal=server="${hub_server}" \
      --from-file=ca.crt="${ca_pem}" \
      --dry-run=client -o yaml | vp_spoke_push_manifest_item_from_stdin
    oc create configmap vp-proxy-ca-push-run -n "${SPOKE_PUSH_SPOKE_NAMESPACE}" \
      --from-file=run.sh="${idir}/cron.sh" \
      --dry-run=client -o yaml | vp_spoke_push_manifest_item_from_stdin
    sed -e "s|@@SPOKE_NAMESPACE@@|${SPOKE_PUSH_SPOKE_NAMESPACE}|g" \
      -e "s|@@PUSH_IMAGE@@|${PUSH_AGENT_IMAGE}|g" \
      -e "s|@@CRON_SCHEDULE@@|${SPOKE_PUSH_CRON_SCHEDULE}|g" \
      -e "s|@@CLUSTER_VALUE@@|${cluster}|g" \
      -e "s|@@HUB_NAMESPACE@@|${SPOKE_PUSH_HUB_NAMESPACE}|g" \
      -e "s|@@INCLUDE_INGRESS@@|${INCLUDE_INGRESS_CA}|g" \
      -e "s|@@INCLUDE_SYSTEM_TRUST@@|${INCLUDE_SYSTEM_TRUST_STORE}|g" \
      "${idir}/cronjob.yaml" | vp_spoke_push_manifest_item_from_stdin
  } >"$out"

  oc apply -f "$out"
  log "ManifestWork ${cluster}/${MANIFEST_WORK_PUSH_AGENT_NAME} applied (spoke push agent)"
}
