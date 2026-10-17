# AGENTS.md — Rapid ADK & Cloud Engineering Harness (`do-harness-lite`)

## 0. Workspace Specification Precedence (Always Inspect First)
1. **Local Specs Win**: Before editing any file, inspect the workspace (`ls -la`, `spec.md`, `PRD.md`, `README.md`, `GEMINI.md`, `.agents/CONTEXT.md`, `triage/briefs/*.md`, `pyproject.toml`, `agents-cli-manifest.yaml`).
2. **Preserve Contracts**: Never rename required entry-point files (`app/agent.py`, `main.py`, `<pkg>/__init__.py`), exported symbols (`root_agent`, `app`), function names, parameter names, or port numbers (`8000`, `8080`, `3002`, `5000`) expected by local test or verification scripts.
3. **Preserve Existing Guardrails**: If the workspace already contains `GEMINI.md`, `.agents/CONTEXT.md`, `.agents/hooks.json`, or `.pre-commit-config.yaml`, keep them intact and additive.

## 1. Google ADK & Vertex AI Runtime Invariants (`RULES-AI` Exam-Speed Edition)
- **Model Selection & Lab Provisioned Throughput Precedence**:
  - **Lab Grader & Provisioned Throughput Win First**: In Qwiklabs / Challenge Labs, **always preserve the exact model specified in `spec.md`, `.env`, or starter code** (e.g., `gemini-3.6-flash` on `global`, which has Provisioned Throughput enabled to prevent `429 Resource Exhausted`). NEVER change the model name unless explicitly instructed.
  - **When Unspecified**: Default to `gemini-3.8-flash` (fast/sub-agent) or `gemini-4-argon` (complex orchestrator) on `GOOGLE_CLOUD_LOCATION="global"`.
- **Anti-"Decorative ADK" & Canonical `agents-cli` Contract (`app/agent.py`)**:
  - **No Raw `generate_content` or Hollow `root_agent`**: Never call `client.models.generate_content()` directly inside an agent module (`app/agent.py` or `<pkg>/__init__.py`), and never export a hollow `root_agent = Agent(...)` with `tools=[]` and `sub_agents=[]`.
  - **Export BOTH `root_agent` and `app`**: In `app/agent.py` (and `<pkg>/__init__.py`), always export `root_agent = Agent(...)` AND `from google.adk.apps import App; app = App(root_agent=root_agent, name="app")` so `agents-cli deploy` (`FROM python:3.12-slim` container build) and `agents-cli playground` work on the first try without Python 3.14 `cloudpickle` (`Code 13`) failures.
  - **Thinking Token Budget & Tool Safety**: When setting `generate_content_config`, use `types.GenerateContentConfig(max_output_tokens=32768)` so thinking tokens never truncate output (`MAX_TOKENS`). Never pass user/LLM input to `eval()`, `exec()`, `subprocess.run(..., shell=True)`, or unparameterized SQL strings.
- **Global vs. Regional Endpoint Split**:
  - **Gemini Model Inference**: When using **`Gemini 4 Argon` (`gemini-4-argon`)**, **`Gemini 3.8 Flash` (`gemini-3.8-flash`)**, or legacy lab models (`gemini-3.6-flash`, `gemini-3.1-pro-preview`, `gemini-3-flash-preview`) on Vertex AI, set `GOOGLE_GENAI_USE_VERTEXAI="True"` and `GOOGLE_CLOUD_LOCATION="global"` in `.env` (or `os.environ` before initializing `genai.Client()` / `Agent()`).
  - **Agent Runtime (`ReasoningEngine`), Vertex AI `EvalTask`, & Cloud Run**: Always use the **regional** location (`us-central1`, `europe-west1`, etc.) in `agents-cli-manifest.yaml`, `--region`, and `vertexai.init(project=..., location=...)`.
  - **Model Armor**: Always use the regional REP endpoint `modelarmor.<region>.rep.googleapis.com` (`ClientOptions(api_endpoint=f"modelarmor.{location}.rep.googleapis.com")`).
- **Agent Identifier Naming**: Every `Agent(name=...)`, `LlmAgent`, `SequentialAgent`, `ParallelAgent`, and `LoopAgent` MUST use a valid Python identifier with **underscores, never hyphens** (`^[a-zA-Z_][a-zA-Z0-9_]*$`).
- **Python Function Tools (`tools=[...]`)**:
  - Every tool function MUST have explicit parameter type annotations, a return type annotation, and a docstring describing *when* and *why* to call it (plus an `Args:` block).
  - Never use non-existent decorators like `@root_agent.skill` or `@agent.tool`; pass plain typed functions directly into `tools=[my_func]`.
  - Define all tool functions and callbacks **above** the `Agent(...)` constructor that references them.
- **Multi-Agent Routing & Single-Parent Rule**:
  - Every specialist agent in `sub_agents=[...]` or `AgentTool(agent=...)` MUST have a clear, non-overlapping `description`.
  - In ADK, an `Agent` instance can belong to **at most one `parent_agent`**. Never pass the same sub-agent instance to two parents; instantiate fresh instances via a factory function if needed.
  - When mixing `VertexAiSearchTool` with custom Python function tools on a root agent, wrap the `VertexAiSearchTool` agent inside `AgentTool(agent=search_agent)` in `tools=[...]`.
