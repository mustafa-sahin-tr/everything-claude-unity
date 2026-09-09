#!/usr/bin/env bash
# Create a Unity 2D mobile game project, fully wired for Claude Code.
# Written for macOS bash 3.2 — no associative arrays, no ${var,,}.
set -eo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_NAME=""
PARENT_DIR="$HOME/Unity"
UNITY_VERSION=""

usage() {
    cat <<USAGE
Usage: new-unity-game.sh <ProjectName> [options]

  --dir <path>       Parent directory (default: ~/Unity)
  --unity <version>  Editor version (default: newest installed)
  -h, --help         This message

Creates a Universal 2D project, strips the template bloat, installs
VContainer + MessagePipe + UniTask, sets up asmdef layering, git, and the
everything-claude-unity Claude Code configuration.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)   PARENT_DIR="$2"; shift 2 ;;
        --unity) UNITY_VERSION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *) PROJECT_NAME="$1"; shift ;;
    esac
done

[ -n "$PROJECT_NAME" ] || { usage >&2; exit 1; }

# Namespace must be a valid C# identifier
NAMESPACE=$(echo "$PROJECT_NAME" | sed 's/[^A-Za-z0-9]//g')
case "$NAMESPACE" in
    [0-9]*|"") echo "Project name must yield a valid C# identifier: '$PROJECT_NAME'" >&2; exit 1 ;;
esac

PROJECT_DIR="$PARENT_DIR/$PROJECT_NAME"
[ -e "$PROJECT_DIR" ] && { echo "Already exists: $PROJECT_DIR" >&2; exit 1; }

step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
step "Checking prerequisites"

EDITOR_ROOT="/Applications/Unity/Hub/Editor"
[ -d "$EDITOR_ROOT" ] || die "No Unity editors found. Install one via Unity Hub first."

if [ -z "$UNITY_VERSION" ]; then
    UNITY_VERSION=$(ls "$EDITOR_ROOT" | sort -V | tail -1)
fi
EDITOR_APP="$EDITOR_ROOT/$UNITY_VERSION/Unity.app"
[ -d "$EDITOR_APP" ] || die "Editor $UNITY_VERSION not installed."
ok "Unity $UNITY_VERSION"

for m in iOSSupport AndroidPlayer; do
    if [ -d "$EDITOR_APP/Contents/PlaybackEngines/$m" ]; then
        ok "$m present"
    else
        printf '    \033[33m!\033[0m %s missing — add it in Unity Hub before building\n' "$m"
    fi
done

