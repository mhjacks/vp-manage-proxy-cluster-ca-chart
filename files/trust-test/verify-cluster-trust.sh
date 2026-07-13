#!/bin/bash
# Verify TLS to hub and managed-cluster API and ingress endpoints using the
# trust-manager CA bundle mounted in this namespace.
set -euo pipefail

CA_BUNDLE_PATH="${CA_BUNDLE_PATH:-/etc/pki/trust/ca-bundle.crt}"
CA_WAIT_SECONDS="${CA_WAIT_SECONDS:-300}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"
MAX_TIME="${MAX_TIME:-45}"
ROUTE_NAME="${ROUTE_NAME:-config-demo}"
ROUTE_NAMESPACE="${ROUTE_NAMESPACE:-config-demo}"
DISCOVER_MANAGED_CLUSTERS="${DISCOVER_MANAGED_CLUSTERS:-true}"
INCLUDE_LOCAL_CLUSTER="${INCLUDE_LOCAL_CLUSTER:-true}"
REQUIRE_REMOTE_REACHABLE="${REQUIRE_REMOTE_REACHABLE:-false}"
HUB_CLUSTER_DOMAIN="${HUB_CLUSTER_DOMAIN:-}"
LOCAL_CLUSTER_DOMAIN="${LOCAL_CLUSTER_DOMAIN:-}"
TRUST_TEST_TARGETS_JSON="${TRUST_TEST_TARGETS_JSON:-[]}"

declare -a TARGET_NAMES=()
declare -a TARGET_APIS=()
declare -a TARGET_INGRESS=()

log() { echo "[cluster-trust-test] $*"; }
warn() { echo "[cluster-trust-test] WARN: $*" >&2; }
die() { echo "[cluster-trust-test] ERROR: $*" >&2; exit 1; }

wait_for_ca_bundle() {
  log "Waiting up to ${CA_WAIT_SECONDS}s for CA bundle at ${CA_BUNDLE_PATH}"
  local i pem_count
  for ((i = 0; i < CA_WAIT_SECONDS; i++)); do
    if [[ -s "${CA_BUNDLE_PATH}" ]]; then
      pem_count=$(grep -c 'BEGIN CERTIFICATE' "${CA_BUNDLE_PATH}" || true)
      log "CA bundle ready (${pem_count} PEM blocks)"
      return 0
    fi
    sleep 1
  done
  die "CA bundle missing or empty at ${CA_BUNDLE_PATH}"
}

ingress_url_for_domain() {
  local domain="$1"
  printf 'https://%s-%s.apps.%s/index.html' "${ROUTE_NAME}" "${ROUTE_NAMESPACE}" "${domain}"
}

api_url_for_domain() {
  local domain="$1"
  printf 'https://api.%s:6443/readyz' "${domain}"
}

add_target() {
  local name="$1"
  local api_url="$2"
  local ingress_url="$3"
  local existing
  for existing in "${TARGET_NAMES[@]:-}"; do
    if [[ "${existing}" == "${name}" ]]; then
      return 0
    fi
  done
  TARGET_NAMES+=("${name}")
  TARGET_APIS+=("${api_url}")
  TARGET_INGRESS+=("${ingress_url}")
}

add_target_for_domain() {
  local name="$1"
  local domain="$2"
  [[ -z "${domain}" ]] && return 0
  add_target "${name}" "$(api_url_for_domain "${domain}")" "$(ingress_url_for_domain "${domain}")"
}

