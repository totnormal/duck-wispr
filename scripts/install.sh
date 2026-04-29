#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'
SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

REPO_URL="https://github.com/totnormal/open-wispr.git"
RAW_BASE="https://raw.githubusercontent.com/totnormal/open-wispr/main"
BREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
APP_NAME="OpenWispr.app"
APP_DEST="/Applications/${APP_NAME}"
APP_BINARY="$APP_DEST/Contents/MacOS/open-wispr"
LAUNCH_AGENT_LABEL="com.openwispr.dictation"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
CONFIG_DIR="$HOME/.config/open-wispr"
MODEL_DIR="$CONFIG_DIR/models"
MODEL_FILE="$MODEL_DIR/ggml-small.bin"
CONFIG_FILE="$CONFIG_DIR/config.json"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/open-wispr-install.XXXXXX")"
REPO_DIR="$WORKDIR/open-wispr"
LOG_FILE="$WORKDIR/install.log"
APP_LOG="$WORKDIR/open-wispr-first-run.log"
SPIN_PID=""
INSTALL_FAILED=0

cleanup() {
    stop_spinner
    if (( INSTALL_FAILED == 0 )); then
        rm -rf "$WORKDIR"
    else
        info "Installer log: ${BOLD}${LOG_FILE}${NC}"
    fi
}
trap cleanup EXIT

print_header() {
    printf "\n${BOLD}open-wispr installer${NC} ${DIM}(main branch)${NC}\n"
    printf "${DIM}────────────────────────────────────────────${NC}\n"
}

step() {
    printf "\n${BLUE}${BOLD}▶ %s${NC}\n" "$1"
}

info() {
    printf "  ${DIM}%b${NC}\n" "$1"
}

ok() {
    printf "\r\033[K  ${GREEN}✓${NC} %b\n" "$1"
}

warn() {
    printf "\r\033[K  ${YELLOW}⚠${NC} %b\n" "$1"
}

fail() {
    printf "\r\033[K  ${RED}✗${NC} %b\n" "$1"
}

spinner() {
    local message="$1"
    while true; do
        for frame in "${SPINNER_FRAMES[@]}"; do
            printf "\r\033[K  ${YELLOW}%s${NC} %s" "$frame" "$message"
            sleep 0.1
        done
    done
}

start_spinner() {
    stop_spinner
    spinner "$1" &
    SPIN_PID=$!
}

stop_spinner() {
    if [[ -n "$SPIN_PID" ]]; then
        kill "$SPIN_PID" >/dev/null 2>&1 || true
        wait "$SPIN_PID" >/dev/null 2>&1 || true
        SPIN_PID=""
        printf "\r\033[K"
    fi
}

die() {
    local message="$1"
    INSTALL_FAILED=1
    stop_spinner
    fail "$message"
    exit 1
}

run() {
    local description="$1"
    shift
    start_spinner "$description"
    if "$@" >>"$LOG_FILE" 2>&1; then
        stop_spinner
        ok "$description"
    else
        stop_spinner
        fail "$description"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /'
        die "Command failed: $*"
    fi
}

wait_for_log_pattern() {
    local pattern="$1"
    local file="$2"
    local timeout="$3"
    local message="$4"
    local elapsed=0

    start_spinner "$message"
    while (( elapsed < timeout )); do
        if [[ -f "$file" ]] && grep -q "$pattern" "$file" 2>/dev/null; then
            stop_spinner
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    stop_spinner
    return 1
}

ensure_macos() {
    [[ "$(uname)" == "Darwin" ]] || die "This installer only works on macOS."
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    (( major >= 13 )) || die "macOS 13 Ventura or later is required."
}

