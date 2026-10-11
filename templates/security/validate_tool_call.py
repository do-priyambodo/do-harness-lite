#!/usr/bin/env python3
"""PreToolUse runtime guardrail hook for coding agents (.agents/hooks.json).

Reads tool invocation JSON from stdin, blocks destructive commands (`rm -rf /`, `mkfs`,
`DROP TABLE`, `gcloud projects delete`, or Cloud Run `--set-env-vars`), and exits 1 on violation.
"""

from __future__ import annotations

import json
import re
import sys

DESTRUCTIVE_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (
        re.compile(r"\bgcloud\s+run\s+(services\s+update|deploy)\b.*--set-env-vars\b"),
        "Blocked: Use --update-env-vars instead of --set-env-vars on Cloud Run.",
    ),
    (
        re.compile(r"rm\s+-rf\s+(/|\$HOME|~|\.)(\s|$|\")"),
        "Blocked: Refusing destructive rm -rf on root, home, or workspace root.",
    ),
    (
        re.compile(r"\bmkfs(\.[a-z0-9]+)?\b", re.IGNORECASE),
        "Blocked: Refusing destructive mkfs filesystem command.",
    ),
    (
        re.compile(r"\bDROP\s+(TABLE|DATABASE)\b", re.IGNORECASE),
        "Blocked: Refusing destructive DROP TABLE / DROP DATABASE statement.",
    ),
    (
        re.compile(r"\bgcloud\s+projects\s+delete\b"),
        "Blocked: Refusing gcloud projects delete.",
    ),
]


def main() -> int:
    raw = sys.stdin.read().strip()
    if not raw:
        return 0
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        serialized = raw
    else:
        tool_input = payload.get("tool_input") or payload.get("input") or payload
        serialized = json.dumps(tool_input)

    for pattern, reason in DESTRUCTIVE_PATTERNS:
        if pattern.search(serialized):
            print(json.dumps({"decision": "block", "reason": reason}))
            print(reason, file=sys.stderr)
            return 1

    print(json.dumps({"decision": "allow"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
