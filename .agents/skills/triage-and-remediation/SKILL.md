---
name: triage-and-remediation
description: Rapid root-cause diagnosis and surgical remediation workflow for multi-bug break/fix challenges across Python ADK agents, Node.js/FastAPI services, AlloyDB/Cloud SQL, Terraform, Semgrep security gates, and Vertex AI Evaluations.
---

# Rapid Triage & Surgical Remediation Protocol

Use this workflow when presented with a partially broken system, an incident queue (`triage/briefs/*.md` or tickets), failing evaluations, or broken infrastructure.

## Step 1: 60-Second Triage Map (Read Before Touching Code)
1. Run `hl-env` and `hl-verify .` to get an instant baseline of environment variables, running ports, Cloud Run services, and static AST/ADK issues.
2. Read all brief/ticket files (`triage/briefs/*.md`, `README.md`, `spec.md`, `.agents/CONTEXT.md`) and list every Deliverable + Acceptance Criterion in a checklist.
3. Classify each issue into one of these 7 high-frequency root-cause buckets:

| Symptom / Failure Mode | Root-Cause Bucket & Exact Fix |
| :--- | :--- |
| **Connection pool exhaustion / latency spike under load (Node.js or Python DB)** | **Per-Request DB Client Anti-Pattern**: `new Client()` + `client.connect()` created inside an HTTP route handler. Replace with a module-level singleton `new Pool({ max: 20, idleTimeoutMillis: 30000, connectionTimeoutMillis: 5000 })` (or SQLAlchemy async engine pool). |
| **Agent returns `404 NotFound` on Gemini 3 model or `400 Invalid Argument` on deploy** | **Location Mismatch**: Set `GOOGLE_CLOUD_LOCATION="global"` for Gemini 3 preview model calls; pass `--region us-central1` (regional) for `agents-cli deploy agent-runtime`, Cloud Run, Model Armor, and Agent Registry. |
| **Agent fails on Turn 1 with `KeyError: Context variable not found`** | **Unseeded Instruction Placeholder**: Change `{var}` in `instruction="..."` to `{var?}` or seed `callback_context.state.setdefault("var", default)` in `before_agent_callback`. |
| **Tool never executes or returns empty/wrong payload when guarded by callback** | **`before_tool_callback` Return Trap**: Returning `{}` or a truthy status dict skips the tool! Return `None` to allow the tool to run; return a `dict` ONLY to block/override the tool. |
| **Agent ignores tool or hallucinates parameters** | **Missing Docstring / Type Hints / Sub-Agent Routing Description**: Add explicit Python type annotations and a clear docstring to the tool function, and set a specific `description="..."` on every sub-agent. |
| **High token cost & slow multi-turn responses on large static reference docs** | **Missing Context Cache / Excessive Thinking Budget**: Move static reference docs into Vertex AI `client.caches.create(...)` (`CachedContent` with `ttl="3600s"`), and set `ThinkingConfig(thinking_budget=0)` for high-throughput routing/extraction turns. |
| **Terraform plan/apply fails or violates security posture** | **Missing CMEK / Private Networking / Labels**: Ensure `google_kms_crypto_key_iam_member` grants `roles/cloudkms.cryptoKeyEncrypterDecrypter` to the service agent with `depends_on`, enable `private_ip_google_access = true`, and attach required `labels` (`env`, `cost_center`, `service`). |

## Step 2: Security Gate Remediation (Semgrep & PreToolUse Hooks)
1. **Static Analysis (`semgrep`)**:
   - Run `semgrep scan --config auto --error` (or custom `.semgrep.yaml`).
   - Fix hardcoded credentials (`os.environ["KEY"]` or Secret Manager), SQL string concatenation (use parameterized queries `$1` / `:param`), `subprocess(..., shell=True)` (pass `shell=False` with argv list), and `eval()`/`exec()`.
2. **Runtime Agent Tool Guard (`PreToolUse` / `before_tool_callback`)**:
   - When configuring `.agents/hooks.json` (`PreToolUse`), read JSON from `stdin` (`tool_name`, `tool_input`), block destructive shell patterns (`rm -rf`, `DROP TABLE`, `gcloud projects delete`, `--set-env-vars`), and exit `2` with a clear reason on `stderr` when blocked (or output `{"decision": "block", "reason": "..."}`).

## Step 3: Verify Every Fix Immediately (`<10s` Loop)
After fixing each ticket:
1. Run `hl-verify .` (`<2s` AST + ADK check).
2. Run the targeted test or reproduction command for that ticket (`pytest -k <test>`, `curl`, `terraform validate`, `semgrep`).
3. If an evaluation score threshold is required (`test_config.json` / `EvalTask`), run the evaluation script and verify `report.json` or GCS output artifacts exist and pass thresholds before moving to the next ticket.
