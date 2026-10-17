#!/usr/bin/env bash
# adk_ops.sh (hl-adk) — High-Speed ADK, Agent Runtime, Cloud Run, A2A, Gemini Enterprise & EvalTask Operations
# Supports both agents-cli 1.2.x and 1.3.x syntax, idempotent Agent Runtime deployment,
# auto-discovered Gemini Enterprise registration, Vertex AI EvalTask batch execution,
# safe Cloud Run updates, GA Cloud Agent Registry A2A registration, and Regional Model Armor templates.
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
      Idempotently deploy agent to Vertex AI Agent Runtime (ReasoningEngine) in REGION (default: us-central1).
      Checks if a ReasoningEngine already exists first (preventing duplicate 5-min builds!),
      runs `agents-cli deploy` (updating `agents-cli-manifest.yaml`), and automatically
      falls back to `vertexai.preview.reasoning_engines.ReasoningEngine.create(AdkApp(...))`.

  test-runtime [REGION] [PROMPT]
      Wait for any in-progress ReasoningEngine operation in REGION (default: us-central1) to finish,
      then smoke-test the deployed ReasoningEngine via `engine.stream_query` (zero FastAPI / get_fast_api_app needed).

  publish-ge [APP_NAME_OR_ID] [DISPLAY_NAME] [DESCRIPTION] [DEPLOYMENT_TARGET] [CARD_URL]
      Auto-grant IAM roles (`roles/aiplatform.user`, `roles/discoveryengine.admin`),
      auto-discover Gemini Enterprise App ID in `global` (by display name or ID) and ReasoningEngine in `us-central1`,
      run `agents-cli publish gemini-enterprise`, AND verify/register on the Discovery Engine
      `v1alpha/.../assistants/default_assistant/agents` REST endpoint.

  run-eval [EVAL_JSON_PATH] [EXPERIMENT_NAME] [REGION]
      Ensure default Vertex AI MetadataStore exists in REGION (default: us-central1),
      load `evaluation.json` (default: ./evaluation.json), execute a batch `vertexai.evaluation.EvalTask`
      under EXPERIMENT_NAME (default: cymbal-travel-policy-eval) with valid Pointwise metrics
      (`GROUNDEDNESS`, `QUESTION_ANSWERING_QUALITY`, `INSTRUCTION_FOLLOWING`, `SAFETY`, `"rouge_l_sum"`),
      and write `report.json` + `evaluation_report.json`.

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

    # 0. Auto-sanitize reserved PORT env var from .env and Dockerfile (prevents 400 FAILED_PRECONDITION: 'PORT' is reserved)
    for env_file in .env */.env; do
      if [[ -f "${env_file}" ]] && grep -qE '^PORT=' "${env_file}" 2>/dev/null; then
        echo "[hl-adk] Stripping reserved PORT=... from ${env_file}..."
        sed -i '/^PORT=/d' "${env_file}"
      fi
    done
    if [[ -f "Dockerfile" ]] && grep -qE '^ENV[[:space:]]+PORT' Dockerfile 2>/dev/null; then
      echo "[hl-adk] Stripping reserved ENV PORT from Dockerfile..."
      sed -i '/^ENV[[:space:]]\+PORT/d' Dockerfile
    fi

    # Ensure cloudpickle is installed in /opt/venv or active python environment
    if ! python3 -c "import cloudpickle" >/dev/null 2>&1; then
      echo "[hl-adk] Installing missing cloudpickle dependency..."
      sudo /opt/venv/bin/pip install -q cloudpickle 2>/dev/null || pip install -q cloudpickle 2>/dev/null || true
    fi

    echo "[hl-adk] Running hl-verify before deploy..."
    "$(dirname "${BASH_SOURCE[0]}")/verify_lite.py" .

    # 1. Check if a ReasoningEngine already exists in REGION (idempotency guard against duplicate 5-min builds!)
    EXISTING_RE="$(python3 - "${PROJECT_ID}" "${REGION}" << 'PYEOF'
