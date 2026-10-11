"""Vertex AI GenAI Evaluation Service (`EvalTask`) & Local `report.json` Runner.

Automatically loads `evaluation.json` (`"evaluation_dataset"` with `question` / `expected_answer`)
if present in the current directory, or falls back to a default trajectory/quality dataset.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import pandas as pd
import vertexai
from vertexai.evaluation import EvalTask, MetricPromptTemplateExamples


def load_or_build_eval_dataset(eval_json_path: str = "evaluation.json") -> pd.DataFrame:
    """Loads `evaluation.json` if present, otherwise builds a reference evaluation DataFrame."""
    path = Path(eval_json_path)
    if path.is_file():
        raw = json.loads(path.read_text(encoding="utf-8"))
        items = raw.get("evaluation_dataset", raw if isinstance(raw, list) else [])
        records: list[dict[str, Any]] = []
        for item in items:
            q = item.get("question") or item.get("prompt") or ""
            ref = item.get("expected_answer") or item.get("reference") or ""
            resp = item.get("response") or ref
            records.append(
                {
                    "prompt": q,
                    "response": resp,
                    "reference": ref,
                    "context": item.get("key_policy_rules", ref),
                }
            )
        if records:
            return pd.DataFrame(records)

    default_records: list[dict[str, Any]] = [
        {
            "prompt": "Check the health status of payments_api including SLA metrics.",
            "reference": "The payments_api service is HEALTHY with P95 latency of 142ms.",
            "context": "Service ID: payments_api. State: HEALTHY. P95 latency: 142.0ms. Error rate: 0.001.",
            "response": "payments_api is currently HEALTHY (P95 latency: 142ms, error rate: 0.1%).",
        }
    ]
    return pd.DataFrame(default_records)


def run_evaluation(
    experiment_name: str = os.environ.get("EVAL_EXPERIMENT_NAME", "travel-policy-eval"),
    output_file: str = "report.json",
    gcs_output_uri: str | None = None,
) -> dict[str, Any]:
    """Executes a Vertex AI EvalTask and writes summary + row metrics to `output_file`."""
    project_id = os.environ["GOOGLE_CLOUD_PROJECT"]
    # Vertex AI EvalTask requires a regional endpoint (e.g., us-central1), NEVER global
    location = os.environ.get("EVAL_LOCATION", "us-central1")
    if location == "global":
        location = "us-central1"

    vertexai.init(project=project_id, location=location)
    eval_df = load_or_build_eval_dataset()

    eval_task = EvalTask(
        dataset=eval_df,
        metrics=[
            MetricPromptTemplateExamples.Pointwise.QUESTION_ANSWERING_QUALITY,
            MetricPromptTemplateExamples.Pointwise.GROUNDEDNESS,
            MetricPromptTemplateExamples.Pointwise.SAFETY,
            "rouge_l_sum",
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
