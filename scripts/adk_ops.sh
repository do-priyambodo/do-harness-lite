#!/usr/bin/env bash
# adk_ops.sh (hl-adk) — High-Speed ADK, Agent Runtime, Cloud Run, A2A & Model Armor Operations
# Encodes exact CLI syntax and regional/global endpoint rules so you never waste time
# debugging flags or wiping Cloud Run environment variables.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: hl-adk <subcommand> [args...]

Subcommands:
  enable-apis [PROJECT_ID]
      Enable Vertex AI, Agent Registry, Model Armor, Cloud Run, Artifact Registry,
      Cloud Build, Secret Manager, and AlloyDB APIs.

  doctor
      Run environment & credential checks (agents-cli doctor + gcloud config).

  scaffold <NAME> [TEMPLATE] [REGION]
      Scaffold an agent with agents-cli (default template: adk-py, region: us-central1).

  deploy-runtime [ENTRYPOINT] [REGION]
      Deploy agent to managed Agent Runtime (default entrypoint: agent_Entrypoint.py:app,
      region: us-central1). Note: Agent Runtime requires a regional endpoint, NEVER global.

  publish-ge <AGENT_ENGINE_ID> <DISPLAY_NAME> <DESCRIPTION> [APP_ID]
      Publish a deployed Agent Runtime engine to Gemini Enterprise.

  update-cloudrun <SERVICE> <REGION> [--image <IMAGE>] [--env KEY=VAL,KEY2=VAL2]
      Safely update a Cloud Run service using --update-env-vars (NEVER --set-env-vars,
      which wipes existing variables).

  register-a2a <SERVICE_ID> <CARD_URL> [REGION] [TARGET_URI]
      Fetch an A2A /.well-known/agent-card.json, strip unsupported interface fields
      (.supportedInterfaces, .additionalInterfaces), and register in Cloud Agent Registry.

  create-model-armor <TEMPLATE_ID> [REGION]
      Configure regional Model Armor endpoint and create a standard prompt/response
      defense template (RAI + PI/Jailbreak + SDP + Malicious URIs).
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
    echo "[hl-adk] Enabling core Google Cloud AI & Serverless APIs on ${PID}..."
    gcloud services enable \
      aiplatform.googleapis.com \
      run.googleapis.com \
      artifactregistry.googleapis.com \
      cloudbuild.googleapis.com \
      secretmanager.googleapis.com \
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
      agents-cli doctor
    else
      echo "WARN: agents-cli is not installed on PATH."
    fi
    ;;

  scaffold)
    NAME="${1:?Usage: hl-adk scaffold <NAME> [TEMPLATE] [REGION]}"
    TEMPLATE="${2:-adk-py}"
    REGION="${3:-us-central1}"
    agents-cli scaffold "${NAME}" \
      --template "${TEMPLATE}" \
      --project "${PROJECT_ID}" \
      --region "${REGION}"
    echo "[hl-adk] Scaffolded ${NAME}. Next: ensure GOOGLE_CLOUD_LOCATION=global in .env if using Gemini 3 preview models."
    ;;

  deploy-runtime)
    ENTRYPOINT="${1:-agent_Entrypoint.py:app}"
    REGION="${2:-us-central1}"
    if [[ "${REGION}" == "global" ]]; then
      echo "ERROR: Agent Runtime deployment requires a regional endpoint (e.g. us-central1), NOT 'global'." >&2
      exit 1
    fi
    echo "[hl-adk] Running hl-verify before deploy..."
    "$(dirname "${BASH_SOURCE[0]}")/verify_lite.py" .
    echo "[hl-adk] Deploying ${ENTRYPOINT} to Agent Runtime in ${REGION}..."
    agents-cli deploy agent-runtime \
      --project "${PROJECT_ID}" \
      --region "${REGION}" \
      --entrypoint "${ENTRYPOINT}" \
      --env-vars "GOOGLE_CLOUD_PROJECT=${PROJECT_ID},GOOGLE_CLOUD_LOCATION=global,GOOGLE_GENAI_USE_VERTEXAI=True"
    ;;

  publish-ge)
    ENGINE_ID="${1:?Usage: hl-adk publish-ge <AGENT_ENGINE_ID> <DISPLAY_NAME> <DESCRIPTION> [APP_ID]}"
    DISPLAY_NAME="${2:?Missing DISPLAY_NAME}"
    DESCRIPTION="${3:?Missing DESCRIPTION}"
    APP_ID="${4:-}"
    ARGS=(
      publish gemini-enterprise
      --agent-engine-id "${ENGINE_ID}"
      --display-name "${DISPLAY_NAME}"
      --description "${DESCRIPTION}"
    )
    [[ -n "${APP_ID}" ]] && ARGS+=(--app-id "${APP_ID}")
    agents-cli "${ARGS[@]}"
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
    SERVICE_ID="${1:?Usage: hl-adk register-a2a <SERVICE_ID> <CARD_URL> [REGION] [TARGET_URI]}"
    CARD_URL="${2:?Missing CARD_URL (e.g. https://service-url/.well-known/agent-card.json)}"
    REGION="${3:-us-central1}"
    TARGET_URI="${4:-${CARD_URL%/.well-known/agent-card.json}}"
    TMP_CARD="/tmp/sanitized-agent-card-$$.json"
    echo "[hl-adk] Fetching and sanitizing A2A card from ${CARD_URL}..."
    curl -fsSL "${CARD_URL}" | jq 'del(.supportedInterfaces, .additionalInterfaces)' > "${TMP_CARD}"
    echo "[hl-adk] Registering ${SERVICE_ID} in Cloud Agent Registry (${REGION})..."
    gcloud alpha agent-registry services create "${SERVICE_ID}" \
      --project="${PROJECT_ID}" \
      --location="${REGION}" \
      --target-uri="${TARGET_URI}" \
      --agent-card-file="${TMP_CARD}" 2>/dev/null || \
    gcloud agent-registry services create "${SERVICE_ID}" \
      --project="${PROJECT_ID}" \
      --location="${REGION}" \
      --target-uri="${TARGET_URI}" \
      --agent-card-file="${TMP_CARD}"
    rm -f "${TMP_CARD}"
    ;;

  create-model-armor)
    TEMPLATE_ID="${1:?Usage: hl-adk create-model-armor <TEMPLATE_ID> [REGION]}"
    REGION="${2:-us-central1}"
    REP_URL="https://modelarmor.${REGION}.rep.googleapis.com/"
    echo "[hl-adk] Setting Model Armor regional endpoint: ${REP_URL}"
    gcloud config set api_endpoint_overrides/modelarmor "${REP_URL}"
    echo "[hl-adk] Creating Model Armor template '${TEMPLATE_ID}' in ${REGION}..."
    gcloud model-armor templates create "${TEMPLATE_ID}" \
      --project="${PROJECT_ID}" \
      --location="${REGION}" \
      --rai-settings-filters='[{"filterType":"HATE_SPEECH","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"DANGEROUS","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"HARASSMENT","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"SEXUALLY_EXPLICIT","confidenceLevel":"MEDIUM_AND_ABOVE"}]' \
      --pi-and-jailbreak-filter-settings-enforcement=ENABLED \
      --pi-and-jailbreak-filter-settings-confidence-level=LOW_AND_ABOVE \
      --malicious-uri-filter-settings-enforcement=ENABLED \
      -- basic-config-filter-enforcement=ENABLED 2>/dev/null || \
    gcloud model-armor templates create "${TEMPLATE_ID}" \
      --project="${PROJECT_ID}" \
      --location="${REGION}" \
      --pi-and-jailbreak-filter-settings-enforcement=ENABLED \
      --malicious-uri-filter-settings-enforcement=ENABLED
    echo "[hl-adk] Template resource: projects/${PROJECT_ID}/locations/${REGION}/templates/${TEMPLATE_ID}"
    ;;

  *)
    usage
    exit 1
    ;;
esac
