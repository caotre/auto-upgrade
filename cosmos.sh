#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIG
# ============================================================

UPGRADE_HEIGHT="${UPGRADE_HEIGHT:-33618500}"

BINARY="${BINARY:-gaiad}"
SCREEN_NAME="${SCREEN_NAME:-cosmos-upgrade}"

PROPOSAL_URL="${PROPOSAL_URL:-https://cosmos-api.polkachu.com/cosmos/gov/v1/proposals/1059}"

PROJECT_HOME="${PROJECT_HOME:-$HOME}"
NEW_BIN="${NEW_BIN:-$PROJECT_HOME/auto-upgrade/gaiad}"

CONFIG_DIR="${CONFIG_DIR:-$PROJECT_HOME/.gaia/config}"

CHECK_INTERVAL=4
PROPOSAL_CHECK_INTERVAL=30


# ============================================================
# COLORS
# ============================================================

GREEN="\033[1;32m"
RED="\033[1;31m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
NC="\033[0m"


# ============================================================
# HELPERS
# ============================================================

print_line() {
    echo "------------------------------------------------------------------------------------"
}


# ============================================================
# TELEGRAM
# ============================================================

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
BOT_TOKEN="${BOT_TOKEN:-${TELEGRAM_BOT_TOKEN}}"
CHAT_ID_ALARM="${CHAT_ID_ALARM:-${TELEGRAM_CHAT_ID}}"

load_telegram() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f /root/auto-upgrade/tg.conf ]]; then
        # shellcheck disable=SC1091
        source /root/auto-upgrade/tg.conf
    elif [[ -f "${PROJECT_HOME:-$HOME}/auto-upgrade/tg.conf" ]]; then
        # shellcheck disable=SC1091
        source "${PROJECT_HOME:-$HOME}/auto-upgrade/tg.conf"
    elif [[ -f "${script_dir}/tg.conf" ]]; then
        # shellcheck disable=SC1091
        source "${script_dir}/tg.conf"
    fi

    BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-${BOT_TOKEN:-}}"
    CHAT_ID_ALARM="${TELEGRAM_CHAT_ID:-${CHAT_ID_ALARM:-}}"
}

send_telegram() {
    local message="$1"
    local response

    if [[ -n "${BOT_TOKEN:-}" && -n "${CHAT_ID_ALARM:-}" ]]; then
        response="$(
            curl -sS \
                --max-time 10 \
                -X POST \
                "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                -d "chat_id=${CHAT_ID_ALARM}" \
                --data-urlencode "text=${message}" \
                2>&1
        )" || {
            echo -e "${YELLOW}WARNING:${NC} Failed to send Telegram notification: ${response}"
            return 0
        }

        if ! echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
            local err_desc
            err_desc="$(echo "$response" | jq -r '.description // "unknown error"' 2>/dev/null || echo "$response")"
            echo -e "${YELLOW}WARNING:${NC} Telegram API returned error: ${err_desc}"
        fi
    fi
}


# ============================================================
# RPC
# ============================================================

get_rpc_height() {
    curl -fsS \
        --max-time 5 \
        "http://127.0.0.1:${RPC_PORT}/status" \
        2>/dev/null |
        jq -r '.result.sync_info.latest_block_height // empty'
}


# ============================================================
# PROPOSAL
# ============================================================

get_proposal_status() {
    if [[ -z "${PROPOSAL_URL:-}" ]]; then
        echo ""
        return
    fi

    local response

    response="$(
        curl -fsS \
            --max-time 10 \
            "$PROPOSAL_URL" \
            2>/dev/null
    )" || {
        echo ""
        return
    }

    echo "$response" |
        jq -r '.proposal.status // empty' 2>/dev/null || true
}


# ============================================================
# FORMAT TIME
# ============================================================

format_time() {
    local seconds="$1"

    (( seconds < 0 )) && seconds=0

    printf "%dd %dh %dm %ds" \
        $((seconds / 86400)) \
        $((seconds % 86400 / 3600)) \
        $((seconds % 3600 / 60)) \
        $((seconds % 60))
}


# ============================================================
# WATCHER MODE
# ============================================================

