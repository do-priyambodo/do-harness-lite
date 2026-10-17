#!/usr/bin/env python3
"""verify_lite.py (hl-verify) — <2s Zero-Dependency ADK & Python Verification Gate.

Checks Python/ADK workspaces without adding any files or requiring third-party packages:
  1. SYNTAX_ERROR: Every .py file parses via ast.parse().
  2. INVALID_AGENT_NAME: Agent/LlmAgent/SequentialAgent/ParallelAgent/LoopAgent name=
     must be a valid Python identifier with underscores, never hyphens (^[a-zA-Z_][a-zA-Z0-9_]*$).
  3. HALLUCINATED_DECORATOR: Flags @*.skill or @*.tool decorators that crash ADK at import time.
  4. DUPLICATE_SUBAGENT_PARENT: Flags the same variable passed into sub_agents=[...] on multiple
     parent agents (raises ValueError: Agent already has a parent_agent).
  5. UNSAFE_STATE_PLACEHOLDER (WARN): Flags {var} without trailing '?' ({var?}) in instruction=.
  6. UNTYPED_OR_UNDOCUMENTED_TOOL (WARN): Flags local functions in tools=[...] missing type hints
     or docstrings.
  7. HARDCODED_API_KEY (WARN / --strict-secrets FAIL): Flags literal AIzaSy... or ghp_... keys.
  8. ENTRYPOINT_IMPORT_SMOKE: Verifies top-level agent.py / main.py defines root_agent or app
     and imports cleanly in a subprocess (--no-import-smoke to skip).
"""

from __future__ import annotations

import argparse
import ast
import os
import pathlib
import re
import subprocess
import sys
import tempfile

SKIP_DIRS = {
    ".venv",
    "venv",
    "env",
    "site-packages",
    "node_modules",
    ".git",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    "dist",
    "build",
    ".terraform",
}

AGENT_CLASSES = {
    "Agent",
    "LlmAgent",
    "SequentialAgent",
    "ParallelAgent",
    "LoopAgent",
}

