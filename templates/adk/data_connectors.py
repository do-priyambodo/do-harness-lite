"""Data connector patterns for ADK agents: MCP Toolbox, AlloyDB IAM Connector, Secret Manager, and GCS.

Includes connection pooling best practices and parameterized SQL queries.
"""

from __future__ import annotations

import json
import os
from typing import Any

import sqlalchemy


# ---------------------------------------------------------------------------
# 1. MCP Toolbox for Databases (GenAI Toolbox) Loader (ADK Native & Sync Client)
# ---------------------------------------------------------------------------
def build_adk_toolbox_toolset(
    toolbox_url: str = "http://127.0.0.1:5000",
    toolset_name: str = "alloydb_nl2sql",
) -> Any:
    """Returns a native ADK `ToolboxToolset` (`pip install 'google-adk[toolbox]'`).

    Pass directly into `Agent(tools=[build_adk_toolbox_toolset()])`.
    """
    from google.adk.tools.toolbox_toolset import ToolboxToolset

    return ToolboxToolset(
        server_url=os.environ.get("TOOLBOX_URL", toolbox_url),
        toolset_name=os.environ.get("TOOLBOX_TOOLSET_NAME", toolset_name),
    )


def load_mcp_toolbox_tools(
    toolbox_url: str = "http://127.0.0.1:5000",
    toolset_name: str | None = None,
) -> list[Any]:
    """Loads parameterized database tools from a running GenAI MCP Toolbox server via `toolbox_core`.

    Args:
        toolbox_url: Base URL of the running `toolbox` server (default port 5000).
        toolset_name: Optional named toolset from `tools.yaml` (loads all tools if None).

    Returns:
        List of ADK-compatible tool objects to pass into `Agent(tools=[...])`.
    """
    from toolbox_core import ToolboxSyncClient

    client = ToolboxSyncClient(toolbox_url)
    if toolset_name:
        return list(client.load_toolset(toolset_name))
    return list(client.load_toolset())


# ---------------------------------------------------------------------------
# 2. AlloyDB Python Connector + SQLAlchemy Connection Pool (Singleton)
# ---------------------------------------------------------------------------
_ENGINE_CACHE: sqlalchemy.Engine | None = None


def get_alloydb_engine(
    instance_uri: str | None = None,
    db_user: str | None = None,
    db_name: str | None = None,
    db_pass: str | None = None,
    enable_iam_auth: bool = False,
) -> sqlalchemy.Engine:
    """Returns a module-level singleton SQLAlchemy Engine backed by AlloyDB Connector.

    Never instantiate a new Connector/Engine per request; always reuse this pool.
    """
    global _ENGINE_CACHE
    if _ENGINE_CACHE is not None:
        return _ENGINE_CACHE

    from google.cloud.alloydb.connector import Connector, IPTypes

    uri = instance_uri or os.environ["ALLOYDB_INSTANCE_URI"]
    user = db_user or os.environ.get("DB_USER", "postgres")
    name = db_name or os.environ.get("DB_NAME", "postgres")
    password = db_pass or os.environ.get("DB_PASS", "")

    connector = Connector()

    def getconn() -> Any:
        kwargs: dict[str, Any] = {
            "user": user,
            "db": name,
            "ip_type": IPTypes.PUBLIC if os.environ.get("ALLOYDB_PUBLIC_IP") else IPTypes.PRIVATE,
            "enable_iam_auth": enable_iam_auth,
        }
        if not enable_iam_auth:
            kwargs["password"] = password
        return connector.connect(uri, "pg8000", **kwargs)

    _ENGINE_CACHE = sqlalchemy.create_engine(
        "postgresql+pg8000://",
        creator=getconn,
        pool_size=10,
        max_overflow=10,
        pool_timeout=30,
        pool_recycle=1800,
    )
    return _ENGINE_CACHE


def query_records_by_status(status_filter: str, limit: int = 25) -> dict[str, Any]:
    """Queries records matching `status_filter` using a parameterized SQL query.

    Call this tool to retrieve operational records filtered by status.

    Args:
        status_filter: Exact status value to filter on (for example, "OPEN" or "CRITICAL").
        limit: Maximum number of rows to return (1 to 100).

    Returns:
        A dictionary containing `status`, `count`, and `rows`.
    """
    safe_limit = max(1, min(int(limit), 100))
    engine = get_alloydb_engine()
    stmt = sqlalchemy.text(
        "SELECT id, status, updated_at FROM records WHERE status = :status ORDER BY updated_at DESC LIMIT :limit"
    )
    with engine.connect() as conn:
        result = conn.execute(stmt, {"status": status_filter, "limit": safe_limit})
        rows = [dict(row._mapping) for row in result]
    return {"status": "ok", "count": len(rows), "rows": rows}


# ---------------------------------------------------------------------------
# 3. Secret Manager & Cloud Storage JSON Helpers
# ---------------------------------------------------------------------------
def access_secret_version(secret_id: str, version_id: str = "latest") -> str:
    """Fetches a secret payload string from Google Cloud Secret Manager."""
    from google.cloud import secretmanager

    project_id = os.environ["GOOGLE_CLOUD_PROJECT"]
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{project_id}/secrets/{secret_id}/versions/{version_id}"
    response = client.access_secret_version(request={"name": name})
    return response.payload.data.decode("utf-8").strip()


def write_json_to_gcs(bucket_name: str, blob_path: str, payload: dict[str, Any]) -> str:
    """Uploads a JSON dictionary to `gs://{bucket_name}/{blob_path}` and returns the URI."""
    from google.cloud import storage

    clean_bucket = bucket_name.replace("gs://", "").strip("/")
    client = storage.Client()
    bucket = client.bucket(clean_bucket)
    blob = bucket.blob(blob_path)
    blob.upload_from_string(
        json.dumps(payload, indent=2, sort_keys=True),
        content_type="application/json",
    )
    return f"gs://{clean_bucket}/{blob_path}"