run_watcher() {
    load_telegram

    print_line
    echo -e " ${GREEN}COSMOS-BASED CHAIN AUTO UPGRADE WATCHER${NC}"
    print_line

    echo -e "Binary       : ${GREEN}${BINARY}${NC}"
    echo -e "Old binary   : ${GREEN}${OLD_BIN}${NC}"
    echo -e "New binary   : ${GREEN}${NEW_BIN}${NC}"
    echo -e "Home         : ${GREEN}${PROJECT_HOME}${NC}"
    echo -e "RPC port     : ${GREEN}${RPC_PORT}${NC}"
    echo -e "RPC URL      : ${GREEN}http://127.0.0.1:${RPC_PORT}${NC}"
    echo -e "Upgrade      : ${BLUE}${UPGRADE_HEIGHT}${NC}"
    echo -e "Proposal API : ${GREEN}${PROPOSAL_URL}${NC}"

    print_line

    # --------------------------------------------------------
    # Validate binary again
    # --------------------------------------------------------

    local version_output
    local version_code

    set +e
    version_output="$("$NEW_BIN" version 2>&1)"
    version_code=$?
    set -e

    if (( version_code != 0 )); then
        echo -e "${RED}ERROR: New binary cannot run.${NC}"
        echo
        echo "$version_output"

        send_telegram \
            "$BINARY upgrade ERROR: new binary failed validation"

        exit 1
    fi

    if [[ -z "$version_output" ]]; then
        echo -e "${RED}ERROR: New binary returned empty version.${NC}"
        exit 1
    fi

    echo -e "New Bin version: ${GREEN}${version_output}${NC}"

    print_line

    echo -e "YOUR NODE WILL BE UPDATED AT HEIGHT ${GREEN}${UPGRADE_HEIGHT}${NC}"
    echo -e "Target version: ${GREEN}${version_output}${NC}"

    print_line

    echo -e "Don't kill this session with ${RED}CTRL+C${NC}"
    echo -e "Detach safely with ${GREEN}CTRL+A then D${NC}"

    print_line

    # --------------------------------------------------------
    # Wait for valid RPC
    # --------------------------------------------------------

    local height=""

    while true; do
        height="$(get_rpc_height || true)"

        if [[ "$height" =~ ^[0-9]+$ ]]; then
            break
        fi

        echo -e "${YELLOW}Waiting for RPC...${NC}"
        sleep 5
    done

    # --------------------------------------------------------
    # Timing
    # --------------------------------------------------------

    local start_height="$height"
    local last_known_height="$height"
    local start_time
    local now
    local elapsed
    local block_delta
    local avg_time=0
    local remaining_blocks
    local remaining_time

    start_time="$(date +%s)"

    # --------------------------------------------------------
    # Proposal
    # --------------------------------------------------------

    local proposal_status=""
    local last_proposal_check=0

    # ========================================================
    # WATCH LOOP
    # ========================================================

    while true; do
        height="$(get_rpc_height || true)"

        if [[ "$height" =~ ^[0-9]+$ ]]; then
            last_known_height="$height"
        else
            echo -e "${YELLOW}RPC unavailable. Retrying...${NC}"

            # Check if node stopped or panicked at upgrade height
            if (( last_known_height >= UPGRADE_HEIGHT - 1 )); then
                local node_halted=false
                if ! systemctl is-active --quiet "$BINARY"; then
                    node_halted=true
                elif journalctl -u "$BINARY" -n 50 --no-pager 2>/dev/null | grep -E -q "UPGRADE .* NEEDED|panic: UPGRADE"; then
                    node_halted=true
                fi

                if [[ "$node_halted" == "true" ]]; then
                    print_line
                    echo -e "${YELLOW}Detected node halt at upgrade height!${NC}"
                    echo -e "Last height : ${GREEN}${last_known_height}${NC} (Target: ${BLUE}${UPGRADE_HEIGHT}${NC})"
                    echo -e "Status      : ${YELLOW}Node stopped/panicked as expected for upgrade.${NC}"
                    print_line
                    break
                fi
            fi

            sleep "$CHECK_INTERVAL"
            continue
        fi

        now="$(date +%s)"

        # ----------------------------------------------------
        # Proposal check
        # ----------------------------------------------------

        if (( now - last_proposal_check >= PROPOSAL_CHECK_INTERVAL )); then
            proposal_status="$(get_proposal_status || true)"
            last_proposal_check="$now"

            if [[ "$proposal_status" == "PROPOSAL_STATUS_REJECTED" ]]; then
                print_line

                echo -e "${RED}Proposal rejected. Upgrade cancelled.${NC}"

                echo "$(date): Upgrade cancelled because proposal was REJECTED" \
                    >> "$PROJECT_HOME/upgrade.log"

                send_telegram \
                    "$BINARY upgrade cancelled: proposal REJECTED"

                exit 0
            fi
        fi

        # ----------------------------------------------------
        # Average block time
        # ----------------------------------------------------

        elapsed=$((now - start_time))
        block_delta=$((height - start_height))

        if (( block_delta > 0 )); then
            avg_time=$((elapsed / block_delta))
        fi

        remaining_blocks=$((UPGRADE_HEIGHT - height))

        if (( remaining_blocks < 0 )); then
            remaining_blocks=0
        fi

        remaining_time=$((remaining_blocks * avg_time))

        # ----------------------------------------------------
        # Display
        # ----------------------------------------------------

        echo -e "Node Height:      ${GREEN}${height}${NC}"
        echo -e "Upgrade Height:   ${BLUE}${UPGRADE_HEIGHT}${NC}"

        if (( avg_time > 0 )); then
            echo -e \
                "Estimated Time:   ${BLUE}$(format_time "$remaining_time")${NC} | Remaining Blocks: ${BLUE}${remaining_blocks}${NC} | Avg Block: ${BLUE}${avg_time}s${NC}"
        else
            echo -e \
                "Estimated Time:   ${YELLOW}calculating...${NC} | Remaining Blocks: ${BLUE}${remaining_blocks}${NC}"
        fi

        if [[ -n "$proposal_status" ]]; then
            echo -e "Proposal Status:  ${GREEN}${proposal_status}${NC}"
        fi

        echo

        # ====================================================
        # UPGRADE CHECK
        # ====================================================

        if (( height >= UPGRADE_HEIGHT )); then
            print_line
            echo -e "${YELLOW}Upgrade height reached (${height} >= ${UPGRADE_HEIGHT}).${NC}"
            echo
            break
        fi

        sleep "$CHECK_INTERVAL"
    done

    # ========================================================
    # UPGRADE EXECUTION
    # ========================================================

    print_line
    echo -e " ${GREEN}EXECUTING UPGRADE${NC}"
    print_line

    # --------------------------------------------------------
    # Final proposal check
    # --------------------------------------------------------

    proposal_status="$(get_proposal_status || true)"

    if [[ "$proposal_status" == "PROPOSAL_STATUS_REJECTED" ]]; then
        echo -e "${RED}Proposal rejected. Upgrade cancelled.${NC}"

        send_telegram \
            "$BINARY upgrade cancelled: proposal REJECTED"

        exit 0
    fi

    if [[ -n "$proposal_status" ]] &&
       [[ "$proposal_status" != "PROPOSAL_STATUS_PASSED" ]]; then
        echo -e "${RED}Upgrade cancelled.${NC}"
        echo -e "Proposal status: ${RED}${proposal_status}${NC}"

        echo "$(date): Upgrade cancelled due to proposal status: $proposal_status" \
            >> "$PROJECT_HOME/upgrade.log"

        send_telegram \
            "$BINARY upgrade cancelled: $proposal_status"

        exit 0
    fi

    if [[ "$proposal_status" == "PROPOSAL_STATUS_PASSED" ]]; then
        echo -e "Proposal: ${GREEN}PASSED${NC}"
    elif [[ -z "$proposal_status" ]]; then
        echo -e "${YELLOW}Proposal API unavailable. Continuing upgrade.${NC}"
    fi

    # --------------------------------------------------------
    # Final binary validation
    # --------------------------------------------------------

    echo
    echo "Final binary check..."

    if ! "$NEW_BIN" version >/dev/null 2>&1; then
        echo -e "${RED}ERROR: New binary failed final validation.${NC}"

        send_telegram \
            "$BINARY upgrade ERROR: binary failed final validation"

        exit 1
    fi

    # --------------------------------------------------------
    # Stop service & Reset systemd failed state (fix start-limit-hit)
    # --------------------------------------------------------

    echo
    echo -e "${YELLOW}Stopping ${BINARY} before replacing binary...${NC}"
    systemctl stop "$BINARY" 2>/dev/null || true
    systemctl reset-failed "$BINARY" 2>/dev/null || true

    # --------------------------------------------------------
    # Replace binary
    # --------------------------------------------------------

    echo
    echo -e "${YELLOW}Replacing binary...${NC}"

    if [[ "$NEW_BIN" != "$OLD_BIN" ]]; then
        cp -f "$NEW_BIN" "$OLD_BIN"
    fi
    chmod +x "$OLD_BIN"

    # --------------------------------------------------------
    # Restart service
    # --------------------------------------------------------

    echo -e "${YELLOW}Restarting ${BINARY}...${NC}"

    systemctl reset-failed "$BINARY" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart "$BINARY"

    sleep 5

    # --------------------------------------------------------
    # Verify service
    # --------------------------------------------------------

    if systemctl is-active --quiet "$BINARY"; then
        print_line

        echo -e "${GREEN}Node upgraded successfully.${NC}"
        echo -e "Version: ${GREEN}${version_output}${NC}"

        echo "$(date): Node successfully upgraded to ${version_output}" \
            >> "$PROJECT_HOME/upgrade.log"

        send_telegram \
            "$BINARY upgraded to ${version_output} and service restarted"
    else
        print_line

        echo -e "${RED}ERROR: ${BINARY} service failed after upgrade.${NC}"

        echo
        echo "Check:"
        echo "  systemctl status $BINARY --no-pager"
        echo "  journalctl -u $BINARY -n 100 --no-pager"

        echo "$(date): Service failed after upgrade to ${version_output}" \
            >> "$PROJECT_HOME/upgrade.log"

        send_telegram \
            "$BINARY upgrade ERROR: service failed after restart"

        exit 1
    fi

    print_line

    echo
    echo "Watcher will close automatically in 15 minutes."
    echo

    sleep 900
    exit 0
}


