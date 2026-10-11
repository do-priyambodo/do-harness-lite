"""Model Armor Regional Endpoint (REP) sanitization helper and ADK callbacks.

CRITICAL TRAP AVOIDED:
Model Armor MUST use the regional endpoint:
    f"modelarmor.{location}.rep.googleapis.com"
Calling the default global endpoint or passing `location="global"` fails.
"""

from __future__ import annotations

import os
from typing import Any

from google.adk.agents.callback_context import CallbackContext
from google.adk.models import LlmRequest, LlmResponse
from google.api_core.client_options import ClientOptions
from google.cloud import modelarmor_v1
from google.genai import types


def get_model_armor_client(location: str = "us-central1") -> modelarmor_v1.ModelArmorClient:
    """Initializes a ModelArmorClient bound to the required regional REP endpoint."""
    if location == "global":
        location = "us-central1"
    return modelarmor_v1.ModelArmorClient(
        client_options=ClientOptions(
            api_endpoint=f"modelarmor.{location}.rep.googleapis.com"
        )
    )


def build_template_path(
    project_id: str | None = None,
    location: str = "us-central1",
    template_id: str | None = None,
) -> str:
    """Builds the full resource name `projects/{p}/locations/{l}/templates/{t}`."""
    pid = project_id or os.environ.get("GOOGLE_CLOUD_PROJECT", "")
    loc = "us-central1" if location == "global" else location
    tid = template_id or os.environ.get("MODEL_ARMOR_TEMPLATE_ID", "default-safety-template")
    if tid.startswith("projects/"):
        return tid
    return f"projects/{pid}/locations/{loc}/templates/{tid}"


def check_user_prompt_safety(
    prompt_text: str,
    project_id: str | None = None,
    location: str = "us-central1",
    template_id: str | None = None,
) -> dict[str, Any]:
    """Sanitizes a user prompt via Model Armor and reports whether a filter matched.

    Args:
        prompt_text: Raw user prompt text to inspect.
        project_id: Google Cloud project ID.
        location: Regional location for the Model Armor template (for example, "us-central1").
        template_id: Model Armor template ID or full resource path.

    Returns:
        A dict with `blocked` (bool), `match_state` (str), and `template` (str).
    """
    client = get_model_armor_client(location=location)
    template_name = build_template_path(project_id, location, template_id)
    request = modelarmor_v1.SanitizeUserPromptRequest(
        name=template_name,
        user_prompt_data=modelarmor_v1.DataItem(text=prompt_text),
    )
    response = client.sanitize_user_prompt(request=request)
    result = response.sanitization_result
    matched = result.filter_match_state == modelarmor_v1.FilterMatchState.MATCH_FOUND
    return {
        "blocked": bool(matched),
        "match_state": result.filter_match_state.name,
        "template": template_name,
    }


def check_model_response_safety(
    response_text: str,
    project_id: str | None = None,
    location: str = "us-central1",
    template_id: str | None = None,
) -> dict[str, Any]:
    """Sanitizes a model response via Model Armor and reports whether a filter matched.

    Args:
        response_text: Model output text to inspect.
        project_id: Google Cloud project ID.
        location: Regional location for the Model Armor template.
        template_id: Model Armor template ID or full resource path.

    Returns:
        A dict with `blocked` (bool), `match_state` (str), and `template` (str).
    """
    client = get_model_armor_client(location=location)
    template_name = build_template_path(project_id, location, template_id)
    request = modelarmor_v1.SanitizeModelResponseRequest(
        name=template_name,
        model_response_data=modelarmor_v1.DataItem(text=response_text),
    )
    response = client.sanitize_model_response(request=request)
    result = response.sanitization_result
    matched = result.filter_match_state == modelarmor_v1.FilterMatchState.MATCH_FOUND
    return {
        "blocked": bool(matched),
        "match_state": result.filter_match_state.name,
        "template": template_name,
    }


def model_armor_before_model_callback(
    callback_context: CallbackContext, llm_request: LlmRequest
) -> LlmResponse | None:
    """ADK `before_model_callback` that blocks unsafe user prompts using Model Armor."""
    _ = callback_context
    if not llm_request.contents or not llm_request.contents[-1].parts:
        return None
    user_text = llm_request.contents[-1].parts[0].text or ""
    if not user_text.strip():
        return None

    verdict = check_user_prompt_safety(user_text)
    if verdict["blocked"]:
        return LlmResponse(
            content=types.Content(
                role="model",
                parts=[
                    types.Part.from_text(
                        text="I cannot fulfill that request because it triggered safety filters."
                    )
                ],
            )
        )
    return None