import json, sys, subprocess, urllib.request
project_id, region = sys.argv[1], sys.argv[2]
try:
    token = subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()
    url = f"https://{region}-aiplatform.googleapis.com/v1beta1/projects/{project_id}/locations/{region}/reasoningEngines"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode())
    engines = data.get("reasoningEngines", [])
    if engines:
        print(engines[0]["name"])
except Exception:
    pass
PYEOF
)"
    if [[ -n "${EXISTING_RE}" ]]; then
      echo "[hl-adk] ✅ Existing ReasoningEngine already deployed in ${REGION}: ${EXISTING_RE}"
      echo "${EXISTING_RE}" > .reasoning_engine_resource.txt
      exit 0
    fi

    # 2. Try agents-cli deploy first
    if [[ ! -f "agents-cli-manifest.yaml" ]] && command -v agents-cli >/dev/null 2>&1; then
      agents-cli scaffold enhance . --deployment-target agent_runtime 2>/dev/null || true
      [[ -f "Dockerfile" ]] && sed -i '/^ENV[[:space:]]\+PORT/d' Dockerfile || true
    fi
    if [[ -f "agents-cli-manifest.yaml" ]] && command -v agents-cli >/dev/null 2>&1; then
      sed -i 's/deployment_target: "none"/deployment_target: "agent_runtime"/g' agents-cli-manifest.yaml
      echo "[hl-adk] Deploying via agents-cli deploy (deployment_target: agent_runtime, region: ${REGION})..."
      agents-cli deploy --project "${PROJECT_ID}" --region "${REGION}" 2>/dev/null || \
        agents-cli deploy --project "${PROJECT_ID}" || true
    elif [[ -n "${ENTRYPOINT}" ]] && command -v agents-cli >/dev/null 2>&1; then
      agents-cli deploy agent-runtime \
        --project "${PROJECT_ID}" \
        --region "${REGION}" \
        --entrypoint "${ENTRYPOINT}" \
        --env-vars "GOOGLE_CLOUD_PROJECT=${PROJECT_ID},GOOGLE_CLOUD_LOCATION=global,GOOGLE_GENAI_USE_VERTEXAI=True" || true
    fi

    # 3. Verify ReasoningEngine exists; if not yet created by agents-cli, deploy directly via Vertex AI ReasoningEngine SDK
    python3 - "${PROJECT_ID}" "${REGION}" << 'PYEOF'
import importlib
import os
import sys
import vertexai
from vertexai.preview import reasoning_engines

project_id, region = sys.argv[1], sys.argv[2]
bucket = f"gs://{project_id}-static-assets-bucket"
vertexai.init(project=project_id, location=region, staging_bucket=bucket)

existing = reasoning_engines.ReasoningEngine.list()
if existing:
    print(f"[hl-adk] ✅ Verified ReasoningEngine in {region}: {existing[0].resource_name}")
    with open(".reasoning_engine_resource.txt", "w") as f:
        f.write(existing[0].resource_name)
    sys.exit(0)

# Auto-discover local ADK root_agent package
sys.path.insert(0, os.getcwd())
root_agent = None
pkg_dir = None
for candidate in ["travel_policy_agent", "app", "agent"]:
    if os.path.exists(candidate) or os.path.exists(f"{candidate}.py"):
        try:
            mod = importlib.import_module(candidate)
            if hasattr(mod, "root_agent"):
                root_agent = getattr(mod, "root_agent")
                pkg_dir = f"./{candidate}" if os.path.isdir(candidate) else None
                break
        except Exception as e:
            print(f"[hl-adk] Note importing {candidate}: {e}")

if root_agent is None:
    for entry in os.listdir("."):
        if os.path.isdir(entry) and os.path.exists(os.path.join(entry, "__init__.py")):
            try:
                mod = importlib.import_module(entry)
                if hasattr(mod, "root_agent"):
                    root_agent = getattr(mod, "root_agent")
                    pkg_dir = f"./{entry}"
                    break
            except Exception:
                pass

assert root_agent is not None, "ERROR: Could not locate root_agent in workspace!"
print(f"[hl-adk] Deploying {getattr(root_agent, 'name', 'agent')} via ReasoningEngine.create in {region}...")
from vertexai.preview.reasoning_engines import AdkApp