# ============================================================
# INTERNAL WATCHER ENTRY
# ============================================================

if [[ "${1:-}" == "--watcher" ]]; then
    : "${OLD_BIN:?OLD_BIN is not set}"
    : "${NEW_BIN:?NEW_BIN is not set}"
    : "${RPC_PORT:?RPC_PORT is not set}"
    : "${PROJECT_HOME:?PROJECT_HOME is not set}"

    run_watcher
    exit 0
fi


# ============================================================
# MAIN
# ============================================================

# ============================================================
# REQUIREMENTS
# ============================================================

for CMD in curl screen jq grep awk systemctl; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo -e "${RED}ERROR:${NC} '$CMD' is not installed."
        exit 1
    fi
done


# ============================================================
# ARCH CHECK
# ============================================================

ARCH="$(uname -m)"

if [[ "$ARCH" != "x86_64" && "$ARCH" != "amd64" ]]; then
    echo -e "${RED}ERROR:${NC} Binary is linux-amd64 but CPU architecture is '$ARCH'."
    exit 1
fi


# ============================================================
# CURRENT BINARY
# ============================================================

OLD_BIN="$(command -v "$BINARY" || true)"

if [[ -z "$OLD_BIN" ]]; then
    echo -e "${RED}ERROR:${NC} $BINARY not found in PATH."
    exit 1