TEMPLATE=$(ls "$EDITOR_APP/Contents/Resources/PackageManager/ProjectTemplates"/*2d*.tgz 2>/dev/null | head -1)
[ -n "$TEMPLATE" ] || die "No 2D project template found for $UNITY_VERSION."
ok "Template $(basename "$TEMPLATE")"

UVX=""
if command -v uvx >/dev/null 2>&1; then
    UVX=$(command -v uvx)
elif [ -x "$HOME/.local/bin/uvx" ]; then
    UVX="$HOME/.local/bin/uvx"
fi
if [ -n "$UVX" ]; then ok "uvx at $UVX"; else
    printf '    \033[33m!\033[0m uvx not found — MCP config will be skipped (install: brew install uv)\n'
fi

[ -x "$SELF_DIR/install.sh" ] || die "install.sh not found next to this script."

# ------------------------------------------------------------ create project
step "Creating project at $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$TEMPLATE" -C "$TMP"
[ -d "$TMP/package/ProjectData~" ] || die "Unexpected template layout."
# -a preserves the dotfiles the template ships with
cp -a "$TMP/package/ProjectData~/." "$PROJECT_DIR/"
rm -rf "$PROJECT_DIR/Library"
ok "Universal 2D project created"

# The template omits ProjectVersion.txt; Unity writes it on first open, but the
# installer reads it to detect the editor version, so write it up front.
mkdir -p "$PROJECT_DIR/ProjectSettings"
cat > "$PROJECT_DIR/ProjectSettings/ProjectVersion.txt" <<VERSION
m_EditorVersion: $UNITY_VERSION
VERSION
ok "ProjectVersion.txt written ($UNITY_VERSION)"

# Name the product after the project rather than leaving the template default
SETTINGS="$PROJECT_DIR/ProjectSettings/ProjectSettings.asset"
if [ -f "$SETTINGS" ]; then
    sed -i '' "s/^  productName:.*/  productName: $PROJECT_NAME/" "$SETTINGS" 2>/dev/null || true
    ok "productName set to $PROJECT_NAME"
fi

# ------------------------------------------------------------------ packages
step "Trimming template packages and adding the architecture stack"
rm -rf "$PROJECT_DIR/Assets/Welcome" "$PROJECT_DIR/Assets/Welcome.meta"

python3 - "$PROJECT_DIR" <<'PY'
import json, sys, pathlib
root = pathlib.Path(sys.argv[1])
p = root / "Packages" / "manifest.json"
m = json.loads(p.read_text())
deps = m["dependencies"]

# Visual Scripting builds a node database during InitializeOnLoad and can stall the
# editor for minutes; the rest is template scaffolding a game does not need.
for pkg in ("com.unity.visualscripting", "com.unity.learn.iet-framework",
            "com.unity.ai.assistant", "com.unity.ai.inference",
            "com.unity.collab-proxy", "com.unity.pipeline"):
    deps.pop(pkg, None)

m["scopedRegistries"] = [{
    "name": "package.openupm.com",
    "url": "https://package.openupm.com",
    "scopes": ["jp.hadashikick", "com.cysharp"],
}]
deps.update({
    "jp.hadashikick.vcontainer": "1.19.0",
    "com.cysharp.messagepipe": "1.8.2",
    "com.cysharp.messagepipe.vcontainer": "1.8.2",
    "com.cysharp.unitask": "2.5.11",
    "com.coplaydev.unity-mcp":
        "https://github.com/CoplayDev/unity-mcp.git?path=/MCPForUnity#main",
})
m["dependencies"] = dict(sorted(deps.items()))
p.write_text(json.dumps(m, indent=2) + "\n")
PY
ok "Removed template bloat; added VContainer, MessagePipe, UniTask, MCP for Unity"

# ------------------------------------------------------------------- asmdefs
step "Creating assembly layering"
python3 - "$PROJECT_DIR" "$NAMESPACE" <<'PY'
import json, os, sys, pathlib
root, ns = pathlib.Path(sys.argv[1]), sys.argv[2]

def write(rel, name, refs, extra=None):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    d = {"name": name, "rootNamespace": name, "references": refs,
         "includePlatforms": [], "excludePlatforms": [], "allowUnsafeCode": False,
         "overrideReferences": False, "precompiledReferences": [],
         "autoReferenced": True, "defineConstraints": [], "versionDefines": [],
         "noEngineReferences": False}
    if extra:
        d.update(extra)
    path.write_text(json.dumps(d, indent=4) + "\n")

# Core stays pure C# so its tests run without opening a scene.
write(f"Assets/Scripts/Core/{ns}.Core.asmdef", f"{ns}.Core", [],
      {"noEngineReferences": True})
write(f"Assets/Scripts/Gameplay/{ns}.Gameplay.asmdef", f"{ns}.Gameplay",
      [f"{ns}.Core", "UniTask", "MessagePipe", "VContainer"])
write(f"Assets/Scripts/Presentation/{ns}.Presentation.asmdef", f"{ns}.Presentation",
      [f"{ns}.Core", f"{ns}.Gameplay", "UniTask", "MessagePipe",
       "MessagePipe.VContainer", "VContainer", "Unity.InputSystem"])
write(f"Assets/Tests/EditMode/{ns}.Tests.EditMode.asmdef", f"{ns}.Tests.EditMode",
      [f"{ns}.Core", f"{ns}.Gameplay", "UnityEngine.TestRunner", "UnityEditor.TestRunner"],
      {"includePlatforms": ["Editor"], "precompiledReferences": ["nunit.framework.dll"],
       "overrideReferences": True, "autoReferenced": False,
       "defineConstraints": ["UNITY_INCLUDE_TESTS"]})
write(f"Assets/Tests/PlayMode/{ns}.Tests.PlayMode.asmdef", f"{ns}.Tests.PlayMode",
      [f"{ns}.Core", f"{ns}.Gameplay", f"{ns}.Presentation", "UniTask", "MessagePipe",
       "MessagePipe.VContainer", "VContainer", "UnityEngine.TestRunner"],
      {"precompiledReferences": ["nunit.framework.dll"], "overrideReferences": True,
       "autoReferenced": False, "defineConstraints": ["UNITY_INCLUDE_TESTS"]})
PY
ok "Core → Gameplay → Presentation, plus EditMode and PlayMode tests"

# ----------------------------------------------------------------------- git
step "Initialising git"
cd "$PROJECT_DIR"
if curl -fsSL --max-time 20 \
    https://raw.githubusercontent.com/github/gitignore/main/Unity.gitignore \
    -o .gitignore 2>/dev/null; then
    ok "Unity .gitignore fetched"
else
    printf 'Library/\nTemp/\nLogs/\nobj/\nBuild/\nUserSettings/\n*.csproj\n*.sln\n*.slnx\n' > .gitignore
    printf '    \033[33m!\033[0m offline — wrote a minimal .gitignore\n'
fi
printf '\n# everything-claude-unity (local session state)\n.claude/state/\n.claude/settings.local.json\n' >> .gitignore
git init -q
ok "repository created"

# ------------------------------------------------------------ claude wiring
step "Installing everything-claude-unity"
"$SELF_DIR/install.sh" --project-dir "$PROJECT_DIR" </dev/null || die "install.sh failed"

if [ -n "$UVX" ]; then
    python3 - "$PROJECT_DIR" "$UVX" <<'PY'
import json, sys, pathlib
root, uvx = pathlib.Path(sys.argv[1]), sys.argv[2]
cfg = {"type": "stdio", "command": uvx,
       "args": ["--from", "mcpforunityserver", "mcp-for-unity", "--transport", "stdio"]}
(root / ".mcp.json").write_text(
    json.dumps({"mcpServers": {"unityMCP": cfg}}, indent=2) + "\n")
PY
    ok ".mcp.json written (server name 'unityMCP', as the agents expect)"
fi

git add -A
git -c user.useConfigOnly=false commit -qm "Initial $PROJECT_NAME project

Universal 2D on Unity $UNITY_VERSION, template extras removed, VContainer +
MessagePipe + UniTask, layered assemblies, everything-claude-unity wiring."
ok "initial commit"

# --------------------------------------------------------------- next steps
cat <<DONE

$(printf '\033[1;32m%s\033[0m' "Ready: $PROJECT_DIR")

  1. Open the project (first import takes a few minutes):
       open -na "$EDITOR_APP" --args -projectPath "$PROJECT_DIR"

  2. In Unity: Window → MCP for Unity → Toggle MCP Window
       Switch the transport to Stdio. The editor defaults to HTTP, which does
       not open the bridge Claude Code talks to.
       Verify with:  lsof -iTCP:6400 -sTCP:LISTEN -nP

  3. Start Claude Code in the project and approve the unityMCP server:
       cd "$PROJECT_DIR" && claude
       /unity-doctor

  4. Write docs/game-design.md before any gameplay code — the agents read it.

DONE
