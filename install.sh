#!/usr/bin/env bash
# ==============================================================================
# do-harness-lite — Global & Stealth Installer for Blank Linux / Cloud VMs
# Usage:
#   bash ~/do-harness-lite/install.sh [optional_workspace_dir]
# ==============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"

echo "🚀 Installing do-harness-lite (Global Mode) from ${REPO_DIR} ..."

# 1. Ensure global directories exist
mkdir -p "${BIN_DIR}"
mkdir -p "${HOME}/.gemini/config/skills"
mkdir -p "${HOME}/.gemini/antigravity/skills"
mkdir -p "${HOME}/.agents/skills"

# 2. Make all scripts executable and link hl-* commands into ~/.local/bin
chmod +x "${REPO_DIR}/scripts/"*.sh "${REPO_DIR}/scripts/"*.py 2>/dev/null || true

ln -sf "${REPO_DIR}/scripts/check_env.sh"        "${BIN_DIR}/hl-env"
ln -sf "${REPO_DIR}/scripts/verify_lite.py"      "${BIN_DIR}/hl-verify"
ln -sf "${REPO_DIR}/scripts/verify_lite.py"      "${BIN_DIR}/verify_lite.py"
ln -sf "${REPO_DIR}/scripts/rescue.sh"           "${BIN_DIR}/hl-rescue"
ln -sf "${REPO_DIR}/scripts/adk_ops.sh"          "${BIN_DIR}/hl-adk"
ln -sf "${REPO_DIR}/scripts/inject_workspace.sh" "${BIN_DIR}/hl-inject"
cp -f "${REPO_DIR}/AGENTS.md"                    "${HOME}/.local/AGENTS.md"

# 3. Install skills into all global discovery paths (Antigravity 2.0, agy CLI, Gemini CLI)
for skill_dir in "${REPO_DIR}/.agents/skills/"*/; do
  [ -d "${skill_dir}" ] || continue
  skill_name="$(basename "${skill_dir}")"
  rm -rf "${HOME}/.gemini/config/skills/${skill_name}" \
         "${HOME}/.gemini/antigravity/skills/${skill_name}" \
         "${HOME}/.agents/skills/${skill_name}"
  cp -R "${skill_dir}" "${HOME}/.gemini/config/skills/${skill_name}"
  cp -R "${skill_dir}" "${HOME}/.gemini/antigravity/skills/${skill_name}"
  cp -R "${skill_dir}" "${HOME}/.agents/skills/${skill_name}"
  echo "   ✅ Installed global skill: ${skill_name}"
done

# 4. Install global AGENTS.md / GEMINI.md instructions (non-destructive append if file exists)
MARKER="<!-- do-harness-lite:global-rules -->"
for target_doc in "${HOME}/.gemini/GEMINI.md" "${HOME}/.agents/AGENTS.md"; do
  if [ -f "${target_doc}" ]; then
    if ! grep -q "${MARKER}" "${target_doc}" 2>/dev/null; then
      printf '\n%s\n' "${MARKER}" >> "${target_doc}"
      cat "${REPO_DIR}/AGENTS.md" >> "${target_doc}"
      echo "   ✅ Appended global rules to ${target_doc}"
    fi
  else
    printf '%s\n' "${MARKER}" > "${target_doc}"
    cat "${REPO_DIR}/AGENTS.md" >> "${target_doc}"
    echo "   ✅ Created global rules at ${target_doc}"
  fi
done

# 5. Ensure ~/.local/bin and standard Vertex AI env defaults are in ~/.bashrc
BASHRC="${HOME}/.bashrc"
touch "${BASHRC}"
if ! grep -q "do-harness-lite:bashrc" "${BASHRC}" 2>/dev/null; then
  cat >> "${BASHRC}" <<EOF

# do-harness-lite:bashrc
export PATH="\${HOME}/.local/bin:\${PATH}"
export DO_HARNESS_LITE_DIR="${REPO_DIR}"
export GOOGLE_GENAI_USE_VERTEXAI="\${GOOGLE_GENAI_USE_VERTEXAI:-True}"
export GOOGLE_CLOUD_LOCATION="\${GOOGLE_CLOUD_LOCATION:-global}"
EOF
  echo "   ✅ Added PATH and Vertex AI global defaults to ~/.bashrc"
fi

# 6. If an optional target workspace directory was passed, stealth-inject AGENTS.md
if [ "${1:-}" != "" ]; then
  "${REPO_DIR}/scripts/inject_workspace.sh" "$1"
fi

echo ""
echo "========================================================================"
echo "✅ do-harness-lite installed globally!"
echo "   Run: source ~/.bashrc"
echo "   Commands available anywhere:"
echo "     hl-env [dir]              # 60s GCP & workspace diagnostic"
echo "     hl-verify [dir]           # <2s AST + ADK trap + import smoke check"
echo "     hl-inject <dir>           # Stealth-inject AGENTS.md (.git/info/exclude)"
echo "     hl-rescue [--kill|--auth] # Unfreeze IDE/agy locks & restore env vars"
echo "     hl-adk <cmd>              # ADK / agents-cli / Cloud Run / Registry / Eval helper"
echo "========================================================================"
