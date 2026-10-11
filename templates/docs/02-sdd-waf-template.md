# Software Design Document (SDD) — Google Cloud Well-Architected Agent System

> **Formatting Rule**: Keep every Markdown table cell **<= 25 words**. Ensure all component names, regions, models, and tool contracts match your implementation.

## 1. System Architecture & Component Topology

```text
[Client / UI]
     |  HTTPS (TLS 1.3 + Cloud Armor WAF)
     v
[Cloud Run Service: agent-service (us-central1, web=False, min=0..max=10)]
     |
     +-- 1. before_model_callback --> [Model Armor Regional REP (modelarmor.us-central1.rep.googleapis.com)]
     |
     +-- 2. ADK Root Coordinator (gemini-3.1-pro-preview, GOOGLE_CLOUD_LOCATION=global)
             |
             +-- [ParallelAgent: context_gatherer]
             |      |-- Sub-Agent A: telemetry_agent (gemini-3-flash-preview)
             |      |       `--> [MCP Toolbox / AlloyDB Pool (us-central1, Private IP, IAM Auth)]
             |      `-- Sub-Agent B: policy_rag_agent (gemini-3-flash-preview + Context Cache)
             |              `--> [Vertex AI Search / CMEK GCS Bucket (us-central1)]
             |
             `-- [Sequential / Loop Synthesizer] --> Structured Triage Recommendation (Read-Only HITL)
```

### Component Inventory (`<= 25 words/cell`)

| Layer | Google Cloud Service | Configuration & Endpoint | Purpose |
| :--- | :--- | :--- | :--- |
| **Serving Runtime** | Cloud Run v2 / Agent Runtime | Regional (`us-central1`), `get_fast_api_app(web=False)`, dedicated IAM SA. | Hosts stateless ADK FastAPI server and A2A agent card endpoint. |
| **Reasoning Engine** | Vertex AI Gemini Models | `GOOGLE_CLOUD_LOCATION=global`; `gemini-3.1-pro-preview` (root) & `gemini-3-flash-preview` (sub-agents). | Orchestrates tool routing, parallel retrieval, and grounded synthesis. |
| **Safety Perimeter** | Google Cloud Model Armor | Regional REP (`modelarmor.us-central1.rep.googleapis.com`), PI/Jailbreak + RAI + SDP filters. | Screens inbound user prompts and outbound model responses in callbacks. |
| **Transactional Data** | AlloyDB for PostgreSQL + MCP Toolbox | Regional (`us-central1`), Private IP, singleton pool (`max=20`), parameterized SQL in `tools.yaml`. | Executes sub-100ms operational state queries without raw SQL exposure. |
| **Knowledge & Artifacts** | Vertex AI Context Cache + CMEK GCS | Regional (`us-central1`) GCS bucket with Cloud KMS CMEK + `CachedContent` (`ttl=3600s`). | Stores static policy corpora and evaluation artifacts (`report.json`). |

---

## 2. Explicit Tool & Data Contracts (JSON Schema / Pydantic)

### Tool 1: `lookup_service_status` (Read-Only Operational Telemetry)
```json
{
  "name": "lookup_service_status",
  "description": "Retrieves current operational health and SLA telemetry for a service ID.",
  "parameters": {
    "type": "object",
    "required": ["service_id"],
    "properties": {
      "service_id": {
        "type": "string",
        "pattern": "^[a-z0-9_-]{2,64}$",
        "description": "Unique lowercase service identifier."
      },
      "include_metrics": {
        "type": "boolean",
        "default": false,
        "description": "Whether to attach P95 latency and error rate metrics."
      }
    }
  },
  "returns": {
    "type": "object",
    "required": ["status", "service_id", "state"],
    "properties": {
      "status": { "type": "string", "enum": ["ok", "error"] },
      "service_id": { "type": "string" },
      "state": { "type": "string", "enum": ["HEALTHY", "DEGRADED", "OUTAGE"] },
      "metrics": {
        "type": "object",
        "properties": {
          "p95_ms": { "type": "number" },
          "error_rate": { "type": "number" }
        }
      }
    }
  },
  "error_handling": "Returns {status: 'error', code: 400|404|503, message: '...'} on invalid ID or timeout (5.0s)."
}
```

### Session State & Memory Contract (`<= 25 words/cell`)

| State Key | Scope Prefix | Seeded In | Purpose |
| :--- | :--- | :--- | :--- |
| `customer_tier` | Session (`state["customer_tier"]`) | `before_agent_callback` | Controls SLA policy tier interpolation (`{customer_tier?}`). |
| `user:preferred_language` | User (`user:`) | `before_agent_callback` | Persists operator locale across sessions for the same `user_id`. |
| `app:policy_version` | Application (`app:`) | Startup config | Tracks active SOP corpus version shared across all users. |
| `temp:turn_trace_id` | Ephemeral (`temp:`) | `before_model_callback` | Correlates per-turn logs/metrics; discarded after the turn completes. |

---

## 3. Google Cloud Well-Architected Framework (6 Pillars) (`<= 25 words/cell`)

| WAF Pillar | Architectural Controls Implemented | Verification Artifact |
| :--- | :--- | :--- |
| **1. Operational Excellence** | Automated AST/ADK verification (`hl-verify`), Vertex AI `EvalTask` CI gates (`report.json`), and OpenTelemetry Cloud Trace spans. | `report.json` (`trajectory_exact_match >= 0.85`). |
| **2. Security, Privacy & Compliance** | Dedicated per-service IAM SAs, regional Model Armor callbacks, `before_tool_callback` parameter guards, Secret Manager, and Cloud KMS CMEK. | `semgrep` zero findings; Model Armor template active. |
| **3. Reliability** | Regional multi-zone AlloyDB, singleton DB connection pooling (`max=20`), `5.0s` tool timeouts, exponential backoff on `429`, and graceful fallback. | Zero connection pool exhaustion under concurrent load. |
| **4. Cost Optimization (FinOps)** | Model tiering (`flash` for sub-agents, `pro` for root), Vertex AI `CachedContent` (`ttl=3600s`), `thinking_budget=0` for routing, and billing labels. | GCP resource `labels` (`environment`, `cost_center`, `service`). |
| **5. Performance Efficiency** | `ParallelAgent` concurrent fan-out for independent DB + RAG lookups, connection reuse, and non-blocking async runner execution. | End-to-end P95 latency `< 5.0s`. |
| **6. Sustainability** | Scale-to-zero Cloud Run revisions (`min_instance_count=0` in non-prod) and deterministic `@node`/callback short-circuiting to avoid redundant LLM calls. | Reduced token and vCPU-second footprint per query. |

---

## 4. FinOps Resource Attribution & Deployment Governance
All provisioned Terraform and Cloud Run resources enforce mandatory cost-attribution labels:
```hcl
labels = {
  environment = "production"
  cost_center = "ai-platform"
  service     = "agent-runtime-service"
  managed_by  = "terraform"
}
```
Rollouts use `gcloud run services update --update-env-vars` (preserving existing environment configuration) and traffic-split revision promotion after `adk eval` passes.
