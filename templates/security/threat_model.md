# STRIDE Architectural Threat Model (`threat_model.md`)

## 1. System Scope & Trust Boundaries
- **Entry Points**: User prompts / chat input, HTTP REST endpoints, and external webhook payloads.
- **Trust Boundary 1 (Ingress -> Agent Orchestrator)**: Untrusted natural language and parameters enter the ADK `Runner` / API gateway; screened by Regional Model Armor (`sanitizeUserPrompt`) and Pydantic v2 input schemas.
- **Trust Boundary 2 (Agent -> Tools & Data Stores)**: Tool invocations cross from LLM reasoning into deterministic Python/Node.js functions and parameterized database queries (`pg.Pool` / MCP Toolbox).
- **Trust Boundary 3 (Workstation / CI Execution)**: Coding agent tool calls are intercepted mid-trajectory by `.agents/hooks.json` (`PreToolUse` -> `validate_tool_call.py`) and pre-commit `semgrep --error`.

---

## 2. STRIDE Threat Matrix & Mitigations

| STRIDE Category | Attack Vector / Threat Scenario | Concrete Mitigation Implemented | Verification / Test Assertion |
| :--- | :--- | :--- | :--- |
| **S — Spoofing** | Caller impersonates another `user_id` or attempts privileged actions as an anonymous `guest` user via prompt or payload manipulation. | Enforce strict identity validation at the tool/API boundary; reject anonymous/guest accounts and bind operations to verified session identity. | `pytest` asserts guest/unauthenticated caller is rejected with explicit authorization error. |
| **T — Tampering** | Parameter tampering (negative quantities/amounts, SQL/command injection) or replay/double-spend of single-use tokens/coupons. | Validate inputs via strict Pydantic v2 `Field(gt=0, pattern=...)` schemas, enforce single-use state tracking / atomic DB transactions, and block `shell=True`. | `pytest` asserts negative values raise `ValidationError` and replayed tokens fail on second call. |
| **R — Repudiation** | Sensitive state mutations (orders, refunds, discount redemptions, config updates) occur without an audit trail. | Emit structured log events recording `user_id`, `action`, `resource_id`, `status`, and UTC timestamp for every state-mutating tool call. | Verify structured audit record is emitted on both allowed and denied mutations. |
| **I — Information Disclosure** | Hardcoded API keys committed to Git, PII leaked in LLM outputs, or raw stack traces exposed to end users. | Source credentials exclusively from `os.environ` / Secret Manager; gate commits with `semgrep --error` (`hardcoded-gemini-api-key`); sanitize errors and redact PII via Model Armor (`sanitizeModelResponse`). | `semgrep --config .semgrep/rules.yaml --error` passes with `0` findings; no secrets in source. |
| **D — Denial of Service** | Unbounded payload sizes, runaway agent loops, or per-request database connection exhaustion under concurrent load. | Enforce `max_length` / `le` bounds on inputs, cap `LoopAgent(max_iterations=...)`, and use singleton `pg.Pool(max=20)` / SQLAlchemy async pool. | Load/concurrency check and boundary tests confirm bounded resource usage. |
| **E — Elevation of Privilege** | Prompt injection attempts to trick the agent into running destructive shell commands (`rm -rf`, `DROP TABLE`, `--set-env-vars`) or unauthorized admin tools. | Intercept tool execution via `.agents/hooks.json` (`PreToolUse` -> `validate_tool_call.py`) and ADK `before_tool_callback` returning an error dict to block unauthorized calls. | `PreToolUse` hook and callback unit tests confirm destructive commands are blocked before execution. |
