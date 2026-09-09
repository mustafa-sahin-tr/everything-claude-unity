#!/usr/bin/env bash
# ============================================================================
# everything-claude-unity installer
# One-command setup for Unity projects
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<user>/everything-claude-unity/main/install.sh | bash
#   # or from cloned repo:
#   ./install.sh [--project-dir <path>]
# ============================================================================

set -eo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
if [ -t 1 ] && command -v tput &>/dev/null; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" RESET=""
fi

info()  { echo "${BLUE}[INFO]${RESET} $*"; }
ok()    { echo "${GREEN}[OK]${RESET}   $*"; }
warn()  { echo "${YELLOW}[WARN]${RESET} $*"; }
error() { echo "${RED}[ERR]${RESET}  $*" >&2; }

# ── Parse Arguments ─────────────────────────────────────────────────────────
PROJECT_DIR="."
SCRIPT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: install.sh [--project-dir <path>]"
            echo ""
            echo "Installs everything-claude-unity into a Unity project."
            echo "Defaults to current directory if --project-dir is not specified."
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Resolve to absolute path
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)

# Determine where the install script lives (for copying files)
if [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

# ── Header ──────────────────────────────────────────────────────────────────
echo ""
echo "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo "${BOLD}${CYAN}║       everything-claude-unity — Installer           ║${RESET}"
echo "${BOLD}${CYAN}║   Full Pipeline Plugin for Unity Game Development   ║${RESET}"
echo "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""

# ── Step 1: Detect Unity Project ────────────────────────────────────────────
info "Detecting Unity project in: $PROJECT_DIR"

if [ ! -d "$PROJECT_DIR/Assets" ]; then
    error "No Assets/ directory found. This doesn't look like a Unity project."
    error "Run this script from your Unity project root, or use --project-dir <path>."
    exit 1
fi

if [ ! -d "$PROJECT_DIR/ProjectSettings" ]; then
    error "No ProjectSettings/ directory found. This doesn't look like a Unity project."
    exit 1
fi

ok "Unity project detected"

# ── Step 2: Scan Project ────────────────────────────────────────────────────
info "Scanning project..."

# Unity version
UNITY_VERSION="unknown"
if [ -f "$PROJECT_DIR/ProjectSettings/ProjectVersion.txt" ]; then
    UNITY_VERSION=$(grep 'm_EditorVersion:' "$PROJECT_DIR/ProjectSettings/ProjectVersion.txt" | awk '{print $2}' || echo "unknown")
fi
ok "Unity version: $UNITY_VERSION"

# Render pipeline
RENDER_PIPELINE="Built-in"
if [ -f "$PROJECT_DIR/Packages/manifest.json" ]; then
    if grep -q "com.unity.render-pipelines.universal" "$PROJECT_DIR/Packages/manifest.json" 2>/dev/null; then
        RENDER_PIPELINE="URP"
    elif grep -q "com.unity.render-pipelines.high-definition" "$PROJECT_DIR/Packages/manifest.json" 2>/dev/null; then
        RENDER_PIPELINE="HDRP"
    fi
fi
ok "Render pipeline: $RENDER_PIPELINE"

# Detect packages
DETECTED_PACKAGES=""
if [ -f "$PROJECT_DIR/Packages/manifest.json" ]; then
    [ "$(grep -c 'com.unity.inputsystem' "$PROJECT_DIR/Packages/manifest.json" 2>/dev/null)" -gt 0 ] && DETECTED_PACKAGES="$DETECTED_PACKAGES Input-System"
    [ "$(grep -c 'com.unity.addressables' "$PROJECT_DIR/Packages/manifest.json" 2>/dev/null)" -gt 0 ] && DETECTED_PACKAGES="$DETECTED_PACKAGES Addressables"
    [ "$(grep -c 'com.unity.cinemachine' "$PROJECT_DIR/Packages/manifest.json" 2>/dev/null)" -gt 0 ] && DETECTED_PACKAGES="$DETECTED_PACKAGES Cinemachine"
    [ "$(grep -c 'com.unity.textmeshpro' "$PROJECT_DIR/Packages/manifest.json" 2>/dev/null)" -gt 0 ] && DETECTED_PACKAGES="$DETECTED_PACKAGES TextMeshPro"
    [ "$(grep -c 'com.unity.timeline' "$PROJECT_DIR/Packages/manifest.json" 2>/dev/null)" -gt 0 ] && DETECTED_PACKAGES="$DETECTED_PACKAGES Timeline"
    [ "$(grep -c 'com.unity.netcode' "$PROJECT_DIR/Packages/manifest.json" 2>/dev/null)" -gt 0 ] && DETECTED_PACKAGES="$DETECTED_PACKAGES Netcode"
    [ "$(grep -c 'jp.hadashikick.vcontainer' "$PROJECT_DIR/Packages/manifest.json" 2>/dev/null)" -gt 0 ] && DETECTED_PACKAGES="$DETECTED_PACKAGES VContainer"
    [ "$(grep -c 'com.demigiant.dotween' "$PROJECT_DIR/Packages/manifest.json" 2>/dev/null)" -gt 0 ] && DETECTED_PACKAGES="$DETECTED_PACKAGES DOTween"
    [ "$(grep -c 'com.cysharp.unitask' "$PROJECT_DIR/Packages/manifest.json" 2>/dev/null)" -gt 0 ] && DETECTED_PACKAGES="$DETECTED_PACKAGES UniTask"
fi
# Check Assets for packages installed via .unitypackage or git
[ -d "$PROJECT_DIR/Assets/Plugins/DOTween" ] && DETECTED_PACKAGES="$DETECTED_PACKAGES DOTween"
[ -d "$PROJECT_DIR/Assets/Plugins/Demigiant" ] && DETECTED_PACKAGES="$DETECTED_PACKAGES DOTween"

if [ -n "$DETECTED_PACKAGES" ]; then
    ok "Detected packages:$DETECTED_PACKAGES"
else
    info "No notable third-party packages detected"
fi

# Count assembly definitions
ASMDEF_COUNT=$(find "$PROJECT_DIR/Assets" -name "*.asmdef" 2>/dev/null | wc -l | tr -d ' ')
ok "Assembly definitions: $ASMDEF_COUNT"

# Count scenes
SCENE_COUNT=$(find "$PROJECT_DIR/Assets" -name "*.unity" 2>/dev/null | wc -l | tr -d ' ')
ok "Scenes: $SCENE_COUNT"

# ── Step 3: Copy .claude/ Directory ─────────────────────────────────────────
info "Installing .claude/ configuration..."

# Check if .claude already exists
if [ -d "$PROJECT_DIR/.claude" ]; then
    warn ".claude/ directory already exists"
    echo ""
    echo "  Options:"
    echo "    1. Backup existing and install fresh"
    echo "    2. Merge (copy missing files only)"
    echo "    3. Abort"
    echo ""

    if [ -t 0 ]; then
        read -rp "  Choose [1/2/3]: " CHOICE
    else
        CHOICE="1"
        info "Non-interactive mode — backing up existing .claude/"
    fi

    case "$CHOICE" in
        1)
            BACKUP_DIR="$PROJECT_DIR/.claude.backup.$(date +%Y%m%d%H%M%S)"
            mv "$PROJECT_DIR/.claude" "$BACKUP_DIR"
            ok "Backed up existing .claude/ to $(basename "$BACKUP_DIR")"
            ;;
        2)
            info "Merging — will not overwrite existing files"
            ;;
        3)
            info "Aborted"
            exit 0
            ;;
        *)
            error "Invalid choice"
            exit 1
            ;;
    esac