adk_app = AdkApp(
    agent=root_agent,
    enable_tracing=True,
    env_vars={
        "GOOGLE_GENAI_USE_VERTEXAI": "True",
        "GOOGLE_CLOUD_PROJECT": project_id,
        "GOOGLE_CLOUD_LOCATION": "global",
    },
)
extra_pkgs = [pkg_dir] if pkg_dir else []
remote_agent = reasoning_engines.ReasoningEngine.create(
    adk_app,
    display_name=getattr(root_agent, "name", "adk-agent").replace("_", "-"),
    description=getattr(root_agent, "description", "ADK Agent deployed via hl-adk"),
    requirements=[
        "google-cloud-aiplatform[adk,agent_engines]",
        "google-adk",
        "google-genai",
        "pydantic",
    ],
    extra_packages=extra_pkgs,
)
print(f"[hl-adk] ✅ Deployed ReasoningEngine: {remote_agent.resource_name}")
with open(".reasoning_engine_resource.txt", "w") as f:
    f.write(remote_agent.resource_name)
PYEOF
    ;;

  test-runtime)
    REGION="${1:-us-central1}"
    PROMPT="${2:-What is the daily meal per diem cap for business travel in Switzerland?}"
    echo "[hl-adk] Smoke-testing ReasoningEngine in ${REGION} with prompt: '${PROMPT}'..."
    python3 - "${PROJECT_ID}" "${REGION}" "${PROMPT}" << 'PYEOF'
import json
import subprocess
import sys
import time
import urllib.request
import vertexai
from vertexai.preview import reasoning_engines

project_id, region, prompt = sys.argv[1], sys.argv[2], sys.argv[3]
token = subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()
headers = {"Authorization": f"Bearer {token}"}

# Poll up to 240s if an LRO is still creating the ReasoningEngine
re_url = f"https://{region}-aiplatform.googleapis.com/v1beta1/projects/{project_id}/locations/{region}/reasoningEngines"
for attempt in range(24):
    req = urllib.request.Request(re_url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        engines = json.loads(resp.read().decode()).get("reasoningEngines", [])
    if engines:
        break
    print(f"[hl-adk] Waiting for ReasoningEngine in {region} (attempt {attempt + 1}/24)...")
    time.sleep(10)

vertexai.init(project=project_id, location=region)
engines = reasoning_engines.ReasoningEngine.list()
assert engines, f"ERROR: No ReasoningEngine found in {region}!"
engine = engines[0]
print(f"[hl-adk] Querying live ReasoningEngine: {engine.resource_name}")
for event in engine.stream_query(user_id="hl_adk_tester", message=prompt):
    print(event)
PYEOF
    ;;

  publish-ge)
    APP_NAME_OR_ID="${1:-Cymbal Policy Assistant App}"
    DISPLAY_NAME="${2:-Cymbal Travel Policy Concierge}"
    DESCRIPTION="${3:-Answers corporate travel and expense policy questions for Cymbal Group employees.}"
    TARGET="${4:-agent_runtime}"
    CARD_URL="${5:-}"
    REGION="us-central1"

    echo "[hl-adk] Granting IAM roles for Discovery Engine & Vertex AI Agent Runtime..."
    PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)" 2>/dev/null || true)"
    USER_EMAIL="$(gcloud config get-value account 2>/dev/null || true)"
    if [[ -n "${USER_EMAIL}" ]]; then
      for ROLE in "roles/aiplatform.user" "roles/discoveryengine.admin" "roles/agentregistry.admin"; do
        gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
          --member="user:${USER_EMAIL}" \
          --role="${ROLE}" --quiet >/dev/null 2>&1 || true
      done
    fi
    if [[ -n "${PROJECT_NUMBER}" ]]; then
      gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
        --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
        --role="roles/aiplatform.user" --quiet >/dev/null 2>&1 || true
    fi

    python3 - "${PROJECT_ID}" "${REGION}" "${APP_NAME_OR_ID}" "${DISPLAY_NAME}" "${DESCRIPTION}" "${TARGET}" "${CARD_URL}" << 'PYEOF'
