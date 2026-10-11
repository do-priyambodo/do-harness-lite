"""Vertex AI GenAI Evaluation Service (`EvalTask`) & Local `report.json` Runner.

Supports both trajectory metrics (`trajectory_exact_match`, `trajectory_in_order_match`,
`trajectory_any_order_match`, `trajectory_precision`, `trajectory_recall`,
`trajectory_single_tool_use`) and response quality metrics (`coherence`, `fluency`,
`safety`, `groundedness`, `ROUGE`), saving results to local `report.json` and optional GCS.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import pandas as pd
import vertexai
from vertexai.evaluation import EvalTask, MetricPromptTemplateExamples


def build_default_eval_dataset() -> pd.DataFrame:
    """Constructs a sample evaluation DataFrame with prompt, reference trajectory, and response."""
    records: list[dict[str, Any]] = [
        {
            "prompt": "Check the health status of payments_api including SLA metrics.",
            "reference": "The payments_api service is HEALTHY with P95 latency of 142ms.",
            "context": "Service ID: payments_api. State: HEALTHY. P95 latency: 142.0ms. Error rate: 0.001.",
            "response": "payments_api is currently HEALTHY (P95 latency: 142ms, error rate: 0.1%).",
            "reference_trajectory": [
                {
                    "tool_name": "lookup_service_status",
                    "tool_input": {"service_id": "payments_api", "include_metrics": True},
                }
            ],
            "predicted_trajectory": [
                {
                    "tool_name": "lookup_service_status",
                    "tool_input": {"service_id": "payments_api", "include_metrics": True},
                }
            ],
        }
    ]
    return pd.DataFrame(records)


def run_evaluation(
    experiment_name: str = "agent-quality-eval",
    output_file: str = "report.json",
    gcs_output_uri: str | None = None,
) -> dict[str, Any]:
    """Executes a Vertex AI EvalTask and writes summary + row metrics to `output_file`."""
    project_id = os.environ["GOOGLE_CLOUD_PROJECT"]
    # Vertex AI EvalTask requires a regional endpoint (e.g., us-central1)
    location = os.environ.get("EVAL_LOCATION", "us-central1")
    if location == "global":
        location = "us-central1"

    vertexai.init(project=project_id, location=location)
    eval_df = build_default_eval_dataset()

    eval_task = EvalTask(
        dataset=eval_df,
        metrics=[
            "trajectory_exact_match",
            "trajectory_in_order_match",
            "trajectory_precision",
            "rouge_l_sum",
            MetricPromptTemplateExamples.Pointwise.COHERENCE,
            MetricPromptTemplateExamples.Pointwise.GROUNDEDNESS,
            MetricPromptTemplateExamples.Pointwise.SAFETY,
        ],
        experiment=experiment_name,
        output_uri_prefix=gcs_output_uri,
    )

    eval_result = eval_task.evaluate()
    summary_metrics = {
        k: (float(v) if isinstance(v, (int, float)) else str(v))
        for k, v in (eval_result.summary_metrics or {}).items()
    }
    rows_output = (
        eval_result.metrics_table.to_dict(orient="records")
        if eval_result.metrics_table is not None
        else []
    )

    report_payload: dict[str, Any] = {
        "experiment": experiment_name,
        "project_id": project_id,
        "location": location,
        "summary_metrics": summary_metrics,
        "results": rows_output,
    }

    Path(output_file).write_text(json.dumps(report_payload, indent=2), encoding="utf-8")
    print(f"[eval] Saved evaluation report to {output_file}")
    print(f"[eval] Summary metrics: {json.dumps(summary_metrics, indent=2)}")
    return report_payload


if __name__ == "__main__":
    run_evaluation()
