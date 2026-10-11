# Technical Discovery & MVP Scoping Document

> **Formatting Rule**: Every Markdown table cell MUST remain **<= 25 words**. Replace bracketed placeholders with concrete stakeholder facts from the discovery brief.

## 1. Executive Summary & Business Problem
- **Core Objective**: Automate grounded operational triage and policy lookup using an enterprise multi-agent system on Google Cloud (Vertex AI + ADK), reducing manual triage latency while enforcing strict safety and human-in-the-loop (HITL) controls.
- **Target Users**: Operations analysts, customer support engineers, and duty managers.
- **Primary Business KPIs**:
  - Reduce mean time to triage (MTTT) by **>= 60%** (target P95 response `< 5.0s`).
  - Maintain **0%** unapproved autonomous production write mutations in Phase 1.
  - Achieve **>= 0.85** trajectory accuracy and **>= 0.90** groundedness on golden evaluation sets.

## 2. Stakeholder Requirements & Pain Points (`<= 25 words/cell`)

| ID | Stakeholder Role | Current Pain Point | Phase 1 Requirement | Success Metric (SLO) |
| :--- | :--- | :--- | :--- | :--- |
| **REQ-01** | Operations Lead | Manual cross-checking of telemetry and SOP documents takes 15-30 minutes per incident. | Grounded parallel retrieval across live operational DB and SOP policy corpus. | P95 latency `< 5.0s`; recall `>= 0.90`. |
| **REQ-02** | Security / CISO | Prompt injection, PII leakage, and unverified autonomous writes pose compliance risks. | Regional Model Armor filtering, least-privilege IAM, and read-only Phase 1 tools. | `100%` prompts screened; `0` unauthorized writes. |
| **REQ-03** | Platform / FinOps | Unbounded LLM token spend and lack of per-service cost attribution labels. | Vertex AI Context Caching for static SOPs, `thinking_budget=0` routing, billing labels. | `>= 50%` cached token savings; `100%` labeled resources. |
| **REQ-04** | Engineering Lead | Fragile monolithic prompts fail silently without trajectory evaluation or observability. | Modular ADK sub-agents, deterministic `adk eval` gate, and Cloud Trace correlation. | Trajectory match `>= 0.85`; CI gate enforced. |

## 3. Phase 1 MVP vs. Phase 2 Cut Line (`<= 25 words/cell`)

| Capability | Phase 1 MVP (In Scope — Read-Only + HITL) | Phase 2 (Out of Scope — Deferred) | Rationale |
| :--- | :--- | :--- | :--- |
| **Data & Policy Lookup** | Read-only parameterized SQL via MCP Toolbox + grounded SOP retrieval. | Cross-region multi-master writes and legacy mainframe sync. | Delivers immediate triage speed with zero data-corruption blast radius. |
| **Remediation Actions** | Generate structured action recommendations for human operator approval. | Autonomous execution of external financial, booking, or prod mutations. | Enforces CISO safety mandate until evaluation confidence exceeds `0.95`. |
| **Guardrails & Identity** | Regional Model Armor prompt/response defense + per-service IAM Service Accounts. | Fine-grained per-row user OAuth token passthrough across external SaaS. | Meets baseline enterprise security within the MVP timeline. |

## 4. Risks, Assumptions & Mitigations (`<= 25 words/cell`)

| Risk / Assumption | Severity | Concrete Mitigation |
| :--- | :--- | :--- |
| **Model Endpoint Mismatch (`global` vs regional)** | High | Pin `GOOGLE_CLOUD_LOCATION=global` for Gemini 3 models and regional endpoints (`us-central1`) for Cloud Run/Model Armor. |
| **Downstream Database Latency or Pool Exhaustion** | High | Use MCP Toolbox / AlloyDB singleton connection pooling (`max=20`) with a `5.0s` query timeout and graceful degradation. |
| **Hallucinated Policy Citations** | High | Enforce grounded RAG retrieval, `temperature=0.1`, and automated `hallucinations_v1 >= 0.90` evaluation gates. |