ENTRYPOINT_FILES = {"agent.py", "main.py"}
VALID_IDENTIFIER_RE = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")
STATE_PLACEHOLDER_RE = re.compile(r"\{([a-zA-Z_][a-zA-Z0-9_:]*)\}")
SECRET_PATTERNS = [
    ("GOOGLE_API_KEY", re.compile(r"AIzaSy[A-Za-z0-9_\-]{10,}")),
    ("GITHUB_PAT", re.compile(r"(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})")),
    ("PRIVATE_KEY_HEADER", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
]


def _call_func_name(node: ast.Call) -> str | None:
    if isinstance(node.func, ast.Name):
        return node.func.id
    if isinstance(node.func, ast.Attribute):
        return node.func.attr
    return None


def _top_level_assigned_names(tree: ast.Module) -> set[str]:
    names: set[str] = set()
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    names.add(target.id)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names.add(node.target.id)
    return names


def check_python_file(
    py_path: pathlib.Path,
    strict_secrets: bool = False,
) -> tuple[list[str], list[str], ast.Module | None]:
    errors: list[str] = []
    warnings: list[str] = []

    try:
        src = py_path.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"{py_path}: [IO_ERROR] {exc}"], warnings, None

    # Secret check
    for label, pattern in SECRET_PATTERNS:
        for line_no, line in enumerate(src.splitlines(), 1):
            if "harness-allow" in line:
                continue
            if pattern.search(line):
                msg = f"{py_path}:{line_no} [HARDCODED_SECRET:{label}] Hardcoded secret pattern detected."
                if strict_secrets:
                    errors.append(msg)
                else:
                    warnings.append(msg)

    try:
        tree = ast.parse(src, filename=str(py_path))
    except SyntaxError as exc:
        errors.append(f"{py_path}:{exc.lineno} [SYNTAX_ERROR] {exc.msg}")
        return errors, warnings, None

    # Collect local function definitions for tool checks and decorator checks
    local_funcs: dict[str, ast.FunctionDef | ast.AsyncFunctionDef] = {}
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            local_funcs[node.name] = node
            for dec in node.decorator_list:
                if isinstance(dec, ast.Attribute) and dec.attr in {"skill", "tool"}:
                    if isinstance(dec.value, ast.Name):
                        errors.append(
                            f"{py_path}:{node.lineno} [HALLUCINATED_DECORATOR] "
                            f"'@{dec.value.id}.{dec.attr}' on '{node.name}' will crash at runtime; "
                            f"pass '{node.name}' inside tools=[{node.name}] instead."
                        )

    # Walk AST for Agent(...), get_fast_api_app(...), and Pointwise.RELEVANCE
    subagent_parents: dict[str, list[int]] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and node.attr == "RELEVANCE":
            if isinstance(node.value, ast.Attribute) and node.value.attr == "Pointwise":
                errors.append(
                    f"{py_path}:{node.lineno} [INVALID_EVAL_METRIC] "
                    f"'Pointwise.RELEVANCE' does not exist in vertexai.evaluation; "
                    f"use 'Pointwise.QUESTION_ANSWERING_QUALITY' or 'Pointwise.INSTRUCTION_FOLLOWING'."
                )

        if not isinstance(node, ast.Call):
            continue
        fn_name = _call_func_name(node)
        if fn_name == "get_fast_api_app":
            kw_names = {kw.arg for kw in node.keywords if kw.arg}
            if "adk_app" in kw_names:
                errors.append(
                    f"{py_path}:{node.lineno} [INVALID_FAST_API_APP_KWARG] "
                    f"get_fast_api_app() does not accept 'adk_app='; use get_fast_api_app(agents_dir='.', web=False) "
                    f"(or omit get_fast_api_app entirely when deploying to Vertex AI Agent Runtime)."
                )
            continue

        if fn_name not in AGENT_CLASSES:
            continue

        kw_map = {kw.arg: kw.value for kw in node.keywords if kw.arg}

        # 1. Validate Agent(name=...)
        name_node = kw_map.get("name")
        if isinstance(name_node, ast.Constant) and isinstance(name_node.value, str):
            agent_name = name_node.value
            if not VALID_IDENTIFIER_RE.match(agent_name):
                errors.append(
                    f"{py_path}:{name_node.lineno} [INVALID_AGENT_NAME] "
                    f"Agent name {agent_name!r} is invalid; ADK requires underscores, never hyphens "
                    f"(e.g. {agent_name.replace('-', '_')!r})."
                )

        # 2. Check instruction= for {state_var} without trailing '?'
        instr_node = kw_map.get("instruction")
        if isinstance(instr_node, ast.Constant) and isinstance(instr_node.value, str):
            for match in STATE_PLACEHOLDER_RE.finditer(instr_node.value):
                var_name = match.group(1)
                warnings.append(
                    f"{py_path}:{instr_node.lineno} [UNSAFE_STATE_PLACEHOLDER] "
                    f"Instruction uses '{{{var_name}}}' without trailing '?'. "
                    f"Prefer '{{{var_name}?}}' to avoid Turn-1 KeyError."
                )

        # 3. Check tools=[...] for local function docstrings & type annotations
        tools_node = kw_map.get("tools")
        if isinstance(tools_node, (ast.List, ast.Tuple)):
            for elt in tools_node.elts:
                if isinstance(elt, ast.Name) and elt.id in local_funcs:
                    fn_def = local_funcs[elt.id]
                    if not ast.get_docstring(fn_def):
                        warnings.append(
                            f"{py_path}:{fn_def.lineno} [UNDOCUMENTED_TOOL] "
                            f"Tool function '{fn_def.name}' has no docstring (ADK uses docstrings to route tool calls)."
                        )
                    non_self_args = [
                        a
                        for a in fn_def.args.args
                        if a.arg not in {"self", "cls", "tool_context"}
                    ]
                    untyped = [a.arg for a in non_self_args if a.annotation is None]
                    if untyped:
                        warnings.append(
                            f"{py_path}:{fn_def.lineno} [UNTYPED_TOOL_PARAM] "
                            f"Tool function '{fn_def.name}' is missing type hints on {untyped}."
                        )

        # 4. Track sub_agents=[...] variables to catch single-parent violations
        sub_node = kw_map.get("sub_agents")
        if isinstance(sub_node, (ast.List, ast.Tuple)):
            for elt in sub_node.elts:
                if isinstance(elt, ast.Name):
                    subagent_parents.setdefault(elt.id, []).append(node.lineno)

    for sub_var, lines in subagent_parents.items():
        if len(lines) > 1:
            errors.append(
                f"{py_path}:{lines[-1]} [DUPLICATE_SUBAGENT_PARENT] "
                f"Sub-agent variable '{sub_var}' is attached to multiple parent agents (lines {lines}). "
                f"ADK raises 'ValueError: Agent already has a parent_agent' — use a factory function."
            )

    return errors, warnings, tree


