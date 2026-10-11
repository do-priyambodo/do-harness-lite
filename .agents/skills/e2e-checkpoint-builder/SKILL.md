---
name: e2e-checkpoint-builder
description: Checkpoint-driven implementation strategy for timed end-to-end Google Cloud & ADK engineering builds. Maximizes objective verification score per minute and prevents late-stage integration failures.
---

# Checkpoint-Driven E2E Builder Protocol

When building an end-to-end solution under a strict clock, never write all code before testing. Execute in **5 self-contained, verifiable checkpoints** so every completed stage is banked and functional.

## Checkpoint 0: Environment & Spec Lock (Minutes 0–5)
1. Run `hl-env` to inspect `PROJECT_ID`, region, existing Cloud Run services, GCS buckets, and `.env` files.
2. Read the problem statement / `spec.md` and list the exact graded artifacts:
   - File paths and entrypoints (`app/agent.py`, `main.py` on `:8000`, `travel_policy_agent/__init__.py`, `tools.yaml`, `report.json`, `sdd.md`)
   - Cloud resources (Cloud Run service name, Agent Runtime engine, Gemini Enterprise app, Model Armor template ID, Agent Registry service ID, GCS bucket outputs)
3. Enable required APIs immediately in the background if not yet enabled:
   `hl-adk enable-apis`

## Checkpoint 1: Data & Tool Layer First (Minutes 5–25)
1. Build and test deterministic data access and tool functions in isolation (`tools.py` or `tools.yaml` for MCP Toolbox):
   - Every tool function has full type hints, return type annotation, a clear docstring, and structured `dict` return values.
   - Verify database/GCS/API connectivity with a 1-line `python3 -c "from tools import my_tool; print(my_tool(...))"` check before wiring into an agent.
2. Run `hl-verify .` (`<2s`) to confirm zero tool signature or secret issues.

## Checkpoint 2: Agent & Guardrail Assembly (Minutes 25–50)
1. Assemble the ADK `root_agent` (and `SequentialAgent` / `ParallelAgent` / `LoopAgent` or ADK 2.0 `Workflow` as specified) using `templates/adk/agent_patterns.py`.
2. Double-check the 4 fatal agent traps:
   - `name` uses underscores only (`^[a-zA-Z_][a-zA-Z0-9_]*$`).
   - Each sub-agent instance has only ONE parent.
   - Any `{state_var}` in `instruction` uses `{state_var?}` or is seeded in `before_agent_callback`.
   - `before_tool_callback` returns `None` to allow execution and returns a `dict` only to block/override.
3. If Model Armor is required, create the regional template (`hl-adk create-model-armor <id> <region>`, or `--output-safe` for output templates) and wire `templates/adk/model_armor_client.py` into `before_model_callback` / `after_model_callback`.
4. Run `hl-verify .` and execute a smoke turn (`adk run` or `agents-cli run`).

## Checkpoint 3: Cloud Deployment, Registry & Gemini Enterprise (Minutes 50–75)
1. Start Cloud Run or Agent Runtime deployment early (deployments take 2–4 minutes; work on docs or evals while the build runs):
   - Agent Runtime: `hl-adk deploy-runtime us-central1` (auto-registers in Agent Registry)
   - Cloud Run update: `hl-adk update-cloudrun <service> <region> --env KEY=VAL` (always `--update-env-vars`, never `--set-env-vars`).
2. If Cloud Agent Registry A2A registration is required for a Cloud Run service:
   - Run `hl-adk register-a2a <service-id> <service-or-card-url> <region> "<Display Name>" "<Description>"`
3. If publishing to Gemini Enterprise is required:
   - Ensure the Gemini Enterprise App is created in `global` with **Google Identity** enabled in Settings, then run:
     `hl-adk publish-ge "$GEMINI_APP_ID" "<Display Name>" "<Description>" agent_runtime`

## Checkpoint 4: Evaluation, Final Audit & Safe Grading Rules (Minutes 75–90)
1. Run required evaluations (`adk eval`, `agents-cli eval run --dataset eval/golden.jsonl --output eval/results/run_v2.json`, or `templates/eval/run_vertex_eval_task.py`) and confirm output artifacts (`report.json`, GCS outputs) exist and pass thresholds.
2. **CRITICAL GRADING RULES**:
   - **Keep Local Servers Running**: Keep `localhost:8000` (`uvicorn main:app` / `python3 agent.py`) and `localhost:5000` (`toolbox`) running in background terminals while clicking **Check My Progress**.
   - **Hold Destructive Teardown Checks**: If the final subtask (e.g., Subtask 25) tests gateway teardown or resource deletion, **hold that check until all earlier checks (1–24) are scored green**.
   - **Never End Early**: Never stop or end the session until the passing score is verified on the progress ribbon.
