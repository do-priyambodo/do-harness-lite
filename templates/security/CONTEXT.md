# Local Project Context & Secure Coding Standards (`.agents/CONTEXT.md`)

## 1. Core Paved Roads (Defense-in-Depth)

1. **Strict Input/Output Schema Boundaries**:
   - Never parse raw unchecked dictionaries, unvalidated JSON strings, or raw query parameters directly in business logic.
   - All tool arguments and API endpoints MUST validate incoming payloads against strict schemas (Pydantic v2 `BaseModel` + `Field(...)` for Python, Zod for TypeScript/Node.js).
   - Enforce explicit bounds: regex `pattern`, string length (`min_length`, `max_length`), numeric bounds (`gt=0`, `le=...`), and strict enums.

2. **Zero Hardcoded Secrets & Credential Hygiene**:
   - Never hardcode API keys, database passwords, tokens, or private keys in source code or configuration files.
   - Load all credentials exclusively from `os.environ` / `os.getenv(...)` or Google Cloud Secret Manager with Application Default Credentials (ADC).

3. **No Unchecked Shell Execution & Parameterized Queries**:
   - Never invoke `subprocess` with `shell=True`, `os.system(...)`, `eval(...)`, or `exec(...)`. Always pass an argument list (`shell=False`).
   - Never format SQL queries with f-strings or string concatenation; always use parameterized queries (`$1` or `:param`).

4. **Autonomous Pre-Commit Remediation Loop**:
   - If a Git pre-commit hook (`semgrep --error`) or test suite fails, immediately treat the finding as a surgical refactoring task: replace the insecure pattern, re-run `pytest` and `semgrep`, and re-commit once all checks pass.

---

## 2. TDD Security Planning Gate (`PLAN.md` Requirement)

Before implementing or refactoring security-sensitive tools, include a **Security Boundaries & Assertions** table in your plan:

| Potential Exploit / Edge Case | Security Boundary | Outcome-Based Test Assertion |
| :--- | :--- | :--- |
| **Negative / Zero / Out-of-Range Values** | Numeric validator (`Field(gt=0, le=100000)`) | Input `<= 0` raises `ValidationError` |
| **Command / SQL / String Injection** | Strict regex `^[a-zA-Z0-9_\-]+$` & parameterized SQL | Malformed payload rejected at boundary |
| **Replay / Double Redemption (TOCTOU)** | Idempotency key / atomic transaction lock | Second identical request returns explicit error |
| **Cross-Tenant IDOR / Guest Escalation** | Verified session identity & tenant scoping | Unauthorized/guest caller receives error / `403` |
| **Hardcoded API Key in Source** | Environment variable (`os.getenv`) + Semgrep gate | `semgrep --error` exits `0` with zero findings |