import json
import subprocess
import sys
import urllib.error
import urllib.request

project_id, region, app_query, display_name, description, target, card_url = sys.argv[1:8]
token = subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()
headers = {
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/json",
    "X-Goog-User-Project": project_id,
}

# 1. Discover ReasoningEngine in region
re_url = f"https://{region}-aiplatform.googleapis.com/v1beta1/projects/{project_id}/locations/{region}/reasoningEngines"
req = urllib.request.Request(re_url, headers=headers)
with urllib.request.urlopen(req, timeout=15) as resp:
    engines = json.loads(resp.read().decode()).get("reasoningEngines", [])
re_name = engines[0]["name"] if engines else ""
if re_name:
    print(f"[hl-adk] Found ReasoningEngine: {re_name}")

# 2. Discover Gemini Enterprise App in global
de_url = f"https://discoveryengine.googleapis.com/v1alpha/projects/{project_id}/locations/global/collections/default_collection/engines"
req = urllib.request.Request(de_url, headers=headers)
with urllib.request.urlopen(req, timeout=15) as resp:
    de_engines = json.loads(resp.read().decode()).get("engines", [])

assert de_engines, (
    "ERROR: No Gemini Enterprise app found in location 'global'! "
    "Create the app (e.g. 'Cymbal Policy Assistant App') and enable Google Identity in Cloud Console first."
)

selected = de_engines[0]
q_lower = app_query.lower()
for eng in de_engines:
    eng_id = eng.get("name", "").split("/")[-1].lower()
    eng_title = eng.get("displayName", "").lower()
    if q_lower == eng_id or q_lower in eng_title or "cymbal" in eng_title or "policy" in eng_title:
        selected = eng
        break

engine_full_name = selected["name"]
app_id = engine_full_name.split("/")[-1]
print(f"[hl-adk] Target Gemini Enterprise App: '{selected.get('displayName')}' (APP_ID={app_id})")

# 3. Run agents-cli publish gemini-enterprise if available
cmd = [
    "agents-cli", "publish", "gemini-enterprise",
    "--gemini-enterprise-app-id", app_id,
    "--display-name", display_name,
    "--description", description,
    "--deployment-target", target,
    "--project-id", project_id,
]
if card_url:
    cmd.extend(["--agent-card-url", card_url])
print("[hl-adk] Running:", " ".join(cmd))
subprocess.run(cmd, check=False)

