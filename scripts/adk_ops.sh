#!/usr/bin/env bash
# adk_ops.sh (hl-adk) — High-Speed ADK, Agent Runtime, Cloud Run, A2A & Model Armor Operations
# Supports both agents-cli 1.2.x and 1.3.x syntax, safe Cloud Run updates,
# GA Cloud Agent Registry A2A registration, and Regional Model Armor templates.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: hl-adk <subcommand> [args...]

Subcommands:
  enable-apis [PROJECT_ID]
      Enable Vertex AI, Agent Registry, Discovery Engine, Model Armor, Cloud Run,
      Artifact Registry, Cloud Build, Secret Manager, and AlloyDB APIs.

  doctor
      Run environment & credential checks (gcloud config + agents-cli info/doctor).

  scaffold <NAME> [REGION] [--workflow]
      Scaffold an ADK agent project using installed agents-cli (auto-detects 1.2.x vs 1.3.x).
      Pass --workflow to use `agents-cli scaffold create <NAME> --adk`.

  deploy-runtime [REGION] [ENTRYPOINT]
      Deploy agent to managed Agent Runtime (default region: us-central1).
      Automatically updates agents-cli-manifest.yaml `deployment_target: "agent_runtime"`
      if present, or passes `--entrypoint` if needed.

  publish-ge <APP_ID> <DISPLAY_NAME> <DESCRIPTION> [DEPLOYMENT_TARGET] [CARD_URL]
      Publish an Agent Runtime (`agent_runtime`) or Cloud Run (`cloud_run`) agent
      to Gemini Enterprise via `agents-cli publish gemini-enterprise`.

  update-cloudrun <SERVICE> <REGION> [--image <IMAGE>] [--env KEY=VAL,KEY2=VAL2]
      Safely update a Cloud Run service using --update-env-vars (NEVER --set-env-vars,
      which wipes existing DB_USER/DB_PASSWORD/VPC variables).

  register-a2a <SERVICE_ID> <SERVICE_OR_CARD_URL> [REGION] [DISPLAY_NAME] [DESCRIPTION]
      Fetch an A2A agent card (with Bearer identity token, checking both
      `/a2a/app/.well-known/agent-card.json` and `/.well-known/agent-card.json`),
      strip `.supportedInterfaces, .additionalInterfaces` via jq, and register via
      `gcloud agent-registry services create --agent-spec-type=a2a-agent-card`.

  create-model-armor <TEMPLATE_ID> [REGION] [--output-safe]
      Configure regional Model Armor REP endpoint (`https://modelarmor.<REGION>.rep.googleapis.com/`)
      and create a defense template (pass `--output-safe` for response templates where
      Jailbreak filtering should be disabled to avoid false positives).
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

SUBCMD="${1}"
shift

PROJECT_ID="${GOOGLE_CLOUD_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"

