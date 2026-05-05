#!/bin/bash
# Runs on the spoke: merge API server CA, optional ingress CA, optional system trust; push to hub (no kubeconfig).
set -euo pipefail
: >/tmp/trust.crt
if oc get configmap kube-apiserver-server-ca -n openshift-config-managed \
  -o jsonpath='{.data.ca-bundle\.crt}' >/tmp/api-ca.crt 2>/dev/null && [[ -s /tmp/api-ca.crt ]]; then
  cat /tmp/api-ca.crt >>/tmp/trust.crt
  printf '\n' >>/tmp/trust.crt
elif [[ -r /var/run/secrets/kubernetes.io/serviceaccount/ca.crt ]]; then
  cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt >>/tmp/trust.crt
  printf '\n' >>/tmp/trust.crt
fi
if [[ "${INCLUDE_SYSTEM_TRUST_STORE:-false}" == "true" ]]; then
  oc get configmap trusted-ca-bundle -n openshift-config-managed \
    -o jsonpath='{.data.ca-bundle\.crt}' >>/tmp/trust.crt || true
  printf '\n' >>/tmp/trust.crt
fi
if [[ "${INCLUDE_INGRESS_CA}" == "true" ]]; then
  oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d >>/tmp/trust.crt || true
  oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d >>/tmp/trust.crt || true
  printf '\n' >>/tmp/trust.crt
fi
HUB_OC=(oc --server="$(cat /hub-api/server)" --token="$(cat /hub-api/token)" --certificate-authority=/hub-api/ca.crt)
"${HUB_OC[@]}" create configmap "bundle-${CLUSTER_NAME}" -n "${HUB_NAMESPACE}" \
  --from-file=ca-bundle.crt=/tmp/trust.crt -o yaml --dry-run=client | "${HUB_OC[@]}" apply -f -
"${HUB_OC[@]}" label configmap "bundle-${CLUSTER_NAME}" -n "${HUB_NAMESPACE}" \
  app.kubernetes.io/name=vp-proxy-ca-spoke-bundle \
  app.kubernetes.io/instance="${CLUSTER_NAME}" --overwrite