- **Session State Placeholders & Scoping**:
  - Always append a trailing `?` to state placeholders in `instruction=` strings (e.g., `{intake_summary?}`) so Turn 1 never fails with `KeyError` before a tool or upstream agent populates the key.
  - In `SequentialAgent`, ensure Step 1 sets `output_key="my_key"` when Step 2 references `{my_key?}`.
  - Use the 4 ADK state scopes deliberately: unprefixed `state["k"]` (current session), `state["user:k"]` (cross-session per user), `state["app:k"]` (global app), `state["temp:k"]` (current turn only).
- **ADK Callback Return Semantics**:
  - `before_tool_callback(tool: BaseTool, args: dict, tool_context: ToolContext) -> dict | None`: Return `None` to **allow** tool execution; return a `dict` (e.g., `{"status": "error", "reason": "Blocked by policy"}`) to **block/short-circuit** the tool call.
  - `before_model_callback(callback_context: CallbackContext, llm_request: LlmRequest) -> LlmResponse | None`: Mutate `llm_request.contents` in place and return `None` to proceed to the model, or return an `LlmResponse` to short-circuit inference.
- **Deployment Target Separation (`Agent Runtime` vs. `Cloud Run` — NEVER MIX)**:
  - **Target A — Vertex AI Agent Runtime (`ReasoningEngine` / `deployment_target: "agent_runtime"`)**:
    - **NEVER set `PORT` in `.env`, `Dockerfile`, or `env_vars`**: `PORT` is a reserved environment variable on Agent Runtime / Cloud Run (`400 FAILED_PRECONDITION: Environment variable name 'PORT' is reserved`). Remove `PORT` from `.env` and `Dockerfile` before running `agents-cli deploy`.
    - **NEVER use `__file__` inside Tool Functions (`Code 13` Pickle Trap)**: When `ReasoningEngine.create` / `client.agent_engines.create` serializes a tool function with `cloudpickle`, `__file__` either raises `NameError` in the remote container or hardcodes the local VM path (`/config/Desktop/...`), causing `Code 13: Reasoning Engine failed to deploy`. Inside every tool function, import `os` locally inside the function body, check relative/container paths (`"corporate_travel_policy.txt"`, `"/code/corporate_travel_policy.txt"`, `"/app/corporate_travel_policy.txt"`) inside `try/except`, and embed a fallback policy/data summary string directly inside the function.
    - **Ensure `cloudpickle` is installed**: Run `sudo /opt/venv/bin/pip install -q cloudpickle` (or `pip install -q cloudpickle`) before using `ReasoningEngine.create` / `client.agent_engines.create`.
    - **Avoid Circular Imports Across Subdirectories**: Never put `import agent` inside `app/agent.py` or `<pkg>/agent.py` (when `sys.path[0]` is the subdirectory, `import agent` imports itself!). Keep `root_agent` in a single canonical module (`<pkg>/__init__.py` or `<pkg>/agent.py` imported via `from .agent import root_agent`).
    - Prefer `hl-adk` one-shot subcommands over ad-hoc `python3 -c` scripts: `hl-adk deploy-runtime us-central1`, `hl-adk test-runtime us-central1 "<prompt>"`, `hl-adk publish-ge "<App Name or ID>"`, and `hl-adk run-eval evaluation.json <experiment-name> us-central1`.
  - **Target B — Cloud Run / FastAPI Container (`deployment_target: "cloud_run"` or local `:8000` service)**:
    - When mounting ADK on FastAPI in a container with a read-only root filesystem, call `get_fast_api_app(agents_dir=".", web=False)` (never pass the non-existent `adk_app=` kwarg, and **NEVER** iterate `[r.methods for r in app.routes]` because Starlette `APIWebSocketRoute` has no `.methods` attribute; use `getattr(r, "methods", ["WS"])` if inspecting routes).
    - When updating an existing Cloud Run service's image or environment variable, ALWAYS use `gcloud run services update <svc> --region=<region> --image=<img_uri>` or `--update-env-vars="KEY=VAL"`. NEVER use `--set-env-vars` on an existing service unless explicitly replacing all variables, as it wipes existing database and VPC settings.
- **Vertex AI `EvalTask` Invariants**:
  - Always ensure the `default` Vertex AI `MetadataStore` exists in the regional location (`us-central1`) before running `EvalTask`.
  - Use ONLY valid `MetricPromptTemplateExamples.Pointwise` constants (`GROUNDEDNESS`, `QUESTION_ANSWERING_QUALITY`, `INSTRUCTION_FOLLOWING`, `SAFETY`, `"rouge_l_sum"`). **NEVER** reference `.RELEVANCE` (does not exist and raises `AttributeError`).

## 2. Fast Verification Loop & 3-Turn Circuit Breaker
1. After every code change, run `hl-verify .` (or `python3 ~/do-harness-lite/scripts/verify_lite.py .`) plus any workspace test/verification command (`pytest`, `npm test`, `hl-adk test-runtime`, or ticket verify script).
2. Never declare a task complete until `hl-verify .` exits with code `0` and the target deployment (`ReasoningEngine` for Agent Runtime, or `localhost:8000` / Cloud Run URL for FastAPI services) is verified responding.
3. **3-Turn Debug-Spiral Circuit Breaker**: If 3 consecutive attempts fail on the same error, STOP editing code. Run `hl-env`, read the full traceback and logs, state the failed assumption, and verify the exact API/schema before making the next surgical edit.
