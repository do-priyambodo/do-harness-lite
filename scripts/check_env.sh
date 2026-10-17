#!/usr/bin/env bash
# check_env.sh (hl-env) — 60-Second Environment & Workspace Diagnostic
# Run this FIRST in any new VM or project folder to inspect GCP config,
# deployed Cloud Run services, local ports, env vars, and workspace structure.
# Supports both direct invocation (`hl-env`) and shell eval (`eval "$(hl-env)"`).
set -uo pipefail

if [[ "${1:-}" == "--export" || "${1:-}" == "--env" ]]; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
  [[ "${PROJECT_ID}" == "(unset)" ]] && PROJECT_ID=""
  cat <<EOF
export PATH="\${HOME}/.local/bin:\${PATH}"
export PROJECT_ID="${PROJECT_ID}"
export GOOGLE_CLOUD_PROJECT="${PROJECT_ID}"
export GOOGLE_GENAI_USE_VERTEXAI="True"
export GOOGLE_CLOUD_LOCATION="global"
EOF
  exit 0
fi

# If stdout is captured (e.g., `eval "$(hl-env)"`), send human-readable output
# to stderr so it still displays on the terminal while stdout emits clean `export` lines.
CAPTURED_STDOUT=0
if [[ ! -t 1 ]]; then
  CAPTURED_STDOUT=1
  exec 3>&1
  exec 1>&2
fi

WORKDIR="${1:-$(pwd)}"
cd "${WORKDIR}" || exit 1

echo "========================================================================"
echo "  do-harness-lite :: Environment & Workspace Diagnostic (hl-env)"
echo "  Workspace: ${WORKDIR}"
echo "  Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "========================================================================"

# 1. Tooling Availability
echo ""
echo "[1/7] CLI Tooling Check"
for cmd in python3 uv gcloud jq git curl node npm terraform semgrep agents-cli adk agy; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    printf "  [OK]   %-12s -> %s\n" "${cmd}" "$(command -v "${cmd}")"
  else
    printf "  [MISS] %-12s (not on PATH)\n" "${cmd}"
  fi
done

# 2. Google Cloud Project & Region
echo ""
echo "[2/7] Google Cloud Identity & Project"
PROJECT_ID=""
if command -v gcloud >/dev/null 2>&1; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
  [[ "${PROJECT_ID}" == "(unset)" ]] && PROJECT_ID=""
  ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
  REGION="$(gcloud config get-value compute/region 2>/dev/null || gcloud config get-value run/region 2>/dev/null || true)"
  echo "  Active Account : ${ACCOUNT:-<unset>}"
  echo "  Project ID     : ${PROJECT_ID:-<unset>}"
  echo "  Default Region : ${REGION:-us-central1 (fallback)}"
  if [[ -n "${PROJECT_ID}" ]]; then
    PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)" 2>/dev/null || true)"
    echo "  Project Number : ${PROJECT_NUMBER:-<unavailable>}"
  fi
else
  echo "  gcloud not installed."
fi

# 3. Environment Variables & .env Inspection
echo ""
echo "[3/7] Shell & .env Variables (Names & Non-Secret Values Only)"
echo "  GOOGLE_CLOUD_PROJECT  = ${GOOGLE_CLOUD_PROJECT:-${PROJECT_ID:-<unset>}}"
echo "  GOOGLE_CLOUD_LOCATION = ${GOOGLE_CLOUD_LOCATION:-global}"
echo "  GOOGLE_GENAI_USE_VERTEXAI = ${GOOGLE_GENAI_USE_VERTEXAI:-True}"

while IFS= read -r -d '' envfile; do
  echo "  Found env file: ${envfile}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    if [[ "${key}" =~ (KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL) ]]; then
      echo "    ${key}=***REDACTED***"
    else
      echo "    ${key}=${val}"
    fi
  done < "${envfile}"
done < <(find "${WORKDIR}" -maxdepth 3 -name ".env*" -not -name "*.example" -print0 2>/dev/null)