find_brew() {
    if command -v brew >/dev/null 2>&1; then
        command -v brew
        return 0
    fi
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

ensure_homebrew() {
    if BREW_BIN="$(find_brew)"; then
        ok "Homebrew already installed"
        return 0
    fi

    step "Installing Homebrew"
    run "Installing Homebrew" env NONINTERACTIVE=1 HOMEBREW_NO_ANALYTICS=1 /bin/bash -c "$(curl -fsSL "$BREW_INSTALL_URL")"

    BREW_BIN="$(find_brew)" || die "Homebrew installed but brew was not found in PATH."
    eval "$($BREW_BIN shellenv)"
    ok "Homebrew ready"
}

ensure_swift_toolchain() {
    step "Checking developer tools"
    if ! xcode-select -p >/dev/null 2>&1; then
        die "Xcode Command Line Tools are required. Run 'xcode-select --install', finish the installation, then re-run this script."
    fi
    run "Checking Swift toolchain" swift --version
}

ensure_brew_package() {
    local formula="$1"
    local label="${2:-$1}"
    if "$BREW_BIN" list "$formula" >/dev/null 2>&1; then
        ok "${label} already installed"
    else
        run "Installing ${label}" "$BREW_BIN" install "$formula"
    fi
}

ensure_dev_tools() {
    step "Installing required tools"
    run "Updating Homebrew metadata" "$BREW_BIN" update
    ensure_brew_package whisper-cpp whisper-cpp
    if command -v git >/dev/null 2>&1; then
        ok "git already available"
    else
        ensure_brew_package git git
    fi
}

clone_repo() {
    step "Fetching open-wispr source"
    run "Cloning repository" git clone --depth 1 --branch main "$REPO_URL" "$REPO_DIR"
}

build_app() {
    step "Building app"
    cd "$REPO_DIR"
    run "Building Swift release binary" swift build -c release
    run "Bundling app" bash scripts/bundle-app.sh .build/release/open-wispr "$APP_NAME" main
}

stop_running_processes() {
    local pids=""
    pids="$(pgrep -f "${APP_BINARY} start" 2>/dev/null || true)"
    if [[ -z "$pids" ]]; then
        ok "No running open-wispr process to stop"
        return 0
    fi

    info "Stopping running open-wispr process(es): $(echo "$pids" | tr '\n' ' ')"
    run "Stopping existing open-wispr process" pkill -f "${APP_BINARY} start"
    sleep 1
    if pgrep -f "${APP_BINARY} start" >/dev/null 2>&1; then
        run "Force stopping lingering open-wispr process" pkill -9 -f "${APP_BINARY} start"
    fi
}

unload_launch_agent() {
    local domain="gui/$(id -u)"
    launchctl bootout "$domain/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
    launchctl disable "$domain/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
    launchctl remove "$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
}

# ── Privileged operations (OSA auth dialog) ───────────────────────

run_privileged() {
    local description="$1"
    shift
    step "$description"
    stop_spinner
    printf "\n  ${YELLOW}${BOLD}🔐 macOS will ask for your password.${NC}\n"
    printf "  ${DIM}Look for the authentication dialog — it may be behind this window.${NC}\n\n"

    local escaped_cmd=""
    for arg in "$@"; do
        escaped_cmd="${escaped_cmd} $(printf '%q' "$arg")"
    done

    start_spinner "$description"
    if osascript -e "do shell script \"${escaped_cmd}\" with administrator privileges" >>"$LOG_FILE" 2>&1; then
        stop_spinner
        ok "$description"
    else
        stop_spinner
        fail "$description"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /'
        die "Privileged command failed: $*"
    fi
}

install_app() {
    [[ -d "$REPO_DIR/$APP_NAME" ]] || die "Bundled app not found at $REPO_DIR/$APP_NAME"

    unload_launch_agent
    stop_running_processes

    if [[ -d "$APP_DEST" ]]; then
        run_privileged "Removing previous app" rm -rf "$APP_DEST"
    else
        ok "No existing app to remove"
    fi
    run_privileged "Copying app to /Applications" cp -R "$REPO_DIR/$APP_NAME" "$APP_DEST"
    [[ -x "$APP_BINARY" ]] || die "Installed app binary not found at $APP_BINARY"
}

valid_model_file() {
    [[ -f "$MODEL_FILE" && -s "$MODEL_FILE" ]]
}

download_model() {
    step "Downloading small multilingual model"
    mkdir -p "$MODEL_DIR"
    if valid_model_file; then
        ok "Model already exists"
        return 0
    fi

    if [[ -f "$MODEL_FILE" && ! -s "$MODEL_FILE" ]]; then
        warn "Removing empty model file from previous attempt"
        rm -f "$MODEL_FILE"
    fi

    local tmp_file
    tmp_file="$(mktemp "$MODEL_DIR/ggml-small.bin.tmp.XXXXXX")"
    if run "Downloading ggml-small.bin (~466 MB)" curl --fail --location --progress-bar --output "$tmp_file" "$MODEL_URL"; then
        if [[ ! -s "$tmp_file" ]]; then
            rm -f "$tmp_file"
            die "Model download completed but produced an empty file."
        fi
        mv "$tmp_file" "$MODEL_FILE"
        ok "Model saved to ${MODEL_FILE}"
    else
        rm -f "$tmp_file"
        die "Failed to download model"
    fi
}

write_config() {
    step "Writing config"
    mkdir -p "$CONFIG_DIR"
    if [[ -f "$CONFIG_FILE" ]]; then
        ok "Config already exists — leaving ${CONFIG_FILE} unchanged"
        return 0
    fi

    cat > "$CONFIG_FILE" <<'EOF'
{
  "hotkey": { "keyCode": 63, "modifiers": [] },
  "modelSize": "small",
  "language": "en",
  "proofreadingMode": "standard",
  "maxRecordings": 0,
  "toggleMode": false
}
EOF
    ok "Config written to ${CONFIG_FILE}"
}

install_launch_agent() {
    step "Configuring auto-start"
    mkdir -p "$HOME/Library/LaunchAgents"
    mkdir -p "$HOME/Library/Logs"
    [[ -x "$APP_BINARY" ]] || die "Cannot create launch agent because app binary was not found at $APP_BINARY"

    cat > "$LAUNCH_AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_BINARY}</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/open-wispr.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/open-wispr.log</string>
</dict>
</plist>
EOF

    unload_launch_agent
    run "Loading launch agent" launchctl load -w "$LAUNCH_AGENT"
}

start_app_and_prompt_permissions() {
    step "Checking permissions"
    : > "$APP_LOG"
    info "OpenWispr is launched via the login agent; no duplicate direct start is performed."
    info "Permission checks are best-effort. If access is already granted, you may not see new prompts."

    if wait_for_log_pattern "Microphone:" "$APP_LOG" 45 "Watching for microphone status..."; then
        if grep -q "Microphone: denied" "$APP_LOG"; then
            warn "Microphone permission was denied"
            info "Grant it in ${BOLD}System Settings → Privacy & Security → Microphone${NC}"
        elif grep -q "Microphone: granted" "$APP_LOG"; then
            ok "Microphone access already granted or confirmed"
        elif grep -q "Microphone: requesting" "$APP_LOG"; then
            ok "Microphone permission request was triggered"
        else
            warn "Observed microphone log output, but could not determine the final state automatically"
        fi
    else
        warn "Did not observe microphone status automatically — this can be normal if permission was already settled or logs were unchanged"
    fi

    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >>"$LOG_FILE" 2>&1 || true
    info "System Settings was opened for ${BOLD}Accessibility${NC}. Enable ${BOLD}OpenWispr${NC} if it is not already allowed."
    if wait_for_log_pattern "Accessibility: granted" "$APP_LOG" 300 "Watching for Accessibility status..."; then
        ok "Accessibility access already granted or confirmed"
    else
        warn "Accessibility was not confirmed automatically — if OpenWispr is already enabled, you can ignore this message"
        info "You can manage it in ${BOLD}System Settings → Privacy & Security → Accessibility${NC}"
    fi

    run "Opening installed app bundle" open "$APP_DEST"
}

print_success() {
    printf "\n${DIM}────────────────────────────────────────────${NC}\n"
    printf "${GREEN}${BOLD}OpenWispr is installed.${NC}\n\n"
    printf "  App:        ${BOLD}%s${NC}\n" "$APP_DEST"
    printf "  Config:     ${BOLD}%s${NC}\n" "$CONFIG_FILE"
    printf "  Model:      ${BOLD}%s${NC}\n" "$MODEL_FILE"
    printf "  Auto-start: ${BOLD}%s${NC}\n\n" "$LAUNCH_AGENT"
    printf "  Hotkey:     ${BOLD}Globe / fn${NC}\n"
    printf "  Language:   ${BOLD}en${NC}\n"
    printf "  Model size: ${BOLD}small${NC}\n"
    printf "  Proofread:  ${BOLD}standard${NC}\n\n"
    printf "  One-line install command for users:\n"
    printf "  ${BOLD}curl -fsSL %s/scripts/install.sh | bash${NC}\n\n" "$RAW_BASE"
}

main() {
    : > "$LOG_FILE"
    print_header
    ensure_macos
    step "Checking system"
    ok "macOS supported"
    ensure_homebrew
    eval "$($BREW_BIN shellenv)"
    export PATH="$(dirname "$BREW_BIN"):/opt/homebrew/bin:/usr/local/bin:$PATH"

    ensure_swift_toolchain
    ensure_dev_tools
    clone_repo
    build_app
    install_app
    download_model
    write_config
    install_launch_agent
    start_app_and_prompt_permissions
    print_success
}

main "$@"