fi


# ============================================================
# RPC PORT
# ============================================================

RPC_PORT="$(
    grep -m1 -oP '^laddr = "\K[^"]+' \
        "$CONFIG_DIR/config.toml" 2>/dev/null |
        awk -F: '{print $NF}' || true
)"

if [[ -z "$RPC_PORT" ]]; then
    RPC_PORT="$(
        grep -m1 -oP \
            'node = "tcp://[^:]+:\K\d+' \
            "$CONFIG_DIR/client.toml" \
            2>/dev/null || true
    )"
fi

if [[ -z "$RPC_PORT" ]]; then
    echo -e "${RED}ERROR:${NC} Cannot detect RPC port."
    exit 1
fi

RPC_URL="http://127.0.0.1:${RPC_PORT}"


# ============================================================
# SCRIPT PATH
# ============================================================

SCRIPT_PATH="$(readlink -f "$0")"


# ============================================================
# INFO
# ============================================================

echo
print_line
echo -e " ${GREEN}COSMOS-BASED CHAIN AUTO UPGRADE${NC}"
print_line

echo "Old binary : $OLD_BIN"
echo "New binary : $NEW_BIN"
echo "Height     : $UPGRADE_HEIGHT"
echo "RPC port   : $RPC_PORT"
echo "RPC URL    : $RPC_URL"
echo "Status     : ${RPC_URL}/status"
echo "Proposal   : $PROPOSAL_URL"
echo "Screen     : $SCREEN_NAME"