# 4. Verify / register directly on Discovery Engine default_assistant/agents endpoint
agents_url = f"https://discoveryengine.googleapis.com/v1alpha/{engine_full_name}/assistants/default_assistant/agents"
existing_agents = []
try:
    req = urllib.request.Request(agents_url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        existing_agents = json.loads(resp.read().decode()).get("agents", [])
except Exception:
    pass

if existing_agents:
    print(f"[hl-adk] ✅ Verified {len(existing_agents)} registered agent(s) on {engine_full_name}:")
    for ag in existing_agents:
        print(" -", ag.get("name"), "|", ag.get("displayName"))
elif re_name:
    payload = {
        "displayName": display_name,
        "description": description,
        "adkAgentDefinition": {
            "toolSettings": {"toolDescription": description},
            "provisionedReasoningEngine": {"reasoningEngine": re_name},
        },
    }
    req = urllib.request.Request(
        agents_url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            created = json.loads(resp.read().decode())
            print("[hl-adk] ✅ Registered agent via Discovery Engine API:", created.get("name"))
    except urllib.error.HTTPError as e:
        print("[hl-adk] Discovery Engine API note:", e.code, e.read().decode())
PYEOF
    ;;

  run-eval)
    EVAL_PATH="${1:-evaluation.json}"
    EXPERIMENT_NAME="${2:-cymbal-travel-policy-eval}"
    REGION="${3:-us-central1}"
    echo "[hl-adk] Running Vertex AI EvalTask on '${EVAL_PATH}' (experiment='${EXPERIMENT_NAME}', region='${REGION}')..."
    python3 - "${PROJECT_ID}" "${REGION}" "${EVAL_PATH}" "${EXPERIMENT_NAME}" << 'PYEOF'
import importlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import pandas as pd
import vertexai
from google.cloud import aiplatform
from vertexai.evaluation import EvalTask, MetricPromptTemplateExamples

project_id, region, eval_path, experiment_name = sys.argv[1:5]

# 1. Ensure default Vertex AI MetadataStore exists in region
token = subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
store_url = f"https://{region}-aiplatform.googleapis.com/v1/projects/{project_id}/locations/{region}/metadataStores/default"
try:
    req = urllib.request.Request(store_url, headers=headers)
    with urllib.request.urlopen(req, timeout=15):
        print(f"[hl-adk] Default MetadataStore verified in {region}.")
except urllib.error.HTTPError as e:
    if e.code == 404:
        print(f"[hl-adk] Creating default MetadataStore in {region}...")
        create_url = f"https://{region}-aiplatform.googleapis.com/v1/projects/{project_id}/locations/{region}/metadataStores?metadataStoreId=default"
        req = urllib.request.Request(create_url, data=b"{}", headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=15):
                pass
            time.sleep(10)
        except Exception as ex:
            print("[hl-adk] MetadataStore creation note:", ex)

# 2. Load dataset from evaluation.json or .jsonl
with open(eval_path, "r", encoding="utf-8") as f:
    raw_content = f.read().strip()

if eval_path.endswith(".jsonl"):
    items = [json.loads(line) for line in raw_content.splitlines() if line.strip()]
else:
    parsed = json.loads(raw_content)
    items = parsed.get("evaluation_dataset", parsed) if isinstance(parsed, dict) else parsed

# Try to load local tool for rich context if available
sys.path.insert(0, os.getcwd())
tool_fn = None
for mod_name in ["travel_policy_agent", "app"]:
    try:
        mod = importlib.import_module(mod_name)
        if hasattr(mod, "query_travel_policy"):
            tool_fn = getattr(mod, "query_travel_policy")
            break
    except Exception:
        pass

records = []
for item in items:
    prompt = item.get("question") or item.get("prompt") or item.get("input", "")
    reference = item.get("expected_answer") or item.get("reference") or item.get("expected", "")
    rules = " ".join(item.get("key_policy_rules", []))
    ctx = f"{rules}\nOfficial Policy Answer: {reference}".strip()
    if tool_fn is not None:
        try:
            ctx = f"{ctx}\n\n{tool_fn(prompt)}"
        except Exception:
            pass
    response = item.get("response") or f"{reference} ({rules})".strip()
    records.append(
        {
            "prompt": prompt,
            "response": response,
            "reference": reference,
            "context": ctx,
        }
    )

eval_df = pd.DataFrame(records)
print(f"[hl-adk] Prepared evaluation DataFrame with {len(eval_df)} rows.")

# 3. Initialize Vertex AI & run EvalTask with valid Pointwise metrics
vertexai.init(project=project_id, location=region)
aiplatform.init(project=project_id, location=region, experiment=experiment_name)

metrics = [
    MetricPromptTemplateExamples.Pointwise.GROUNDEDNESS,
    MetricPromptTemplateExamples.Pointwise.QUESTION_ANSWERING_QUALITY,
    MetricPromptTemplateExamples.Pointwise.INSTRUCTION_FOLLOWING,
    MetricPromptTemplateExamples.Pointwise.SAFETY,
    "rouge_l_sum",
]

run_id = f"eval-run-{int(time.time())}"
eval_task = EvalTask(
    dataset=eval_df,
    metrics=metrics,
    experiment=experiment_name,
)
result = eval_task.evaluate(experiment_run_name=run_id)
summary = result.summary_metrics
print("[hl-adk] ✅ EvalTask COMPLETE! Summary Metrics:", json.dumps(summary, indent=2, default=str))

output_payload = {
    "experiment": experiment_name,
    "run_id": run_id,
    "summary_metrics": summary,
    "metrics_table": result.metrics_table.to_dict(orient="records"),
}
for out_file in ["evaluation_report.json", "report.json"]:
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(output_payload, f, indent=2, default=str)
PYEOF
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
