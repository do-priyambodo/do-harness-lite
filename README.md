# do-harness-lite — Rapid ADK & Google Cloud Engineering Harness

`do-harness-lite` is a zero-dependency, global-first engineering harness for building, triaging, evaluating, and deploying **Google Agent Development Kit (ADK 1.x & 2.0)** and **Google Cloud** systems at high speed.

It is designed for fresh cloud workstations and timed engineering sprints where:
- You need **< 2-second verification (`hl-verify`)** instead of slow CI pipelines.
- You want **global agent rules & skills (`~/.gemini/`, `~/.agents/`)** so target project repositories stay 100% `git status`-clean.
- You standardize on **`Gemini 4 Argon` (`gemini-4-argon`)** as the default Pro / Root Orchestrator model and **`Gemini 3.8 Flash` (`gemini-3.8-flash`)** as the default Fast / Sub-Agent model on `GOOGLE_CLOUD_LOCATION="global"`.
- You need **ready-to-copy blueprints** for ADK multi-agent workflows, Regional Model Armor, MCP Toolbox / AlloyDB pooling, Vertex AI `EvalTask`, Cloud Agent Registry (A2A), Semgrep + `PreToolUse` hooks, Terraform CMEK infrastructure, and Well-Architected SDDs.

---

## 30-Second Quickstart on Any Fresh VM

```bash
git clone https://github.com/do-priyambodo/do-harness-lite.git ~/do-harness-lite
~/do-harness-lite/install.sh
export PATH="$HOME/.local/bin:$PATH"
```

Then inside your target project directory:

```bash
cd /path/to/your/workspace
hl-env                  # 1. 60-second diagnostic of GCP project, env vars, ports, and files
hl-verify .             # 2. <2-second AST + ADK trap verifier
hl-inject .             # 3. (Optional) Inject AGENTS.md & auto-hide in .git/info/exclude
```

---

## CLI Toolkit (`~/.local/bin/`)

| Command | Script | Purpose |
| :--- | :--- | :--- |
| `hl-env [DIR]` | `scripts/check_env.sh` | Inspects CLI tools, active `gcloud` project/region, `.env` variables (redacting secrets), broken `.venv` symlinks, open local ports (`8000`, `8080`, `3000`, `5000`), Cloud Run services, and GCS buckets. |
| `hl-verify [DIR]` | `scripts/verify_lite.py` | `<2s` zero-dependency Python AST & ADK static analyzer. Catches hyphenated `Agent(name=...)`, hallucinated `@tool` decorators, shared `sub_agents` instances, unsafe `{state_key}` placeholders, untyped/undocumented tool functions, hardcoded secrets, and import errors. |
| `hl-adk <cmd>` | `scripts/adk_ops.sh` | High-speed wrapper for `enable-apis`, `doctor`, `scaffold`, `deploy-runtime` (enforcing regional endpoints), `publish-ge`, `update-cloudrun` (enforcing `--update-env-vars`), `register-a2a` (stripping unsupported A2A card fields), and `create-model-armor` (setting regional REP endpoint). |
| `hl-rescue <opt>` | `scripts/rescue.sh` | Emergency recovery when an IDE or agent CLI hangs: `--kill` (terminates hung IDE/agent processes), `--auth` (resets corrupted OAuth token cache), `--fix-venv` (rebuilds broken `.venv` symlinks), `--env` (prints Vertex AI exports), and `--run "<prompt>"` (bounded 180s headless run). |
| `hl-inject [DIR]` | `scripts/inject_workspace.sh` | Copies or appends `AGENTS.md` into `DIR` and registers `AGENTS.md` in `.git/info/exclude` so `git status` remains untouched. |

---

## Global Skills Installed (`~/.gemini/config/skills/` & `~/.agents/skills/`)

1. **`adk-runtime-invariants`**: Authoritative rules for ADK 1.x/2.0, `global` vs. regional endpoints, tool signatures, callback return contracts, session state prefixes (`user:`, `app:`, `temp:`), Context Caching, Model Armor, and Cloud Run safety.
2. **`triage-and-remediation`**: Rapid root-cause diagnosis matrix for multi-ticket break/fix scenarios (DB connection pooling, location mismatches, callback return traps, Semgrep rules, `PreToolUse` hooks, and Terraform CMEK/networking fixes).
3. **`waf-discovery-and-sdd`**: High-density Technical Discovery and Google Cloud Well-Architected Framework (WAF) SDD authoring protocol (`<= 25 words` per table cell, Read-Only Phase 1 MVP cut line, JSON Schema tool contracts, and FinOps billing labels).
4. **`e2e-checkpoint-builder`**: 5-checkpoint execution strategy for timed end-to-end builds so every completed layer (Tools -> Agent -> Cloud Deploy -> Eval -> Docs) is verified and banked early.

---

## Reference Blueprints (`templates/` & `prompts/`)

```text
do-harness-lite/
├── AGENTS.md                                 # Core runtime invariants (<70 lines)
├── install.sh                                # One-command global installer
├── scripts/
│   ├── check_env.sh                          # hl-env
│   ├── verify_lite.py                        # hl-verify (includes --selftest)
│   ├── adk_ops.sh                            # hl-adk
│   ├── rescue.sh                             # hl-rescue
│   └── inject_workspace.sh                   # hl-inject
├── .agents/skills/                           # 4 global skills
├── templates/
│   ├── adk/
│   │   ├── agent_patterns.py                 # Agent, Sequential/Parallel/Loop, callbacks, Context Cache
│   │   ├── model_armor_client.py             # Regional REP ModelArmorClient & ADK callback
│   │   ├── data_connectors.py                # MCP Toolbox, AlloyDB singleton pool, Secret Manager, GCS
│   │   └── tools.yaml                        # Parameterized MCP Toolbox for Databases config
│   ├── eval/
│   │   ├── run_vertex_eval_task.py           # Vertex AI EvalTask runner -> report.json & GCS
│   │   └── test_config.json                  # ADK eval criteria thresholds
│   ├── security/
│   │   ├── CONTEXT.md                        # Passive .agents/CONTEXT.md (Paved Roads & TDD Gate)
│   │   ├── pre-commit-config.yaml            # Passive .pre-commit-config.yaml running semgrep --error
│   │   ├── semgrep_rules.yaml                # Custom Semgrep rules (API key, SQLi, shell=True, Cloud Run)
│   │   ├── threat_model.md                   # Passive 6-row STRIDE architectural threat model template
│   │   ├── test_security_boundaries.py       # Hermetic outcome-based pytest security boundary template
│   │   ├── validate_tool_call.py             # PreToolUse runtime guardrail script (exits 1 on block)
│   │   └── hooks.json                        # .agents/hooks.json configuration
│   ├── terraform/
│   │   └── main.tf                           # KMS CMEK, GCS, Least-Privilege SA, Cloud Run v2, labels
│   └── docs/
│       ├── 01-discovery-template.md          # Scoped Phase 1 MVP Discovery template (<=25 words/cell)
│       └── 02-sdd-waf-template.md            # 6-Pillar WAF SDD with JSON Schema contracts & topology
└── prompts/
    ├── 01-triage-breakfix.md                 # Copy-paste prompt for multi-ticket break/fix labs
    ├── 02-discovery-and-sdd.md               # Copy-paste prompt for Discovery & SDD authoring
    └── 03-e2e-build.md                       # Copy-paste prompt for end-to-end builds
```

---

## Self-Verification

```bash
python3 scripts/verify_lite.py --selftest
python3 scripts/verify_lite.py . --no-import-smoke --strict-secrets
```
