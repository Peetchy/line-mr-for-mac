#!/bin/bash
# End-to-end verification of the LINE accessibility bridge.
#
# Builds and installs the plugin, (re)launches LINE.app with it, dumps the AX tree with
# build/ax_inspect and checks the login screen:
#   - AXTextField "Email address" and "Password" have non-empty titles/descriptions
#   - the Password field has subrole AXSecureTextField (even while empty)
#   - AXButton "Log in" and "Reset password" exist and expose AXPress
#   - AXCheckBox "Log me in automatically" exists
#   - AXStaticText "QR code login" and the QR instructions have non-empty values
# and, when LINE is logged in, the main window:
#   - sidebar tabs (AXRadioButton "Friends" / "Chats") expose AXPress
#   - the Chats / Friends AXList has labelled rows and no dead (role-less) children
#   - if a chat is open, its Messages AXList has labelled rows
#
# The login checks need LINE to be logged out with the English UI. If LINE shows another
# screen, those checks are reported as SKIPPED and generic bridge checks still run.
# Requires the terminal to be trusted under Privacy & Security > Accessibility.
# NOTE: this quits a running LINE instance.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

AX="$ROOT/build/ax_inspect"
CACHE_DIR="$(getconf DARWIN_USER_CACHE_DIR)"
LOG="${CACHE_DIR%/}/jp.naver.line.mac/a11y/a11y.log"
DUMP="$(mktemp -t line_ax_dump)"
trap 'rm -f "$DUMP"' EXIT

pass=0; fail=0; skip=0
ok()   { echo "PASS: $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $*"; fail=$((fail + 1)); }
skp()  { echo "SKIPPED: $*"; skip=$((skip + 1)); }

echo "== Building and installing"
make all >/dev/null && make install >/dev/null || { echo "build/install failed"; exit 1; }

echo "== Launching LINE with the bridge"
log_lines_before=0
[[ -f "$LOG" ]] && log_lines_before=$(wc -l < "$LOG")
"$ROOT/tools/line-a11y-launcher.sh" --restart || exit 1

echo "== Waiting for the LINE window"
"$AX" --wait 60 --depth 0 >/dev/null 2>&1
rc=$?
if [[ $rc -eq 2 ]]; then
    echo "ax_inspect is not trusted for accessibility; grant access and rerun."; exit 1
fi
sleep 5   # let LcApplication finish startup and the watchdog run

"$AX" --wait 30 > "$DUMP" 2>/dev/null || { echo "ax_inspect failed"; exit 1; }
echo "   $(wc -l < "$DUMP" | tr -d ' ') AX elements captured"

# --- Bridge loaded? ---------------------------------------------------------------------------
if [[ -f "$LOG" ]] && tail -n +"$((log_lines_before + 1))" "$LOG" | grep -q "\[bridge\] started"; then
    ok "plugin loaded and bridge started (see $LOG)"
else
    bad "bridge start not found in $LOG"
fi

# has_line ROLE PATTERN [REQUIRE_ACTION]
has_line() {
    local role="$1" pattern="$2" action="${3:-}"
    local lines
    lines=$(grep -E "role=$role " "$DUMP" | grep -F -- "$pattern") || return 1
    [[ -z "$action" ]] && return 0
    echo "$lines" | grep -Eq "actions=\[[^]]*$action"
}

