#!/bin/bash
set -e

HWMON_BASE="${FAN_CONTROL_HWMON_BASE:-/sys/class/hwmon}"
INSTALL_DIR="${FAN_CONTROL_INSTALL_DIR:-/data/fan-control}"
SERVICE_FILE="${FAN_CONTROL_SERVICE_FILE:-/etc/systemd/system/fan-control.service}"
PID_FILE="${FAN_CONTROL_PID_FILE:-/var/run/fan-control.pid}"

ASSUME_YES=false
KEEP_CONFIG=false
for arg in "$@"; do
    case "$arg" in
        -y | --yes) ASSUME_YES=true ;;
        --keep-config) KEEP_CONFIG=true ;;
        -h | --help)
            echo "Usage: uninstall.sh [--yes] [--keep-config]"
            echo "  --yes          do not ask for confirmation"
            echo "  --keep-config  remove everything except $INSTALL_DIR/config"
            exit 0
            ;;
        *)
            echo "Error: unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

# Check for systemd availability
if ! command -v systemctl >/dev/null 2>&1; then
    echo "Error: systemd is required but not found"
    exit 1
fi

# Refuse obviously dangerous removal targets (the path can come from the
# environment). Require an absolute path, then resolve it so /etc/,
# /usr/../etc and symlinks are judged by where they really point.
case "$INSTALL_DIR" in
    /*) ;;
    *)
        echo "Error: refusing to remove unsafe install directory (not an absolute path): '$INSTALL_DIR'"
        exit 1
        ;;
esac
# -m also resolves paths whose parent directories do not exist (a half-removed
# install must still be uninstallable); -f is the fallback for tools without -m.
RESOLVED_INSTALL_DIR=$(readlink -m -- "$INSTALL_DIR" 2>/dev/null || readlink -f -- "$INSTALL_DIR" 2>/dev/null || true)
if [ -z "$RESOLVED_INSTALL_DIR" ]; then
    # No usable readlink: accept the path only if it has no dot segments
    case "$INSTALL_DIR" in
        *"/.."* | *"/./"* | */.)
            echo "Error: cannot resolve install directory: '$INSTALL_DIR'"
            exit 1
            ;;
    esac
    RESOLVED_INSTALL_DIR="$INSTALL_DIR"