fi

# Copy files from the repo's .claude directory
if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/.claude" ]; then
    # Installing from cloned repo
    if [ "${CHOICE:-1}" = "2" ]; then
        # Merge mode — copy only missing files
        rsync -a --ignore-existing "$SCRIPT_DIR/.claude/" "$PROJECT_DIR/.claude/"
    else
        cp -r "$SCRIPT_DIR/.claude" "$PROJECT_DIR/.claude"
    fi
    ok "Copied .claude/ directory (agents, commands, skills, hooks, rules)"
else
    # Installing via curl — download from GitHub
    info "Downloading from GitHub..."
    if command -v git &>/dev/null; then
        TEMP_DIR=$(mktemp -d)
        git clone --depth 1 https://github.com/user/everything-claude-unity.git "$TEMP_DIR" 2>/dev/null
        cp -r "$TEMP_DIR/.claude" "$PROJECT_DIR/.claude"
        rm -rf "$TEMP_DIR"
        ok "Downloaded and installed .claude/ directory"
    else
        error "git not found. Please clone the repo manually:"
        error "  git clone https://github.com/user/everything-claude-unity.git"
        error "  ./everything-claude-unity/install.sh --project-dir $PROJECT_DIR"
        exit 1
    fi
fi

# ── Step 3b: Create State Directory ────────────────────────────────────────
mkdir -p "$PROJECT_DIR/.claude/state"
ok "State directory created (.claude/state/)"

# ── Step 4: Make Scripts Executable ─────────────────────────────────────────
chmod +x "$PROJECT_DIR/.claude/hooks/"*.sh 2>/dev/null || true
ok "Hook scripts made executable"

# ── Step 5: Copy Validation Scripts ─────────────────────────────────────────
if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/scripts" ]; then
    mkdir -p "$PROJECT_DIR/.claude/scripts"
    cp "$SCRIPT_DIR/scripts/"*.sh "$PROJECT_DIR/.claude/scripts/" 2>/dev/null || true
    chmod +x "$PROJECT_DIR/.claude/scripts/"*.sh 2>/dev/null || true
    ok "Validation scripts installed"
fi

# ── Step 5b: Copy Test Suite ──────────────────────────────────────────────
if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/tests" ]; then
    mkdir -p "$PROJECT_DIR/.claude/tests"
    cp "$SCRIPT_DIR/tests/"*.sh "$PROJECT_DIR/.claude/tests/" 2>/dev/null || true
    chmod +x "$PROJECT_DIR/.claude/tests/run-tests.sh" 2>/dev/null || true
    ok "Test suite installed"