discover_local_cluster_domain() {
  local ingress_domain base_domain api_url
  ingress_domain="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  if [[ -n "${ingress_domain}" ]]; then
    if [[ "${ingress_domain}" == apps.* ]]; then
      base_domain="${ingress_domain#apps.}"
    else
      base_domain="${ingress_domain}"
    fi
    echo "${base_domain}"
    return 0
  fi
  api_url="$(oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}' 2>/dev/null || true)"
  if [[ "${api_url}" =~ https://api\.([^:/]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

discover_local_targets() {
  local domain route_host
  domain="${LOCAL_CLUSTER_DOMAIN:-}"
  if [[ -z "${domain}" ]]; then
    domain="$(discover_local_cluster_domain || true)"
  fi
  if [[ -z "${domain}" ]]; then
    warn "Could not determine local cluster domain"
    return 0
  fi
  add_target_for_domain "local:${domain}" "${domain}"

  route_host="$(oc get route "${ROUTE_NAME}" -n "${ROUTE_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "${route_host}" ]]; then
    add_target "local-route:${route_host}" \
      "$(api_url_for_domain "${domain}")" \
      "https://${route_host}/index.html"
  fi
}

discover_hub_target() {
  local domain="${HUB_CLUSTER_DOMAIN:-}"
  [[ -z "${domain}" ]] && return 0
  add_target_for_domain "hub:${domain}" "${domain}"
}

discover_managed_cluster_targets() {
  if [[ "${DISCOVER_MANAGED_CLUSTERS}" != "true" ]]; then
    return 0
  fi
  if ! oc api-resources --api-group=cluster.open-cluster-management.io 2>/dev/null | grep -q managedclusters; then
    return 0
  fi
  local mc_name api_url domain
  while IFS=$'\t' read -r mc_name api_url; do
    [[ -z "${mc_name}" || "${mc_name}" == "local-cluster" ]] && continue
    [[ -z "${api_url}" ]] && continue
    if [[ "${api_url}" =~ https://api\.([^:/]+) ]]; then
      domain="${BASH_REMATCH[1]}"
      add_target_for_domain "managed:${mc_name}" "${domain}"
    else
      warn "Skipping ${mc_name}: unrecognized API URL ${api_url}"
    fi
  done < <(
    oc get managedclusters.cluster.open-cluster-management.io -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.managedClusterClientConfigs[0].url}{"\n"}{end}' 2>/dev/null || true
  )
}

load_configured_targets() {
  if ! command -v python3 >/dev/null 2>&1; then
    [[ "${TRUST_TEST_TARGETS_JSON}" != "[]" && -n "${TRUST_TEST_TARGETS_JSON}" ]] && \
      warn "python3 unavailable; skipping TRUST_TEST_TARGETS_JSON"
    return 0
  fi
  python3 - "${TRUST_TEST_TARGETS_JSON}" <<'PY'
import json, sys

raw = sys.argv[1] or "[]"
try:
    targets = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"invalid TRUST_TEST_TARGETS_JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(targets, list):
    print("TRUST_TEST_TARGETS_JSON must be a JSON array", file=sys.stderr)
    sys.exit(1)

for item in targets:
    if not isinstance(item, dict):
        continue
    name = item.get("name") or item.get("clusterDomain") or "configured"
    domain = item.get("clusterDomain") or ""
    api_url = item.get("apiUrl") or item.get("api") or ""
    ingress_url = item.get("ingressUrl") or item.get("ingress") or ""
    if domain and not api_url:
        api_url = f"https://api.{domain}:6443/readyz"
    if domain and not ingress_url:
        route_name = item.get("routeName") or "config-demo"
        route_ns = item.get("routeNamespace") or "config-demo"
        ingress_url = f"https://{route_name}-{route_ns}.apps.{domain}/index.html"
    if api_url or ingress_url:
        print("\t".join([name, api_url or "-", ingress_url or "-"]))
PY
  while IFS=$'\t' read -r name api_url ingress_url; do
    [[ -z "${name}" ]] && continue
    add_target "${name}" \
      "$( [[ "${api_url}" == "-" ]] && echo "" || echo "${api_url}" )" \
      "$( [[ "${ingress_url}" == "-" ]] && echo "" || echo "${ingress_url}" )"
  done
}

build_targets() {
  load_configured_targets
  if [[ "${INCLUDE_LOCAL_CLUSTER}" == "true" ]]; then
    discover_local_targets
  fi
  discover_hub_target
  discover_managed_cluster_targets
  ((${#TARGET_NAMES[@]} > 0)) || die "No test targets discovered or configured"
}

curl_tls() {
  local label="$1"
  local url="$2"
  [[ -z "${url}" ]] && return 0

  log "TLS check ${label}: ${url}"
  local err_file
  err_file="$(mktemp)"
  if curl -g -sS --cacert "${CA_BUNDLE_PATH}" \
    --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${MAX_TIME}" \
    -o /dev/null "${url}" 2>"${err_file}"; then
    rm -f "${err_file}"
    log "PASS ${label}"
    return 0
  fi

  local err
  err="$(tr '\n' ' ' <"${err_file}")"
  rm -f "${err_file}"

  if [[ "${err}" == *"SSL certificate problem"* || "${err}" == *"certificate verify failed"* ]]; then
    die "TLS verification failed for ${label} (${url}): ${err}"
  fi

  if [[ "${REQUIRE_REMOTE_REACHABLE}" == "true" ]]; then
    die "Request failed for ${label} (${url}): ${err}"
  fi
  warn "Skipped unreachable endpoint ${label} (${url}): ${err}"
  return 0
}

main() {
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v oc >/dev/null 2>&1 || die "oc is required"

  wait_for_ca_bundle
  build_targets

  local failures=0 i
  for ((i = 0; i < ${#TARGET_NAMES[@]}; i++)); do
    log "Target ${TARGET_NAMES[i]}"
    curl_tls "${TARGET_NAMES[i]} API" "${TARGET_APIS[i]}" || failures=$((failures + 1))
    curl_tls "${TARGET_NAMES[i]} ingress" "${TARGET_INGRESS[i]}" || failures=$((failures + 1))
  done

  ((${failures} == 0)) || die "${failures} TLS check(s) failed"
  log "All TLS checks passed for ${#TARGET_NAMES[@]} target(s)"
}

main "$@"
