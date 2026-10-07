# UniFi Intelligent Fan Control (fork)

Advanced temperature management for Ubiquiti UniFi OS devices with fan control.

> **This is a fork of [iceTeaSA/unifi-fan-control](https://github.com/iceteaSA/unifi-fan-control)** with safety, installer and uninstaller fixes (see [Changes in this fork](#changes-in-this-fork)). The fixes are covered by sandboxed regression tests that drive the real scripts with a simulated fan controller. **They have not yet been verified on real UniFi hardware.** Test on a non-critical device first. Original design and code by the upstream author; this fork keeps the MIT license and the original copyright notice.

Upstream confirmed working on: UCG-Max, UCG-Fibre, UXG-Fibre, UDM-SE, UDM-Pro-Max, UDR7, UNVR.

**Not supported: UniFi switches (USW line).** They run BusyBox `sh` with no bash, no
`ubnt-systool` for temperature, and no systemd, and their fans are firmware controlled
rather than exposed as writable `/sys/class/hwmon/*/pwm*`. Confirmed on a USW Enterprise
48 PoE running 7.5.9: no `/sys/class/hwmon/*/pwm*` entries exist at all. This needs
consoles and gateways running full UniFi OS.

> In every command below, replace `YOUR_USERNAME` with the GitHub account that hosts this fork.

## Features
- **Four Operational States**:
  - **OFF**: Fan disabled (temp < activation threshold)
  - **TAPER**: Post-cooling minimum speed period
  - **ACTIVE**: Quadratic response curve (temp >= activation threshold)
  - **EMERGENCY**: Immediate full speed (255 PWM) at critical temps
- **Emergency Override**: Instant full speed at critical temps, with hysteresis for stable transitions. Emergency is not limited by `MAX_PWM_STEP`.
- **Quadratic Response**: Progressive cooling curve for optimal noise/performance
- **Enhanced Adaptive Learning**: PWM optimization with temperature trend analysis
- **Exponential Smoothing**: Noise-resistant temperature tracking (fractional precision, no integer dead zone)
- **Robust Safety Systems**:
  - Speed limits and thermal protection
  - Hardware validation
  - Sensor failure detection and recovery
  - Configuration validation
  - systemd watchdog and timeouts on external commands, so a hung tool cannot stall the control loop
- **State Transition Hysteresis**: Prevents rapid state oscillation
- **Multi-Fan Auto-Detection**: Automatically discovers and controls all active fan channels
  - Searches hwmon class directories first (UCG-Max, UNVR)
  - Falls back to raw sysfs device paths when needed (UDM-SE)
  - Identifies active fans by RPM reading and write-tests each channel
  - All detected fans receive the same PWM value
  - A channel that fails to accept writes is marked suspect and re-tested, while the others keep being controlled
- **Drive Temperature Floor**: Raises PWM for a hot NVMe or SATA drive without changing the CPU curve
  - Sleeping SATA drives are not woken up by temperature reads
  - Drives are rescanned periodically, so a hot-plugged drive is picked up
  - A single failed read does not drop a drive's floor (3 consecutive failures are needed)

## Installation
```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/unifi-fan-control/main/install.sh | sudo bash
```

By default, the installer resolves the latest tagged release, downloads its
runtime tarball, and verifies the tarball against that release's `SHA256SUMS`.
The installed version is recorded in `/data/fan-control/VERSION`.

After restarting the service, the installer waits `FAN_CONTROL_HEALTH_WAIT` seconds
(default 8) and checks that the service stays running. If it does not, the installer
restores the previous files and the previous enabled/active state of the service. A
Ctrl-C or a dropped SSH session during the install rolls back the same way.

> A tagged release must exist in your fork before the one-line "latest release" install works.
> Until the first release is published, use a checkout (see Manual Installation).

### Pin a Release

Use a version when you need a known build:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/unifi-fan-control/main/install.sh | sudo FAN_CONTROL_VERSION=v1.2.0 bash
```

`FAN_CONTROL_VERSION` accepts `v1.2.0` or `1.2.0`. Pinned installs verify the
matching release tarball before replacing installed files.

To go one step further, pin the expected SHA-256 of the tarball, taken from a source you
trust (for example the release page, read on another machine):

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/unifi-fan-control/main/install.sh | sudo FAN_CONTROL_VERSION=v1.2.0 FAN_CONTROL_EXPECTED_SHA256=<64 hex characters> bash
```

`FAN_CONTROL_EXPECTED_SHA256` only applies to verified release downloads. On an
unverified path (branch install, `FAN_CONTROL_ALLOW_UNVERIFIED`) the installer refuses
instead of silently ignoring it.

### Release Download DNS Failures

GitHub redirects verified release downloads from `github.com` to
`release-assets.githubusercontent.com`. Both names must resolve. If the installer
names `release-assets.githubusercontent.com`, fix the device's DNS resolver or
allow that host first. That is a resolver failure, not a broken installer or
release.

If the installer reports that `raw.githubusercontent.com` is reachable and the
resolver cannot be fixed immediately, a one-time fallback is available for one
specific tag:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/unifi-fan-control/v1.2.0/install.sh | sudo FAN_CONTROL_ALLOW_UNVERIFIED=v1.2.0 bash
```

This bypasses SHA256 verification for that install. It still validates the
downloaded files before writing them, but it is not the normal or preferred path.
`FAN_CONTROL_ALLOW_UNVERIFIED` must exactly match the tag being installed.

### Using a Different Branch
For development builds:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/unifi-fan-control/main/install.sh | sudo FAN_CONTROL_BRANCH=feature/example bash
```

Branch installs download individual files from GitHub and are unverified. Do
not use them for production routers. `FAN_CONTROL_VERSION` and
`FAN_CONTROL_BRANCH` cannot be used together.

### Manual Installation
If you prefer to inspect the code before installation:
```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/unifi-fan-control.git
cd unifi-fan-control

# Run the installer from a checkout or extracted release tarball
sudo ./install.sh
```

When all four runtime files are beside `install.sh`, the installer uses those
local files without a network request. In that case `FAN_CONTROL_VERSION` and
`FAN_CONTROL_BRANCH` are not used, and `FAN_CONTROL_EXPECTED_SHA256` is ignored with a
warning.

## Configuration
Edit `/data/fan-control/config`:
```bash
# Core Thresholds
MIN_TEMP=60            # Base threshold (°C)
MAX_TEMP=85            # Critical temperature (°C), must exceed MIN_TEMP + HYSTERESIS
HYSTERESIS=5           # Temperature buffer (°C)

# Fan Behavior
MIN_PWM=91        # Minimum active speed (0-255)
MAX_PWM=255       # Maximum speed (0-255)
MAX_PWM_STEP=25   # Maximum speed change per adjustment (not applied in EMERGENCY)
                  # Note: Due to hardware limitations, actual PWM values may vary slightly from requested values
EXIT_PWM=91       # Speed left on the fans when the service stops (0-255)

# Drive Temperature Floor
# auto detects a readable NVMe or SATA drive; false skips detection entirely
DRIVE_TEMP_ENABLED=auto
DRIVE_MIN_TEMP=50        # Start raising the PWM floor (°C)
DRIVE_MAX_TEMP=70        # Reach maximum PWM (°C)
DRIVE_CHECK_INTERVAL=60  # Drive temperature polling interval (seconds)

# Advanced Tuning
ALPHA=20          # Smoothing factor, lower values make the smoothed temp follow raw temp more closely (0-100 raw→smooth)
DEADBAND=1        # Temperature stability threshold (°C)
LEARNING_RATE=5   # Hourly PWM optimization step size
TAPER_MINS=90     # Cool-down duration (minutes)
CHECK_INTERVAL=15 # Temperature check frequency (seconds)

# Auto-detects all active fan channels by default (recommended)
# Set to false to use FAN_PWM_DEVICE as a single manual override instead
FAN_PWM_AUTODETECT=true
# Only used when FAN_PWM_AUTODETECT=false
FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1"
OPTIMAL_PWM_FILE="/data/fan-control/optimal_pwm"
```

> **Note**: The script automatically checks for missing configuration parameters and adds them with default values if they're not present in the config file. Invalid values are corrected in place (only the affected line changes, comments are kept). If the emergency temperature is not above the activation temperature, only `MAX_TEMP` is reset when its default is enough, otherwise all three temperature settings are reset.

### About `EXIT_PWM`

When the service stops, the fans are left at `EXIT_PWM` (default 91, a moderate speed).
The previous behaviour was to write 0. Whether PWM 0 hands control back to the firmware
or stops the fan depends on the device. Before setting `EXIT_PWM=0`, stop the service on a
non-critical device and watch the fan speed and temperature for a few minutes. If the fan
stops and the temperature climbs, set it back to 91. Rebooting the device returns the fans
to firmware control.

### Config file requirements

The service runs as root and loads the config as a shell file, so it refuses to start if
the config file or its directory is not owned by root, or is writable by group or others.
Re-running the installer fixes the permissions. A config saved with Windows (CRLF) line
endings is converted automatically.

Apply changes:
```bash
systemctl restart fan-control.service
```

## Operational Overview
| State       | Trigger Condition          | Exit Condition                   | Behavior                          |
|-------------|----------------------------|----------------------------------|-----------------------------------|
| **OFF**     | <65°C (60+5)               | Temp >= 65°C                     | Fan disabled                      |
| **TAPER**   | Temp <= 60°C from ACTIVE   | Temp >= 67°C or timer elapsed    | Minimum speed for configured mins |
| **ACTIVE**  | 65°C - 85°C                | Temp <= 60°C or Temp >= 85°C     | Quadratic speed response          |
| **EMERGENCY**| >=85°C                    | Temp <= 80°C (with hysteresis)   | Immediate full speed (255 PWM)    |

### State Transitions
- **OFF → ACTIVE**: Temperature rises above activation threshold (65°C)
- **ACTIVE → TAPER**: Temperature drops below minimum threshold (60°C)
- **ACTIVE → EMERGENCY**: Temperature reaches critical level (85°C)
- **TAPER → OFF**: Cool-down period (default: 90 minutes) completes
- **TAPER → ACTIVE**: Temperature rises significantly above activation threshold (67°C, with 2°C buffer)
- **EMERGENCY → ACTIVE**: Temperature drops significantly below critical level (80°C, with 5°C hysteresis)

## Monitoring & Logging
Key operational signals:
```log
# Temperature Monitoring
TEMP: RAW=68℃ | SMOOTH=65℃ | DELTA=-3℃

# Speed Calculations
CALC: temp_diff=5℃ | range=20℃ | speed=100pwm

# State Transitions
STATE: OFF→ACTIVE (67℃ ≥ 65℃)
STATE: ACTIVE→TAPER (59℃ ≤ 60℃)
STATE: →EMERGENCY (86℃ ≥ 85℃)
STATE: EMERGENCY→ACTIVE (79℃ ≤ 80℃)
STATE: TAPER→ACTIVE (67℃ ≥ 67℃)

# Speed Changes
SET: 55→80pwm | Reason: Ramp-up limited: 55→80pwm
SET: 120→255pwm | Reason: EMERGENCY: Temp 86℃ ≥ 85℃

# Fan Channel Detection
pwm1_enable=1 (manual)

# Drive Temperature Floor
DRIVE: Detected /dev/nvme0n1 via nvme | Temp=47℃ | wctemp=83℃

# Enhanced Learning System
LEARNING: 80→85pwm (+5 (rising temp 2℃)) [Rate=7]
LEARNING: 95→90pwm (-5 (stable below threshold)) [Rate=5]
LEARNING: 100→99pwm (-1 (efficiency optimization)) [Rate=5]

# Error Handling
ERROR: Failed to read temperature (attempt 1)
ALERT: Multiple temperature read failures - using last known temperature
SAFETY: Activating emergency mode due to sensor failure

# Configuration Validation
CONFIG: Invalid MIN_TEMP value: 25 (should be between 30 and 80), using default: 60
CONFIG: Updating configuration file with corrected values

# Configuration Management
CONFIG: Missing parameter detected: CHECK_INTERVAL
CONFIG: Updating configuration file with 1 missing parameters
CONFIG: Configuration file updated successfully

# Deployed version
CONFIG: fan-control vX.Y.Z starting

# System Status
STATUS: State=ACTIVE | PWM=120 | Temp=72℃
STATUS: State=EMERGENCY | PWM=255 | Temp=86℃
```

The `pwmN_enable` line is informational. If a channel is not in manual mode (value 1), the
fan may be driven by the firmware regardless of what is written to it. The service reports
this but does not change it.

View logs with:
```bash
journalctl -u fan-control.service -f          # Live monitoring
journalctl -u fan-control.service --since "10 minutes ago"  # Recent history
```

## Technical Implementation
- **Quadratic Response Curve**:

<br>

$$
PWM = MIN_{PWM} + \frac{(temp_{diff}^2 \times (MAX_{PWM} - MIN_{PWM}))}{temp_{range}^2}
$$

Where:  
`temp_diff = current_temp - activation_temp`  
`temp_range = MAX_TEMP - activation_temp`


- **Exponential Smoothing**:

<br>

$$
smoothed_{temp} = \frac{\alpha \times previous_{smooth} + (100 - \alpha) \times raw_{temp}}{100}
$$

(α configured via ALPHA parameter)

<br>


- **Enhanced Adaptive Learning**:
  - Adjusts optimal PWM based on thermal performance every 30 minutes (configurable)
  - Uses adaptive learning rate based on temperature stability
  - Implements three learning strategies:
    1. Proactive PWM increase when temperature is rising
    2. PWM reduction when temperature is stable below threshold
    3. Efficiency optimization when running faster than necessary with stable temperatures


- **Robust Error Handling**:
  - Tracks consecutive temperature reading failures
  - Implements safety measures after multiple failures
  - Uses last known temperature when readings fail
  - Activates fans proactively during sensor uncertainty

- **Configuration Validation**:
  - Validates all parameters against reasonable ranges
  - Automatically corrects invalid settings
  - Prevents misconfiguration issues

- **Hardware PWM Limitations**:  
  Due to device hardware limitations, the actual PWM values applied may differ from the requested values
  (e.g., setting 50 might result in ~48, or 100 might result in ~92)

## Maintenance
```bash
# Service Management
systemctl status fan-control.service   # Current state
systemctl restart fan-control.service  # Apply config changes

# Full Removal (asks for confirmation when run from a terminal)
/data/fan-control/uninstall.sh

# Non-interactive removal, or removal that keeps your config file
/data/fan-control/uninstall.sh --yes
/data/fan-control/uninstall.sh --yes --keep-config
```

On uninstall the fans are left at `EXIT_PWM` (default 91). Reboot the device to return
them to firmware control. The uninstaller refuses to remove system directories and
requires an absolute install path.

### Which version am I running?

```bash
cat /data/fan-control/VERSION
journalctl -u fan-control.service | grep starting | tail -1
# CONFIG: fan-control v1.1.1 starting
```

Neither prints anything on builds older than v1.0.0, which predate version identity.

### Updating

Re-run the installer. There is no auto-update: this runs as root, and a self-updating
root daemon is a large attack surface for a fan controller.

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/unifi-fan-control/main/install.sh | sudo bash
```

**Your config is preserved.** `/data/fan-control/config` is never replaced by an
install or upgrade. Only the scripts and the service unit are replaced. The running
service may add missing settings or correct invalid ones in place. No backup step
is needed.

### Does it survive a UniFi OS update?

A normal firmware update, yes. A factory reset, no.

UniFi OS runs root as an overlay: the firmware is a read-only lower layer, and anything
you install lands in the upper layer. Both halves of this install live there (the
systemd unit and `/data/fan-control`), so they share one fate. A firmware update swaps
the lower layer and leaves the upper alone.

What does remove it: factory reset, `reset2defaults`, re-adoption, or any recovery flow
that rebuilds the overlay. If the service disappears and other things you installed went
with it, that was the overlay rather than this script. Reinstall with the one-liner above.

## Changes in this fork

Behaviour changes you may notice when upgrading from upstream:

1. **Exit speed.** On stop or uninstall the fans stay at `EXIT_PWM` (default 91) instead of 0. See [About `EXIT_PWM`](#about-exit_pwm).
2. **Emergency is immediate.** EMERGENCY jumps to full speed in one step instead of ramping at `MAX_PWM_STEP` (which took about two minutes to reach 255).
3. **Config permissions.** A config file or directory that is not root-owned, or is group/world writable, makes the service refuse to start. Windows line endings are converted automatically.
4. **Invalid `MAX_TEMP`.** Only `MAX_TEMP` is reset when it is not above `MIN_TEMP + HYSTERESIS` and its default is enough.
5. **Service unit.** Adds `WatchdogSec=300`, `NotifyAccess=all`, `ProtectSystem=full` and `LimitCORE=0`. If a device refuses to start the service, remove `ProtectSystem=full` first, then the two watchdog lines.
6. **Installer.** Waits for the service to stay healthy after the restart (default 8 seconds) and rolls back on failure or on Ctrl-C. Downloads use timeouts, HTTPS-only and a size cap. `FAN_CONTROL_EXPECTED_SHA256` pins the tarball.
7. **Uninstaller.** Asks for confirmation on a terminal, supports `--yes` and `--keep-config`, never executes the config file, and refuses unsafe directories such as `/var/*`.

Control and safety fixes:

- Smoothing keeps fractional precision, so the filtered temperature no longer stalls near the threshold.
- Adaptive learning compares against the previous reading and stores its result, so it actually adapts.
- A hot drive's floor ramps up from at least `MIN_PWM`, is applied while in ACTIVE, and is released again when the drive cools.
- A ramp-down that was cut short by the step limit continues even when the temperature is steady.
- If the temperature cannot be read at startup, the service assumes the activation temperature instead of an empty value.
- The lock is taken before any PWM write, so two instances cannot fight.
- A fan channel that rejects writes is marked suspect and re-tested instead of silently ignored.
- SATA temperature reads use `smartctl -n standby`, so sleeping drives are not woken.
- Stopping the service responds immediately instead of after the current sleep.

## Project Structure
- **fan-control.sh**: The main script that monitors temperature and controls fan speed
- **VERSION**: Bare SemVer identity for the deployed daemon
- **install.sh**: Installation script that copies files and sets up the systemd service
  - Uses local runtime files first, then a pinned release, branch, or latest release
  - Verifies release tarballs and rejects unsafe archive contents before installation
  - Rolls back on failure
- **uninstall.sh**: Script to remove the fan control system
- **fan-control.service**: Systemd service configuration
- **tests/**: Sandboxed test suite (no device, no root required)
  - `tests/run-tests.sh` runs every `tests/test_*.sh`
  - `tests/test_audit_fixes.sh`: regression tests for the control logic and the uninstaller, driven by a simulated fan controller and a virtual clock
  - `tests/test_install_flow.sh`: installer rollback, health check and hash pin behaviour with a fake `systemctl`
- **release-please-config.json** / **.release-please-manifest.json**: Tagged-release automation configuration
- **.github/workflows/release.yml**: Builds and verifies tagged release assets
- **.github/workflows/ci.yml**: Syntax check, ShellCheck (advisory) and the test suites on every push and pull request

## Credits & Acknowledgments
- **Original project**: [iceTeaSA/unifi-fan-control](https://github.com/iceteaSA/unifi-fan-control), MIT licensed. This fork keeps the original license and copyright notice.
- **Thermal Research**: [UCG-Max Thermal Thread](https://www.reddit.com/r/Ubiquiti/comments/1fr8xyt/)
- **System Integration**: SierraSoftworks service patterns

---

**Disclaimer**: Community project, not affiliated with Ubiquiti Inc. Fans and thermal management are safety-relevant: use at your own risk and validate on a non-critical device first.  
**Compatibility**: Upstream verified on UniFi OS 4.0.0+ | UCG-Max, UCG-Fibre, UXG-Fibre, UDM-SE, UDM-Pro-Max, UDR7, UNVR. This fork's changes are pending hardware verification.  
**License**: MIT
