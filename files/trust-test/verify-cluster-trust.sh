#!/bin/bash
# Verify TLS to hub and managed-cluster API and ingress endpoints using the
# trust-manager CA bundle mounted in this namespace.
set -euo pipefail

CA_BUNDLE_PATH="${CA_BUNDLE_PATH:-/etc/pki/trust/ca-bundle.crt}"
CA_WAIT_SECONDS="${CA_WAIT_SECONDS:-300}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"
MAX_TIME="${MAX_TIME:-45}"
DISCOVER_MANAGED_CLUSTERS="${DISCOVER_MANAGED_CLUSTERS:-true}"
INCLUDE_LOCAL_CLUSTER="${INCLUDE_LOCAL_CLUSTER:-true}"
REQUIRE_REMOTE_REACHABLE="${REQUIRE_REMOTE_REACHABLE:-false}"
HUB_CLUSTER_DOMAIN="${HUB_CLUSTER_DOMAIN:-}"
LOCAL_CLUSTER_DOMAIN="${LOCAL_CLUSTER_DOMAIN:-}"
TRUST_TEST_TARGETS_JSON="${TRUST_TEST_TARGETS_JSON:-[]}"
CONSOLE_INGRESS_ENABLED="${CONSOLE_INGRESS_ENABLED:-true}"
CONSOLE_HOST_TEMPLATE="${CONSOLE_HOST_TEMPLATE:-console-openshift-console.apps.%s}"
CONSOLE_PATH="${CONSOLE_PATH:-/}"
CONSOLE_ROUTE_NAME="${CONSOLE_ROUTE_NAME:-console}"
CONSOLE_ROUTE_NAMESPACE="${CONSOLE_ROUTE_NAMESPACE:-openshift-console}"
ADDITIONAL_INGRESS_JSON="${ADDITIONAL_INGRESS_JSON:-[]}"

declare -a API_NAMES=()
declare -a API_URLS=()
declare -a INGRESS_LABELS=()
declare -a INGRESS_URLS=()

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

