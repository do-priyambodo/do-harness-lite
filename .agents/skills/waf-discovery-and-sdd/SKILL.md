---
name: waf-discovery-and-sdd
description: Generates concise, high-scoring Technical Discovery documents and Google Cloud Well-Architected Framework (WAF) Software Design Documents (SDDs) with strict token/word budgets, Read-Only Phase 1 MVP boundaries, JSON Schema tool contracts, and FinOps billing labels.
---

# Technical Discovery & WAF Software Design Document (SDD) Skill

Use this skill when authoring architecture documents, technical discovery findings, or Software Design Documents (SDDs) under tight time constraints.

## 1. Non-Negotiable Formatting & Conciseness Rules
- **Table Cell Word Limit**: Keep every Markdown table cell **<= 25 words** (or <= 30 words max). Dense prose paragraphs inside tables fail automated rubric checks and waste generation time.
- **No Placeholder Text**: Never leave `TODO`, `TBD`, or `<insert here>` in any section. Every section must contain concrete component names, APIs, metrics, and failure modes.
- **Traceability**: Map every business requirement (`REQ-01`, `REQ-02`) to a concrete architectural component, tool contract, and evaluation metric.

## 2. Discovery & MVP Scoping Rules (Phase 1 vs. Phase 2 Cut Line)
When scoping a Phase 1 MVP from stakeholder transcripts or briefs:
1. **Phase 1 MVP = Read-Only + Grounded Triage + Human-in-the-Loop (HITL)**:
   - Include: Data ingestion, grounded RAG/search over policy/telemetry docs, read-only database/API lookup tools, structured triage recommendations, and Model Armor prompt sanitization.
   - **Defer to Phase 2 (Out of Scope for Phase 1)**: Autonomous destructive write actions (e.g., auto-executing database mutations, external financial/rebooking transactions, unapproved production changes) and complex legacy write-back integrations without an API.
2. **Quantify Value & SLOs**:
   - State explicit latency targets (`P95 < 3.0s` for single-agent lookup, `P95 < 8.0s` for multi-agent workflow), availability (`99.9%`), and evaluation pass thresholds (`trajectory_exact_match >= 0.85`, `hallucination == 0.0`).

## 3. Mandatory SDD Technical Contracts
Every SDD MUST include these four concrete technical blocks (copy from `templates/docs/02-sdd-waf-template.md`):
1. **ASCII / Mermaid Component Topology Diagram**:
   - Show User -> Cloud Load Balancer / Cloud Armor -> Cloud Run (`web=False`) -> Model Armor (Regional REP) -> ADK Root Coordinator -> Sub-Agents / MCP Toolbox -> AlloyDB / Vertex AI Search / GCS.
2. **Explicit Tool Schema Contract (Pydantic / JSON Schema)**:
   - Define at least 2 core tools with exact input parameter types, constraints, return schema, error codes (`400`, `403`, `404`, `429`, `503`), and timeout/retry behavior.
3. **FinOps & Resource Attribution (`labels`)**:
   - Specify mandatory GCP billing labels on all Cloud Run, GKE, AlloyDB, and GCS resources:
     ```hcl
     labels = {
       environment = "production"
       cost_center = "ai-platform"
       service     = "agent-runtime"
       managed_by  = "terraform"
     }
     ```
4. **All 6 Google Cloud Well-Architected Framework (WAF) Pillars**:
   - **Operational Excellence**: CI/CD gates (`hl-verify`, `adk eval`, `semgrep`), Cloud Logging/Trace OpenTelemetry correlation (`trace_id`), automated rollback via Cloud Run revisions.
   - **Security, Privacy & Compliance**: Least-privilege per-service IAM Service Accounts, Workload Identity Federation, Model Armor prompt/response filtering, CMEK encryption, Secret Manager, `before_tool_callback` parameter policy enforcement.
   - **Reliability**: Regional multi-zone AlloyDB/GKE, Cloud Run min/max scaling, exponential backoff with jitter on `429 ResourceExhausted`, graceful fallback when a downstream tool times out (`temp:degraded_mode`).
   - **Cost Optimization (FinOps)**: Context Caching (`CachedContent` TTL) for static system prompts/docs, `ThinkingConfig(thinking_budget=0)` on simple classification nodes, model routing (`gemini-3-flash-preview` for triage, `gemini-3.1-pro-preview` for complex synthesis), scale-to-zero dev services.
   - **Performance Efficiency**: `ParallelAgent` for independent I/O lookups, connection pooling (`pg.Pool` / SQLAlchemy async pool + AlloyDB Auth Proxy), streaming responses where applicable.
   - **Sustainability**: Right-sized regional compute, avoiding redundant LLM invocations via deterministic `@node` / `before_model_callback` caching.
