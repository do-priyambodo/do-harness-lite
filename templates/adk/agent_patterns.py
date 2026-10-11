"""Reference blueprints for Google ADK (1.x & 2.0) agents, workflows, callbacks, and context caching.

Copy only the sections you need into your project's agent module.
All examples obey strict ADK invariants:
  - Agent names match ^[a-zA-Z_][a-zA-Z0-9_]*$ (underscores only)
  - Every tool parameter is typed and every tool has a docstring
  - Sub-agent instances are never shared across two parent agents
  - Instruction state placeholders use {key?} or are seeded in before_agent_callback
"""

from __future__ import annotations

import os
from typing import Any

from google.adk.agents import Agent, LoopAgent, ParallelAgent, SequentialAgent
from google.adk.agents.callback_context import CallbackContext
from google.adk.models import LlmRequest, LlmResponse
from google.adk.tools.agent_tool import AgentTool
from google.adk.tools.base_tool import BaseTool
from google.adk.tools.tool_context import ToolContext
from google.genai import Client
from google.genai import types

# ---------------------------------------------------------------------------
# 1. Environment & Model Defaults
# ---------------------------------------------------------------------------
# Gemini 3 preview models require GOOGLE_CLOUD_LOCATION="global"
os.environ.setdefault("GOOGLE_GENAI_USE_VERTEXAI", "True")
os.environ.setdefault("GOOGLE_CLOUD_LOCATION", "global")

DEFAULT_FAST_MODEL = os.environ.get("ADK_FAST_MODEL", "gemini-3-flash-preview")
DEFAULT_PRO_MODEL = os.environ.get("ADK_PRO_MODEL", "gemini-3.1-pro-preview")


# ---------------------------------------------------------------------------
# 2. Deterministic Custom Tools (Typed + Documented, No @tool Decorator)
# ---------------------------------------------------------------------------
def lookup_service_status(service_id: str, include_metrics: bool = False) -> dict[str, Any]:
    """Looks up the operational status and optional SLA metrics for a given service ID.

    Call this tool when the user asks about the health, uptime, or incident state
    of a named service.

    Args:
        service_id: Unique identifier of the service (for example, "payments_api").
        include_metrics: Whether to include P95 latency and error rate fields.

    Returns:
        A dictionary containing `status`, `service_id`, `state`, and optional `metrics`.
    """
    normalized = service_id.strip().lower()
    result: dict[str, Any] = {
        "status": "ok",
        "service_id": normalized,
        "state": "HEALTHY",
    }
    if include_metrics:
        result["metrics"] = {"p95_ms": 142.0, "error_rate": 0.001}
    return result


def finish_refinement_loop(reason: str, tool_context: ToolContext) -> dict[str, str]:
    """Signals that an iterative LoopAgent has met its quality bar and should exit.

    Call this tool ONLY when all acceptance criteria are satisfied.

    Args:
        reason: Brief explanation of why the loop is complete.
        tool_context: Injected ADK ToolContext used to escalate out of LoopAgent.

    Returns:
        A confirmation dictionary recording the exit reason.
    """
    tool_context.actions.escalate = True
    return {"status": "completed", "reason": reason}


# ---------------------------------------------------------------------------
# 3. Callbacks (State Seeding, Model Guardrail, Tool Policy Guard)
# ---------------------------------------------------------------------------
def seed_default_session_state(callback_context: CallbackContext) -> types.Content | None:
    """Seeds required session state keys before Turn 1 so {var} templates never KeyError."""
    callback_context.state.setdefault("customer_tier", "standard")
    callback_context.state.setdefault("user:preferred_language", "en")
    callback_context.state.setdefault("temp:turn_audit_passed", True)
    # Return None to allow the agent to proceed normally.
    return None


def before_model_guardrail(
    callback_context: CallbackContext, llm_request: LlmRequest
) -> LlmResponse | None:
    """Inspects the outbound prompt before calling the LLM.

    Return `None` to proceed to the model, or return an `LlmResponse` to block/short-circuit.
    """
    _ = callback_context
    last_text = ""
    if llm_request.contents and llm_request.contents[-1].parts:
        last_text = llm_request.contents[-1].parts[0].text or ""

    if "IGNORE ALL PREVIOUS INSTRUCTIONS" in last_text.upper():
        return LlmResponse(
            content=types.Content(
                role="model",
                parts=[types.Part.from_text(text="Request blocked by safety policy.")],
            )
        )
    return None


