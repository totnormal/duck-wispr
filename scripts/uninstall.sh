#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

step() { printf "\n  ${BLUE}${BOLD}%s${NC}\n" "$1"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$1"; }

printf "\n"
printf "  ${BOLD}duck-wispr${NC} ${DIM}— uninstall${NC}\n"
printf "  ${DIM}────────────────────────────────────────────${NC}\n"

step "Stopping service"
brew services stop duck-wispr 2>/dev/null || true
pkill -f "duck-wispr start" 2>/dev/null || true
sleep 1
ok "Stopped"

step "Removing formula and tap"
brew uninstall --force duck-wispr 2>/dev/null || true
brew untap human37/duck-wispr 2>/dev/null || true
ok "Removed"

step "Removing app bundle"
rm -rf ~/Applications/DuckWispr.app
rm -rf /Applications/DuckWispr.app 2>/dev/null || true
ok "Removed"

step "Removing config, model, and logs"
rm -rf ~/.config/duck-wispr
rm -f /opt/homebrew/var/log/duck-wispr.log 2>/dev/null || true
ok "Removed"

step "Unregistering from LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -u ~/Applications/DuckWispr.app 2>/dev/null || true
ok "Unregistered"

printf "\n"
printf "  ${DIM}────────────────────────────────────────────${NC}\n"
printf "  ${GREEN}${BOLD}Uninstalled.${NC}\n"
printf "\n"
printf "  To reinstall:\n"
printf "  ${BOLD}curl -fsSL https://raw.githubusercontent.com/human37/duck-wispr/main/scripts/install.sh | bash${NC}\n"
printf "\n"
