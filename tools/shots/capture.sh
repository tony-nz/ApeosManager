#!/bin/bash
# Retakes every screenshot on the documentation site, from demo mode.
#
#   tools/shots/capture.sh [manager|quota]
#
# Both apps are launched under -demoMode YES, so nothing here touches a real printer,
# a real credential or the operator's own settings. See Sources/Shared/Demo/DemoMode.swift.
#
# Coordinates are window-relative. The window frame is set through the Accessibility API
# first, so a control at window point (wx, wy) is at screen (X0+wx, Y0+wy) -- which is
# why nothing here depends on where a window was last dragged to. Captures are 2x on
# Retina, so a point measured in a `-o` capture is at half its pixel coordinate.
#
# Needs Screen Recording (for screencapture) and Accessibility (for the click and AX
# helpers) granted to the terminal. macOS prompts once for each.
set -e
cd "$(dirname "$0")/../.."

OUT=docs/screenshots
BUILD=./build/Build/Products/Debug
X0=140; Y0=120; W=1320; H=820
SIDEBAR=240        # the sidebar's own width, which the detail pane starts after
WHICH=${1:-all}

mkdir -p "$OUT" bin
for t in winlist click axwin focus key type; do
    [ tools/shots/$t.swift -nt bin/$t ] && swiftc -O -o bin/$t tools/shots/$t.swift
done

# Click at a point given relative to the managed window. The app is brought forward
# first: a click on a background window is spent activating it, not pressing anything.
PID=""
win_click() {
    ./bin/focus "$PID" >/dev/null
    ./bin/click $((X0 + $1)) $((Y0 + $2))
    sleep "${3:-1.2}"
}

# The detail pane's tab bar is centred in the pane, so a tab's x follows the window
# width. Offsets are measured from that centre once, and survive a resize.
tab_x() { echo $(( SIDEBAR + (W - SIDEBAR) / 2 + $1 )); }
TAB_OVERVIEW=-184; TAB_TRAYS=-115; TAB_SETTINGS=-51; TAB_ACCOUNTS=24
TAB_BOOK=116; TAB_LOGS=195
TAB_Y=136
# Sidebar rows, measured from a `-o` capture scaled 1:1 with window points. Measuring
# from a shadowed capture instead is the easy mistake: the shadow pads the image, so
# every coordinate comes out shifted and the clicks land just outside their controls.
SB_X=65
SB_OVERVIEW=85; SB_USERS=113; SB_BOOK=141; SB_LOGS=168
SB_RECEPTION=234; SB_ACCOUNTS_ROOM=273; SB_GOODS_IN=312
SB_STUDIO=351; SB_BRANCH=390

# Capture the app's ordinary (layer 0) window. The shadow is kept: it reads better on
# a page than a bare rectangle, and CSS cannot add one that matches.
shot() {
    local pid=$1 name=$2
    local id
    id=$(./bin/winlist "Apeos" "$pid" | awk -F'\t' '$3=="layer=0"{print $1}' | head -1 | sed 's/id=//')
    [ -n "$id" ] || { echo "no window for $name" >&2; return 1; }
    screencapture -x -l"$id" "$OUT/$name.png"
    echo "  $name"
}

capture_manager() {
    pkill -f "$BUILD/ApeosManager.app/Contents/MacOS" 2>/dev/null || true
    sleep 1
    nohup "$BUILD/ApeosManager.app/Contents/MacOS/ApeosManager" -demoMode YES >/dev/null 2>&1 &
    sleep 6
    local pid; pid=$(pgrep -f "$BUILD/ApeosManager.app/Contents/MacOS" | head -1)
    PID=$pid
    ./bin/focus "$pid" >/dev/null
    ./bin/axwin "$pid" "*" $X0 $Y0 $W $H >/dev/null
    sleep 1
    win_click $SB_X $SB_OVERVIEW

    echo "manager:"
    shot "$pid" fleet-overview          # the argument for the app: Ready, and not

    win_click $SB_X $SB_USERS;  shot "$pid" fleet-users
    win_click $SB_X $SB_BOOK;   shot "$pid" fleet-address-book
    win_click $SB_X $SB_LOGS;   shot "$pid" fleet-logs

    # One printer's own screens. The tab bar sits at window y=136; the tabs are
    # Overview / Trays / Settings / Accounts / Address Book / Logs.
    win_click $SB_X $SB_STUDIO 2.5; shot "$pid" printer-overview  # Design Studio: spent drum
    win_click "$(tab_x $TAB_LOGS)" $TAB_Y
    shot "$pid" printer-jobs                                # who printed what
    win_click 405 163;    shot "$pid" printer-faults        # its one repeating code
    win_click "$(tab_x $TAB_TRAYS)" $TAB_Y
    shot "$pid" printer-trays                               # and its empty A3 tray
    win_click "$(tab_x $TAB_SETTINGS)" $TAB_Y
    shot "$pid" printer-settings                            # the device's own identity

    win_click $SB_X $SB_ACCOUNTS_ROOM 2.5                   # Accounts Copy Room
    win_click "$(tab_x $TAB_ACCOUNTS)" $TAB_Y
    shot "$pid" printer-accounts

    capture_add_user "$pid"
    capture_edit_user "$pid"

    # Last, because it is a sheet: one left open silently blocks every click after it,
    # which is why it is dismissed rather than left for the next run to trip over.
    win_click 146 26 3.0                                    # + in the toolbar
    win_click 852 318 4.5                                   # Scan Network, then let it run
    shot "$pid" add-printer                                 # the sweep, with results
    ./bin/key 53
}

