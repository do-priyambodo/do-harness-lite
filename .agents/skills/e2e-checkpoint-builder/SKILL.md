---
name: e2e-checkpoint-builder
description: Checkpoint-driven implementation strategy for timed end-to-end Google Cloud & ADK engineering builds. Maximizes objective verification score per minute and prevents late-stage integration failures.
---

# Checkpoint-Driven E2E Builder Protocol

When building an end-to-end solution under a strict clock (e.g., 90–120 minutes), never write all code before testing. Execute in **5 self-contained, verifiable checkpoints** so every completed stage is banked and functional.

## Checkpoint 0: Environment & Spec Lock (Minutes 0–5)
1. Run `hl-env` to inspect `PROJECT_ID`, region, existing Cloud Run services, GCS buckets, and `.env` files.
2. Read the problem statement / `spec.md` and list the exact graded artifacts:
   - File paths (e.g., `agent.py`, `tools.yaml`, `main.tf`, `report.json`, `sdd.md`)
   - Cloud resources (e.g., Cloud Run service name, Agent Runtime engine, Model Armor template ID, Agent Registry service ID, GCS bucket outputs)
3. Enable required APIs immediately in the background if not yet enabled:
   `hl-adk enable-apis`

## Checkpoint 1: Data & Tool Layer First (Minutes 5–25)
1. Build and test deterministic data access and tool functions in isolation (`tools.py` or `tools.yaml` for MCP Toolbox):
   - Every tool function has full type hints, a clear docstring, and structured `dict` return values (`{"status": "ok", "data": ...}` or `{"status": "error", "message": ...}`).
   - Verify database/GCS/API connectivity with a 1-line `python3 -c "from tools import my_tool; print(my_tool(...))"` check before wiring into an agent.
2. Run `hl-verify .` (`<2s`) to confirm zero tool signature or secret issues.

## Checkpoint 2: Agent & Guardrail Assembly (Minutes 25–50)
1. Assemble the ADK `root_agent` (and `SequentialAgent` / `ParallelAgent` / `LoopAgent` or ADK 2.0 `Workflow` as specified) using `templates/adk/agent_patterns.py`.
2. Double-check the 4 fatal agent traps:
   - `name` uses underscores only (`^[a-zA-Z_][a-zA-Z0-9_]*$`).
   - Each sub-agent instance has only ONE parent.
   - Any `{state_var}` in `instruction` uses `{state_var?}` or is seeded in `before_agent_callback`.
   - `before_tool_callback` returns `None` to allow execution and returns a `dict` only to block/override.
3. If Model Armor is required, create the regional template (`hl-adk create-model-armor <id> <region>`) and wire `templates/adk/model_armor_client.py` into `before_model_callback` / `after_model_callback`.
4. Run `hl-verify .` and execute a smoke turn (`adk run` or `Runner.run_async`).

## Checkpoint 3: Cloud Deployment & Registry Wiring (Minutes 50–75)
1. Start Cloud Run or Agent Runtime deployment early (deployments take 2–4 minutes; work on docs or evals while the build runs):
   - Agent Runtime: `hl-adk deploy-runtime agent_Entrypoint.py:app us-central1`
   - Cloud Run update: `hl-adk update-cloudrun <service> <region> --env KEY=VAL` (always `--update-env-vars`, never `--set-env-vars`).
2. If Cloud Agent Registry A2A registration is required:
   - Verify `/.well-known/agent-card.json` is reachable, then run:
     `hl-adk register-a2a <service-id> <card-url> <region>`

## Checkpoint 4: Evaluation, Final Audit & Clean Tree (Minutes 75–90)
1. Run required evaluations (`adk eval` or `templates/eval/run_vertex_eval_task.py`) and confirm output artifacts (`report.json`, GCS evaluation outputs) are non-empty and meet target thresholds.
2. Run `hl-verify . --strict-secrets` to ensure zero syntax errors, zero ADK traps, and zero leaked credentials.
3. Check `git status` and `git diff` to ensure no required files were accidentally deleted or polluted.
