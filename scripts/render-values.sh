#!/usr/bin/env bash
# =============================================================================
# render-values.sh — render a deploy-ready Helm values file for one app by
# merging Terraform outputs onto the committed per-app base values.
#
# Usage:
#   scripts/render-values.sh <app> [tag]
#     <app>  one of: wrapper | crm | fa
#     [tag]  optional image tag override (default: $TAG env, else "latest")
#
# What it does:
#   1. Reads `terraform -chdir=<tf> output -json app_wiring` (the consolidated
#      per-app wiring) plus the full `terraform output -json` (for the ACM cert
#      used by the ALB ingress, which app_wiring does not carry).
#   2. Extracts, with jq, the app's slice: image repo, env map, IRSA role ARN,
#      Secrets Manager secret ARN, API host, and the ALB certificate ARN.
#   3. Deep-merges those onto helm/zopkit-backend/values-<app>.yaml with yq,
#      writing helm/zopkit-backend/values-<app>.generated.yaml.
#
# Dependencies: bash >= 4, terraform, jq, and yq v4 (mikefarah/yq — the Go
#   implementation; `yq --version` must report v4.x). On macOS: `brew install yq`.
#
# Idempotent: re-running regenerates the .generated.yaml from the committed base
# every time, so it never compounds edits. The base values-<app>.yaml is never
# modified. Apply with:
#   helm upgrade --install <app> ./helm/zopkit-backend \
#     -f helm/zopkit-backend/values-<app>.generated.yaml -n zopkit-prod
# =============================================================================
set -euo pipefail

# --- locate repo dirs relative to this script (works from any CWD) -----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${DEPLOY_DIR}/terraform"
CHART_DIR="${DEPLOY_DIR}/helm/zopkit-backend"

err()  { printf 'render-values: error: %s\n' "$*" >&2; exit 1; }
note() { printf 'render-values: %s\n' "$*" >&2; }

# --- args --------------------------------------------------------------------
APP="${1:-}"
[ -n "${APP}" ] || err "missing app argument. Usage: $0 <wrapper|crm|fa> [tag]"
case "${APP}" in
  wrapper|crm|fa) ;;
  *) err "unknown app '${APP}'. Expected one of: wrapper, crm, fa" ;;
esac

# tag precedence: $2 > $TAG env > "latest"
TAG="${2:-${TAG:-latest}}"

BASE_VALUES="${CHART_DIR}/values-${APP}.yaml"
OUT_VALUES="${CHART_DIR}/values-${APP}.generated.yaml"
[ -f "${BASE_VALUES}" ] || err "base values file not found: ${BASE_VALUES}"

# --- tool checks -------------------------------------------------------------
command -v terraform >/dev/null 2>&1 || err "terraform not found on PATH"
command -v jq        >/dev/null 2>&1 || err "jq not found on PATH"
command -v yq        >/dev/null 2>&1 || err "yq not found on PATH (need mikefarah/yq v4: 'brew install yq')"
# Guard against the legacy python 'yq'; we require the Go yq v4 .* syntax below.
if ! yq --version 2>&1 | grep -Eq 'v?4\.'; then
  err "yq v4 (mikefarah/yq) required; found: $(yq --version 2>&1)"
fi

# --- pull Terraform outputs --------------------------------------------------
# app_wiring: { <app>: { image, port, api_host, frontend_host, irsa_role_arn,
#                        secret_arn, env: {..}, ... } }  (see terraform/outputs.tf)
note "reading terraform outputs from ${TF_DIR} ..."
WIRING_JSON="$(terraform -chdir="${TF_DIR}" output -json app_wiring 2>/dev/null)" \
  || err "could not read 'app_wiring' output. Has 'terraform apply' run in ${TF_DIR}?"

# Full output set — used to find the ALB certificate ARN (app_wiring omits it).
ALL_JSON="$(terraform -chdir="${TF_DIR}" output -json 2>/dev/null || echo '{}')"

# Slice out this app; fail loudly if the key is absent.
APP_JSON="$(jq -e --arg a "${APP}" '.[$a]' <<<"${WIRING_JSON}")" \
  || err "app '${APP}' not present in app_wiring output"