case "${SUBCMD}" in
  enable-apis)
    PID="${1:-${PROJECT_ID}}"
    echo "[hl-adk] Enabling core Google Cloud AI, Discovery Engine & Serverless APIs on ${PID}..."
    gcloud services enable \
      aiplatform.googleapis.com \
      run.googleapis.com \
      artifactregistry.googleapis.com \
      cloudbuild.googleapis.com \
      secretmanager.googleapis.com \
      discoveryengine.googleapis.com \
      modelarmor.googleapis.com \
      agentregistry.googleapis.com \
      alloydb.googleapis.com \
      sqladmin.googleapis.com \
      --project="${PID}"
    echo "[hl-adk] APIs enabled."
    ;;

  doctor)
    echo "[hl-adk] Checking gcloud & agents-cli health..."
    gcloud config list
    if command -v agents-cli >/dev/null 2>&1; then
      agents-cli info 2>/dev/null || agents-cli doctor 2>/dev/null || agents-cli --version
    else
      echo "WARN: agents-cli is not installed on PATH."
    fi
    ;;

  scaffold)
    NAME="${1:?Usage: hl-adk scaffold <NAME> [REGION] [--workflow]}"
    REGION="${2:-us-central1}"
    FLAG="${3:-}"
    if [[ "${FLAG}" == "--workflow" || "${REGION}" == "--workflow" ]]; then
      echo "[hl-adk] Scaffolding ADK workflow agent '${NAME}'..."
      agents-cli scaffold create "${NAME}" --adk
    else
      echo "[hl-adk] Scaffolding ADK prototype agent '${NAME}' in ${REGION}..."
      agents-cli create "${NAME}" --prototype --yes --region "${REGION}" 2>/dev/null || \
      agents-cli scaffold create "${NAME}" --agent adk --prototype
    fi
    echo "[hl-adk] Scaffolded ${NAME}. Ensure GOOGLE_GENAI_USE_VERTEXAI=True and GOOGLE_CLOUD_LOCATION=global in .env."
    ;;

  deploy-runtime)
    REGION="${1:-us-central1}"
    ENTRYPOINT="${2:-}"
    if [[ "${REGION}" == "global" ]]; then
      echo "ERROR: Agent Runtime deployment requires a regional endpoint (e.g. us-central1), NOT 'global'." >&2
      exit 1
    fi
    echo "[hl-adk] Running hl-verify before deploy..."
    "$(dirname "${BASH_SOURCE[0]}")/verify_lite.py" .
    if [[ -f "agents-cli-manifest.yaml" ]]; then
      sed -i 's/deployment_target: "none"/deployment_target: "agent_runtime"/g' agents-cli-manifest.yaml
      echo "[hl-adk] Updated agents-cli-manifest.yaml -> deployment_target: \"agent_runtime\""
      agents-cli deploy --project "${PROJECT_ID}"
    elif [[ -n "${ENTRYPOINT}" ]]; then
      agents-cli deploy agent-runtime \
        --project "${PROJECT_ID}" \
        --region "${REGION}" \
        --entrypoint "${ENTRYPOINT}" \
        --env-vars "GOOGLE_CLOUD_PROJECT=${PROJECT_ID},GOOGLE_CLOUD_LOCATION=global,GOOGLE_GENAI_USE_VERTEXAI=True"
    else
      agents-cli deploy --project "${PROJECT_ID}"
    fi
    ;;

  publish-ge)
    APP_ID="${1:?Usage: hl-adk publish-ge <APP_ID> <DISPLAY_NAME> <DESCRIPTION> [DEPLOYMENT_TARGET] [CARD_URL]}"
    DISPLAY_NAME="${2:?Missing DISPLAY_NAME}"
    DESCRIPTION="${3:?Missing DESCRIPTION}"
    TARGET="${4:-agent_runtime}"
    CARD_URL="${5:-}"
    CMD=(
      agents-cli publish gemini-enterprise
      --gemini-enterprise-app-id "${APP_ID}"
      --display-name "${DISPLAY_NAME}"
      --description "${DESCRIPTION}"
      --deployment-target "${TARGET}"
      --project-id "${PROJECT_ID}"
    )
    [[ -n "${CARD_URL}" ]] && CMD+=(--agent-card-url "${CARD_URL}")
    echo "[hl-adk] Publishing to Gemini Enterprise app '${APP_ID}'..."
    "${CMD[@]}"
    ;;

  update-cloudrun)
    SERVICE="${1:?Usage: hl-adk update-cloudrun <SERVICE> <REGION> [--image IMG] [--env K=V]}"
    REGION="${2:?Missing REGION}"
    shift 2
    IMAGE=""
    ENV_VARS=""
    while [[ $# -gt 0 ]]; do
      case "${1}" in
        --image) IMAGE="${2}"; shift 2 ;;
        --env)   ENV_VARS="${2}"; shift 2 ;;
        *) echo "Unknown arg: ${1}" >&2; exit 1 ;;
      esac
    done
    CMD=(gcloud run services update "${SERVICE}" --project="${PROJECT_ID}" --region="${REGION}")
    [[ -n "${IMAGE}" ]] && CMD+=(--image="${IMAGE}")
    # CRITICAL: Always use --update-env-vars, NEVER --set-env-vars
    [[ -n "${ENV_VARS}" ]] && CMD+=(--update-env-vars="${ENV_VARS}")
    echo "[hl-adk] Executing: ${CMD[*]}"
    "${CMD[@]}"
    ;;

  register-a2a)
    SERVICE_ID="${1:?Usage: hl-adk register-a2a <SERVICE_ID> <SERVICE_OR_CARD_URL> [REGION] [DISPLAY_NAME] [DESCRIPTION]}"
    RAW_URL="${2:?Missing SERVICE_OR_CARD_URL}"
    REGION="${3:-us-central1}"
    DISPLAY_NAME="${4:-${SERVICE_ID}}"
    DESCRIPTION="${5:-A2A Agent Service registered via do-harness-lite}"
    OUT_CARD="agent-card.json"

    TOKEN="$(gcloud auth print-identity-token 2>/dev/null || true)"
    AUTH_ARGS=()
    [[ -n "${TOKEN}" ]] && AUTH_ARGS=(-H "Authorization: Bearer ${TOKEN}")

    if [[ "${RAW_URL}" == *.json ]]; then
      CANDIDATE_URLS=("${RAW_URL}")
    else
      BASE_URL="${RAW_URL%/}"
      CANDIDATE_URLS=(
        "${BASE_URL}/a2a/app/.well-known/agent-card.json"
        "${BASE_URL}/.well-known/agent-card.json"
        "${BASE_URL}/.well-known/agent.json"
      )
    fi

    FETCHED=""
    for url in "${CANDIDATE_URLS[@]}"; do
      echo "[hl-adk] Probing A2A card at ${url}..."
      if RAW_JSON="$(curl -fsSL "${AUTH_ARGS[@]}" "${url}" 2>/dev/null)" && [[ -n "${RAW_JSON}" ]]; then
        echo "${RAW_JSON}" | jq 'del(.supportedInterfaces, .additionalInterfaces)' > "${OUT_CARD}"
        FETCHED="${url}"
        break
      fi
    done

    if [[ -z "${FETCHED}" ]]; then
      echo "ERROR: Could not fetch A2A agent card from any candidate URL: ${CANDIDATE_URLS[*]}" >&2
      exit 1
    fi

    echo "[hl-adk] Sanitized card saved to ${OUT_CARD} (from ${FETCHED}). Registering '${SERVICE_ID}' in ${REGION}..."
    gcloud agent-registry services create "${SERVICE_ID}" \
      --project="${PROJECT_ID}" \
      --location="${REGION}" \
      --display-name="${DISPLAY_NAME}" \
      --description="${DESCRIPTION}" \
      --agent-spec-type=a2a-agent-card \
      --agent-spec-content="${OUT_CARD}" || \
    gcloud agent-registry services update "${SERVICE_ID}" \
      --project="${PROJECT_ID}" \
      --location="${REGION}" \
      --display-name="${DISPLAY_NAME}" \
      --description="${DESCRIPTION}" \
      --clear-agent-spec \
      --agent-spec-type=a2a-agent-card \
      --agent-spec-content="${OUT_CARD}"
    ;;

  create-model-armor)
    TEMPLATE_ID="${1:?Usage: hl-adk create-model-armor <TEMPLATE_ID> [REGION] [--output-safe]}"
    REGION="${2:-us-central1}"
    MODE="${3:-}"
    REP_URL="https://modelarmor.${REGION}.rep.googleapis.com/"
    export CLOUDSDK_API_ENDPOINT_OVERRIDES_MODELARMOR="${REP_URL}"
    gcloud config set api_endpoint_overrides/modelarmor "${REP_URL}" >/dev/null 2>&1 || true

    echo "[hl-adk] Using Regional Model Armor REP endpoint: ${REP_URL}"
    RAI_FILTERS='[{"filterType":"HATE_SPEECH","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"DANGEROUS","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"HARASSMENT","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"SEXUALLY_EXPLICIT","confidenceLevel":"MEDIUM_AND_ABOVE"}]'

    if [[ "${MODE}" == "--output-safe" ]]; then
      echo "[hl-adk] Creating OUTPUT-safe Model Armor template '${TEMPLATE_ID}' (Jailbreak filter OFF to prevent false positives)..."
      gcloud model-armor templates create "${TEMPLATE_ID}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}" \
        --rai-settings-filters="${RAI_FILTERS}" \
        --malicious-uri-filter-settings-enforcement=ENABLED \
        --basic-config-filter-enforcement=ENABLED
    else
      echo "[hl-adk] Creating INPUT Model Armor template '${TEMPLATE_ID}' (RAI + PI/Jailbreak + Malicious URI)..."
      gcloud model-armor templates create "${TEMPLATE_ID}" \
        --project="${PROJECT_ID}" \
        --location="${REGION}" \
        --rai-settings-filters="${RAI_FILTERS}" \
        --pi-and-jailbreak-filter-settings-enforcement=ENABLED \
        --pi-and-jailbreak-filter-settings-confidence-level=LOW_AND_ABOVE \
        --malicious-uri-filter-settings-enforcement=ENABLED \
        --basic-config-filter-enforcement=ENABLED
    fi
    echo "[hl-adk] Template resource: projects/${PROJECT_ID}/locations/${REGION}/templates/${TEMPLATE_ID}"
    ;;

  *)
    usage
    exit 1
    ;;
esac