normalize_path() {
  local path="$1"
  [[ -z "${path}" || "${path}" == "/" ]] && printf '/' && return 0
  [[ "${path}" == /* ]] && printf '%s' "${path}" || printf '/%s' "${path}"
}

build_https_url() {
  local host="$1"
  local path="$2"
  printf 'https://%s%s' "${host}" "$(normalize_path "${path}")"
}

api_url_for_domain() {
  local domain="$1"
  printf 'https://api.%s:6443/readyz' "${domain}"
}

console_url_for_domain() {
  local domain="$1"
  local host
  host="$(printf "${CONSOLE_HOST_TEMPLATE}" "${domain}")"
  build_https_url "${host}" "${CONSOLE_PATH}"
}

discover_local_console_url() {
  local route_host
  route_host="$(oc get route "${CONSOLE_ROUTE_NAME}" -n "${CONSOLE_ROUTE_NAMESPACE}" \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  [[ -z "${route_host}" ]] && return 1
  build_https_url "${route_host}" "${CONSOLE_PATH}"
}

add_api_check() {
  local name="$1"
  local url="$2"
  [[ -z "${url}" ]] && return 0
  local existing
  for existing in "${API_NAMES[@]:-}"; do
    if [[ "${existing}" == "${name}" ]]; then
      return 0
    fi
  done
  API_NAMES+=("${name}")
  API_URLS+=("${url}")
}

add_ingress_check() {
  local label="$1"
  local url="$2"
  [[ -z "${url}" ]] && return 0
  local existing
  for existing in "${INGRESS_LABELS[@]:-}"; do
    if [[ "${existing}" == "${label}" ]]; then
      return 0
    fi
  done
  INGRESS_LABELS+=("${label}")
  INGRESS_URLS+=("${url}")
}

add_console_ingress_for_domain() {
  local label_prefix="$1"
  local domain="$2"
  local prefer_local_discovery="${3:-false}"
  local url=""

  [[ "${CONSOLE_INGRESS_ENABLED}" == "true" ]] || return 0
  if [[ "${prefer_local_discovery}" == "true" ]] && url="$(discover_local_console_url)"; then
    add_ingress_check "${label_prefix} console" "${url}"
    return 0
  fi
  add_ingress_check "${label_prefix} console" "$(console_url_for_domain "${domain}")"
}

expand_additional_ingress_for_domain() {
  local label_prefix="$1"
  local domain="$2"
  if ! command -v python3 >/dev/null 2>&1; then
    [[ "${ADDITIONAL_INGRESS_JSON}" != "[]" && -n "${ADDITIONAL_INGRESS_JSON}" ]] && \
      warn "python3 unavailable; skipping ADDITIONAL_INGRESS_JSON for ${label_prefix}"
    return 0
  fi
  python3 - "${label_prefix}" "${domain}" "${ADDITIONAL_INGRESS_JSON}" <<'PY'
import json, sys

label_prefix, domain, raw = sys.argv[1], sys.argv[2], sys.argv[3] or "[]"
try:
    entries = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"invalid ADDITIONAL_INGRESS_JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(entries, list):
    print("ADDITIONAL_INGRESS_JSON must be a JSON array", file=sys.stderr)
    sys.exit(1)

def norm_path(path):
    if not path or path == "/":
        return "/"
    return path if path.startswith("/") else f"/{path}"

for item in entries:
    if not isinstance(item, dict):
        continue
    name = item.get("name") or item.get("label") or "additional"
    url = item.get("url") or item.get("ingressUrl") or item.get("ingress") or ""
    if not url:
        template = item.get("hostTemplate") or item.get("host") or ""
        if template and domain:
            host = template % domain
            path = norm_path(item.get("path") or "/")
            url = f"https://{host}{path}"
    if url:
        print(f"{label_prefix} {name}\t{url}")
PY
  while IFS=$'\t' read -r label url; do
    [[ -z "${label}" || -z "${url}" ]] && continue
    add_ingress_check "${label}" "${url}"
  done
}

add_cluster_checks() {
  local label_prefix="$1"
  local domain="$2"
  local prefer_local_console="${3:-false}"
  [[ -z "${domain}" ]] && return 0
  add_api_check "${label_prefix}" "$(api_url_for_domain "${domain}")"
  add_console_ingress_for_domain "${label_prefix}" "${domain}" "${prefer_local_console}"
  expand_additional_ingress_for_domain "${label_prefix}" "${domain}"
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
  local domain
  domain="${LOCAL_CLUSTER_DOMAIN:-}"
  if [[ -z "${domain}" ]]; then
    domain="$(discover_local_cluster_domain || true)"
  fi
  if [[ -z "${domain}" ]]; then
    warn "Could not determine local cluster domain"
    return 0
  fi
  add_cluster_checks "local:${domain}" "${domain}" "true"
}

discover_hub_target() {
  local domain="${HUB_CLUSTER_DOMAIN:-}"
  [[ -z "${domain}" ]] && return 0
  add_cluster_checks "hub:${domain}" "${domain}" "false"
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
      add_cluster_checks "managed:${mc_name}" "${domain}" "false"
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
  python3 - "${TRUST_TEST_TARGETS_JSON}" "${CONSOLE_INGRESS_ENABLED}" "${CONSOLE_HOST_TEMPLATE}" "${CONSOLE_PATH}" <<'PY'
import json, sys

raw, console_enabled, host_template, console_path = sys.argv[1:5]
try:
    targets = json.loads(raw or "[]")
except json.JSONDecodeError as exc:
    print(f"invalid TRUST_TEST_TARGETS_JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(targets, list):
    print("TRUST_TEST_TARGETS_JSON must be a JSON array", file=sys.stderr)
    sys.exit(1)

def norm_path(path):
    if not path or path == "/":
        return "/"
    return path if path.startswith("/") else f"/{path}"

for item in targets:
    if not isinstance(item, dict):
        continue
    name = item.get("name") or item.get("clusterDomain") or "configured"
    domain = item.get("clusterDomain") or ""
    api_url = item.get("apiUrl") or item.get("api") or ""
    ingress_url = item.get("ingressUrl") or item.get("ingress") or ""
    if domain and not api_url:
        api_url = f"https://api.{domain}:6443/readyz"
    if domain and not ingress_url and console_enabled.lower() == "true":
        host = host_template % domain
        ingress_url = f"https://{host}{norm_path(console_path)}"
    if api_url:
        print("\t".join(["API", name, api_url]))
    if ingress_url:
        print("\t".join(["INGRESS", f"{name} ingress", ingress_url]))
    extras = item.get("additionalIngress") or item.get("additionalUrls") or []
    if isinstance(extras, list):
        for extra in extras:
            if not isinstance(extra, dict):
                continue
            label = extra.get("name") or extra.get("label") or "additional"
            url = extra.get("url") or extra.get("ingressUrl") or ""
            if not url:
                template = extra.get("hostTemplate") or extra.get("host") or ""
                if template and domain:
                    url = f"https://{template % domain}{norm_path(extra.get('path') or '/')}"
            if url:
                print("\t".join(["INGRESS", f"{name} {label}", url]))
PY
  while IFS=$'\t' read -r kind name url; do
    [[ -z "${kind}" || -z "${name}" || -z "${url}" ]] && continue
    if [[ "${kind}" == "API" ]]; then
      add_api_check "${name}" "${url}"
    else
      add_ingress_check "${name}" "${url}"
    fi
  done
}

build_targets() {
  load_configured_targets
  if [[ "${INCLUDE_LOCAL_CLUSTER}" == "true" ]]; then
    discover_local_targets
  fi
  discover_hub_target
  discover_managed_cluster_targets
  ((${#API_NAMES[@]} + ${#INGRESS_LABELS[@]} > 0)) || die "No test targets discovered or configured"
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
  for ((i = 0; i < ${#API_NAMES[@]}; i++)); do
    log "API target ${API_NAMES[i]}"
    curl_tls "${API_NAMES[i]} API" "${API_URLS[i]}" || failures=$((failures + 1))
  done
  for ((i = 0; i < ${#INGRESS_LABELS[@]}; i++)); do
    log "Ingress target ${INGRESS_LABELS[i]}"
    curl_tls "${INGRESS_LABELS[i]}" "${INGRESS_URLS[i]}" || failures=$((failures + 1))
  done

  ((${failures} == 0)) || die "${failures} TLS check(s) failed"
  log "All TLS checks passed (${#API_NAMES[@]} API, ${#INGRESS_LABELS[@]} ingress)"
}

main "$@"