# The Add User sheet. Four panes, and each is worth its own shot: the sheet is where
# most of what this app does for an administrator actually happens.
#
# Every pane is entered by clicking its tab first. Assuming the sheet is still on the
# pane the last shot left it on is how a run ends up typing usage limits into the
# permissions pickers.
capture_add_user() {
    local pid=$1
    local ADD_USER_X=1214 ADD_USER_Y=79
    local T_DETAILS=457 T_PRINTERS=592 T_USAGE=727 T_PERMS=861 T_Y=185

    win_click $SB_X $SB_USERS 2.0                           # the fleet Users screen
    win_click $ADD_USER_X $ADD_USER_Y 2.5

    win_click $T_DETAILS $T_Y
    win_click 660 249; ./bin/type "2061"
    win_click 660 286; ./bin/type "Stock Room Desk"
    win_click 660 452; ./bin/type "stockroom@example.net"
    sleep 1
    shot "$pid" add-user-details

    win_click $T_PRINTERS $T_Y 1.2
    win_click 402 274; win_click 402 310; win_click 402 382  # the three signed in
    sleep 1
    shot "$pid" add-user-printers

    win_click $T_USAGE $T_Y 1.2
    win_click 636 243; win_click 573 243; ./bin/type "200"   # copy colour
    win_click 636 328; win_click 573 328; ./bin/type "250"   # print colour
    win_click 636 356; win_click 573 356; ./bin/type "1000"  # print mono
    sleep 1
    shot "$pid" add-user-usage

    win_click $T_PERMS $T_Y 2.5
    shot "$pid" add-user-permissions

    ./bin/key 53                                             # discard; nothing is written
    sleep 1
}

# Editing an existing account, which differs from creating one: the usage and permission
# panes are per printer, because the devices hold their own copies and disagree.
capture_edit_user() {
    local pid=$1
    local EDIT_X=1041 EDIT_Y=79
    # Same tab positions as the Add User sheet, but 27pt lower: this one carries the
    # account's name and printer count above the tabs.
    local T_USAGE=727 T_PERMS=861 T_Y=212

    win_click $SB_X $SB_USERS 2.0
    win_click 500 169 1.2                                    # select 2041 Reception Desk
    win_click $EDIT_X $EDIT_Y 2.5

    win_click $T_USAGE $T_Y 1.5
    shot "$pid" edit-user-usage

    win_click $T_PERMS $T_Y 2.5
    shot "$pid" edit-user-permissions

    ./bin/key 53
    sleep 1
}

capture_quota() {
    pkill -f "$BUILD/ApeosQuota.app/Contents/MacOS" 2>/dev/null || true
    sleep 1
    nohup "$BUILD/ApeosQuota.app/Contents/MacOS/ApeosQuota" -demoMode YES >/dev/null 2>&1 &
    sleep 7
    local pid; pid=$(pgrep -f "$BUILD/ApeosQuota.app/Contents/MacOS" | head -1)
    PID=$pid

    # The menu bar extra's own x, which moves with whatever else is up there -- and with
    # the label itself, which widens once a balance is being shown.
    local mx
    mx=$(./bin/winlist "Apeos Quota" "$pid" \
         | awk -F'\t' '$3=="layer=25" && $5 !~ /-/ {print $5}' | head -1 | tr -d '@' | cut -d, -f1)
    echo "quota: (menu bar item at x=$mx)"

    ./bin/click $((mx + 20)) 12
    sleep 3
    local pop
    pop=$(./bin/winlist "Apeos Quota" "$pid" | awk -F'\t' '$3=="layer=101"{print $1}' | head -1 | sed 's/id=//')
    screencapture -x -l"$pop" "$OUT/quota-menu-bar.png"
    echo "  quota-menu-bar"

    # The popover's own footer buttons, measured 1:1 against its 340x472 frame:
    # refresh at x=261, the pop-out at 286, the overflow menu at 311.
    ./bin/click $((mx + 286)) $((26 + 454))
    sleep 3
    ./bin/key 53                                   # dismiss the popover behind it
    sleep 1
    ./bin/focus "$pid" >/dev/null
    ./bin/axwin "$pid" "Balance" 300 200 260 285 >/dev/null
    sleep 1
    local bid
    bid=$(./bin/winlist "Apeos Quota" "$pid" | awk -F'\t' '$3=="layer=3"{print $1}' | head -1 | sed 's/id=//')
    screencapture -x -l"$bid" "$OUT/quota-balance.png"
    echo "  quota-balance"

    # "Details..." in the balance window's footer.
    ./bin/focus "$pid" >/dev/null
    ./bin/click $((300 + 218)) $((200 + 265))
    sleep 3
    ./bin/axwin "$pid" "Apeos Quota" 300 160 660 640 >/dev/null
    sleep 1
    local did
    did=$(./bin/winlist "Apeos Quota" "$pid" | awk -F'\t' '$3=="layer=0"{print $1}' | head -1 | sed 's/id=//')
    screencapture -x -l"$did" "$OUT/quota-detail.png"
    echo "  quota-detail"
}

case "$WHICH" in
    manager) capture_manager ;;
    quota)   capture_quota ;;
    *)       capture_manager; capture_quota ;;
esac
echo "done -> $OUT"
