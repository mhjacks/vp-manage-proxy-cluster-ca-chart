#!/bin/bash
# Runs on the spoke: merge API server CA, optional ingress CA; update local export Secret.
set -euo pipefail
: >/tmp/trust.crt
if [[ "${INCLUDE_API_CA:-true}" == "true" ]]; then
  if oc get configmap kube-apiserver-server-ca -n openshift-config-managed \
    -o jsonpath='{.data.ca-bundle\.crt}' >/tmp/api-ca.crt 2>/dev/null && [[ -s /tmp/api-ca.crt ]]; then
    cat /tmp/api-ca.crt >>/tmp/trust.crt
    printf '\n' >>/tmp/trust.crt
  elif [[ -r /var/run/secrets/kubernetes.io/serviceaccount/ca.crt ]]; then
    cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt >>/tmp/trust.crt
    printf '\n' >>/tmp/trust.crt
  fi
fi
if [[ "${INCLUDE_INGRESS_CA}" == "true" ]]; then
  oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d >>/tmp/trust.crt || true
  oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d >>/tmp/trust.crt || true
  printf '\n' >>/tmp/trust.crt
fi
if [[ ! -s /tmp/trust.crt ]]; then
  echo "no CA material collected for export" >&2
  exit 1
fi
oc create secret generic "${EXPORT_SECRET_NAME}" -n "${EXPORT_NAMESPACE}" \
  --from-file="${EXPORT_SECRET_KEY}=/tmp/trust.crt" \
  --dry-run=client -o yaml | oc apply -f -
oc label secret "${EXPORT_SECRET_NAME}" -n "${EXPORT_NAMESPACE}" \
  app.kubernetes.io/name=vp-proxy-ca-eso-export \
  app.kubernetes.io/instance="${CLUSTER_NAME}" \
  app.kubernetes.io/component=export-source \
  --overwrite