print_line
echo


# ============================================================
# EXISTING SCREEN CHECK
# ============================================================

if screen -ls 2>/dev/null |
    grep -q "[.]${SCREEN_NAME}[[:space:]]"; then

    echo -e "${RED}ERROR:${NC} Screen '$SCREEN_NAME' is already running."

    echo
    echo "Resume:"
    echo "  screen -r $SCREEN_NAME"

    echo
    echo "Force resume:"
    echo "  screen -dr $SCREEN_NAME"

    echo
    echo "Kill:"
    echo "  screen -S $SCREEN_NAME -X quit"

    exit 1
fi


# ============================================================
# LOCAL BINARY CHECK
# ============================================================

echo -e "${CYAN}Checking local binary...${NC}"

if [[ ! -f "$NEW_BIN" ]]; then
    echo -e "${RED}ERROR:${NC} New binary not found at '$NEW_BIN'."
    echo "Please ensure the binary is placed at '$NEW_BIN' or specify NEW_BIN."
    exit 1
fi

if [[ ! -s "$NEW_BIN" ]]; then
    echo -e "${RED}ERROR:${NC} New binary at '$NEW_BIN' is empty (0 bytes)."
    exit 1
fi

chmod +x "$NEW_BIN"

if command -v file >/dev/null 2>&1; then
    echo "New binary file info:"
    file "$NEW_BIN"

    echo
fi


# ============================================================
# TEST NEW BINARY
# ============================================================

echo -e "${CYAN}Checking new binary...${NC}"

set +e

NEW_VERSION="$("$NEW_BIN" version 2>&1)"
VERSION_EXIT_CODE=$?

set -e

if (( VERSION_EXIT_CODE != 0 )); then
    echo
    print_line

    echo -e "${RED}ERROR: New binary failed to run.${NC}"

    echo
    echo "Exit code:"
    echo "  $VERSION_EXIT_CODE"

    echo
    echo "Output:"
    print_line

    printf '%s\n' "$NEW_VERSION" | head -n 80

    print_line

    echo
    echo -e "${YELLOW}Auto-upgrade was NOT started.${NC}"

    echo
    echo "Manual test:"
    echo "  $NEW_BIN version"

    echo
    echo "First 50 error lines:"
    echo "  $NEW_BIN version 2>&1 | head -n 50"

    exit 1
fi

if [[ -z "$NEW_VERSION" ]]; then
    echo -e "${RED}ERROR:${NC} New binary returned empty version."
    exit 1
fi

echo -e "${GREEN}New binary OK${NC}"
echo -e "New version : ${GREEN}${NEW_VERSION}${NC}"

echo


# ============================================================
# RPC CHECK
# ============================================================

echo -e "${CYAN}Checking RPC...${NC}"

CURRENT_HEIGHT="$(
    curl -fsS \
        --max-time 5 \
        "${RPC_URL}/status" \
        2>/dev/null |
        jq -r '.result.sync_info.latest_block_height // empty' \
        2>/dev/null || true
)"

if [[ "$CURRENT_HEIGHT" =~ ^[0-9]+$ ]]; then
    echo -e "${GREEN}RPC OK${NC}"
    echo "Current height : $CURRENT_HEIGHT"
else
    echo -e "${YELLOW}WARNING:${NC} RPC does not respond correctly."
    echo "RPC: ${RPC_URL}/status"
fi

echo


# ============================================================
# SUDO
# ============================================================

