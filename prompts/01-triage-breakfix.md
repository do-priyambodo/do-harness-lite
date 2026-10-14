# Copy-Paste Prompt 01: Multi-Ticket Triage & Surgical Break/Fix

Copy and paste the prompt block below into your coding agent (`agy` or IDE chat) when working on a multi-ticket break/fix or remediation workspace:

```text
Follow the global rules in ~/.gemini/GEMINI.md and load the `triage-and-remediation` and `adk-runtime-invariants` skills.

Execute this workflow strictly:
1. Run `hl-env` and `hl-verify .` first to inspect the workspace, active ports, environment variables, and existing Python/ADK issues.
2. Read README.md, .agents/CONTEXT.md (if present), and every ticket/brief file in the workspace. Build a concise checklist of all tickets and their exact acceptance criteria.
3. Solve each ticket one by one using surgical edits:
   - Never delete or overwrite existing `.agents/` or `GEMINI.md` files in the repo.
   - For Gemini models (`gemini-4-argon`, `gemini-3.8-flash`, or legacy lab models `gemini-3.6-flash`, `gemini-3.1-pro-preview`, `gemini-3-flash-preview`), set `GOOGLE_CLOUD_LOCATION="global"` and `GOOGLE_GENAI_USE_VERTEXAI="True"`.
   - For Cloud Run, Agent Runtime, Model Armor, AlloyDB, and Agent Registry, always use a regional location (e.g., `us-central1`).
   - Ensure every ADK `Agent(name=...)` uses underscores only, every sub-agent has a single parent, instruction state variables use `{var?}` or are seeded in `before_agent_callback`, and `before_tool_callback` returns `None` when allowing execution.
   - For database pool exhaustion (Node.js `pg` or Python SQLAlchemy), replace per-request client creation with a module-level singleton connection pool (`max: 20`).
   - For Cloud Run updates, ALWAYS use `--update-env-vars`, NEVER `--set-env-vars`.
4. After completing EACH ticket, immediately run `hl-verify .` and the ticket-specific verification command (pytest, semgrep, terraform validate, or eval script) before moving to the next ticket.
```
