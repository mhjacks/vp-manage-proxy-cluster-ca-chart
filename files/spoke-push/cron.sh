#!/bin/bash
# Runs on the spoke: read local trust bundle, push to hub API using mounted credentials (no kubeconfig).
set -euo pipefail
oc get configmap trusted-ca-bundle -n openshift-config-managed \
  -o jsonpath='{.data.ca-bundle\.crt}' >/tmp/trust.crt
if [[ "${INCLUDE_INGRESS_CA}" == "true" ]]; then
  oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d >>/tmp/trust.crt || true
  oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d >>/tmp/trust.crt || true
fi
HUB_OC=(oc --server="$(cat /hub-api/server)" --token="$(cat /hub-api/token)" --certificate-authority=/hub-api/ca.crt)
"${HUB_OC[@]}" create configmap "bundle-${CLUSTER_NAME}" -n "${HUB_NAMESPACE}" \
  --from-file=ca-bundle.crt=/tmp/trust.crt -o yaml --dry-run=client | "${HUB_OC[@]}" apply -f -
"${HUB_OC[@]}" label configmap "bundle-${CLUSTER_NAME}" -n "${HUB_NAMESPACE}" \
  app.kubernetes.io/name=vp-proxy-ca-spoke-bundle \
  app.kubernetes.io/instance="${CLUSTER_NAME}" --overwrite
