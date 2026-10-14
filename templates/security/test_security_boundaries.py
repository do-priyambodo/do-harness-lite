"""Hermetic outcome-based security boundary test template (pytest).

Adapt imports (`execute_action`, `InputSchema`, `STATE_STORE`) to match the target workspace module.
Run with: pytest -q
"""

from __future__ import annotations

import os
from pathlib import Path
import re

from pydantic import BaseModel, Field, ValidationError
import pytest


class SecureOrderInput(BaseModel):
    """Reference strict Pydantic v2 boundary schema."""

    user_id: str = Field(..., min_length=1, max_length=64, pattern=r"^[a-zA-Z0-9_\-]+$")
    item_id: str = Field(..., min_length=1, max_length=64, pattern=r"^[a-zA-Z0-9_\-]+$")
    quantity: int = Field(..., gt=0, le=100)
    coupon_code: str | None = Field(default=None, max_length=32, pattern=r"^[A-Z0-9_\-]+$")


_REDEEMED_COUPONS: set[str] = set()


def process_secure_order(payload: dict) -> dict:
    """Reference outcome-based domain function enforcing auth, schema, and replay boundaries."""
    validated = SecureOrderInput.model_validate(payload)
    if validated.user_id.lower().startswith("guest"):
        return {"status": "error", "reason": "Registered user account required"}
    if validated.coupon_code:
        if validated.coupon_code in _REDEEMED_COUPONS:
            return {"status": "error", "reason": "Coupon has already been redeemed"}
        _REDEEMED_COUPONS.add(validated.coupon_code)
    return {"status": "ok", "user_id": validated.user_id, "quantity": validated.quantity}


@pytest.fixture(autouse=True)
def _reset_state() -> None:
    """Guarantee hermetic test isolation before and after every test."""
    _REDEEMED_COUPONS.clear()
    yield
    _REDEEMED_COUPONS.clear()


def test_negative_or_zero_quantity_rejected() -> None:
    """Tampering/DoS boundary: quantity <= 0 must raise ValidationError."""
    with pytest.raises(ValidationError):
        SecureOrderInput(user_id="user_1", item_id="sku_1", quantity=0)
    with pytest.raises(ValidationError):
        SecureOrderInput(user_id="user_1", item_id="sku_1", quantity=-5)


def test_injection_payload_rejected_by_pattern() -> None:
    """Tampering boundary: SQL/shell metacharacters in identifiers must fail schema validation."""
    with pytest.raises(ValidationError):
        SecureOrderInput(user_id="user_1; DROP TABLE users;--", item_id="sku_1", quantity=1)


def test_guest_user_blocked() -> None:
    """Spoofing/Privilege boundary: guest callers cannot execute protected actions."""
    res = process_secure_order({"user_id": "guest_anon", "item_id": "sku_1", "quantity": 1})
    assert res["status"] == "error"
    assert "Registered user" in res["reason"]


def test_single_use_coupon_cannot_be_replayed() -> None:
    """Tampering/Replay boundary: single-use token succeeds once and is rejected on replay."""
    first = process_secure_order(
        {"user_id": "user_1", "item_id": "sku_1", "quantity": 1, "coupon_code": "SAVE20"}
    )
    assert first["status"] == "ok"

    replay = process_secure_order(
        {"user_id": "user_2", "item_id": "sku_1", "quantity": 1, "coupon_code": "SAVE20"}
    )
    assert replay["status"] == "error"
    assert "already been redeemed" in replay["reason"]


def test_no_hardcoded_google_api_key_in_source() -> None:
    """Information Disclosure boundary: source files must not contain hardcoded AIzaSy keys."""
    key_pattern = re.compile(r"AIza" + r"Sy[A-Za-z0-9_\-]{20,}")
    repo_root = Path(os.getcwd())
    for py_file in repo_root.rglob("*.py"):
        if ".venv" in py_file.parts or "node_modules" in py_file.parts:
            continue
        content = py_file.read_text(encoding="utf-8", errors="ignore")
        assert not key_pattern.search(content), f"Hardcoded API key found in {py_file}"