# --- Login-screen checks -------------------------------------------------------------------------
if grep -Fq '"Log in"' "$DUMP"; then
    for label in "Email address" "Password"; do
        if has_line AXTextField "\"$label\""; then ok "AXTextField '$label' is labelled"
        else bad "AXTextField '$label' missing or unlabelled"; fi
    done
    if grep -E "role=AXTextField subrole=AXSecureTextField " "$DUMP" | grep -Fq 'title="Password"'; then
        ok "Password field has subrole AXSecureTextField"
    else
        bad "Password field is not exposed as AXSecureTextField"
    fi
    for label in "Log in" "Reset password"; do
        if has_line AXButton "\"$label\"" AXPress; then ok "AXButton '$label' exposes AXPress"
        else bad "AXButton '$label' missing or without AXPress"; fi
    done
    if has_line AXCheckBox "Log me in automatically"; then ok "AXCheckBox 'Log me in automatically'"
    else bad "AXCheckBox 'Log me in automatically' missing"; fi
    if grep -E "role=AXStaticText " "$DUMP" | grep -Fq 'val="QR code login"'; then
        ok "AXStaticText 'QR code login' has a value"
    else
        bad "AXStaticText 'QR code login' missing or empty"
    fi
    # Instructions: any other static text that mentions the QR code and is a full sentence.
    if grep -E "role=AXStaticText " "$DUMP" | grep -iE 'val="[^"]*QR[^"]{20,}"' | grep -vFq 'val="QR code login"'; then
        ok "AXStaticText QR instructions have a value"
    else
        bad "AXStaticText QR instructions missing or empty"
    fi
else
    skp "login-screen checks (LINE is not on the English login screen)"
fi

# --- Main-window checks ------------------------------------------------------------------------
# list_stats TITLE -> "<labelled rows> <dead children>" for the AXList titled TITLE
list_stats() {
    awk -v t="$1" '
        function indent(s) { match(s, /^ */); return RLENGTH }
        index($0, "role=AXList ") && index($0, "title=\"" t "\"") { depth = indent($0); inlist = 1; next }
        inlist && indent($0) <= depth { inlist = 0 }
        inlist && indent($0) == depth + 2 {
            if ($0 ~ /^ *role=- /) dead++
            else if ($0 !~ /val=""/ || $0 !~ /title=""/) labelled++
        }
        END { printf "%d %d\n", labelled, dead }' "$DUMP"
}

if grep -Eq 'role=AXRadioButton .*title="Chats"' "$DUMP"; then
    for label in "Friends" "Chats"; do
        if has_line AXRadioButton "title=\"$label\"" AXPress; then ok "sidebar tab '$label' exposes AXPress"
        else bad "sidebar tab '$label' missing or without AXPress"; fi
    done
    checked=0
    for list in "Chats" "Friends"; do
        grep -Eq "role=AXList .*title=\"$list\"" "$DUMP" || continue
        checked=1
        read -r labelled dead < <(list_stats "$list")
        if [[ $labelled -gt 0 ]]; then ok "AXList '$list' has $labelled labelled rows"
        else bad "AXList '$list' has no labelled rows"; fi
        if [[ $dead -eq 0 ]]; then ok "AXList '$list' has no dead children"
        else bad "AXList '$list' has $dead dead children"; fi
    done
    [[ $checked -eq 1 ]] || bad "no AXList titled 'Chats' or 'Friends'"
    if grep -Eq 'role=AXList .*title="Messages"' "$DUMP"; then
        read -r labelled dead < <(list_stats "Messages")
        if [[ $labelled -gt 0 && $dead -eq 0 ]]; then ok "AXList 'Messages' has $labelled labelled rows"
        else bad "AXList 'Messages': $labelled labelled rows, $dead dead children"; fi
    else
        skp "Messages list checks (no chat open)"
    fi
else
    skp "main-window checks (LINE is not logged in)"
fi

# --- Generic checks (any screen) -------------------------------------------------------------
if grep -E "role=AXButton " "$DUMP" | grep -vF 'title="" desc=""' | grep -q "AXPress"; then
    ok "labelled AXButtons with AXPress exist"
else
    bad "no labelled AXButton with AXPress"
fi
unlabelled=$(grep -E "role=AXTextField " "$DUMP" | grep -cF 'title="" desc=""' || true)
if [[ "$unlabelled" -eq 0 ]]; then ok "no unlabelled AXTextFields"
else bad "$unlabelled AXTextField(s) without title/description"; fi

echo
echo "== $pass passed, $fail failed, $skip skipped"
[[ $fail -eq 0 ]]
