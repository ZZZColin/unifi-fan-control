#!/bin/bash
###############################################################################
# UniFi Intelligent Fan Controller (hardened fork)
#
# Changes versus upstream (see FORK-GUIDE.md for the full list):
#   F1  EMERGENCY bypasses the ramp limiter (immediate MAX_PWM)
#   F2  Learning: per-tick temperature delta, OPTIMAL_PWM reloaded after update
#   F3  Smoothing keeps float precision (no integer dead zone with high ALPHA)
#   F4  TAPER cannot drop to OFF while temp is still >= activation temp
#   F5  Initial temperature read fails safe (assume activation temp, fans on)
#   F6  Config validation: leading zeros, MAX_TEMP vs activation temp,
#       in-place key updates that keep user comments, root-only config check
#   F7  EXIT_PWM: configurable PWM written on exit (default 91, not 0)
#   F8  External commands run under timeout, systemd watchdog keep-alive
#   F9  smartctl uses -n standby and tolerates SMART history exit bits
#   F10 flock is taken BEFORE any PWM probe; periodic re-detect no longer
#       writes read-back values; periodic forced re-write of the last PWM
#   F11 pwmN_enable is reported at detection time
#   F12 Drive hot-plug rescan and per-drive hold of the last good temperature
#   F13 Drive floor ramps from at least MIN_PWM; failed MAX_PWM probe excludes
#       the channel; startup read failure ignores the saved temperature
###############################################################################

umask 077

###[ CONFIGURATION ]###########################################################
CONFIG_FILE="${FAN_CONTROL_CONFIG_FILE:-/data/fan-control/config}"
TEMP_STATE_FILE="${FAN_CONTROL_TEMP_STATE_FILE:-/data/fan-control/temp_state}"
HWMON_BASE="${FAN_CONTROL_HWMON_BASE:-/sys/class/hwmon}"
VERSION_FILE="${FAN_CONTROL_VERSION_FILE:-/data/fan-control/VERSION}"
DRIVE_DEV_DIR="${FAN_CONTROL_DRIVE_DEV_DIR:-/dev}"
EXTERNAL_CMD_TIMEOUT="${FAN_CONTROL_CMD_TIMEOUT:-10}"

# Define default configuration values
DEFAULT_MIN_PWM=91                                    # Minimum active fan speed (0-255)
DEFAULT_MAX_PWM=255                                   # Maximum fan speed (0-255)
DEFAULT_MIN_TEMP=60                                   # Base threshold (°C)
DEFAULT_MAX_TEMP=85                                   # Critical temperature (°C)
DEFAULT_HYSTERESIS=5                                  # Temperature buffer (°C)
DEFAULT_CHECK_INTERVAL=15                             # Base check interval (seconds)
DEFAULT_TAPER_MINS=90                                 # Cool-down duration (minutes)
DEFAULT_FAN_PWM_AUTODETECT=true                       # Auto-detect all active fan PWM channels
DEFAULT_FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1" # Only used when FAN_PWM_AUTODETECT=false
DEFAULT_OPTIMAL_PWM_FILE="${FAN_CONTROL_OPTIMAL_PWM_FILE:-/data/fan-control/optimal_pwm}"
DEFAULT_MAX_PWM_STEP=25 # Max PWM change per adjustment
DEFAULT_DEADBAND=1      # Temp stability threshold (°C)
DEFAULT_ALPHA=20        # Smoothing factor, lower values make the smoothed temp follow raw temp more closely (0-100)
DEFAULT_LEARNING_RATE=5 # PWM optimization step size
DEFAULT_DRIVE_TEMP_ENABLED=auto
DEFAULT_DRIVE_MIN_TEMP=50
DEFAULT_DRIVE_MAX_TEMP=70
DEFAULT_DRIVE_CHECK_INTERVAL=60
DEFAULT_EXIT_PWM=91 # PWM left on the fans when the service stops

# Run an external command with a timeout so a hung tool cannot stall the loop.
run_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        # -k (kill after) is not supported by every timeout (old busybox): probe once
        if [[ -z "${TIMEOUT_KILL_OPT:-}" ]]; then
            if timeout -k 1 1 true >/dev/null 2>&1; then TIMEOUT_KILL_OPT=yes; else TIMEOUT_KILL_OPT=no; fi
        fi
        if [[ "$TIMEOUT_KILL_OPT" == yes ]]; then
            timeout -k 2 "$EXTERNAL_CMD_TIMEOUT" "$@"
        else
            timeout "$EXTERNAL_CMD_TIMEOUT" "$@"
        fi
    else
        "$@"
    fi
}

# Create config file if it doesn't exist
if [[ ! -f "$CONFIG_FILE" ]]; then
    logger -t fan-control "CONFIG: Creating new config file"

    # Create directory if it doesn't exist
    config_dir=$(dirname "$CONFIG_FILE")
    if [[ ! -d "$config_dir" ]]; then
        if ! mkdir -p "$config_dir" 2>/dev/null; then
            logger -t fan-control "FATAL: Failed to create config directory: $config_dir"
            exit 1
        fi
    fi

    # Use a temporary file and atomic move to prevent partial writes
    temp_config="${CONFIG_FILE}.tmp"
    if ! cat >"$temp_config" <<-DEFAULTS 2>/dev/null; then
MIN_PWM=$DEFAULT_MIN_PWM             # Minimum active fan speed (0-255)
MAX_PWM=$DEFAULT_MAX_PWM            # Maximum fan speed (0-255)
MIN_TEMP=$DEFAULT_MIN_TEMP            # Base threshold (°C)
MAX_TEMP=$DEFAULT_MAX_TEMP            # Critical temperature (°C)
HYSTERESIS=$DEFAULT_HYSTERESIS           # Temperature buffer (°C)
CHECK_INTERVAL=$DEFAULT_CHECK_INTERVAL      # Base check interval (seconds)
TAPER_MINS=$DEFAULT_TAPER_MINS          # Cool-down duration (minutes)
FAN_PWM_AUTODETECT=$DEFAULT_FAN_PWM_AUTODETECT  # Auto-detect all active fan PWM channels
FAN_PWM_DEVICE="$DEFAULT_FAN_PWM_DEVICE"  # Only used when FAN_PWM_AUTODETECT=false
OPTIMAL_PWM_FILE="$DEFAULT_OPTIMAL_PWM_FILE"
MAX_PWM_STEP=$DEFAULT_MAX_PWM_STEP        # Max PWM change per adjustment (EMERGENCY ignores it)
DEADBAND=$DEFAULT_DEADBAND             # Temp stability threshold (°C)
ALPHA=$DEFAULT_ALPHA               # Smoothing factor, lower values make the smoothed temp follow raw temp more closely (0-100)
LEARNING_RATE=$DEFAULT_LEARNING_RATE        # PWM optimization step size
DRIVE_TEMP_ENABLED=$DEFAULT_DRIVE_TEMP_ENABLED
DRIVE_MIN_TEMP=$DEFAULT_DRIVE_MIN_TEMP
DRIVE_MAX_TEMP=$DEFAULT_DRIVE_MAX_TEMP
DRIVE_CHECK_INTERVAL=$DEFAULT_DRIVE_CHECK_INTERVAL
EXIT_PWM=$DEFAULT_EXIT_PWM            # PWM written when the service stops (0 = hand back to firmware; verify on your device first)
DEFAULTS
        logger -t fan-control "FATAL: Failed to write to temporary config file"
        exit 1
    elif ! mv "$temp_config" "$CONFIG_FILE" 2>/dev/null; then
        logger -t fan-control "FATAL: Failed to create config file"
        rm -f "$temp_config" 2>/dev/null # Clean up the temporary file
        exit 1
    else
        logger -t fan-control "CONFIG: New configuration file created successfully"
    fi
fi