def before_tool_policy_guard(
    tool: BaseTool, args: dict[str, Any], tool_context: ToolContext
) -> dict[str, Any] | None:
    """Validates tool arguments before execution.

    CRITICAL:
      - Return `None` to allow the tool to execute normally.
      - Return a `dict` ONLY when you want to SKIP the tool and return that dict instead.
    """
    _ = tool_context
    if tool.name == "lookup_service_status":
        svc = str(args.get("service_id", "")).strip()
        if not svc:
            return {"status": "error", "message": "service_id must not be empty."}
    return None


# ---------------------------------------------------------------------------
# 4. Context Caching & Thinking Budget Helper (Token & Latency Optimization)
# ---------------------------------------------------------------------------
def create_context_cache(
    model: str,
    system_instruction: str,
    large_reference_text: str,
    ttl_seconds: int = 3600,
) -> str:
    """Creates a Vertex AI CachedContent resource for large static reference corpora.

    Returns the cache resource name (`cached_content.name`) to reference in GenerateContentConfig.
    """
    client = Client(vertexai=True)
    cache = client.caches.create(
        model=model,
        config=types.CreateCachedContentConfig(
            system_instruction=system_instruction,
            contents=[large_reference_text],
            ttl=f"{ttl_seconds}s",
        ),
    )
    return cache.name or ""


def fast_non_thinking_config(cached_content_name: str | None = None) -> types.GenerateContentConfig:
    """Returns a GenerateContentConfig with thinking_budget=0 for fast classification/routing."""
    return types.GenerateContentConfig(
        temperature=0.1,
        thinking_config=types.ThinkingConfig(thinking_budget=0),
        cached_content=cached_content_name,
    )


# ---------------------------------------------------------------------------
# 5. Multi-Agent Workflow Patterns (Sequential, Parallel, Loop, Root Coordinator)
# ---------------------------------------------------------------------------
def build_reference_multi_agent_system() -> Agent:
    """Builds a clean multi-agent hierarchy without sharing sub-agent instances."""
    # Parallel fan-out branches (each writes to a distinct output_key)
    telemetry_branch = Agent(
        name="telemetry_collector",
        model=DEFAULT_FAST_MODEL,
        description="Collects service health and latency telemetry.",
        instruction="Check service health for the requested service. Tier: {customer_tier?}",
        tools=[lookup_service_status],
        output_key="telemetry_summary",
    )

    policy_branch = Agent(
        name="policy_collector",
        model=DEFAULT_FAST_MODEL,
        description="Summarizes applicable SLA policy tiers.",
        instruction="Summarize SLA rules for customer tier {customer_tier?}.",
        output_key="policy_summary",
    )

    parallel_gather = ParallelAgent(
        name="parallel_context_gather",
        description="Runs telemetry and policy collection concurrently.",
        sub_agents=[telemetry_branch, policy_branch],
    )

    # Iterative refinement loop with explicit max_iterations
    draft_synthesizer = Agent(
        name="draft_synthesizer",
        model=DEFAULT_FAST_MODEL,
        description="Synthesizes gathered telemetry and SLA policy into an action plan.",
        instruction=(
            "Combine telemetry ({telemetry_summary?}) and policy ({policy_summary?}) "
            "into a concise remediation plan. Call finish_refinement_loop once complete."
        ),
        tools=[finish_refinement_loop],
        output_key="final_plan",
    )

    refinement_loop = LoopAgent(
        name="plan_refinement_loop",
        description="Refines the remediation plan up to 2 iterations.",
        sub_agents=[draft_synthesizer],
        max_iterations=2,
    )

    # Sequential pipeline chaining parallel gather -> refinement loop
    diagnostic_pipeline = SequentialAgent(
        name="diagnostic_pipeline",
        description="Executes parallel context gathering followed by plan synthesis.",
        sub_agents=[parallel_gather, refinement_loop],
    )

    # Root coordinator wrapping the workflow via AgentTool (safe for playgrounds & A2A)
    return Agent(
        name="root_operations_coordinator",
        model=DEFAULT_PRO_MODEL,
        description="Root coordinator for service diagnostics and SLA remediation.",
        instruction=(
            "You are the Root Operations Coordinator. Route diagnostic requests "
            "to diagnostic_pipeline and return a clear summary."
        ),
        tools=[AgentTool(agent=diagnostic_pipeline)],
        before_agent_callback=seed_default_session_state,
        before_model_callback=before_model_guardrail,
        before_tool_callback=before_tool_policy_guard,
    )


root_agent = build_reference_multi_agent_system()
