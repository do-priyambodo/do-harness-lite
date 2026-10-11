# AGENTS.md — Rapid ADK & Cloud Engineering Harness (`do-harness-lite`)

## 0. Workspace Specification Precedence (Always Inspect First)
1. **Local Specs Win**: Before editing any file, inspect the workspace (`ls -la`, `spec.md`, `PRD.md`, `README.md`, `GEMINI.md`, `.agents/CONTEXT.md`, `triage/briefs/*.md`, `pyproject.toml`, `agents-cli-manifest.yaml`).
2. **Preserve Contracts**: Never rename required entry-point files (`app/agent.py`, `main.py`, `<pkg>/__init__.py`), exported symbols (`root_agent`, `app`), function names, parameter names, or port numbers (`8000`, `8080`, `3002`, `5000`) expected by local test or verification scripts.
3. **Preserve Existing Guardrails**: If the workspace already contains `GEMINI.md`, `.agents/CONTEXT.md`, `.agents/hooks.json`, or `.pre-commit-config.yaml`, keep them intact and additive.

## 1. Google ADK & Vertex AI Runtime Invariants
- **Global vs. Regional Endpoint Split**:
  - **Gemini Model Inference**: When using `gemini-3.6-flash` or `gemini-2.5-flash` on Vertex AI, set `GOOGLE_GENAI_USE_VERTEXAI="True"` and `GOOGLE_CLOUD_LOCATION="global"` in `.env` (or `os.environ` before initializing `genai.Client()` / `Agent()`).
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
- **Cloud Run & Container Packaging**:
  - When mounting ADK on FastAPI in a container with a read-only root filesystem, call `get_fast_api_app(adk_app=root_agent, web=False)`.
  - When updating an existing Cloud Run service's image or environment variable, ALWAYS use `gcloud run services update <svc> --region=<region> --image=<img_uri>` or `--update-env-vars="KEY=VAL"`. NEVER use `--set-env-vars` on an existing service unless explicitly replacing all variables, as it wipes existing database and VPC settings.

## 2. Fast Verification Loop & 3-Turn Circuit Breaker
1. After every code change, run `hl-verify .` (or `python3 ~/do-harness-lite/scripts/verify_lite.py .`) plus any workspace test/verification command (`pytest`, `npm test`, ticket verify script).
2. Never declare a task complete until `hl-verify .` exits with code `0` and any required local server (`localhost:8000` / `localhost:8080`) is verified listening.
3. **3-Turn Debug-Spiral Circuit Breaker**: If 3 consecutive attempts fail on the same error, STOP editing code. Run `hl-env`, read the full traceback and logs, state the failed assumption, and verify the exact API/schema before making the next surgical edit.
