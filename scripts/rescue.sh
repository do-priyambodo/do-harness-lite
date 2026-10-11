#!/usr/bin/env bash
# rescue.sh (hl-rescue) — Emergency IDE / Agent CLI Recovery & Headless Runner
# Handles hung IDE processes, corrupted OAuth token caches, broken .venv symlinks,
# and bounded headless execution when the GUI freezes.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: hl-rescue [OPTION]

Options:
  --env                 Print export commands for standard Vertex AI & GCP env vars
  --kill                Terminate hung IDE / agent processes (antigravity, code, agy)
  --auth                Clear corrupted OAuth token cache and re-authenticate gcloud
  --fix-venv [DIR]      Rebuild broken Python .venv in DIR (default: current directory)
  --run "<PROMPT>"      Run headless agent CLI with a 180s timeout and auto-permissions
  --help                Show this help message

Typical recovery workflow when the IDE freezes or spins:
  1. hl-rescue --kill
  2. eval "$(hl-rescue --env)"
  3. hl-rescue --run "Read AGENTS.md and complete Task 1, then run hl-verify."
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

case "${1}" in
  --env)
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
    cat <<EOF
export PROJECT_ID="${PROJECT_ID}"
export GOOGLE_CLOUD_PROJECT="${PROJECT_ID}"
export GOOGLE_GENAI_USE_VERTEXAI="True"
export GOOGLE_CLOUD_LOCATION="global"
EOF
    ;;

  --kill)
    echo "[hl-rescue] Terminating hung IDE / agent background processes..."
    for proc in antigravity code agy; do
      if pgrep -f "${proc}" >/dev/null 2>&1; then
        pkill -9 -f "${proc}" 2>/dev/null || true
        echo "  Killed process matching: ${proc}"
      else
        echo "  No running process matching: ${proc}"
      fi
    done
    echo "[hl-rescue] Done."
    ;;

  --auth)
    echo "[hl-rescue] Clearing cached OAuth tokens..."
    rm -rf "${HOME}/.gemini/antigravity-cli/antigravity-oauth-token" \
           "${HOME}/.config/antigravity" 2>/dev/null || true
    echo "[hl-rescue] Running gcloud auth login & application-default login..."
    gcloud auth login --update-adc
    ;;

  --fix-venv)
    TARGET_DIR="${2:-$(pwd)}"
    cd "${TARGET_DIR}" || exit 1
    echo "[hl-rescue] Rebuilding .venv in ${TARGET_DIR}..."
    rm -rf "${TARGET_DIR}/.venv"
    if command -v uv >/dev/null 2>&1; then
      if [[ -f "pyproject.toml" ]]; then
        uv sync
      elif [[ -f "requirements.txt" ]]; then
        uv venv .venv && uv pip install -r requirements.txt
      else
        uv venv .venv
      fi
    else
      python3 -m venv .venv
      [[ -f "requirements.txt" ]] && .venv/bin/pip install -r requirements.txt
    fi
    echo "[hl-rescue] .venv rebuilt cleanly."
    ;;

  --run)
    shift
    if [[ $# -eq 0 ]]; then
      echo "ERROR: --run requires a prompt string." >&2
      exit 1
    fi
    PROMPT="$*"
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
    export PROJECT_ID="${PROJECT_ID}"
    export GOOGLE_CLOUD_PROJECT="${PROJECT_ID}"
    export GOOGLE_GENAI_USE_VERTEXAI="True"
    export GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION:-global}"

    if command -v agy >/dev/null 2>&1; then
      echo "[hl-rescue] Running headless agy (timeout: 180s)..."
      timeout 180s agy -p "${PROMPT}" --dangerously-skip-permissions
    elif command -v gemini >/dev/null 2>&1; then
      echo "[hl-rescue] Running headless gemini CLI (timeout: 180s)..."
      timeout 180s gemini -p "${PROMPT}" --yolo
    else
      echo "ERROR: Neither 'agy' nor 'gemini' CLI found on PATH." >&2
      exit 1
    fi
    ;;

  *)
    usage
    exit 1
    ;;
esac