fi
INSTALL_DIR="$RESOLVED_INSTALL_DIR"
case "$INSTALL_DIR" in
    / | /data | /var | /boot | /bin | /sbin | /lib | /lib64 | /root | /home | /sys | /dev | /proc | /run | /tmp | /mnt | /opt | /srv | /media | /lost+found | \
        /etc | /etc/* | /usr | /usr/* | /bin/* | /sbin/* | /lib/* | /lib64/* | /boot/* | /sys/* | /proc/* | /dev/* | /root/* | /home/* | /var/* | /media/* | /lost+found/*)
        echo "Error: refusing to remove unsafe install directory: '$INSTALL_DIR'"
        exit 1
        ;;
esac

# Ask before deleting the user's configuration, but only when a person is at the
# terminal. Without a terminal (pipe, ssh without -t) the prompt is skipped,
# the same as passing --yes.
if [ "$ASSUME_YES" = false ] && [ -t 0 ]; then
    printf 'Remove fan-control and delete %s? [y/N] ' "$INSTALL_DIR"
    read -r answer || answer=""
    case "$answer" in
        y | Y | yes | YES) ;;
        *)
            echo "Aborted."
            exit 1
            ;;
    esac
fi

# PWM value to leave on the fans. Same default as fan-control.sh (91). Read the
# number with grep instead of sourcing the config file, so uninstalling never
# executes it. Like `source`, the last assignment wins; optional quotes are
# accepted. A line not starting at column 0 is ignored, because the daemon's
# own check (grep '^EXIT_PWM=') appends the default after it and the last wins.
# Out-of-range or malformed values fall back to the default.
EXIT_PWM=91
if [ -f "$INSTALL_DIR/config" ]; then
    # Only a plain number (optionally quoted) followed by end of line, space, ;
    # or # is accepted; anything else (1e2, 77abc, $((50))) falls back to 91,
    # as fan-control.sh does for an invalid value.
    # Matched quotes only; a comment must be preceded by whitespace or ';' as in the shell.
    configured_exit_pwm=$(grep -E '^EXIT_PWM=' "$INSTALL_DIR/config" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -nE "s/^EXIT_PWM=([0-9]+|\"[0-9]+\"|'[0-9]+')(;[[:space:]]*(#.*)?|[[:space:]]+(;[[:space:]]*)?(#.*)?)?\$/\1/p" | tr -d "\"'")
    # Drop leading zeros, then cap the length like fan-control.sh (no 64-bit wrap)
    raw_exit_pwm=$configured_exit_pwm
    configured_exit_pwm="${configured_exit_pwm#"${configured_exit_pwm%%[!0]*}"}"
    if [ -n "$raw_exit_pwm" ] && [ -z "$configured_exit_pwm" ]; then
        configured_exit_pwm=0 # the value was all zeros
    fi
    case "$configured_exit_pwm" in
        '') ;;
        *[!0-9]*) ;;
        *)
            if [ "${#configured_exit_pwm}" -le 3 ] && [ "$configured_exit_pwm" -le 255 ]; then
                EXIT_PWM=$configured_exit_pwm
            fi
            ;;
    esac
fi

# Stop and disable service
systemctl stop fan-control.service 2>/dev/null || true
systemctl disable fan-control.service 2>/dev/null || true

# Set all fan PWM channels to EXIT_PWM
# Mirrors the detection logic in fan-control.sh to find all channels
reset_ok=false

# Strategy 1: pwm files directly in hwmon class directories
for pwm_file in "$HWMON_BASE"/hwmon*/pwm[1-9]; do
    if [ -e "$pwm_file" ]; then
        echo "Setting $pwm_file to $EXIT_PWM..."
        { echo "$EXIT_PWM" >"$pwm_file"; } 2>/dev/null && reset_ok=true
    fi
done

# Strategy 2: raw device paths (for UDM-SE where class dir has no pwm files)
if [ "$reset_ok" = false ]; then
    for hwmon_dir in "$HWMON_BASE"/hwmon*; do
        dev_path=$(readlink -f "$hwmon_dir/device" 2>/dev/null) || continue
        for pwm_file in "$dev_path"/pwm[1-9]; do
            if [ -e "$pwm_file" ]; then
                echo "Setting $pwm_file to $EXIT_PWM..."
                { echo "$EXIT_PWM" >"$pwm_file"; } 2>/dev/null && reset_ok=true
            fi
        done
    done
fi

[ "$reset_ok" = false ] && echo "Warning: No PWM devices found to reset"
if [ "$EXIT_PWM" -eq 0 ]; then
    echo "Note: fans were set to PWM 0. Confirm on your device that this hands control back to firmware (check temperature for a few minutes)."
else
    echo "Note: fans were left at PWM $EXIT_PWM. Reboot to return them to firmware control if you do not want that."
fi

# Remove system files
echo "Removing system files..."
rm -f "$SERVICE_FILE" || echo "Warning: Could not remove service file"
rm -f "$PID_FILE" || echo "Warning: Could not remove PID file"

# Remove data files
echo "Removing data files..."
if [ -d "$INSTALL_DIR" ]; then
    if [ "$KEEP_CONFIG" = true ]; then
        find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name config -exec rm -rf {} + || {
            echo "Warning: Could not remove all files from $INSTALL_DIR"
        }
        if [ -f "$INSTALL_DIR/config" ]; then
            echo "Kept $INSTALL_DIR/config"
        fi
    else
        rm -rf "$INSTALL_DIR" || {
            echo "Warning: Could not remove data directory"
            echo "You may need to manually remove $INSTALL_DIR"
        }
    fi
else
    echo "Data directory not found, skipping"
fi

# Reload systemd
systemctl daemon-reload

echo "Uninstallation complete."
