# Copy-Paste Prompt 02: Technical Discovery & WAF Software Design Document (SDD)

Copy and paste the prompt block below into your coding agent when tasked with producing a Technical Discovery report and/or a Google Cloud Well-Architected Software Design Document (SDD):

```text
Load the `waf-discovery-and-sdd` and `adk-runtime-invariants` skills, and reference `~/do-harness-lite/templates/docs/01-discovery-template.md` and `~/do-harness-lite/templates/docs/02-sdd-waf-template.md`.

Execute this workflow strictly:
1. Read all stakeholder transcripts, briefs, and requirement files in the workspace.
2. Author the Technical Discovery document and/or Software Design Document (SDD) at the exact target file paths required by the instructions.
3. Enforce these non-negotiable quality rules:
   - Keep EVERY Markdown table cell <= 25 words (concise, scannable, zero fluff).
   - Scope Phase 1 MVP strictly to Read-Only data/policy retrieval + grounded triage recommendations + Human-in-the-Loop (HITL) approval. Explicitly defer autonomous destructive production/financial write actions to Phase 2.
   - Include an ASCII or Mermaid component topology diagram showing Cloud Run (`web=False`), Regional Model Armor (`modelarmor.<region>.rep.googleapis.com`), ADK Root Coordinator (`GOOGLE_CLOUD_LOCATION=global`), `ParallelAgent` / `SequentialAgent` sub-agents, MCP Toolbox / AlloyDB connection pooling, and Vertex AI Context Caching.
   - Include explicit JSON Schema / Pydantic contracts for at least 2 core tools (parameters, return schema, error codes, and timeouts).
   - Cover all 6 Google Cloud Well-Architected Framework (WAF) pillars (Operational Excellence, Security, Reliability, Cost Optimization / FinOps with `labels`, Performance Efficiency, and Sustainability).
   - Leave zero `TODO` or `TBD` placeholders anywhere in the document.
```