fi

# ── Step 6: Generate CLAUDE.md ──────────────────────────────────────────────
info "Generating CLAUDE.md..."

CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"

if [ -f "$CLAUDE_MD" ]; then
    warn "CLAUDE.md already exists — generating as CLAUDE.md.generated"
    CLAUDE_MD="$PROJECT_DIR/CLAUDE.md.generated"
fi

# Generate CLAUDE.md
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/scripts/generate-claude-md.sh" ]; then
    bash "$SCRIPT_DIR/scripts/generate-claude-md.sh" "$PROJECT_DIR" "$CLAUDE_MD"
else
    # Inline generation if script not available
    cat > "$CLAUDE_MD" << HEREDOC
# Project Configuration

## Unity Project
- **Unity Version:** $UNITY_VERSION
- **Render Pipeline:** $RENDER_PIPELINE
- **Assembly Definitions:** $ASMDEF_COUNT
- **Scenes:** $SCENE_COUNT
- **Detected Packages:**$DETECTED_PACKAGES

## Architecture

This project uses the everything-claude-unity plugin for Claude Code.
All coding guidelines are in \`.claude/rules/\`.

## Rules

Follow the coding standards in:
- \`.claude/rules/csharp-unity.md\` — C# style conventions
- \`.claude/rules/performance.md\` — performance rules (zero-alloc Update)
- \`.claude/rules/serialization.md\` — serialization safety (FormerlySerializedAs)
- \`.claude/rules/architecture.md\` — architecture patterns (composition, SO, events)
- \`.claude/rules/unity-specifics.md\` — Unity-specific rules (Editor/Runtime, threading)

## MCP Integration

Unity MCP server should be running at \`http://localhost:8080/mcp\`.
Use MCP tools for scene/prefab manipulation — never text-edit .unity/.prefab files.

## Key Conventions
- \`[SerializeField] private\` — never expose public fields for inspector
- \`[FormerlySerializedAs]\` — ALWAYS when renaming serialized fields
- Cache \`GetComponent\` in Awake — never call in Update
- \`obj == null\` not \`obj?.Method()\` — Unity overrides == for destroyed objects
- Editor code in \`Editor/\` folder or \`#if UNITY_EDITOR\` guard
HEREDOC
fi

ok "Generated $(basename "$CLAUDE_MD")"

# ── Step 7: Update .gitignore ───────────────────────────────────────────────
GITIGNORE="$PROJECT_DIR/.gitignore"

if [ -f "$GITIGNORE" ]; then
    ENTRIES_TO_ADD=()

    if ! grep -qF '.claude/settings.local.json' "$GITIGNORE" 2>/dev/null; then
        ENTRIES_TO_ADD+=('.claude/settings.local.json')
    fi
    if ! grep -qF '.claude/state/' "$GITIGNORE" 2>/dev/null; then
        ENTRIES_TO_ADD+=('.claude/state/*.json')
        ENTRIES_TO_ADD+=('.claude/state/*.jsonl')
        ENTRIES_TO_ADD+=('.claude/state/*.txt')
        ENTRIES_TO_ADD+=('.claude/state/*.md')
    fi

    if [ ${#ENTRIES_TO_ADD[@]} -gt 0 ]; then
        echo "" >> "$GITIGNORE"
        echo "# Claude Code local settings and session state" >> "$GITIGNORE"
        for ENTRY in "${ENTRIES_TO_ADD[@]}"; do
            echo "$ENTRY" >> "$GITIGNORE"
        done
        ok "Updated .gitignore"
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${RESET}"
echo "${BOLD}${GREEN}║         Installation Complete!                      ║${RESET}"
echo "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo "  ${BOLD}Installed:${RESET}"
echo "    ${CYAN}Hooks${RESET}     — 22 lifecycle hooks (5 blocking, 17 advisory)"
echo "    ${CYAN}Rules${RESET}     — 5 coding guideline files"
echo "    ${CYAN}Agents${RESET}    — 20 specialized agents (haiku/sonnet/opus)"
echo "    ${CYAN}Commands${RESET}  — 22 slash commands"
echo "    ${CYAN}Skills${RESET}    — 41 knowledge modules"
echo "    ${CYAN}Tests${RESET}     — Test suite in tests/"
echo "    ${CYAN}MCP${RESET}       — Unity MCP configured at localhost:8080"
echo ""
echo "  ${BOLD}Next steps:${RESET}"
echo "    1. Review the generated ${CYAN}CLAUDE.md${RESET} and customize it"
echo "    2. Install unity-mcp in your Unity project:"
echo "       ${YELLOW}Window > Package Manager > + > Add from git URL${RESET}"
echo "       ${YELLOW}https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#main${RESET}"
echo "    3. Start the MCP server: ${YELLOW}Window > MCP for Unity > Start Server${RESET}"
echo "    4. Run ${CYAN}claude${RESET} in your project directory"
echo "    5. Try: ${CYAN}/unity-audit${RESET} to check project health"
echo ""
echo "  ${BOLD}Documentation:${RESET} https://github.com/user/everything-claude-unity"
echo ""