def verify_directory(
    root: pathlib.Path,
    run_import_smoke: bool = True,
    strict_secrets: bool = False,
) -> int:
    errors: list[str] = []
    warnings: list[str] = []
    py_count = 0

    for py_path in sorted(root.rglob("*.py")):
        rel_parts = py_path.relative_to(root).parts
        if SKIP_DIRS.intersection(rel_parts):
            continue
        if py_path.name == "verify_lite.py":
            continue
        py_count += 1
        f_errs, f_warns, tree = check_python_file(py_path, strict_secrets=strict_secrets)
        errors.extend(f_errs)
        warnings.extend(f_warns)

        # Entrypoint check on top-level agent.py / main.py (skip sub_agents/ and tests/)
        if (
            tree is not None
            and py_path.name in ENTRYPOINT_FILES
            and not {"sub_agents", "tests", "test", "demo", "templates"}.intersection(rel_parts)
        ):
            names = _top_level_assigned_names(tree)
            if not ({"root_agent", "app"} & names):
                warnings.append(
                    f"{py_path}:1 [MISSING_ENTRYPOINT_SYMBOL] "
                    f"{py_path.name} does not assign module-level 'root_agent' or 'app'."
                )
            elif run_import_smoke:
                mod_dir = str(py_path.parent.resolve())
                pkg_root = str(root.resolve())
                mod_name = py_path.stem
                env = os.environ.copy()
                env.setdefault("GOOGLE_GENAI_USE_VERTEXAI", "True")
                env.setdefault("GOOGLE_CLOUD_LOCATION", "global")
                cmd = [
                    sys.executable,
                    "-c",
                    f"import sys; sys.path[:0] = [{mod_dir!r}, {pkg_root!r}]; import {mod_name}",
                ]
                try:
                    res = subprocess.run(cmd, capture_output=True, text=True, timeout=8, env=env)
                    if res.returncode != 0:
                        err_tail = "\n".join(res.stderr.strip().splitlines()[-6:])
                        errors.append(
                            f"{py_path}:1 [ENTRYPOINT_IMPORT_FAILED] "
                            f"Importing {py_path} failed (exit {res.returncode}):\n{err_tail}"
                        )
                except subprocess.TimeoutExpired:
                    warnings.append(f"{py_path}:1 [IMPORT_TIMEOUT] Importing {py_path} timed out after 8s.")

    for w in warnings:
        print(f"⚠️  WARN: {w}")
    for e in errors:
        print(f"❌ FAIL: {e}")

    if errors:
        print(f"\n[FAIL] {len(errors)} error(s), {len(warnings)} warning(s) across {py_count} Python file(s).")
        return 1

    print(f"✅ [PASS] {py_count} Python file(s) verified ({len(warnings)} advisory warning(s)).")
    return 0


def run_selftest() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tdir = pathlib.Path(tmp)
        bad_file = tdir / "bad_agent.py"
        bad_file.write_text(
            'class Dummy:\n'
            '    def skill(self, fn): return fn\n'
            'root_agent = Dummy()\n'
            '@root_agent.skill\n'
            'def my_tool(x):\n'
            '    return x\n'
            'def Agent(**kwargs): return kwargs\n'
            'def get_fast_api_app(**kwargs): return kwargs\n'
            'app = get_fast_api_app(adk_app=root_agent, web=False)\n'
            'm = MetricPromptTemplateExamples.Pointwise.RELEVANCE\n'
            'sub = Agent(name="bad-hyphen-name", instruction="Hello {missing_q}", tools=[my_tool])\n'
            'p1 = Agent(name="parent_one", sub_agents=[sub])\n'
            'p2 = Agent(name="parent_two", sub_agents=[sub])\n',
            encoding="utf-8",
        )
        errs, warns, _ = check_python_file(bad_file)
        codes = " ".join(errs + warns)
        for expected in [
            "HALLUCINATED_DECORATOR",
            "INVALID_AGENT_NAME",
            "DUPLICATE_SUBAGENT_PARENT",
            "UNSAFE_STATE_PLACEHOLDER",
            "UNDOCUMENTED_TOOL",
            "UNTYPED_TOOL_PARAM",
            "INVALID_FAST_API_APP_KWARG",
            "INVALID_EVAL_METRIC",
        ]:
            if expected not in codes:
                print(f"[SELFTEST FAIL] Expected {expected} in {codes}")
                return 1
    print("✅ verify_lite.py --selftest PASSED (all 8 detector classes verified).")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Fast zero-dependency ADK & Python verifier.")
    parser.add_argument("target", nargs="?", default=".", help="Target directory to verify")
    parser.add_argument("--no-import-smoke", action="store_true", help="Skip subprocess import smoke check")
    parser.add_argument("--strict-secrets", action="store_true", help="Fail on hardcoded API key patterns")
    parser.add_argument("--selftest", action="store_true", help="Run built-in detector self-tests")
    args = parser.parse_args()

    if args.selftest:
        return run_selftest()

    target_path = pathlib.Path(args.target).resolve()
    if not target_path.exists():
        print(f"Error: path {target_path} does not exist.", file=sys.stderr)
        return 2
    return verify_directory(
        target_path,
        run_import_smoke=not args.no_import_smoke,
        strict_secrets=args.strict_secrets,
    )


if __name__ == "__main__":
    sys.exit(main())