# --- extract fields with jq --------------------------------------------------
IMAGE_REPO="$(jq -re '.image'         <<<"${APP_JSON}")" || err "app_wiring.${APP}.image missing"
IRSA_ROLE="$(jq -re '.irsa_role_arn'  <<<"${APP_JSON}")" || err "app_wiring.${APP}.irsa_role_arn missing"
SECRET_ARN="$(jq -re '.secret_arn'    <<<"${APP_JSON}")" || err "app_wiring.${APP}.secret_arn missing"
API_HOST="$(jq -re '.api_host'        <<<"${APP_JSON}")" || err "app_wiring.${APP}.api_host missing"
# env is a flat string->string map; emit compact JSON for yq to load as a node.
ENV_JSON="$(jq -ce '.env // {}'       <<<"${APP_JSON}")"

# The ExternalSecret remoteRef key: prefer the human-readable secret NAME
# (zopkit/<env>/<app>) already committed in the base values; the secret ARN from
# Terraform also works as an ESO key. We pass the ARN so the rendered file is
# fully self-describing and unambiguous across accounts/regions.
SECRET_REF="${SECRET_ARN}"

# ALB ingress certificate ARN: app_wiring does not carry it, so probe the full
# output set for any of the likely names that the frozen outputs.tf might expose.
# If none is present (outputs.tf owns outputs and currently exposes none), keep
# whatever certArn the committed base file already has — never blank it out.
CERT_ARN="$(jq -r '
  ( .acm_cert_arn.value
    // .alb_acm_certificate_arn.value
    // .acm_certificate_arn.value
    // .wildcard_certificate_arn.value
    // empty )
' <<<"${ALL_JSON}" 2>/dev/null || true)"

# Valkey secret name/ARN — ESO pulls REDIS_URL/REDIS_PASSWORD/REDIS_ENABLED from it
# into the pod Secret (externalSecret.sharedKeys). Without this the cache is unreachable.
VALKEY_SECRET="$(jq -r '
  ( .valkey_secret_name.value // .valkey_secret_arn.value // empty )
' <<<"${ALL_JSON}" 2>/dev/null || true)"

# --- merge onto the base values with yq --------------------------------------
# Strategy: copy base -> generated, then set each Terraform-derived field.
# `env: {{...}}` is replaced wholesale (the wiring env is authoritative);
# everything else in the base (probes, resources, autoscaling, replicaCount,
# ingress.extraHosts, workers, ...) is preserved untouched.
note "rendering ${OUT_VALUES} (app=${APP}, tag=${TAG}) ..."
cp "${BASE_VALUES}" "${OUT_VALUES}"

ENV_JSON="${ENV_JSON}" \
IMAGE_REPO="${IMAGE_REPO}" \
TAG="${TAG}" \
IRSA_ROLE="${IRSA_ROLE}" \
SECRET_REF="${SECRET_REF}" \
API_HOST="${API_HOST}" \
yq -i '
  .image.repository           = strenv(IMAGE_REPO) |
  .image.tag                  = strenv(TAG) |
  .serviceAccount.roleArn     = strenv(IRSA_ROLE) |
  .externalSecret.remoteRef.key = strenv(SECRET_REF) |
  .ingress.host               = strenv(API_HOST) |
  .env                        = (strenv(ENV_JSON) | fromjson)
' "${OUT_VALUES}"

# Only set the ingress cert if Terraform actually exposed one; otherwise the
# base file's certArn stands (operators may set it manually if no output exists).
if [ -n "${CERT_ARN}" ]; then
  CERT_ARN="${CERT_ARN}" yq -i '.ingress.certArn = strenv(CERT_ARN)' "${OUT_VALUES}"
else
  note "no ACM cert ARN found in terraform outputs; left ingress.certArn from base values."
  note "  (expose an 'acm_cert_arn' output or set certArn by hand.)"
fi

# Wire the Valkey shared secret so REDIS_URL/REDIS_PASSWORD reach the pods.
if [ -n "${VALKEY_SECRET}" ]; then
  VALKEY_SECRET="${VALKEY_SECRET}" yq -i '.externalSecret.sharedKeys = [strenv(VALKEY_SECRET)]' "${OUT_VALUES}"
else
  note "no valkey secret name in terraform outputs; left externalSecret.sharedKeys from base values."
fi

# --- done --------------------------------------------------------------------
note "wrote rendered values for '${APP}' (image=${IMAGE_REPO}:${TAG})"
# Print ONLY the output path on stdout so callers (Makefile/CI) can capture it.
printf '%s\n' "${OUT_VALUES}"