# The config file is sourced as shell code. When running as root, refuse to
# source it unless it and its directory are owned by root and not writable by
# group/other (a writable directory would let someone swap the file).
if [[ "$(id -u)" -eq 0 ]]; then
    for _path in "$CONFIG_FILE" "$(dirname "$CONFIG_FILE")"; do
        # -L: judge the file the symlink points to, not the link itself
        config_meta=$(stat -L -c '%u %a' "$_path" 2>/dev/null)
        config_owner=${config_meta%% *}
        config_mode=${config_meta##* }
        if ! [[ "$config_mode" =~ ^[0-7]+$ ]]; then
            logger -t fan-control "FATAL: Cannot determine owner and mode of $_path"
            exit 1
        fi
        if [[ "$config_owner" != "0" ]] || (((8#$config_mode & 8#022) != 0)); then
            logger -t fan-control "FATAL: $_path must be owned by root and not group/world writable (owner=$config_owner mode=$config_mode)"
            exit 1
        fi
    done
    unset _path
fi

# A config edited on Windows has CRLF line endings; the carriage returns would
# become part of every value and reset all settings to defaults. Convert once.
if grep -q $'\r' "$CONFIG_FILE" 2>/dev/null; then
    logger -t fan-control "CONFIG: Converting CRLF line endings in $CONFIG_FILE"
    if tr -d '\r' <"$CONFIG_FILE" >"${CONFIG_FILE}.tmp" 2>/dev/null && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE" 2>/dev/null; then
        :
    else
        rm -f "${CONFIG_FILE}.tmp" 2>/dev/null
        logger -t fan-control "WARNING: Could not rewrite $CONFIG_FILE; values are still cleaned of carriage returns during validation"
    fi
fi

# Source the config file
# shellcheck source=/dev/null
source "$CONFIG_FILE" 2>/dev/null

# Check if each required parameter is defined, and add missing ones
missing_params=()
missing_values=()
missing_comments=()

check_param() {
    local param=$1
    local default_value=$2
    local comment=$3

    if ! grep -q "^${param}=" "$CONFIG_FILE" 2>/dev/null; then
        logger -t fan-control "CONFIG: Missing parameter detected: $param"
        missing_params+=("$param")
        missing_values+=("$default_value")
        missing_comments+=("$comment")
        # Set the value in the current environment
        eval "${param}=${default_value}"
    fi
}

# Check each parameter
check_param "MIN_PWM" "$DEFAULT_MIN_PWM" "# Minimum active fan speed (0-255)"
check_param "MAX_PWM" "$DEFAULT_MAX_PWM" "# Maximum fan speed (0-255)"
check_param "MIN_TEMP" "$DEFAULT_MIN_TEMP" "# Base threshold (°C)"
check_param "MAX_TEMP" "$DEFAULT_MAX_TEMP" "# Critical temperature (°C)"
check_param "HYSTERESIS" "$DEFAULT_HYSTERESIS" "# Temperature buffer (°C)"
check_param "CHECK_INTERVAL" "$DEFAULT_CHECK_INTERVAL" "# Base check interval (seconds)"
check_param "TAPER_MINS" "$DEFAULT_TAPER_MINS" "# Cool-down duration (minutes)"
check_param "FAN_PWM_AUTODETECT" "$DEFAULT_FAN_PWM_AUTODETECT" "# Auto-detect all active fan PWM channels"
check_param "FAN_PWM_DEVICE" "\"$DEFAULT_FAN_PWM_DEVICE\"" "# Fan PWM device path (only used when FAN_PWM_AUTODETECT=false)"
check_param "OPTIMAL_PWM_FILE" "\"$DEFAULT_OPTIMAL_PWM_FILE\"" "# Optimal PWM file path"
check_param "MAX_PWM_STEP" "$DEFAULT_MAX_PWM_STEP" "# Max PWM change per adjustment (EMERGENCY ignores it)"
check_param "DEADBAND" "$DEFAULT_DEADBAND" "# Temp stability threshold (°C)"
check_param "ALPHA" "$DEFAULT_ALPHA" "# Smoothing factor (0-100)"
check_param "LEARNING_RATE" "$DEFAULT_LEARNING_RATE" "# PWM optimization step size"
check_param "DRIVE_TEMP_ENABLED" "$DEFAULT_DRIVE_TEMP_ENABLED" "# Enable drive temperature PWM floor (auto, true, false)"
check_param "DRIVE_MIN_TEMP" "$DEFAULT_DRIVE_MIN_TEMP" "# Drive temperature where PWM floor begins (°C)"
check_param "DRIVE_MAX_TEMP" "$DEFAULT_DRIVE_MAX_TEMP" "# Drive temperature where PWM floor reaches maximum (°C)"
check_param "DRIVE_CHECK_INTERVAL" "$DEFAULT_DRIVE_CHECK_INTERVAL" "# Drive temperature polling interval (seconds)"
check_param "EXIT_PWM" "$DEFAULT_EXIT_PWM" "# PWM written when the service stops (0 = hand back to firmware; verify on your device first)"

# If missing parameters were found, update the config file atomically
if [ ${#missing_params[@]} -gt 0 ]; then
    logger -t fan-control "CONFIG: Updating configuration file with ${#missing_params[@]} missing parameters"

    # Create a temporary file
    temp_config="${CONFIG_FILE}.tmp"

    # Copy existing config to temp file
    if ! cp "$CONFIG_FILE" "$temp_config" 2>/dev/null; then
        logger -t fan-control "ERROR: Failed to create temporary config file for update"
        # Continue with current in-memory values, but don't update the file
    else
        # A last line without a newline would swallow the first appended key
        if [[ -n "$(tail -c1 "$temp_config" 2>/dev/null)" ]]; then
            echo >>"$temp_config" 2>/dev/null
        fi
        # Add each missing parameter
        update_failed=false
        for i in "${!missing_params[@]}"; do
            if ! echo "${missing_params[$i]}=${missing_values[$i]}        ${missing_comments[$i]}" >>"$temp_config" 2>/dev/null; then
                logger -t fan-control "ERROR: Failed to add parameter ${missing_params[$i]} to config file"
                update_failed=true
                break
            fi
        done

        if [ "$update_failed" = true ]; then
            logger -t fan-control "ERROR: Config file update failed"
            rm -f "$temp_config" 2>/dev/null # Clean up the temporary file
        else
            # Replace the original file with the updated one
            if ! mv "$temp_config" "$CONFIG_FILE" 2>/dev/null; then
                logger -t fan-control "ERROR: Failed to update config file"
                rm -f "$temp_config" 2>/dev/null # Clean up the temporary file
            else
                logger -t fan-control "CONFIG: Configuration file updated successfully"
            fi
        fi
    fi
fi

# Replace the value of a single KEY= line in the config file, keeping every
# other line (including user comments) and the trailing comment of that line.
config_set() {
    local key=$1
    local value=$2
    local temp_config="${CONFIG_FILE}.tmp"

    # Escape the characters that are special in a sed replacement
    value=${value//\\/\\\\}
    value=${value//&/\\&}
    value=${value//@/\\@}

    if sed -E "s@^(${key}=)(\"[^\"]*\"|[^[:space:]]*)@\1${value}@" "$CONFIG_FILE" >"$temp_config" 2>/dev/null &&
        mv "$temp_config" "$CONFIG_FILE" 2>/dev/null; then
        return 0
    fi
    rm -f "$temp_config" 2>/dev/null
    return 1
}

###[ CONFIG MIGRATION ]########################################################
# Migrate configs from older versions of fan-control. Idempotent.
migrate_config() {
    # Migration 1: FAN_PWM_DEVICE pointing to a raw sysfs device path.
    # With auto-detection this is no longer needed; reset to the standard default.
    if [[ "$FAN_PWM_AUTODETECT" != "false" ]] &&
        [[ "$FAN_PWM_DEVICE" != "$DEFAULT_FAN_PWM_DEVICE" ]] &&
        [[ "$FAN_PWM_DEVICE" != "/sys/class/hwmon/hwmon0/pwm1" ]]; then
        logger -t fan-control "MIGRATE: FAN_PWM_DEVICE reset to default (was: $FAN_PWM_DEVICE)"
        FAN_PWM_DEVICE="$DEFAULT_FAN_PWM_DEVICE"
        if config_set "FAN_PWM_DEVICE" "\"$FAN_PWM_DEVICE\""; then
            logger -t fan-control "MIGRATE: Config file updated successfully"
        else
            logger -t fan-control "MIGRATE: Failed to update config file"
        fi
    fi
}

migrate_config

# Validate configuration parameters. Values are normalised to plain decimal
# (so 08 is read as 8, not an invalid octal) and corrected keys are recorded.
CORRECTED_PARAMS=()

validate_config() {
    local param=$1
    local value=$2
    local min=$3
    local max=$4
    local default=$5
    local original=$value
    local stripped

    value=${value//$'\r'/}
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        # Drop leading zeros (08 is decimal 8, not an invalid octal) and refuse
        # values too long to compare safely (64-bit arithmetic would wrap).
        stripped=${value#"${value%%[!0]*}"}
        stripped=${stripped:-0}
        if ((${#stripped} <= 6)); then
            value=$stripped
        else
            value="too-long"
        fi
    fi

    if ! [[ "$value" =~ ^[0-9]+$ ]] || ((value < min || value > max)); then
        logger -t fan-control "CONFIG: Invalid $param value: $original (should be between $min and $max), using default: $default"
        eval "${param}=${default}"
        CORRECTED_PARAMS+=("$param")
        return 1
    fi
    eval "${param}=${value}"
    return 0
}

validate_config "MIN_PWM" "$MIN_PWM" 0 255 "$DEFAULT_MIN_PWM"
validate_config "MAX_PWM" "$MAX_PWM" "${MIN_PWM:-$DEFAULT_MIN_PWM}" 255 "$DEFAULT_MAX_PWM"
validate_config "MIN_TEMP" "$MIN_TEMP" 30 80 "$DEFAULT_MIN_TEMP"
validate_config "MAX_TEMP" "$MAX_TEMP" "$MIN_TEMP" 100 "$DEFAULT_MAX_TEMP"
validate_config "HYSTERESIS" "$HYSTERESIS" 1 15 "$DEFAULT_HYSTERESIS"
validate_config "CHECK_INTERVAL" "$CHECK_INTERVAL" 5 60 "$DEFAULT_CHECK_INTERVAL"
validate_config "TAPER_MINS" "$TAPER_MINS" 1 240 "$DEFAULT_TAPER_MINS"
validate_config "MAX_PWM_STEP" "$MAX_PWM_STEP" 1 50 "$DEFAULT_MAX_PWM_STEP"
validate_config "DEADBAND" "$DEADBAND" 0 10 "$DEFAULT_DEADBAND"
validate_config "ALPHA" "$ALPHA" 1 99 "$DEFAULT_ALPHA"
validate_config "LEARNING_RATE" "$LEARNING_RATE" 1 20 "$DEFAULT_LEARNING_RATE"
validate_config "DRIVE_MIN_TEMP" "$DRIVE_MIN_TEMP" 30 90 "$DEFAULT_DRIVE_MIN_TEMP"
validate_config "DRIVE_MAX_TEMP" "$DRIVE_MAX_TEMP" 40 95 "$DEFAULT_DRIVE_MAX_TEMP"
validate_config "DRIVE_CHECK_INTERVAL" "$DRIVE_CHECK_INTERVAL" 15 600 "$DEFAULT_DRIVE_CHECK_INTERVAL"
validate_config "EXIT_PWM" "$EXIT_PWM" 0 255 "$DEFAULT_EXIT_PWM"
DRIVE_TEMP_ENABLED=${DRIVE_TEMP_ENABLED//$'\r'/}
if [[ "$DRIVE_TEMP_ENABLED" != "auto" && "$DRIVE_TEMP_ENABLED" != "true" && "$DRIVE_TEMP_ENABLED" != "false" ]]; then
    logger -t fan-control "CONFIG: Invalid DRIVE_TEMP_ENABLED value: $DRIVE_TEMP_ENABLED, using default: $DEFAULT_DRIVE_TEMP_ENABLED"
    DRIVE_TEMP_ENABLED=$DEFAULT_DRIVE_TEMP_ENABLED
    CORRECTED_PARAMS+=("DRIVE_TEMP_ENABLED")
fi
if ((DRIVE_MAX_TEMP <= DRIVE_MIN_TEMP)); then
    logger -t fan-control "CONFIG: DRIVE_MAX_TEMP must exceed DRIVE_MIN_TEMP, using defaults"
    DRIVE_MIN_TEMP=$DEFAULT_DRIVE_MIN_TEMP
    DRIVE_MAX_TEMP=$DEFAULT_DRIVE_MAX_TEMP
    CORRECTED_PARAMS+=("DRIVE_MIN_TEMP" "DRIVE_MAX_TEMP")
fi
# The emergency temperature must sit above the fan activation temperature.
if ((MAX_TEMP <= MIN_TEMP + HYSTERESIS)); then
    logger -t fan-control "CONFIG: MAX_TEMP ($MAX_TEMP) must exceed MIN_TEMP+HYSTERESIS ($((MIN_TEMP + HYSTERESIS))), correcting"
    # Reset only MAX_TEMP when the default is enough; otherwise all three
    if ((DEFAULT_MAX_TEMP > MIN_TEMP + HYSTERESIS)); then
        MAX_TEMP=$DEFAULT_MAX_TEMP
        CORRECTED_PARAMS+=("MAX_TEMP")
    else
        MIN_TEMP=$DEFAULT_MIN_TEMP
        MAX_TEMP=$DEFAULT_MAX_TEMP
        HYSTERESIS=$DEFAULT_HYSTERESIS
        CORRECTED_PARAMS+=("MIN_TEMP" "MAX_TEMP" "HYSTERESIS")
    fi
fi

# Write corrected values back, touching only the affected lines.
if [ ${#CORRECTED_PARAMS[@]} -gt 0 ]; then
    logger -t fan-control "CONFIG: Updating configuration file with corrected values"
    for _param in "${CORRECTED_PARAMS[@]}"; do
        if ! config_set "$_param" "${!_param}"; then
            logger -t fan-control "ERROR: Failed to update $_param in config file"
        fi
    done
    unset _param
fi

# Derived values
FAN_ACTIVATION_TEMP=$((MIN_TEMP + HYSTERESIS))
TAPER_DURATION=$((TAPER_MINS * 60))

###[ RUNTIME CHECKS ]##########################################################
# Check for ubnt-systool availability
if ! command -v ubnt-systool >/dev/null 2>&1; then
    logger -t fan-control "FATAL: ubnt-systool command not found"
    exit 1
fi

###[ SHARED STATE, LOCK AND CLEANUP ]##########################################
FAN_PWM_DEVICES=()
KNOWN_PWM_DEVICES=()
declare -A PWM_DEVICE_STATUS=()
PWM_DETECTION_INITIALIZED=false
PWM_RECHECK_LOOPS=10
DRIVE_RESCAN_LOOPS=40
LAST_PWM=-1           # Last PWM value set
FORCE_PWM_WRITE=false # Re-write LAST_PWM even if unchanged (resync after external writes)
RAMP_DOWN_PENDING=false # True while a limited ramp-down has not reached the target yet
FLOOR_HELD=false      # True while a hot drive has raised the speed above the CPU curve
TAPER_LAST_LOGGED_MIN=""

PID_FILE="${FAN_CONTROL_PID_FILE:-/var/run/fan-control.pid}"

# Leave the fans at EXIT_PWM when we stop. EXIT_PWM=0 only makes sense if 0
# hands control back to firmware on your hardware; the default is not 0.
cleanup() {
    [[ -n "${SLEEP_PID:-}" ]] && kill "$SLEEP_PID" 2>/dev/null
    # Controlled channels first, then any channel seen earlier that is currently
    # excluded, so a flapping channel is not left at a high or low value.
    for _d in "${FAN_PWM_DEVICES[@]}" "${KNOWN_PWM_DEVICES[@]}"; do
        { echo "$EXIT_PWM" >"$_d"; } 2>/dev/null
    done
    rm -f "$PID_FILE" 2>/dev/null
}

# Take the single-instance lock BEFORE touching any PWM channel, so a second
# copy can never disturb the fans of the running instance.
# Open the lock FD WITHOUT truncating (>>) so a running instance's PID isn't clobbered
exec 200>>"$PID_FILE"
if ! flock -n 200; then
    logger -t fan-control "ALERT: Another instance already holds the lock (PID $(cat "$PID_FILE" 2>/dev/null))"
    exit 1
fi
echo $$ >"$PID_FILE"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# systemd watchdog keep-alive (no-op when not started by systemd with WatchdogSec)
notify_watchdog() {
    if [[ -n "${NOTIFY_SOCKET:-}" ]] && command -v systemd-notify >/dev/null 2>&1; then
        systemd-notify WATCHDOG=1 2>/dev/null || true
    fi
    return 0
}

###[ PWM DEVICE DETECTION ]####################################################
# Detect writable fan PWM channels and retain their availability state.
# A zero-RPM reading is not proof that a channel has no fan: shutdown leaves
# channels at zero, and excluding one can leave a fan permanently uncontrolled.
detect_pwm_devices() {
    local candidates=()
    local writable=()
    local previous_devices=("${FAN_PWM_DEVICES[@]}")
    local pwm_file
    local known_pwm
    local candidate_known
    local candidate_present
    local is_initial_detection=false
    local devices_changed=false

    if [[ "$PWM_DETECTION_INITIALIZED" == false ]]; then
        is_initial_detection=true
    fi

    # Strategy 1: look for pwm files directly in hwmon class directories
    # Works on: UCG-Max (lm63 driver), UNVR (adt7475, kernel exposes class symlinks)
    for pwm_file in "$HWMON_BASE"/hwmon*/pwm[1-9]; do
        [[ -e "$pwm_file" ]] && candidates+=("$pwm_file")
    done

    # Strategy 2: if no class-level pwm files found, resolve via raw device paths
    # Needed for UDM-SE where adt7475 driver does not expose pwm in the class dir
    if [[ ${#candidates[@]} -eq 0 ]]; then
        logger -t fan-control "DETECT: No pwm in hwmon class dirs, falling back to raw device paths"
        for hwmon_dir in "$HWMON_BASE"/hwmon*; do
            local dev_path
            dev_path=$(readlink -f "$hwmon_dir/device" 2>/dev/null) || continue
            for pwm_file in "$dev_path"/pwm[1-9]; do
                [[ -e "$pwm_file" ]] && candidates+=("$pwm_file")
            done
        done
    fi

    if [[ ${#candidates[@]} -eq 0 && "$is_initial_detection" == true ]]; then
        logger -t fan-control "FATAL: No PWM devices found in /sys"
        exit 1
    fi

    # Keep checking paths seen before: an absent PWM file must be reported as an
    # exclusion instead of silently disappearing from the controlled set.
    for known_pwm in "${KNOWN_PWM_DEVICES[@]}"; do
        candidate_present=false
        for pwm_file in "${candidates[@]}"; do
            if [[ "$known_pwm" == "$pwm_file" ]]; then
                candidate_present=true
                break
            fi
        done
        if [[ "$candidate_present" == false ]]; then
            candidates+=("$known_pwm")
        fi
    done

    # Filter candidates to channels whose writable state can be proven.
    for pwm_file in "${candidates[@]}"; do
        local current_val
        if ! current_val=$(cat "$pwm_file" 2>/dev/null); then
            if [[ "${PWM_DEVICE_STATUS[$pwm_file]:-}" != "excluded" ]]; then
                logger -t fan-control "DETECT: ${pwm_file} unavailable, excluding"
                devices_changed=true
            fi
            PWM_DEVICE_STATUS["$pwm_file"]="excluded"
            continue
        fi

        # Only channels that are new, excluded or suspect get the write test.
        # Channels already under control are NOT rewritten with their read-back
        # value: hardware quantisation (e.g. 100 reads back as 92) would make
        # that a slow downward ratchet.
        if [[ "${PWM_DEVICE_STATUS[$pwm_file]:-}" != "controlled" ]]; then
            # sysfs file permissions are unreliable, so test by writing the current value back
            if ! { echo "$current_val" >"$pwm_file"; } 2>/dev/null; then
                if [[ "${PWM_DEVICE_STATUS[$pwm_file]:-}" != "excluded" ]]; then
                    logger -t fan-control "DETECT: ${pwm_file} unavailable, excluding"
                    devices_changed=true
                fi
                PWM_DEVICE_STATUS["$pwm_file"]="excluded"
                continue
            fi
            # A channel that failed a write but passes the test again still holds
            # a stale value: rewrite the current target on the next tick.
            if [[ "${PWM_DEVICE_STATUS[$pwm_file]:-}" == "suspect" ]]; then
                FORCE_PWM_WRITE=true
            fi
        fi
        writable+=("$pwm_file")

        candidate_known=false
        for known_pwm in "${KNOWN_PWM_DEVICES[@]}"; do
            if [[ "$known_pwm" == "$pwm_file" ]]; then
                candidate_known=true
                break
            fi
        done
        if [[ "$candidate_known" == false ]]; then
            KNOWN_PWM_DEVICES+=("$pwm_file")
        fi
    done

    if [[ "$is_initial_detection" == true ]]; then
        if [[ ${#writable[@]} -eq 0 ]]; then
            logger -t fan-control "FATAL: No writable PWM devices found"
            exit 1
        fi

        # MAX_PWM never slows a fan that was already cooling a hot device. Two
        # seconds clears the measured one-second RPM registration point without
        # waiting for the six-second settling time.
        local probed=()
        for pwm_file in "${writable[@]}"; do
            if { echo "$MAX_PWM" >"$pwm_file"; } 2>/dev/null; then
                probed+=("$pwm_file")
            else
                logger -t fan-control "DETECT: ${pwm_file} unavailable, excluding"
                PWM_DEVICE_STATUS["$pwm_file"]="excluded"
            fi
        done
        writable=("${probed[@]}")
        if [[ ${#writable[@]} -eq 0 ]]; then
            logger -t fan-control "FATAL: No writable PWM devices found"
            exit 1
        fi
        logger -t fan-control "DETECT: Probing writable PWM channels at ${MAX_PWM}pwm for 2s"
        sleep 2
    fi

    FAN_PWM_DEVICES=()
    for pwm_file in "${writable[@]}"; do
        local pwm_dir
        pwm_dir=$(dirname "$pwm_file")
        local pwm_name
        pwm_name=$(basename "$pwm_file")
        local fan_num="${pwm_name#pwm}"
        local fan_input="${pwm_dir}/fan${fan_num}_input"
        local rpm=0

        [[ -f "$fan_input" ]] && rpm=$(cat "$fan_input" 2>/dev/null || echo 0)

        if [[ "${PWM_DEVICE_STATUS[$pwm_file]:-}" == "excluded" ]]; then
            logger -t fan-control "DETECT: ${pwm_file} writable again, including"
            devices_changed=true
            if ((LAST_PWM >= 0)); then
                if ! { echo "$LAST_PWM" >"$pwm_file"; } 2>/dev/null; then
                    logger -t fan-control "ERROR: Failed to restore PWM device $pwm_file after detection"
                    PWM_DEVICE_STATUS["$pwm_file"]="excluded"
                    continue
                fi
            fi
        fi
        PWM_DEVICE_STATUS["$pwm_file"]="controlled"
        FAN_PWM_DEVICES+=("$pwm_file")

        if [[ "$is_initial_detection" == true ]]; then
            if ((rpm > 0)); then
                logger -t fan-control "DETECT: ${pwm_file} -> fan${fan_num} = ${rpm} RPM (active)"
            else
                logger -t fan-control "DETECT: ${pwm_file} -> fan${fan_num} = 0 RPM (unknown, controlled)"
            fi
            # Report the hwmon enable mode: anything other than 1 (manual) may mean
            # the driver or firmware overrides what we write.
            if [[ -r "${pwm_file}_enable" ]]; then
                local enable_mode
                enable_mode=$(cat "${pwm_file}_enable" 2>/dev/null)
                if [[ "$enable_mode" == "1" ]]; then
                    logger -t fan-control "DETECT: ${pwm_file}_enable=1 (manual)"
                else
                    logger -t fan-control "WARNING: ${pwm_file}_enable=${enable_mode:-unknown} (not manual); writes may be overridden by the driver or firmware"
                fi
            fi
        fi
    done

    if [[ ${#FAN_PWM_DEVICES[@]} -eq 0 ]]; then
        if [[ "$is_initial_detection" == true ]]; then
            logger -t fan-control "FATAL: No writable PWM devices found"
            exit 1
        fi
        logger -t fan-control "ERROR: No writable PWM devices found during periodic detection"
    fi

    if [[ ${#previous_devices[@]} -ne ${#FAN_PWM_DEVICES[@]} ]]; then
        devices_changed=true
    else
        for pwm_file in "${!FAN_PWM_DEVICES[@]}"; do
            if [[ "${FAN_PWM_DEVICES[$pwm_file]}" != "${previous_devices[$pwm_file]}" ]]; then
                devices_changed=true
                break
            fi
        done
    fi

    if [[ "$is_initial_detection" == true || "$devices_changed" == true ]]; then
        logger -t fan-control "DETECT: Controlling ${#FAN_PWM_DEVICES[@]} fan(s): ${FAN_PWM_DEVICES[*]}"
    fi
    # A channel that just appeared or came back holds whatever value the hardware
    # had; write the current target to every channel on the next tick.
    if [[ "$is_initial_detection" == false && "$devices_changed" == true ]]; then
        FORCE_PWM_WRITE=true
    fi
    PWM_DETECTION_INITIALIZED=true
}

# Determine PWM devices to control
if [[ "$FAN_PWM_AUTODETECT" != "false" ]]; then
    detect_pwm_devices
else
    # Manual override: validate the configured single device
    logger -t fan-control "DETECT: Auto-detect disabled, using configured device: $FAN_PWM_DEVICE"
    _current_val=$(cat "$FAN_PWM_DEVICE" 2>/dev/null) || {
        logger -t fan-control "FATAL: PWM device $FAN_PWM_DEVICE not readable"
        exit 1
    }
    if ! echo "$_current_val" >"$FAN_PWM_DEVICE" 2>/dev/null; then
        logger -t fan-control "FATAL: PWM device $FAN_PWM_DEVICE not writable"
        exit 1
    fi
    unset _current_val
    FAN_PWM_DEVICES=("$FAN_PWM_DEVICE")
fi

# Ensure directories for state files exist
mkdir -p "$(dirname "$TEMP_STATE_FILE")" "$(dirname "$OPTIMAL_PWM_FILE")" || {
    logger -t fan-control "FATAL: Failed to create required directories"
    exit 1
}

notify_watchdog

###[ CORE FUNCTIONALITY ]######################################################
# State definitions
STATE_OFF=0       # Fan completely off
STATE_TAPER=1     # Cooling down period before turning off
STATE_ACTIVE=2    # Normal operation with temperature-based fan speed
STATE_EMERGENCY=3 # Critical temperature, maximum fan speed

# Runtime variables
CURRENT_STATE=$STATE_OFF
TAPER_START=0 # Timestamp when taper mode started
TAPER_HOLD_LOGGED=false
SMOOTHED_TEMP=50     # Current smoothed temperature (integer, used for decisions)
SMOOTHED_TEMP_F=50   # Smoothed temperature with fractional precision
PREV_LOOP_TEMP=50    # Smoothed temperature at the previous loop tick
LAST_ADJUSTMENT=0    # Timestamp of last PWM optimization
LAST_AVG_TEMP=0      # Temperature at the last PWM change (for deadband calculations)
TEMP_READ_FAILURES=0 # Track consecutive temperature reading failures
DRIVE_TEMP_AVAILABLE=false
DRIVE_DEVICES=()
DRIVE_METHODS=()
DRIVE_READ_FAILURE_LOGGED=()
DRIVE_LAST_TEMP=()  # last good temperature per drive
DRIVE_FAIL_COUNT=() # consecutive failed polls per drive
DRIVE_FAIL_HOLD_POLLS=3
DRIVE_TEMP=0
DRIVE_WARNING_TEMP="unknown"
DRIVE_PWM_FLOOR=0
DRIVE_FLOOR_DEVICE=""
DRIVE_LAST_FLOOR_DEVICE=""
DRIVE_LAST_FLOOR_TEMP=0
DRIVE_LAST_FLOOR_PWM=0
DRIVE_LAST_CHECK=0
DRIVE_ALL_READ_FAILURE_LOGGED=false
LOG_TEMP_CHANGE_THRESHOLD=2
LAST_LOGGED_RAW_TEMP=""
LAST_LOGGED_SMOOTHED_TEMP=""
LAST_LOGGED_RAW_SMOOTH_DELTA=""
LAST_LOGGED_CALC_TEMP=""
LAST_LOGGED_DEADBAND_TEMP=""

# Function to safely write to a file using atomic operations
atomic_write_file() {
    local target_file="$1"
    local content="$2"
    local temp_file="${target_file}.tmp"

    if ! echo "$content" >"$temp_file" 2>/dev/null; then
        logger -t fan-control "ERROR: Failed to write to temporary file for $target_file"
        return 1
    elif ! mv "$temp_file" "$target_file" 2>/dev/null; then
        logger -t fan-control "ERROR: Failed to update file $target_file"
        rm -f "$temp_file" 2>/dev/null # Clean up the temporary file
        return 1
    fi
    return 0
}

# Print the CPU temperature as an integer, or fail.
read_cpu_temp() {
    local output
    output=$(run_timeout ubnt-systool cputemp 2>/dev/null || true)
    [[ "$output" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    printf '%s\n' "$output" | awk '{print int($1)}'
}

# Initialize smoothed temp from state file or raw temp.
# If the sensor cannot be read at startup, assume the activation temperature so
# the fans come on instead of starting from a bogus empty/zero reading.
INIT_READ_FAILED=false
if ! raw_temp=$(read_cpu_temp); then
    raw_temp=$FAN_ACTIVATION_TEMP
    INIT_READ_FAILED=true
    logger -t fan-control "WARNING: Initial temperature read failed, assuming ${raw_temp}°C"
fi
if [[ "$INIT_READ_FAILED" == true ]]; then
    # A saved temperature would be compared with a made-up raw value; ignore it.
    SMOOTHED_TEMP=$raw_temp
elif [[ -f "$TEMP_STATE_FILE" ]]; then
    saved_temp=$(cat "$TEMP_STATE_FILE" 2>/dev/null)
    # Validate saved temperature is a number and within reasonable range
    if [[ "$saved_temp" =~ ^[0-9]+$ ]] && ((saved_temp >= 20 && saved_temp <= 100)); then
        # Don't use saved temp if it's too far from current raw temp (prevents large jumps)
        init_delta=$((saved_temp - raw_temp))
        ((init_delta < 0)) && init_delta=$((-init_delta))
        if ((init_delta < 15)); then
            SMOOTHED_TEMP=$saved_temp
            logger -t fan-control "INIT: Loaded saved temp=${SMOOTHED_TEMP}°C | Raw=${raw_temp}°C"
        else
            SMOOTHED_TEMP=$raw_temp
            logger -t fan-control "INIT: Discarded saved temp=${saved_temp}°C (too far from raw=${raw_temp}°C)"
        fi
    else
        SMOOTHED_TEMP=$raw_temp
        logger -t fan-control "INIT: Invalid saved temp=${saved_temp}°C, using raw=${raw_temp}°C"
    fi
else
    SMOOTHED_TEMP=$raw_temp
    logger -t fan-control "INIT: No saved temp, using raw=${raw_temp}°C"
fi
SMOOTHED_TEMP_F=$SMOOTHED_TEMP
PREV_LOOP_TEMP=$SMOOTHED_TEMP

# MUST be called directly, never via $(...) because state must persist in the parent shell.
has_meaningful_temp_change() {
    local current_temp=$1
    local last_logged_temp=$2

    if [[ -z "$last_logged_temp" ]]; then
        return 0
    fi

    local temp_delta=$((current_temp - last_logged_temp))
    if ((temp_delta < 0)); then
        temp_delta=$((-temp_delta))
    fi

    if ((temp_delta >= LOG_TEMP_CHANGE_THRESHOLD)); then
        return 0
    fi
    return 1
}

get_smoothed_temp() {
    local raw_temp

    if raw_temp=$(read_cpu_temp); then
        # Reset failure counter on successful read
        TEMP_READ_FAILURES=0
    else
        TEMP_READ_FAILURES=$((TEMP_READ_FAILURES + 1))
        logger -t fan-control "ERROR: Failed to read temperature (attempt $TEMP_READ_FAILURES)"
        # Use last known temperature; the fail-safe decision is in update_fan_state
        raw_temp=$SMOOTHED_TEMP
    fi

    local previous=$SMOOTHED_TEMP

    # Exponential smoothing: smoothed = (alpha * previous + (100 - alpha) * raw) / 100
    # The fractional value is kept between ticks; only the decision value is rounded.
    # Rounding the stored value would leave a dead zone of about +-50/(100-alpha) degrees.
    SMOOTHED_TEMP_F=$(awk -v a="$ALPHA" -v s="$SMOOTHED_TEMP_F" -v r="$raw_temp" 'BEGIN { printf "%.3f", (a * s + (100 - a) * r) / 100 }')
    SMOOTHED_TEMP=$(awk -v s="$SMOOTHED_TEMP_F" 'BEGIN { printf "%.0f", s }')

    # Safety check: If raw and smoothed temps differ by more than 20°C, reset smoothed temp
    local temp_diff=$((raw_temp - SMOOTHED_TEMP))
    if ((${temp_diff#-} > 20)); then
        logger -t fan-control "ALERT: Large temp difference detected (${temp_diff}°C) - resetting smoothed temp"
        SMOOTHED_TEMP=$raw_temp
        SMOOTHED_TEMP_F=$raw_temp
    fi

    # Save smoothed temp to state file (only if it changed)
    if ((SMOOTHED_TEMP != previous)); then
        atomic_write_file "$TEMP_STATE_FILE" "$SMOOTHED_TEMP"
    fi

    local raw_smooth_delta=$((raw_temp - SMOOTHED_TEMP))
    if ((raw_smooth_delta < 0)); then
        raw_smooth_delta=$((-raw_smooth_delta))
    fi

    local smoothing_progress=false
    # A large raw jump can settle by one final degree; keep that convergence
    # visible without treating a one-degree raw flutter as new information.
    if [[ "$raw_temp" == "$LAST_LOGGED_RAW_TEMP" && -n "$LAST_LOGGED_RAW_SMOOTH_DELTA" ]] &&
        ((raw_smooth_delta < LAST_LOGGED_RAW_SMOOTH_DELTA)); then
        smoothing_progress=true
    fi

    local temp_log="TEMP:  RAW=${raw_temp}°C | SMOOTH=${SMOOTHED_TEMP}°C | DELTA=$((raw_temp - SMOOTHED_TEMP))°C"
    if has_meaningful_temp_change "$raw_temp" "$LAST_LOGGED_RAW_TEMP" ||
        has_meaningful_temp_change "$SMOOTHED_TEMP" "$LAST_LOGGED_SMOOTHED_TEMP" ||
        [[ "$smoothing_progress" == true ]]; then
        logger -t fan-control "$temp_log"
        LAST_LOGGED_RAW_TEMP=$raw_temp
        LAST_LOGGED_SMOOTHED_TEMP=$SMOOTHED_TEMP
        LAST_LOGGED_RAW_SMOOTH_DELTA=$raw_smooth_delta
    fi
}

calculate_speed() {
    local avg_temp=$1
    local temp_range=$((MAX_TEMP - FAN_ACTIVATION_TEMP))
    local temp_diff=$((avg_temp - FAN_ACTIVATION_TEMP))

    # Clamp to zero below the activation temperature: temp_diff is squared below,
    # which discards the sign, so a negative diff would otherwise re-inflate PWM
    # symmetrically with heating, making the fan speed up as the device cools (#26).
    if ((temp_diff < 0)); then
        temp_diff=0
    fi

    # Prevent division by zero
    ((temp_range > 0)) || temp_range=1

    # Quadratic response curve calculation:
    # PWM = MIN_PWM + (temp_diff²/temp_range²) * (MAX_PWM - MIN_PWM)
    # The formula is multiplied by 20 and divided by 10 to improve integer math precision
    local speed=$(((temp_diff * temp_diff * (MAX_PWM - MIN_PWM) * 20) / (temp_range * temp_range * 10)))
    speed=$((speed + MIN_PWM))

    # Ensure speed doesn't exceed MAX_PWM
    speed=$((speed > MAX_PWM ? MAX_PWM : speed))

    echo "$speed"
}

log_calculation() {
    local avg_temp=$1
    local speed=$2
    local temp_range=$((MAX_TEMP - FAN_ACTIVATION_TEMP))
    local temp_diff=$((avg_temp - FAN_ACTIVATION_TEMP))

    if ((temp_diff < 0)); then
        temp_diff=0
    fi
    if ((temp_range <= 0)); then
        temp_range=1
    fi

    local calc_log="CALC: temp_diff=${temp_diff}°C | range=${temp_range}°C | speed=${speed}pwm"
    if has_meaningful_temp_change "$avg_temp" "$LAST_LOGGED_CALC_TEMP"; then
        logger -t fan-control "$calc_log"
        LAST_LOGGED_CALC_TEMP=$avg_temp
    fi
}

json_number() {
    local json="$1"
    local field="$2"

    printf '%s\n' "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" | sed -n '1p'
}

json_object_number() {
    local json="$1"
    local object="$2"
    local field="$3"

    printf '%s\n' "$json" | sed -n "/\"${object}\"[[:space:]]*:[[:space:]]*{/,/}/ { s/.*\"${field}\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p; }" | sed -n '1p'
}

read_nvme_temperature() {
    local device="$1"
    local smart_log
    local raw_temp
    local controller
    local warning_temp

    smart_log=$(run_timeout nvme smart-log -o json "$device" 2>/dev/null) || return 1
    raw_temp=$(json_number "$smart_log" "temperature")
    [[ "$raw_temp" =~ ^[0-9]+$ ]] || return 1

    # nvme-cli reports SMART temperatures in Kelvin; smartctl uses Celsius.
    DRIVE_READ_TEMP=$((raw_temp - 273))
    ((DRIVE_READ_TEMP >= 0 && DRIVE_READ_TEMP <= 120)) || return 1

    controller=$(run_timeout nvme id-ctrl -o json "$device" 2>/dev/null || true)
    warning_temp=$(json_number "$controller" "wctemp")
    if [[ "$warning_temp" =~ ^[0-9]+$ ]]; then
        if ((warning_temp >= 273)); then
            warning_temp=$((warning_temp - 273))
        fi
        DRIVE_WARNING_TEMP=$warning_temp
    else
        DRIVE_WARNING_TEMP="unknown"
    fi
}

read_smartctl_temperature() {
    local device="$1"
    local smart_log
    local smart_rc
    local raw_temp
    local warning_temp

    # -n standby: never wake a sleeping disk just to read its temperature.
    # smartctl's exit status is a bit mask. Bits 0 and 1 (command line error,
    # device open failed or standby) mean there is no usable data. The higher
    # bits only describe the disk's SMART history and must not discard a valid
    # temperature, which would disable the floor for exactly the disks that are
    # in trouble.
    smart_log=$(run_timeout smartctl -n standby -j -a "$device" 2>/dev/null)
    smart_rc=$?
    if ((smart_rc & 3)); then
        return 1
    fi
    raw_temp=$(json_number "$smart_log" "current")
    [[ "$raw_temp" =~ ^[0-9]+$ ]] || return 1
    ((raw_temp >= 0 && raw_temp <= 120)) || return 1

    DRIVE_READ_TEMP=$raw_temp
    warning_temp=$(json_object_number "$smart_log" "nvme_composite_temperature_threshold" "warning")
    if [[ "$warning_temp" =~ ^[0-9]+$ ]]; then
        DRIVE_WARNING_TEMP=$warning_temp
    else
        DRIVE_WARNING_TEMP="unknown"
    fi
}

calculate_drive_pwm_floor() {
    local drive_range=$((DRIVE_MAX_TEMP - DRIVE_MIN_TEMP))

    if ((DRIVE_TEMP <= DRIVE_MIN_TEMP)); then
        DRIVE_PWM_FLOOR=0
    elif ((DRIVE_TEMP >= DRIVE_MAX_TEMP)); then
        DRIVE_PWM_FLOOR=$MAX_PWM
    else
        DRIVE_PWM_FLOOR=$((MIN_PWM + ((DRIVE_TEMP - DRIVE_MIN_TEMP) * (MAX_PWM - MIN_PWM) / drive_range)))
    fi
}

# Enumerate drives. Mode "initial" also computes the first floor; mode
# "rescan" only registers devices that appeared after startup (hot-plug) and
# leaves the floor to the next regular poll.
detect_drive_temperature() {
    local mode="${1:-initial}"
    local device
    local device_found=false
    local known_device
    local warning_temp_display
    local method
    local hottest_index=-1
    local index
    local known_index
    local drive_read_ok

    [[ "$DRIVE_TEMP_ENABLED" != "false" ]] || return 0

    for device in "$DRIVE_DEV_DIR"/nvme?n? "$DRIVE_DEV_DIR"/sd?; do
        [[ -e "$device" ]] || continue

        known_device=false
        for known_index in "${!DRIVE_DEVICES[@]}"; do
            if [[ "${DRIVE_DEVICES[$known_index]}" == "$device" ]]; then
                known_device=true
                break
            fi
        done
        [[ "$known_device" == true ]] && continue

        device_found=true
        method="smartctl"
        drive_read_ok=false

        if [[ "$device" == "$DRIVE_DEV_DIR"/nvme?n? ]]; then
            method="nvme"
            if read_nvme_temperature "$device"; then
                drive_read_ok=true
            elif read_smartctl_temperature "$device"; then
                method="smartctl"
                drive_read_ok=true
            fi
        elif read_smartctl_temperature "$device"; then
            drive_read_ok=true
        fi

        DRIVE_DEVICES+=("$device")
        DRIVE_METHODS+=("$method")
        DRIVE_READ_FAILURE_LOGGED+=(false)
        DRIVE_LAST_TEMP+=("")
        DRIVE_FAIL_COUNT+=(0)
        index=$((${#DRIVE_DEVICES[@]} - 1))
        if [[ "$drive_read_ok" = true ]]; then
            DRIVE_LAST_TEMP[index]=$DRIVE_READ_TEMP
            warning_temp_display="not reported"
            if [[ "$DRIVE_WARNING_TEMP" =~ ^[0-9]+$ ]]; then
                warning_temp_display="${DRIVE_WARNING_TEMP}°C"
            fi
            logger -t fan-control "DRIVE: Detected ${device} via ${method} | Temp=${DRIVE_READ_TEMP}°C | wctemp=${warning_temp_display}"

            # Only the initial scan picks a floor drive; a rescan must not disturb
            # DRIVE_TEMP (the forced poll that follows recomputes it).
            if [[ "$mode" == "initial" ]] && ((hottest_index < 0 || DRIVE_READ_TEMP > DRIVE_TEMP)); then
                hottest_index=$index
                DRIVE_TEMP=$DRIVE_READ_TEMP
            fi
        else
            logger -t fan-control "DRIVE: ${device} read failed or device in standby; excluding it from floor"
            DRIVE_READ_FAILURE_LOGGED[index]=true
        fi
        notify_watchdog
    done

    if [[ "$device_found" = true ]]; then
        DRIVE_TEMP_AVAILABLE=true
        if [[ "$mode" == "initial" ]]; then
            DRIVE_LAST_CHECK=$(date +%s)
        else
            DRIVE_LAST_CHECK=0 # force a poll on the next loop
        fi
    fi

    if [[ "$mode" == "initial" ]] && ((hottest_index >= 0)); then
        DRIVE_FLOOR_DEVICE="${DRIVE_DEVICES[$hottest_index]}"
        calculate_drive_pwm_floor
        DRIVE_LAST_FLOOR_DEVICE=$DRIVE_FLOOR_DEVICE
        DRIVE_LAST_FLOOR_TEMP=$DRIVE_TEMP
        DRIVE_LAST_FLOOR_PWM=$DRIVE_PWM_FLOOR
        logger -t fan-control "DRIVE: ${DRIVE_FLOOR_DEVICE} drives floor | Temp=${DRIVE_TEMP}°C | Floor=${DRIVE_PWM_FLOOR}pwm"
    fi
}

update_drive_temperature() {
    local now
    local index
    local drive_read_ok=false
    local hottest_index=-1

    [[ "$DRIVE_TEMP_AVAILABLE" = true ]] || return 0
    now=$(date +%s)
    if ((now - DRIVE_LAST_CHECK < DRIVE_CHECK_INTERVAL)); then
        return 0
    fi
    DRIVE_LAST_CHECK=$now

    for index in "${!DRIVE_DEVICES[@]}"; do
        drive_read_ok=false
        if [[ "${DRIVE_METHODS[$index]}" = "nvme" ]]; then
            if read_nvme_temperature "${DRIVE_DEVICES[$index]}"; then
                drive_read_ok=true
            fi
        fi

        if [[ "${DRIVE_METHODS[$index]}" = "smartctl" ]]; then
            if read_smartctl_temperature "${DRIVE_DEVICES[$index]}"; then
                drive_read_ok=true
            fi
        fi

        if [[ "$drive_read_ok" = true ]]; then
            if [[ "${DRIVE_READ_FAILURE_LOGGED[$index]}" = true ]]; then
                logger -t fan-control "DRIVE: ${DRIVE_DEVICES[$index]} read recovered"
            fi
            DRIVE_READ_FAILURE_LOGGED[index]=false
            DRIVE_FAIL_COUNT[index]=0
            DRIVE_LAST_TEMP[index]=$DRIVE_READ_TEMP

            if ((hottest_index < 0 || DRIVE_READ_TEMP > DRIVE_TEMP)); then
                hottest_index=$index
                DRIVE_TEMP=$DRIVE_READ_TEMP
            fi
        else
            DRIVE_FAIL_COUNT[index]=$((${DRIVE_FAIL_COUNT[$index]:-0} + 1))
            if [[ "${DRIVE_READ_FAILURE_LOGGED[$index]}" = false ]]; then
                logger -t fan-control "DRIVE: ${DRIVE_DEVICES[$index]} read failed or device in standby; excluding it from floor after ${DRIVE_FAIL_HOLD_POLLS} failed polls"
                DRIVE_READ_FAILURE_LOGGED[index]=true
            fi
            # Hold this drive's last good temperature through a few failed polls so a
            # single transient error cannot drop the floor of a hot drive.
            if ((DRIVE_FAIL_COUNT[index] < DRIVE_FAIL_HOLD_POLLS)) && [[ "${DRIVE_LAST_TEMP[$index]:-}" =~ ^[0-9]+$ ]]; then
                if ((hottest_index < 0 || DRIVE_LAST_TEMP[index] > DRIVE_TEMP)); then
                    hottest_index=$index
                    DRIVE_TEMP=${DRIVE_LAST_TEMP[$index]}
                fi
            fi
        fi
        notify_watchdog
    done

    if ((hottest_index >= 0)); then
        DRIVE_FLOOR_DEVICE="${DRIVE_DEVICES[$hottest_index]}"
        calculate_drive_pwm_floor
        DRIVE_ALL_READ_FAILURE_LOGGED=false
        if [[ "$DRIVE_FLOOR_DEVICE" != "$DRIVE_LAST_FLOOR_DEVICE" || "$DRIVE_TEMP" -ne "$DRIVE_LAST_FLOOR_TEMP" || "$DRIVE_PWM_FLOOR" -ne "$DRIVE_LAST_FLOOR_PWM" ]]; then
            logger -t fan-control "DRIVE: ${DRIVE_FLOOR_DEVICE} drives floor | Temp=${DRIVE_TEMP}°C | Floor=${DRIVE_PWM_FLOOR}pwm"
            DRIVE_LAST_FLOOR_DEVICE=$DRIVE_FLOOR_DEVICE
            DRIVE_LAST_FLOOR_TEMP=$DRIVE_TEMP
            DRIVE_LAST_FLOOR_PWM=$DRIVE_PWM_FLOOR
        fi
    else
        # No drive has a usable reading, even after the per-drive hold: fail open.
        DRIVE_PWM_FLOOR=0
        DRIVE_FLOOR_DEVICE=""
        if [[ "$DRIVE_ALL_READ_FAILURE_LOGGED" = false ]]; then
            logger -t fan-control "DRIVE: All cached drives unreadable; floor disabled"
            DRIVE_ALL_READ_FAILURE_LOGGED=true
        fi
    fi
}

# Speed control with logging
set_fan_speed() {
    local new_speed=$1
    local current_temp=$SMOOTHED_TEMP
    local reason="Normal operation"
    local emergency=false

    if ((current_temp >= MAX_TEMP || CURRENT_STATE == STATE_EMERGENCY)); then
        emergency=true
        new_speed=$MAX_PWM
        reason="EMERGENCY: Temp ${current_temp}°C (limit ${MAX_TEMP}°C)"
    fi

    RAMP_DOWN_PENDING=false
    if [[ "$emergency" == true ]]; then
        : # Emergency: full speed immediately, no ramp limiting
    elif ((CURRENT_STATE == STATE_OFF)); then
        new_speed=0 # Force 0 PWM regardless of other logic
        reason="OFF state override"
    else
        # Apply ramp limits only in non-OFF, non-emergency states
        if ((new_speed > LAST_PWM + MAX_PWM_STEP)); then
            reason="Ramp-up limited: ${LAST_PWM}→$((LAST_PWM + MAX_PWM_STEP))pwm"
            new_speed=$((LAST_PWM + MAX_PWM_STEP))
        elif ((new_speed < LAST_PWM - MAX_PWM_STEP)); then
            reason="Ramp-down limited: ${LAST_PWM}→$((LAST_PWM - MAX_PWM_STEP))pwm"
            new_speed=$((LAST_PWM - MAX_PWM_STEP))
            RAMP_DOWN_PENDING=true # keep stepping down even inside the deadband
        fi

        # Enforce MIN/MAX only in active states
        new_speed=$((new_speed > MAX_PWM ? MAX_PWM : new_speed))
        if ((new_speed < MIN_PWM)); then
            new_speed=$MIN_PWM
            reason="Minimum speed ${MIN_PWM}pwm"
        fi
    fi

    # The floor follows the OFF override so a hot drive can still start a cool CPU's fan.
    if ((DRIVE_PWM_FLOOR > new_speed)); then
        # Ramp from at least MIN_PWM: starting from 0 or -1 would pass through
        # speeds (24, 49, 74) too low for a fan to turn reliably.
        local floor_base=$LAST_PWM
        if ((floor_base < MIN_PWM)); then
            floor_base=$MIN_PWM
        fi
        if ((DRIVE_PWM_FLOOR > floor_base + MAX_PWM_STEP)); then
            new_speed=$((floor_base + MAX_PWM_STEP))
            reason="Drive floor ramp-up: ${LAST_PWM}→${new_speed}pwm"
        else
            new_speed=$DRIVE_PWM_FLOOR
            reason="Drive temperature floor: ${DRIVE_TEMP}°C"
        fi
        FLOOR_HELD=true # the drive, not the CPU curve, is holding the speed up
    fi

    local changed=false
    if [[ "$new_speed" -ne "$LAST_PWM" ]]; then
        changed=true
    fi

    if [[ "$changed" == true || "$FORCE_PWM_WRITE" == true ]]; then
        FORCE_PWM_WRITE=false
        # Note: Due to hardware limitations, the actual PWM value applied may differ from the requested value
        # (e.g., setting 50 might result in ~48, or 100 might result in ~92)
        # The write counts as done when at least one channel took it, so one dead
        # channel cannot freeze LAST_PWM (and the ramp) for the healthy ones. The
        # failed channel is marked suspect and re-tested by the next detection.
        local write_ok=false
        for pwm_dev in "${FAN_PWM_DEVICES[@]}"; do
            if { echo "$new_speed" >"$pwm_dev"; } 2>/dev/null; then
                write_ok=true
            else
                logger -t fan-control "ERROR: Failed to write to PWM device $pwm_dev"
                if [[ ! -e "$pwm_dev" ]]; then
                    logger -t fan-control "FATAL: PWM device $pwm_dev no longer exists"
                fi
                PWM_DEVICE_STATUS["$pwm_dev"]="suspect"
            fi
        done
        if [[ "$write_ok" = true ]]; then
            if [[ "$changed" == true ]]; then
                logger -t fan-control "SET: ${LAST_PWM}→${new_speed}pwm | Reason: ${reason}"
                LAST_AVG_TEMP=$current_temp # Reset deadband tracking on change
            fi
            LAST_PWM=$new_speed
        fi
    fi

    if [[ "$changed" == true ]] && ((CURRENT_STATE == STATE_ACTIVE)); then
        local now
        now=$(date +%s)
        # Check if it's time to adjust the optimal PWM value (every 30 minutes)
        if ((now - LAST_ADJUSTMENT > 1800)); then
            local optimal
            optimal=$(cat "$OPTIMAL_PWM_FILE" 2>/dev/null || echo "$OPTIMAL_PWM")
            # Validate optimal PWM value
            if ! [[ "$optimal" =~ ^[0-9]+$ ]] || ((optimal < MIN_PWM || optimal > MAX_PWM)); then
                logger -t fan-control "WARNING: Invalid optimal PWM value: ${optimal}, using MIN_PWM"
                optimal=$MIN_PWM
            fi
            local original_optimal=$optimal
            local adjustment=""
            local adaptive_rate=$LEARNING_RATE

            # Temperature change since the previous loop tick. (Upstream compared
            # against LAST_AVG_TEMP after resetting it to the current value, so
            # the delta was always 0 and the rising-temperature rules never ran.)
            local temp_delta=$((current_temp - PREV_LOOP_TEMP))
            local temp_stability=${temp_delta#-} # Use absolute value of temp_delta

            # Adjust learning rate based on temperature stability
            if ((temp_stability < DEADBAND)); then
                adaptive_rate=$((LEARNING_RATE + 2))
            elif ((temp_stability > DEADBAND * 3)); then
                adaptive_rate=$((LEARNING_RATE - 1))
                adaptive_rate=$((adaptive_rate < 1 ? 1 : adaptive_rate))
            fi

            # 1. At optimal speed but temp rising: increase PWM
            # 2. At optimal speed but temp stable below MIN_TEMP: decrease PWM
            # 3. Above optimal speed, temp stable and not too high: try to decrease
            # 4. Below optimal speed but temp rising quickly: increase
            if ((new_speed == optimal)); then
                if ((temp_delta > 0 && current_temp > MIN_TEMP)); then
                    local rise_factor=$((temp_delta > 2 ? 2 : 1))
                    local adj_amount=$((adaptive_rate * rise_factor))
                    adjustment="+${adj_amount} (rising temp ${temp_delta}°C)"
                    optimal=$((optimal + adj_amount))
                elif ((current_temp < MIN_TEMP && temp_stability < DEADBAND * 2)); then
                    adjustment="-${adaptive_rate} (stable below threshold)"
                    optimal=$((optimal - adaptive_rate))
                fi
            elif ((new_speed > optimal && temp_stability < DEADBAND && current_temp < MIN_TEMP + HYSTERESIS)); then
                adjustment="-1 (efficiency optimization)"
                optimal=$((optimal - 1))
            elif ((new_speed < optimal && temp_delta > DEADBAND * 2)); then
                adjustment="+${adaptive_rate} (rapid temp increase ${temp_delta}°C)"
                optimal=$((optimal + adaptive_rate))
            fi

            if [[ -n "$adjustment" ]]; then
                # Ensure optimal PWM stays within valid range
                optimal=$((optimal > MAX_PWM ? MAX_PWM : optimal))
                optimal=$((optimal < MIN_PWM ? MIN_PWM : optimal))

                if atomic_write_file "$OPTIMAL_PWM_FILE" "$optimal"; then
                    LAST_ADJUSTMENT=$now
                    OPTIMAL_PWM=$optimal # take effect without a restart
                    logger -t fan-control "LEARNING: ${original_optimal}→${optimal}pwm (${adjustment}) [Rate=${adaptive_rate}]"
                fi
            fi
        fi
    fi
}

###[ STATE MANAGEMENT ]########################################################
update_fan_state() {
    get_smoothed_temp
    update_drive_temperature
    local avg_temp=$SMOOTHED_TEMP
    local now
    now=$(date +%s)
    local state_transition=""

    # Sensor fail-safe: write MAX_PWM directly, bypassing state machine and ramp
    # limits (the OFF-state override in set_fan_speed would force 0).
    if ((TEMP_READ_FAILURES >= 3)); then
        if ((LAST_PWM != MAX_PWM)); then
            logger -t fan-control "ALERT: Sensor fail-safe active (${TEMP_READ_FAILURES} consecutive read failures) - forcing MAX_PWM"
        fi
        for pwm_dev in "${FAN_PWM_DEVICES[@]}"; do
            { echo "$MAX_PWM" >"$pwm_dev"; } 2>/dev/null
        done
        LAST_PWM=$MAX_PWM
        CURRENT_STATE=$STATE_ACTIVE # so recovery re-evaluates from a sane state
        PREV_LOOP_TEMP=$SMOOTHED_TEMP
        return
    fi

    # Check for emergency condition first
    if ((avg_temp >= MAX_TEMP)); then
        if ((CURRENT_STATE != STATE_EMERGENCY)); then
            state_transition="→EMERGENCY (${avg_temp}°C ≥ ${MAX_TEMP}°C)"
            CURRENT_STATE=$STATE_EMERGENCY
        fi
        set_fan_speed "$MAX_PWM"
    else
        # Normal state machine when not in emergency
        case $CURRENT_STATE in
            "$STATE_EMERGENCY")
                # Exit emergency mode only when temperature drops significantly below MAX_TEMP
                if ((avg_temp <= MAX_TEMP - HYSTERESIS)); then
                    state_transition="EMERGENCY→ACTIVE (${avg_temp}°C ≤ $((MAX_TEMP - HYSTERESIS))°C)"
                    CURRENT_STATE=$STATE_ACTIVE
                    local calculated_speed
                    calculated_speed=$(calculate_speed "$avg_temp")
                    log_calculation "$avg_temp" "$calculated_speed"
                    set_fan_speed "$calculated_speed"
                else
                    # Stay in emergency mode
                    set_fan_speed "$MAX_PWM"
                fi
                ;;

            "$STATE_OFF")
                if ((avg_temp >= FAN_ACTIVATION_TEMP)); then
                    state_transition="OFF→ACTIVE (${avg_temp}°C ≥ ${FAN_ACTIVATION_TEMP}°C)"
                    CURRENT_STATE=$STATE_ACTIVE
                    set_fan_speed "$OPTIMAL_PWM"
                else
                    set_fan_speed 0
                fi
                ;;

            "$STATE_TAPER")
                if ((avg_temp >= FAN_ACTIVATION_TEMP + 2)); then # Added 2°C buffer to prevent oscillation
                    state_transition="TAPER→ACTIVE (${avg_temp}°C ≥ $((FAN_ACTIVATION_TEMP + 2))°C)"
                    CURRENT_STATE=$STATE_ACTIVE
                    set_fan_speed "$OPTIMAL_PWM"
                elif ((now - TAPER_START >= TAPER_DURATION)); then
                    if ((avg_temp < FAN_ACTIVATION_TEMP)); then
                        state_transition="TAPER→OFF (${TAPER_MINS}min elapsed)"
                        CURRENT_STATE=$STATE_OFF
                        set_fan_speed 0
                    else
                        # Timer elapsed but the device is still at/above the
                        # activation temp: do not stop the fan only to restart it.
                        if [[ "$TAPER_HOLD_LOGGED" == false ]]; then
                            logger -t fan-control "TAPER: Timer elapsed but ${avg_temp}°C ≥ ${FAN_ACTIVATION_TEMP}°C; holding minimum speed"
                            TAPER_HOLD_LOGGED=true
                        fi
                        set_fan_speed "$MIN_PWM"
                    fi
                else
                    local remaining=$((TAPER_DURATION - (now - TAPER_START)))
                    # One log line per minute, not one per tick
                    if [[ "$TAPER_LAST_LOGGED_MIN" != "$((remaining / 60))" ]]; then
                        logger -t fan-control "TAPER: Remaining $((remaining / 60))m | Current: ${avg_temp}°C"
                        TAPER_LAST_LOGGED_MIN=$((remaining / 60))
                    fi
                    set_fan_speed "$MIN_PWM"
                fi
                ;;

            "$STATE_ACTIVE")
                if ((avg_temp <= MIN_TEMP)); then
                    state_transition="ACTIVE→TAPER (${avg_temp}°C ≤ ${MIN_TEMP}°C)"
                    CURRENT_STATE=$STATE_TAPER
                    TAPER_START=$now
                    TAPER_HOLD_LOGGED=false
                    TAPER_LAST_LOGGED_MIN=""
                    set_fan_speed "$MIN_PWM"
                else
                    local temp_delta=$((avg_temp - LAST_AVG_TEMP))
                    if ((${temp_delta#-} > DEADBAND)); then
                        logger -t fan-control "DEADBAND:  DELTA=${temp_delta}°C | THRESHOLD=${DEADBAND}°C"
                        local speed
                        speed=$(calculate_speed "$avg_temp")
                        log_calculation "$avg_temp" "$speed"
                        set_fan_speed "$speed"
                        LAST_AVG_TEMP=$avg_temp # no PWM change must not repeat this log every tick
                    else
                        # Force adjustment if we're below target PWM
                        local target_speed
                        target_speed=$(calculate_speed "$avg_temp")
                        log_calculation "$avg_temp" "$target_speed"
                        if ((LAST_PWM < target_speed)); then
                            logger -t fan-control "DEADBAND:  Forcing adjustment (current ${LAST_PWM}pwm < target ${target_speed}pwm)"
                            set_fan_speed "$target_speed"
                        elif ((DRIVE_PWM_FLOOR > LAST_PWM)); then
                            # A hot drive needs more than we are running: ramp up now,
                            # not at the next resync.
                            logger -t fan-control "DEADBAND:  Drive floor ${DRIVE_PWM_FLOOR}pwm > current ${LAST_PWM}pwm"
                            set_fan_speed "$target_speed"
                        elif [[ "$FLOOR_HELD" == true || "$RAMP_DOWN_PENDING" == true ]] && ((LAST_PWM > target_speed && LAST_PWM > DRIVE_PWM_FLOOR)); then
                            # The drive cooled down, or a ramp-down was cut short: keep stepping towards the CPU curve
                            set_fan_speed "$target_speed"
                        else
                            RAMP_DOWN_PENDING=false
                            if ((LAST_PWM <= target_speed || LAST_PWM <= DRIVE_PWM_FLOOR)); then
                                [[ "$DRIVE_PWM_FLOOR" -eq 0 ]] && FLOOR_HELD=false
                            fi
                            local deadband_log="DEADBAND:  No change | DELTA=${temp_delta}°C"
                            if has_meaningful_temp_change "$avg_temp" "$LAST_LOGGED_DEADBAND_TEMP"; then
                                logger -t fan-control "$deadband_log"
                                LAST_LOGGED_DEADBAND_TEMP=$avg_temp
                            fi
                            # Nothing to change, but still honour a pending resync write
                            if [[ "$FORCE_PWM_WRITE" == true ]]; then
                                set_fan_speed "$LAST_PWM"
                            fi
                        fi
                    fi
                fi
                ;;
        esac
    fi

    PREV_LOOP_TEMP=$SMOOTHED_TEMP
    [[ -n "$state_transition" ]] && logger -t fan-control "STATE: ${state_transition}"
}

###[ MAIN EXECUTION ]##########################################################
# Initialize optimal PWM file if it doesn't exist
[[ -f "$OPTIMAL_PWM_FILE" ]] || {
    if atomic_write_file "$OPTIMAL_PWM_FILE" "$MIN_PWM"; then
        logger -t fan-control "INIT: Created optimal PWM file with ${MIN_PWM}pwm"
    fi
}

# Read and validate optimal PWM value
OPTIMAL_PWM=$(cat "$OPTIMAL_PWM_FILE" 2>/dev/null || echo "$MIN_PWM")
if ! [[ "$OPTIMAL_PWM" =~ ^[0-9]+$ ]] || ((OPTIMAL_PWM < MIN_PWM || OPTIMAL_PWM > MAX_PWM)); then
    logger -t fan-control "WARNING: Invalid optimal PWM value: ${OPTIMAL_PWM}, using MIN_PWM"
    OPTIMAL_PWM=$MIN_PWM

    # Write corrected value back to file
    if atomic_write_file "$OPTIMAL_PWM_FILE" "$OPTIMAL_PWM"; then
        logger -t fan-control "FIXED: Updated optimal PWM file with corrected value ${OPTIMAL_PWM}pwm"
    fi
fi
FAN_CONTROL_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
if ! [[ "$FAN_CONTROL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    FAN_CONTROL_VERSION="unknown"
fi
logger -t fan-control "CONFIG: fan-control v${FAN_CONTROL_VERSION} starting"
logger -t fan-control "START: Optimal=${OPTIMAL_PWM}pwm | Config: MIN=${MIN_TEMP}°C, MAX=${MAX_TEMP}°C, HYST=${HYSTERESIS}°C, EXIT_PWM=${EXIT_PWM}"

detect_drive_temperature initial
get_smoothed_temp
if ((SMOOTHED_TEMP >= FAN_ACTIVATION_TEMP)); then
    logger -t fan-control "COLDSTART: Initial temp ${SMOOTHED_TEMP}°C ≥ ${FAN_ACTIVATION_TEMP}°C"
    CURRENT_STATE=$STATE_ACTIVE
    set_fan_speed "$OPTIMAL_PWM"
else
    logger -t fan-control "COLDSTART: Initial temp ${SMOOTHED_TEMP}°C - Fans off"
    set_fan_speed 0
fi
PREV_LOOP_TEMP=$SMOOTHED_TEMP

# Define state names for more readable logging
get_state_name() {
    case $1 in
        "$STATE_OFF") echo "OFF" ;;
        "$STATE_TAPER") echo "TAPER" ;;
        "$STATE_ACTIVE") echo "ACTIVE" ;;
        "$STATE_EMERGENCY") echo "EMERGENCY" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# Main loop
declare -i loop_counter=0
declare -i pwm_recheck_counter=0
declare -i drive_rescan_counter=0
while true; do
    update_fan_state
    notify_watchdog

    if [[ "$FAN_PWM_AUTODETECT" != "false" ]]; then
        pwm_recheck_counter=$((pwm_recheck_counter + 1))
        if ((pwm_recheck_counter >= PWM_RECHECK_LOOPS)); then
            detect_pwm_devices
            pwm_recheck_counter=0
        fi
    fi

    # Resync the hardware with what we believe we last wrote: another process
    # (or a stray second instance) may have changed the PWM behind our back.
    # Rewriting LAST_PWM is idempotent and cannot drift.
    if ((loop_counter > 0 && loop_counter % PWM_RECHECK_LOOPS == 0)); then
        FORCE_PWM_WRITE=true
    fi

    drive_rescan_counter=$((drive_rescan_counter + 1))
    if ((drive_rescan_counter >= DRIVE_RESCAN_LOOPS)); then
        detect_drive_temperature rescan
        drive_rescan_counter=0
    fi

    # Log status every 10 iterations
    ((loop_counter++ % 10 == 0)) && {
        state_name=$(get_state_name $CURRENT_STATE)
        current_temp=$SMOOTHED_TEMP
        logger -t fan-control "STATUS: State=${state_name} | PWM=${LAST_PWM} | Temp=${current_temp}°C"
    }

    # Sleep in the background and wait, so TERM/INT run the cleanup at once
    # instead of after the sleep. 200>&- keeps the sleep from holding the lock.
    sleep "$CHECK_INTERVAL" 200>&- &
    SLEEP_PID=$!
    wait "$SLEEP_PID" || true
    SLEEP_PID=""
done
