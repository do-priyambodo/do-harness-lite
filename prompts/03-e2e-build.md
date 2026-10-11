# Copy-Paste Prompt 03: Checkpoint-Driven End-to-End Agent Build & Deploy

Copy and paste the prompt block below into your coding agent when executing a full end-to-end build, evaluation, and deployment challenge:

```text
Load the `e2e-checkpoint-builder`, `adk-runtime-invariants`, and `waf-discovery-and-sdd` skills. Reference blueprints in `~/do-harness-lite/templates/`.

Execute in 5 verifiable checkpoints so every stage is banked early:
1. Checkpoint 0 (Env & Spec Lock):
   - Run `hl-env` to inspect PROJECT_ID, region, existing Cloud Run services, GCS buckets, and `.env` files.
   - Read all instructions / `spec.md` and list every required deliverable file path and Cloud resource name.
2. Checkpoint 1 (Tools & Data Layer First):
   - Implement and test deterministic tools (`tools.py` or `tools.yaml` for MCP Toolbox) using `~/do-harness-lite/templates/adk/data_connectors.py`.
   - Every tool function must have explicit Python type hints, a clear docstring, and no `@tool` decorator.
   - Run `hl-verify .` (<2s) to verify zero tool or syntax errors.
3. Checkpoint 2 (ADK Agent & Model Armor Assembly):
   - Build the ADK agent hierarchy using `~/do-harness-lite/templates/adk/agent_patterns.py`.
   - Enforce underscore-only agent names, single parent per sub-agent instance, `{var?}` optional state placeholders, and `before_tool_callback` returning `None` to allow execution.
   - If Model Armor is required, use `hl-adk create-model-armor <template-id> <region>` and wire `~/do-harness-lite/templates/adk/model_armor_client.py` with the regional REP endpoint (`modelarmor.<region>.rep.googleapis.com`).
   - Run `hl-verify .` after wiring the agent.
4. Checkpoint 3 (Cloud Deployment & A2A Registration):
   - Deploy or update Cloud Run / Agent Runtime using `hl-adk deploy-runtime` or `hl-adk update-cloudrun` (always `--update-env-vars`, never `--set-env-vars`).
   - If Cloud Agent Registry A2A registration is required, use `hl-adk register-a2a <service-id> <card-url> <region>` (which strips `.supportedInterfaces` and `.additionalInterfaces` before registration).
5. Checkpoint 4 (Evaluation & Final Audit):
   - Run the evaluation suite (`adk eval` or `~/do-harness-lite/templates/eval/run_vertex_eval_task.py`) and verify `report.json` / GCS artifacts exist and meet score thresholds.
   - Complete any required SDD / architecture documentation (`<= 25 words` per table cell) and run `hl-verify . --strict-secrets`.
```