# 4. Workspace Structure & Key Artifacts
echo ""
echo "[4/7] Workspace Key Files & Structure"
for pattern in "README.md" "AGENTS.md" "GEMINI.md" "spec.md" "pyproject.toml" "package.json" "agents-cli-manifest.yaml" "tools.yaml" ".agents/CONTEXT.md" ".agents/hooks.json"; do
  while IFS= read -r found; do
    [[ -n "${found}" ]] && echo "  [FOUND] ${found#"${WORKDIR}/"}"
  done < <(find "${WORKDIR}" -maxdepth 3 -path "*/${pattern}" -o -name "${pattern}" 2>/dev/null | sort -u)
done

if [[ -d "${WORKDIR}/triage" ]]; then
  echo "  [FOUND] triage/ directory:"
  find "${WORKDIR}/triage" -maxdepth 3 -type f | sed "s|^${WORKDIR}/|    - |"
fi

# 5. Broken Virtualenv Check (.venv python3 symlink)
echo ""
echo "[5/7] Python Virtualenv Health"
while IFS= read -r -d '' venv_dir; do
  py_bin="${venv_dir}/bin/python3"
  if [[ -L "${py_bin}" && ! -e "${py_bin}" ]]; then
    echo "  [WARN] Broken symlink in ${venv_dir}: $(readlink "${py_bin}") does not exist!"
    echo "         Fix: uv venv --clear ${venv_dir} && uv pip install -r requirements.txt"
  elif [[ -x "${py_bin}" ]]; then
    echo "  [OK]   ${venv_dir} -> $("${py_bin}" --version 2>&1)"
  fi
done < <(find "${WORKDIR}" -maxdepth 3 -type d -name ".venv" -print0 2>/dev/null)

# 6. Local Listening Ports & Background Logs
echo ""
echo "[6/7] Local Listening Ports (8000, 8080, 3000, 3002, 5000, 5432)"
if command -v ss >/dev/null 2>&1; then
  ss -tulpn 2>/dev/null | grep -E ':(8000|8080|3000|3002|5000|5432)\b' || echo "  (no listeners on standard dev ports)"
elif command -v lsof >/dev/null 2>&1; then
  lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | grep -E ':(8000|8080|3000|3002|5000|5432)\b' || echo "  (no listeners on standard dev ports)"
fi

if [[ -f "${WORKDIR}/.google-agents-cli/run_server.log" ]]; then
  echo "  [LOG] Last 10 lines of .google-agents-cli/run_server.log:"
  tail -n 10 "${WORKDIR}/.google-agents-cli/run_server.log" | sed 's/^/    /'
fi

# 7. Cloud Resources Snapshot (Fast, Non-Blocking)
echo ""
echo "[7/7] Cloud Resources Snapshot (if authenticated)"
if [[ -n "${PROJECT_ID:-}" ]]; then
  echo "  Cloud Run Services:"
  timeout 10s gcloud run services list --project="${PROJECT_ID}" --format="table(metadata.name,status.url,status.conditions[0].status)" 2>/dev/null | sed 's/^/    /' || echo "    (skipped or timed out)"
  echo "  GCS Buckets:"
  timeout 10s gcloud storage buckets list --project="${PROJECT_ID}" --format="value(name)" 2>/dev/null | sed 's/^/    - gs:\/\//' || echo "    (skipped or timed out)"
fi

echo ""
echo "========================================================================"
echo "  Next step: run 'hl-verify ${WORKDIR}' to check Python/ADK invariants."
echo "========================================================================"

if [[ "${CAPTURED_STDOUT}" -eq 1 ]]; then
  cat >&3 <<EOF
export PATH="\${HOME}/.local/bin:\${PATH}"
export PROJECT_ID="${PROJECT_ID}"
export GOOGLE_CLOUD_PROJECT="${PROJECT_ID}"
export GOOGLE_GENAI_USE_VERTEXAI="True"
export GOOGLE_CLOUD_LOCATION="global"
EOF
  exec 3>&-
fi
