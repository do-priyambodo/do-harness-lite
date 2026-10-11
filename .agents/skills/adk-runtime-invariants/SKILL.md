---
name: adk-runtime-invariants
description: Authoritative Google ADK (1.x and 2.0), Vertex AI, Model Armor, MCP Toolbox, and Cloud Run implementation patterns and anti-trap rules. Load whenever writing, debugging, evaluating, or deploying ADK agents.
---

# ADK Runtime Invariants & Anti-Trap Reference

Follow these rules strictly whenever creating, modifying, evaluating, or deploying agents with the Google Agent Development Kit (`google-adk`).

## 1. Environment & Region Split ( #1 Silent Failure )
- **Gemini 3 Models (`gemini-3.6-flash`, `gemini-3-flash-preview`, `gemini-3.1-pro-preview`)**:
  - Require `GOOGLE_CLOUD_LOCATION="global"` and `GOOGLE_GENAI_USE_VERTEXAI="True"`.
  - Calling a regional endpoint (`us-central1`) with `gemini-3.6-flash` or preview models raises `404 NOT_FOUND ... Publisher model`.
  - If a project does not have `gemini-3.6-flash` allowlisted, fall back to `gemini-2.5-flash`.
- **Regional Control Planes (`us-central1` or assigned region)**:
  - **Agent Runtime Deploy** (`agents-cli deploy`), **Vertex AI `EvalTask`** (`vertexai.init(project=..., location="us-central1")`), **Cloud Run**, **Cloud Agent Registry**, **AlloyDB / Cloud SQL**, and **Model Armor** (`https://modelarmor.<region>.rep.googleapis.com/`) MUST use a regional location — NEVER `global`.

## 2. Agent & Multi-Agent Construction Rules
1. **Valid Agent Names**: `Agent(name="...")` MUST match `^[a-zA-Z_][a-zA-Z0-9_]*$` (underscores only, NO hyphens or spaces).
2. **Single-Parent Rule**: Every sub-agent instance can belong to only ONE parent `sub_agents=[...]` list. Passing the same sub-agent object to two parents raises `ValueError: Agent already has a parent_agent`. Instantiate separate factory instances if needed.
3. **Safe State Interpolation**: Any `{state_key}` inside `instruction="..."` throws `KeyError: 'Context variable not found'` on Turn 1 if `session.state["state_key"]` is not yet set. Either:
   - Use optional syntax `{state_key?}`, OR
   - Seed a default in `before_agent_callback`: `callback_context.state.setdefault("state_key", "")`.
4. **Custom Tool Rules**:
   - Plain Python functions passed to `tools=[...]` — NEVER use `@tool`, `@function_tool`, or `@root_agent.skill` decorators.
   - Every parameter MUST have a Python type annotation (`str`, `int`, `float`, `bool`, `list[str]`, `dict[str, Any]`) and a return type annotation.
   - Every tool MUST have a docstring explaining WHEN and WHY to call it, plus an `Args:` block.
5. **Built-in Tool Isolation (`google_search` / `VertexAiSearchTool`)**:
   - When mixing `VertexAiSearchTool` or `google_search` with custom Python functions, wrap the search agent with `AgentTool(agent=search_agent)` and pass that `AgentTool` to the root coordinator.

## 3. Workflow Agents & ADK 2.0 Graph Orchestration
- **Deterministic Pipelines**:
  - `SequentialAgent(name="...", sub_agents=[step_a, step_b])`: fixed step-by-step order; pass structured outputs between steps via `output_key="step_a_result"` and reference `{step_a_result?}` in the next step.
  - `ParallelAgent(name="...", sub_agents=[worker_1, worker_2])`: concurrent fan-out for independent tasks; each branch writes to a distinct `output_key`.
  - `LoopAgent(name="...", sub_agents=[critic, refiner], max_iterations=3)`: iterative refinement; always set `max_iterations` and exit via `tool_context.actions.escalate = True`.
- **ADK 2.0 `Workflow` & `App` Packaging**:
  - Connect nodes/agents with `Edge.chain("START", intake_agent)` inside `Workflow(name="...", edges=[*Edge.chain(...)])` and expose `app = App(name="...", root_agent=workflow)`.
  - Deterministic Python `@node` functions MUST accept ONLY state/input parameters — NEVER add `ToolContext` as a parameter in a `@node` function.

## 4. Callback Return Value Contracts
| Callback | Return `None` | Return Value |
| :--- | :--- | :--- |
| `before_agent_callback(callback_context)` | Proceed to run agent | `types.Content` -> skip agent and return this content |
| `before_model_callback(callback_context, llm_request)` | Proceed to call LLM (after optional in-place PII redaction) | `LlmResponse` -> short-circuit LLM and return this response |
| `after_model_callback(callback_context, llm_response)` | Keep original `llm_response` | `LlmResponse` -> replace model response |
| `before_tool_callback(tool, args, tool_context)` | Proceed to execute tool | `dict` -> **SKIP** tool execution and return this `dict` as the tool output |
| `after_tool_callback(tool, args, tool_context, tool_response)` | Keep original `tool_response` | `dict` -> replace tool output |

## 5. Session State Prefix Scopes
- No prefix (`state["key"]`): current session only.
- `user:key` (`state["user:tier"]`): persists across sessions for the same `user_id`.
- `app:key` (`state["app:policy_version"]`): shared across all users of the application.
- `temp:key` (`state["temp:scratch"]`): discarded at the end of the current invocation turn; never persisted.

## 6. Model Armor & Prompt Injection Defense
- Always initialize `ModelArmorClient` with the **regional** REP endpoint:
  ```python
  from google.api_core.client_options import ClientOptions
  from google.cloud import modelarmor_v1
  client = modelarmor_v1.ModelArmorClient(
      transport="rest",
      client_options=ClientOptions(api_endpoint=f"modelarmor.{location}.rep.googleapis.com"),
  )
  ```
- Inspect `response.sanitization_result.filter_match_state == modelarmor_v1.FilterMatchState.MATCH_FOUND`.
- **Output Template Best Practice**: On an output/response Model Armor template (`sanitize_model_response`), keep Prompt Injection / Jailbreak detection **disabled** (`hl-adk create-model-armor <id> <region> --output-safe`) so benign agent answers are not false-positively blocked.

## 7. Cloud Run & A2A Production Wiring
- **Headless API Server**: Use `get_fast_api_app(adk_app=root_agent, web=False)` in containers with read-only filesystems.
- **Env Var Safety**: Always update Cloud Run services with `--update-env-vars KEY=VAL` or `--image=...`. Never use `--set-env-vars`, which wipes existing `DB_USER`, `DB_PASSWORD`, and VPC variables.
- **A2A Agent Registry**: Fetch the card from `/a2a/app/.well-known/agent-card.json` (or `/.well-known/agent-card.json`) with `Authorization: Bearer $(gcloud auth print-identity-token)`, strip `.supportedInterfaces, .additionalInterfaces` via `jq`, and register via `gcloud agent-registry services create NAME --location=REGION --agent-spec-type=a2a-agent-card --agent-spec-content=agent-card.json` (automated by `hl-adk register-a2a`).
