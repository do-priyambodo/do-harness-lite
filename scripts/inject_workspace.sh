#!/usr/bin/env bash
# inject_workspace.sh (hl-inject) — Git-Clean Workspace Rule Injector
# Copies or appends do-harness-lite's AGENTS.md into a target repository and
# hides it via .git/info/exclude so 'git status' stays 100% clean.
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
HARNESS_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
TARGET_DIR="${1:-$(pwd)}"

if [[ ! -d "${TARGET_DIR}" ]]; then
  echo "ERROR: Target directory does not exist: ${TARGET_DIR}" >&2
  exit 1
fi

TARGET_DIR="$(cd "${TARGET_DIR}" && pwd)"
AGENTS_SRC=""
for candidate in \
  "${HARNESS_ROOT}/AGENTS.md" \
  "${DO_HARNESS_LITE_DIR:-}/AGENTS.md" \
  "${HOME}/.local/AGENTS.md" \
  "/tmp/do-harness-lite/AGENTS.md" \
  "${HOME}/do-harness-lite/AGENTS.md" \
  "${HOME}/.agents/AGENTS.md"; do
  if [[ -n "${candidate}" && -f "${candidate}" ]]; then
    AGENTS_SRC="${candidate}"
    break
  fi
done

if [[ -z "${AGENTS_SRC}" ]]; then
  echo "ERROR: Could not locate AGENTS.md in ${HARNESS_ROOT} or fallback paths." >&2
  exit 1
fi

AGENTS_DST="${TARGET_DIR}/AGENTS.md"
MARKER="<!-- do-harness-lite-workspace -->"

if [[ -f "${AGENTS_DST}" ]]; then
  if grep -qF "${MARKER}" "${AGENTS_DST}" 2>/dev/null && [[ "$(wc -l < "${AGENTS_DST}")" -gt 5 ]]; then
    echo "[hl-inject] AGENTS.md in ${TARGET_DIR} already contains do-harness-lite rules."
  elif grep -qF "${MARKER}" "${AGENTS_DST}" 2>/dev/null; then
    {
      echo "${MARKER}"
      cat "${AGENTS_SRC}"
    } > "${AGENTS_DST}"
    echo "[hl-inject] Repaired incomplete ${AGENTS_DST} with full do-harness-lite rules."
  else
    {
      echo ""
      echo "${MARKER}"
      cat "${AGENTS_SRC}"
    } >> "${AGENTS_DST}"
    echo "[hl-inject] Appended do-harness-lite rules to existing ${AGENTS_DST}."
  fi
else
  {
    echo "${MARKER}"
    cat "${AGENTS_SRC}"
  } > "${AGENTS_DST}"
  echo "[hl-inject] Created ${AGENTS_DST}."
  # If this is a git repo and AGENTS.md is untracked, exclude it locally so git status is clean
  if [[ -d "${TARGET_DIR}/.git" ]]; then
    EXCLUDE_FILE="${TARGET_DIR}/.git/info/exclude"
    mkdir -p "$(dirname "${EXCLUDE_FILE}")"
    if ! grep -qxF "AGENTS.md" "${EXCLUDE_FILE}" 2>/dev/null; then
      echo "AGENTS.md" >> "${EXCLUDE_FILE}"
      echo "[hl-inject] Added AGENTS.md to ${EXCLUDE_FILE} (keeps 'git status' clean)."
    fi
  fi
fi