if (( EUID != 0 )); then
    echo -e "${CYAN}Checking sudo access...${NC}"

    if ! sudo -v; then
        echo -e "${RED}ERROR:${NC} sudo authentication failed."
        exit 1
    fi

    echo -e "${GREEN}Sudo OK${NC}"
    echo
fi


# ============================================================
# TELEGRAM CHECK
# ============================================================

load_telegram

if [[ -n "${BOT_TOKEN:-}" && -n "${CHAT_ID_ALARM:-}" ]]; then
    echo -e "${CYAN}Checking Telegram configuration...${NC}"
    echo -e "${GREEN}Telegram OK${NC} (Chat ID: ${CHAT_ID_ALARM})"
    echo
else
    echo -e "${YELLOW}WARNING:${NC} Telegram notification is not configured (tg.conf missing or empty)."
    echo
fi


# ============================================================
# START WATCHER
# ============================================================

echo -e "${CYAN}Starting upgrade watcher...${NC}"

if (( EUID == 0 )); then
    screen -dmS "$SCREEN_NAME" \
        env \
        BINARY="$BINARY" \
        OLD_BIN="$OLD_BIN" \
        NEW_BIN="$NEW_BIN" \
        PROJECT_HOME="$PROJECT_HOME" \
        RPC_PORT="$RPC_PORT" \
        UPGRADE_HEIGHT="$UPGRADE_HEIGHT" \
        PROPOSAL_URL="$PROPOSAL_URL" \
        SCREEN_NAME="$SCREEN_NAME" \
        BOT_TOKEN="${BOT_TOKEN:-}" \
        CHAT_ID_ALARM="${CHAT_ID_ALARM:-}" \
        TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
        TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}" \
        bash "$SCRIPT_PATH" --watcher
else
    screen -dmS "$SCREEN_NAME" \
        sudo -n env \
        BINARY="$BINARY" \
        OLD_BIN="$OLD_BIN" \
        NEW_BIN="$NEW_BIN" \
        PROJECT_HOME="$PROJECT_HOME" \
        RPC_PORT="$RPC_PORT" \
        UPGRADE_HEIGHT="$UPGRADE_HEIGHT" \
        PROPOSAL_URL="$PROPOSAL_URL" \
        SCREEN_NAME="$SCREEN_NAME" \
        BOT_TOKEN="${BOT_TOKEN:-}" \
        CHAT_ID_ALARM="${CHAT_ID_ALARM:-}" \
        TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
        TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}" \
        bash "$SCRIPT_PATH" --watcher
fi

sleep 2


# ============================================================
# VERIFY SCREEN
# ============================================================

if ! screen -ls 2>/dev/null |
    grep -q "[.]${SCREEN_NAME}[[:space:]]"; then

    echo
    echo -e "${RED}ERROR:${NC} '$SCREEN_NAME' screen failed to start."

    echo
    echo "Possible sudo issue."

    echo
    echo "Try running the script as root:"
    echo "  sudo bash $SCRIPT_PATH"

    exit 1
fi


# ============================================================
# DONE
# ============================================================

echo
print_line
echo -e " ${GREEN}AUTO-UPGRADE STARTED SUCCESSFULLY${NC}"
print_line

echo
echo "New version:"
echo "  $NEW_VERSION"

echo
echo "Current height:"
echo "  ${CURRENT_HEIGHT:-unknown}"

echo
echo "Upgrade height:"
echo "  $UPGRADE_HEIGHT"

echo
echo "RPC:"
echo "  $RPC_URL"

echo
echo "Status:"
echo "  ${RPC_URL}/status"

echo
echo "Screen commands:"

echo
echo "  Resume / open:"
echo "    screen -r $SCREEN_NAME"

echo
echo "  Force resume if already attached:"
echo "    screen -dr $SCREEN_NAME"

echo
echo "  Detach WITHOUT stopping:"
echo "    Ctrl+A, then D"

echo
echo "  List screen sessions:"
echo "    screen -ls"

echo
echo "  Stop / kill upgrade watcher:"
echo "    screen -S $SCREEN_NAME -X quit"

echo
print_line

echo
echo -e "${YELLOW}IMPORTANT:${NC}"
echo "  Do NOT press Ctrl+C inside the upgrade screen."
echo "  Use Ctrl+A then D to detach and leave it running."

echo
