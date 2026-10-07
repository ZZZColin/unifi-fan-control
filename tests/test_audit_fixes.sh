#!/bin/bash
###############################################################################
# Regression tests for the audit fixes. No device and no root required.
# A fake sysfs, fake ubnt-systool/logger/sleep/date and a virtual clock drive
# fan-control.sh through scripted temperature sequences.
#
# Safety: everything is created under mktemp directories. Tests that exercise
# uninstall.sh run its dangerous-path cases with `rm` and `find` replaced by
# loggers, so even a broken guard cannot delete anything.
###############################################################################
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="${FAN_CONTROL_SCRIPT:-$REPO_ROOT/fan-control.sh}"

FAILURES=0
pass() { echo "    ok: $1"; }
fail() {
    echo "    FAIL: $1"
    FAILURES=$((FAILURES + 1))
}
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (expected '$3', got '$2')"; }
assert_contains() { grep -qF -- "$3" <<<"$2" && pass "$1" || fail "$1 (missing '$3')"; }
assert_not_contains() { grep -qF -- "$3" <<<"$2" && fail "$1 (unexpected '$3')" || pass "$1"; }

TMP_DIRS=()
cleanup_tmp() {
    if ((${#TMP_DIRS[@]} > 0)); then
        rm -rf "${TMP_DIRS[@]}"
    fi
}
trap cleanup_tmp EXIT

# new_env: build a sandbox in $T. Optional $1 = extra config lines.
new_env() {
    T=$(mktemp -d)
    TMP_DIRS+=("$T")
    mkdir -p "$T/bin" "$T/hwmon/hwmon0" "$T/dev"
    echo 0 >"$T/hwmon/hwmon0/pwm1"
    echo 0 >"$T/hwmon/hwmon0/fan1_input"
    echo 1 >"$T/hwmon/hwmon0/pwm1_enable"
    echo 1700000000 >"$T/clock"
    : >"$T/log"
    : >"$T/trace"
    : >"$T/queue"
    echo 40 >"$T/temp"

    cat >"$T/bin/ubnt-systool" <<EOF
#!/bin/bash
t=\$(cat "$T/temp")
[[ "\$t" == FAIL ]] && exit 1
echo "\$t"
EOF
    cat >"$T/bin/logger" <<EOF
#!/bin/bash
shift 2
echo "\$*" >>"$T/log"
EOF
    cat >"$T/bin/date" <<EOF
#!/bin/bash
if [[ "\$1" == "+%s" ]]; then cat "$T/clock"; else exec /bin/date "\$@"; fi
EOF
    # The loop sleep (anything but the 2s probe) consumes the next scripted
    # temperature and records the PWM value; the 2s probe only moves the clock.
    # An optional executable $T/hook is called with the tick number.
    cat >"$T/bin/sleep" <<EOF
#!/bin/bash
echo \$((\$(cat "$T/clock") + \$1)) >"$T/clock"
[[ "\$1" == "2" ]] && exit 0
tick=\$(( \$(cat "$T/tick" 2>/dev/null || echo 0) + 1 )); echo \$tick >"$T/tick"
echo "\$tick \$(cat "$T/hwmon/hwmon0/pwm1") \$(cat "$T/hwmon/hwmon0/pwm2" 2>/dev/null || echo -)" >>"$T/trace2"
cat "$T/hwmon/hwmon0/pwm1" >>"$T/trace"
[[ -x "$T/hook" ]] && "$T/hook" \$tick
next=\$(head -n 1 "$T/queue")
if [[ -z "\$next" ]]; then kill -TERM \$PPID; exit 0; fi
sed -i 1d "$T/queue"
echo "\$next" >"$T/temp"
EOF
    chmod +x "$T/bin/"*

    cat >"$T/config" <<EOF
# my custom comment
MIN_PWM=91
MAX_PWM=255
MIN_TEMP=60
MAX_TEMP=85
HYSTERESIS=5
CHECK_INTERVAL=5
TAPER_MINS=90
FAN_PWM_AUTODETECT=true
FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1"
OPTIMAL_PWM_FILE="$T/optimal"
MAX_PWM_STEP=25
DEADBAND=1
ALPHA=20
LEARNING_RATE=5
DRIVE_TEMP_ENABLED=false
DRIVE_MIN_TEMP=50
DRIVE_MAX_TEMP=70
DRIVE_CHECK_INTERVAL=60
EXIT_PWM=77
${1:-}
EOF
    chmod 600 "$T/config"
    echo "1.0.0" >"$T/VERSION"
}

# A second PWM channel for tests that need two fans.
add_second_fan() {
    echo 0 >"$T/hwmon/hwmon0/pwm2"
    echo 0 >"$T/hwmon/hwmon0/fan2_input"
}

# run_fc: run the controller until the scripted queue is exhausted.
run_fc() {
    PATH="$T/bin:$PATH" \
        FAN_CONTROL_CONFIG_FILE="$T/config" \
        FAN_CONTROL_TEMP_STATE_FILE="$T/temp_state" \
        FAN_CONTROL_HWMON_BASE="$T/hwmon" \
        FAN_CONTROL_VERSION_FILE="$T/VERSION" \
        FAN_CONTROL_DRIVE_DEV_DIR="$T/dev" \
        FAN_CONTROL_OPTIMAL_PWM_FILE="$T/optimal" \
        FAN_CONTROL_PID_FILE="$T/pid" \
        timeout 120 bash "$SCRIPT" >"$T/stdout" 2>&1
    RC=$?
}

queue() { printf '%s\n' "$@" >"$T/queue"; }
steady() {
    local n=$1 v=$2
    local q=()
    for _ in $(seq 1 "$n"); do q+=("$v"); done
    queue "${q[@]}"
}
log() { cat "$T/log"; }
enable_drives() {
    sed -i 's/^DRIVE_TEMP_ENABLED=false/DRIVE_TEMP_ENABLED=auto/; s/^DRIVE_CHECK_INTERVAL=60/DRIVE_CHECK_INTERVAL=15/' "$T/config"
}

echo "[1] EMERGENCY reaches MAX_PWM immediately (no ramp limiting)"
new_env
echo 50 >"$T/temp"
queue 50 95 95
run_fc
# tick1 reads 50, tick2 reads 50, tick3 reads 95 -> smoothed 86 >= 85 -> 255 right away
assert_eq "pwm on the first hot tick" "$(sed -n 3p "$T/trace")" "255"
assert_contains "state transition logged" "$(log)" "→EMERGENCY"

echo "[2] High ALPHA converges (no integer dead zone)"
new_env "ALPHA=95"
echo 70 >"$T/temp"
echo 60 >"$T/temp_state"
steady 150 70
run_fc
assert_eq "smoothed temp reaches raw temp" "$(cat "$T/temp_state")" "70"

echo "[3] Learning reacts to rising temperature and OPTIMAL_PWM file changes"
new_env
echo 60 >"$T/temp"
queue 66 66 66 66 66 66
run_fc
opt=$(cat "$T/optimal" 2>/dev/null || echo missing)
if [[ "$opt" =~ ^[0-9]+$ ]] && ((opt > 91)); then pass "optimal PWM rose above MIN_PWM ($opt)"; else fail "optimal PWM did not rise (got '$opt')"; fi
assert_contains "LEARNING logged" "$(log)" "LEARNING:"

echo "[4] Config: leading zeros accepted, bad value fixed in place, comments kept"
new_env "ZZZ=1"
sed -i 's/^HYSTERESIS=5/HYSTERESIS=05/; s/^MIN_TEMP=60/MIN_TEMP=08   # base threshold/' "$T/config"
echo 40 >"$T/temp"
queue 40
run_fc
assert_not_contains "05 is not reported invalid" "$(log)" "Invalid HYSTERESIS"
assert_contains "08 is rejected (below 30)" "$(log)" "Invalid MIN_TEMP"
assert_contains "user comment preserved" "$(cat "$T/config")" "# my custom comment"
assert_contains "MIN_TEMP rewritten to default, trailing comment kept" "$(cat "$T/config")" "MIN_TEMP=60   # base threshold"
assert_contains "ZZZ custom line preserved" "$(cat "$T/config")" "ZZZ=1"

echo "[5] Config: MAX_TEMP must exceed activation temperature"
new_env
sed -i 's/^MIN_TEMP=60/MIN_TEMP=80/; s/^HYSTERESIS=5/HYSTERESIS=10/' "$T/config"
echo 40 >"$T/temp"
queue 40
run_fc
assert_contains "temperature set reset" "$(log)" "must exceed MIN_TEMP+HYSTERESIS"

echo "[6] EXIT_PWM is written when the service stops"
new_env
echo 40 >"$T/temp"
queue 40 40
run_fc
assert_eq "final pwm equals EXIT_PWM" "$(cat "$T/hwmon/hwmon0/pwm1")" "77"

echo "[7] A second instance does not touch the fans (lock before probe)"
new_env
echo 33 >"$T/hwmon/hwmon0/pwm1"
(
    exec 9>>"$T/pid"
    flock 9
    touch "$T/lock_ready"
    sleep 6
) &
holder=$!
for _ in $(seq 1 50); do
    [[ -e "$T/lock_ready" ]] && break
    sleep 0.1
done
queue 40
run_fc
wait "$holder" 2>/dev/null
assert_eq "second instance exits with 1" "$RC" "1"
assert_eq "pwm untouched" "$(cat "$T/hwmon/hwmon0/pwm1")" "33"
assert_contains "lock conflict logged" "$(log)" "Another instance already holds the lock"

echo "[8] Sensor failure forces MAX_PWM"
new_env
echo 40 >"$T/temp"
queue FAIL FAIL FAIL FAIL FAIL
run_fc
assert_contains "fail-safe logged" "$(log)" "Sensor fail-safe active"
assert_eq "pwm at max after repeated failures" "$(sed -n 4p "$T/trace")" "255"

echo "[9] Unreadable sensor at startup starts the fans"
new_env
echo FAIL >"$T/temp"
queue FAIL
run_fc
assert_contains "startup fallback logged" "$(log)" "Initial temperature read failed"
assert_contains "fans start (assumed activation temp)" "$(log)" "COLDSTART: Initial temp 65°C ≥ 65°C"
first_pwm=$(sed -n 1p "$T/trace")
if [[ "$first_pwm" =~ ^[0-9]+$ ]] && ((first_pwm >= 91)); then pass "fans running after first tick ($first_pwm)"; else fail "fans not running after first tick (got '$first_pwm')"; fi

echo "[9b] A saved temperature is ignored when the startup read failed"
new_env
echo FAIL >"$T/temp"
echo 62 >"$T/temp_state"
queue FAIL
run_fc
assert_contains "saved temp ignored" "$(log)" "COLDSTART: Initial temp 65°C"
assert_not_contains "saved 62 not loaded" "$(log)" "Loaded saved temp"

echo "[10] smartctl is called with -n standby; SMART-history exit bits keep the reading"
new_env "ZZZ=1"
sed -i 's/^DRIVE_TEMP_ENABLED=false/DRIVE_TEMP_ENABLED=auto/' "$T/config"
touch "$T/dev/sda"
cat >"$T/bin/smartctl" <<EOF
#!/bin/bash
echo "\$*" >>"$T/smartctl_args"
echo '{ "temperature": { "current": 62 } }'
exit 64
EOF
chmod +x "$T/bin/smartctl"
echo 40 >"$T/temp"
queue 40
run_fc
assert_contains "-n standby used" "$(cat "$T/smartctl_args" 2>/dev/null)" "-n standby"
assert_contains "drive detected despite exit status 64" "$(log)" "Detected"
assert_contains "drive floor engaged" "$(log)" "drives floor"

echo "[11] TAPER does not drop to OFF while temp is still at/above activation"
new_env "TAPER_MINS=1"
echo 70 >"$T/temp"
# go hot (ACTIVE), cool into TAPER, then sit at 66C for more than a minute of virtual time
q=(58 58 58 58 58 58 58 58)
for _ in $(seq 1 30); do q+=(66); done
queue "${q[@]}"
run_fc
assert_contains "TAPER hold logged" "$(log)" "holding minimum speed"
assert_not_contains "no TAPER->OFF while at 66C" "$(log)" "TAPER→OFF"

echo "[12] Drive floor never ramps through speeds below MIN_PWM"
new_env
sed -i 's/^DRIVE_TEMP_ENABLED=false/DRIVE_TEMP_ENABLED=auto/' "$T/config"
touch "$T/dev/sda"
cat >"$T/bin/smartctl" <<EOF
#!/bin/bash
echo '{ "temperature": { "current": 70 } }'
EOF
chmod +x "$T/bin/smartctl"
echo 40 >"$T/temp"
steady 11 40
run_fc
low=$(awk '$1 > 0 && $1 < 91' "$T/trace" | head -n 1)
assert_eq "no nonzero PWM below MIN_PWM" "$low" ""
assert_eq "floor reaches MAX_PWM" "$(tail -n 1 "$T/trace")" "255"

echo "[13] A hot drive that fails reads keeps its floor for a few polls (per-drive hold)"
new_env
enable_drives
touch "$T/dev/sda" "$T/dev/sdb"
cat >"$T/bin/smartctl" <<EOF
#!/bin/bash
n=\$(cat "$T/smart_calls" 2>/dev/null || echo 0)
echo \$((n + 1)) >"$T/smart_calls"
# sda: hot on the first read (detection), then fails; sdb: always cool
if [[ "\$*" == *sda* ]]; then
    if ((n == 0)); then echo '{ "temperature": { "current": 70 } }'; exit 0; fi
    exit 2
fi
echo '{ "temperature": { "current": 35 } }'
EOF
chmod +x "$T/bin/smartctl"
echo 40 >"$T/temp"
steady 6 40
run_fc
assert_not_contains "floor not dropped after a single failed poll" "$(log)" "floor disabled"
last=$(tail -n 1 "$T/trace")
if [[ "$last" =~ ^[0-9]+$ ]] && ((last >= 91)); then pass "fans still running on the held floor ($last)"; else fail "floor was dropped (final pwm '$last')"; fi

echo "[14] A drive that stays unreadable eventually loses its floor"
new_env
enable_drives
touch "$T/dev/sda"
cat >"$T/bin/smartctl" <<EOF
#!/bin/bash
n=\$(cat "$T/smart_calls" 2>/dev/null || echo 0); echo \$((n + 1)) >"$T/smart_calls"
((n == 0)) && { echo '{ "temperature": { "current": 70 } }'; exit 0; }
exit 2
EOF
chmod +x "$T/bin/smartctl"
echo 40 >"$T/temp"
steady 30 40
run_fc
assert_contains "floor dropped after repeated failures" "$(log)" "floor disabled"
assert_eq "fans back to OFF" "$(tail -n 1 "$T/trace")" "0"

echo "[15] A drive that heats up while the CPU is steady raises the fans promptly, then releases them"
new_env
enable_drives
touch "$T/dev/sda"
cat >"$T/bin/smartctl" <<EOF
#!/bin/bash
n=\$(cat "$T/smart_calls" 2>/dev/null || echo 0); echo \$((n + 1)) >"$T/smart_calls"
# cool, then hot for polls 8..13, then cool again
if ((n >= 8 && n < 14)); then echo '{ "temperature": { "current": 70 } }'; else echo '{ "temperature": { "current": 35 } }'; fi
EOF
chmod +x "$T/bin/smartctl"
echo 66 >"$T/temp"
steady 80 66
run_fc
first255=$(awk '$1 == 255 {print NR; exit}' "$T/trace")
if [[ "$first255" =~ ^[0-9]+$ ]] && ((first255 <= 36)); then pass "floor reached 255 promptly (tick $first255)"; else fail "floor ramp too slow (first 255 at tick '${first255:-never}')"; fi
last=$(tail -n 1 "$T/trace")
if [[ "$last" =~ ^[0-9]+$ ]] && ((last <= 130)); then pass "fans released after the drive cooled ($last)"; else fail "fans stuck high after the drive cooled (final pwm '$last')"; fi

echo "[16] CRLF config is converted, not reset to defaults"
new_env
sed -i 's/^MIN_PWM=91/MIN_PWM=120/; s/$/\r/' "$T/config"
echo 40 >"$T/temp"
queue 40 40
run_fc
assert_contains "conversion logged" "$(log)" "Converting CRLF"
assert_not_contains "no value reset to default" "$(log)" "Invalid"
assert_eq "no carriage returns left in config" "$(grep -c $'\r' "$T/config")" "0"
assert_eq "user EXIT_PWM honoured" "$(cat "$T/hwmon/hwmon0/pwm1")" "77"

echo "[17] Config: long zero-padded numbers are normalised, over-long numbers rejected"
new_env
# 18446744073709551637 is 2^64 + 21: a 64-bit parser would wrap it to a valid 21
sed -i 's/^MIN_TEMP=60/MIN_TEMP=0000000069/; s/^CHECK_INTERVAL=5/CHECK_INTERVAL=1234567/; s/^ALPHA=20/ALPHA=18446744073709551637/' "$T/config"
echo 40 >"$T/temp"
queue 40
run_fc
assert_contains "zero-padded value used as 69" "$(log)" "MIN=69°C"
assert_contains "over-long value rejected" "$(log)" "Invalid CHECK_INTERVAL value: 1234567"
assert_contains "wrap-around value rejected" "$(log)" "Invalid ALPHA value: 18446744073709551637"

echo "[18] A PWM value changed behind our back is rewritten (resync)"
new_env
echo 66 >"$T/temp"
printf '#!/bin/bash\n[[ "$1" == 4 ]] && echo 5 >"%s/hwmon/hwmon0/pwm1"\nexit 0\n' "$T" >"$T/hook"
chmod +x "$T/hook"
steady 30 66
run_fc
assert_contains "tamper happened" "$(tr '\n' ' ' <"$T/trace")" "5"
assert_eq "controller restored its value" "$(tail -n 1 "$T/trace")" "91"

echo "[19] A channel that disappears and returns gets the current PWM again"
new_env
add_second_fan
echo 66 >"$T/temp"
printf '#!/bin/bash\nH="%s/hwmon/hwmon0"\n[[ "$1" == 3 ]] && { rm -f $H/pwm2; mkdir $H/pwm2; }\n[[ "$1" == 14 ]] && { rmdir $H/pwm2; echo 0 >$H/pwm2; }\nexit 0\n' "$T" >"$T/hook"
chmod +x "$T/hook"
steady 40 66
run_fc
assert_contains "exclusion logged" "$(log)" "pwm2 unavailable, excluding"
assert_contains "return logged" "$(log)" "pwm2 writable again"
last2=$(tail -n 1 "$T/trace2")
assert_eq "returned channel follows the controller (last tick, before EXIT_PWM)" "$(awk '{print $3}' <<<"$last2")" "$(awk '{print $2}' <<<"$last2")"
assert_not_contains "no raw shell error leaked for the failing channel" "$(cat "$T/stdout")" "Is a directory"

echo "[20] Hot-plugged drive is picked up by the rescan"
new_env
enable_drives
touch "$T/dev/sda"
cat >"$T/bin/smartctl" <<EOF
#!/bin/bash
if [[ "\$*" == *sdb* ]]; then echo '{ "temperature": { "current": 70 } }'; else echo '{ "temperature": { "current": 35 } }'; fi
EOF
chmod +x "$T/bin/smartctl"
printf '#!/bin/bash\n[[ "$1" == 3 ]] && touch "%s/dev/sdb"\nexit 0\n' "$T" >"$T/hook"
chmod +x "$T/hook"
echo 40 >"$T/temp"
steady 80 40
run_fc
assert_contains "hot-plugged drive detected" "$(log)" "Detected $T/dev/sdb"
assert_eq "its floor is applied" "$(tail -n 1 "$T/trace")" "255"

echo "[21] Below the activation temperature the speed does not inflate (negative diff clamp)"
new_env
echo 70 >"$T/temp"
q=(70 70 70)
for _ in $(seq 1 25); do q+=(62); done
queue "${q[@]}"
run_fc
assert_eq "settles on MIN_PWM at 62C" "$(tail -n 1 "$T/trace")" "91"

echo "[22] EMERGENCY is kept until MAX_TEMP-HYSTERESIS"
new_env
echo 90 >"$T/temp"
q=(90 90 90 90)
for _ in $(seq 1 15); do q+=(82); done
queue "${q[@]}"
run_fc
assert_not_contains "no early exit" "$(log)" "EMERGENCY→ACTIVE"
assert_eq "still at MAX_PWM" "$(tail -n 1 "$T/trace")" "255"

echo "[23] Stale saved temperature is discarded; PID file removed on exit"
new_env
echo 40 >"$T/temp"
echo 90 >"$T/temp_state"
queue 40
run_fc
assert_contains "far saved temp discarded" "$(log)" "Discarded saved temp"
assert_eq "pid file removed" "$([[ -e "$T/pid" ]] && echo present || echo gone)" "gone"

echo "[24] Root-run refuses a config not owned by root (fake id)"
if [[ "$(id -u)" != 0 ]]; then
    new_env
    printf '#!/bin/bash\necho 0\n' >"$T/bin/id"
    chmod +x "$T/bin/id"
    echo 33 >"$T/hwmon/hwmon0/pwm1"
    echo 40 >"$T/temp"
    queue 40
    run_fc
    assert_eq "exit 1" "$RC" "1"
    assert_contains "FATAL logged" "$(log)" "must be owned by root"
    assert_eq "pwm untouched" "$(cat "$T/hwmon/hwmon0/pwm1")" "33"
else
    echo "    skip: already root"
fi

echo "[25] TAPER logs once per minute, not once per tick"
new_env
echo 70 >"$T/temp"
q=(58 58 58 58 58 58 58 58)
for _ in $(seq 1 30); do q+=(58); done
queue "${q[@]}"
run_fc
remaining_lines=$(grep -c "TAPER: Remaining" "$T/log")
if ((remaining_lines >= 1 && remaining_lines <= 5)); then pass "TAPER progress lines: $remaining_lines"; else fail "TAPER progress lines: $remaining_lines (expected 1 to 5)"; fi

###############################################################################
# uninstall.sh. Everything lives under one mktemp dir in /tmp (not $TMPDIR, which
# could sit under a path the guard refuses). The dangerous-path cases run with
# rm/find replaced by loggers and must not call them at all.
###############################################################################
echo "[26] uninstall.sh: EXIT_PWM parsing"
U=$(mktemp -d /tmp/fc-uninstall.XXXXXX)
TMP_DIRS+=("$U")
mkdir -p "$U/bin" "$U/safebin" "$U/cwd"
printf '#!/bin/bash\nexit 0\n' >"$U/bin/systemctl"
chmod +x "$U/bin/systemctl"
UNINSTALL="$U/uninstall-under-test.sh"
# uninstall.sh insists on root; run a copy without that one check so the test
# works unprivileged. Everything else is the real script.
sed 's/if \[ "\$(id -u)" -ne 0 \]; then/if [ "0" -ne 0 ]; then/' "$REPO_ROOT/uninstall.sh" >"$UNINSTALL"

# run_uninstall CONFIG_CONTENT -> prints the resulting PWM value
run_uninstall() {
    local d
    d=$(mktemp -d "$U/case.XXXXXX")
    mkdir -p "$d/inst" "$d/hw/hwmon0"
    echo 5 >"$d/hw/hwmon0/pwm1"
    printf '%b' "$1" >"$d/inst/config"
    (
        cd "$U/cwd" || exit 1
        PATH="$U/bin:$PATH" FAN_CONTROL_INSTALL_DIR="$d/inst" FAN_CONTROL_HWMON_BASE="$d/hw" FAN_CONTROL_SERVICE_FILE="$d/svc" FAN_CONTROL_PID_FILE="$d/p" bash "$UNINSTALL" --yes >"$d/out" 2>&1
    )
    echo "$d" >"$U/last_dir" # the caller runs us in $(...), so a variable would be lost
    cat "$d/hw/hwmon0/pwm1"
}
assert_eq "last assignment wins, quotes and trailing comment accepted" "$(run_uninstall 'EXIT_PWM=10\nEXIT_PWM="120"   # note\n')" "120"
assert_eq "install dir removed" "$([[ -d "$(cat "$U/last_dir")/inst" ]] && echo present || echo gone)" "gone"
assert_eq "no config: default 91" "$(run_uninstall '# nothing\n')" "91"
assert_eq "zero padded 0077" "$(run_uninstall 'EXIT_PWM=0077\n')" "77"
assert_eq "semicolon terminator" "$(run_uninstall 'EXIT_PWM=77;\n')" "77"
assert_eq "CRLF line ending" "$(run_uninstall 'EXIT_PWM=60\r\n')" "60"
assert_eq "out of range 300 falls back" "$(run_uninstall 'EXIT_PWM=300\n')" "91"
assert_eq "trailing garbage 77abc falls back" "$(run_uninstall 'EXIT_PWM=77abc\n')" "91"
assert_eq "1e2 falls back" "$(run_uninstall 'EXIT_PWM=1e2\n')" "91"
assert_eq "export form falls back (daemon appends its own default)" "$(run_uninstall 'export EXIT_PWM=50\n')" "91"
assert_eq "7+ digits with leading zeros" "$(run_uninstall 'EXIT_PWM=0000050\n')" "50"
assert_eq "hash glued to the digits is invalid" "$(run_uninstall 'EXIT_PWM=50#x\n')" "91"
assert_eq "trailing command is invalid" "$(run_uninstall 'EXIT_PWM=50 foo\n')" "91"
assert_eq "mismatched quotes are invalid" "$(run_uninstall "EXIT_PWM=\"50'\n")" "91"
assert_eq "all zeros means 0" "$(run_uninstall 'EXIT_PWM=000\n')" "0"
assert_eq "number then space and comment" "$(run_uninstall 'EXIT_PWM=50 # c\n')" "50"
assert_eq "explicit 0 honoured" "$(run_uninstall 'EXIT_PWM=0\n')" "0"

echo "[27] uninstall.sh: unsafe paths are refused before anything is removed"
for c in rm find; do
    printf '#!/bin/bash\necho "%s $*" >>"%s/removal.log"\nexit 0\n' "$c" "$U" >"$U/safebin/$c"
done
chmod +x "$U/safebin/"*
: >"$U/removal.log"
for bad in / /etc/ /usr/../etc . .. relative/path /tmp /var/lib /var/log /lost+found /home/x /root/x; do
    out=$(
        cd "$U/cwd" || exit 1
        PATH="$U/safebin:$U/bin:$PATH" FAN_CONTROL_INSTALL_DIR="$bad" FAN_CONTROL_HWMON_BASE="$U/hw" FAN_CONTROL_SERVICE_FILE="$U/svc" FAN_CONTROL_PID_FILE="$U/p" bash "$UNINSTALL" --yes 2>&1
    )
    assert_contains "refuses '$bad'" "$out" "refusing to remove"
done
assert_eq "rm and find were never called" "$(cat "$U/removal.log")" ""

echo "[28] uninstall.sh: a half-removed install (missing parent directory) can still be uninstalled"
out=$(
    cd "$U/cwd" || exit 1
    PATH="$U/bin:$PATH" FAN_CONTROL_INSTALL_DIR="$U/no/such/parent/fan-control" FAN_CONTROL_HWMON_BASE="$U/hw" FAN_CONTROL_SERVICE_FILE="$U/svc" FAN_CONTROL_PID_FILE="$U/p" bash "$UNINSTALL" --yes 2>&1
)
assert_contains "continues past the missing directory" "$out" "Data directory not found"
assert_contains "finishes" "$out" "Uninstallation complete"

echo "[29] An interrupted ramp-down continues inside the deadband"
new_env
echo 90 >"$T/temp"
q=(90 90 90 90 90 90 90 90)
for _ in $(seq 1 40); do q+=(70); done
queue "${q[@]}"
run_fc
last=$(tail -n 1 "$T/trace")
if ((last < 150)); then pass "settled near the curve target (got $last)"; else fail "fan stuck high at $last"; fi

echo "[30] Config without trailing newline: appended keys do not glue onto the last line"
new_env
printf 'EXIT_PWM=77\nLEARNING_RATE=5' >"$T/config.new"
grep -v '^EXIT_PWM=\|^LEARNING_RATE=\|^DRIVE_CHECK_INTERVAL=' "$T/config" >"$T/config.base"
{ cat "$T/config.base"; cat "$T/config.new"; } >"$T/config.joined"
mv "$T/config.joined" "$T/config"
chmod 600 "$T/config"
steady 3 40
run_fc
assert_not_contains "no glued line" "$(cat "$T/config")" "LEARNING_RATE=5DRIVE"
assert_contains "kept the last user value" "$(cat "$T/config")" "EXIT_PWM=77"

echo "[31] Out-of-order MAX_TEMP resets only MAX_TEMP"
new_env
sed -i 's/^MIN_TEMP=60/MIN_TEMP=70/; s/^HYSTERESIS=5/HYSTERESIS=3/; s/^MAX_TEMP=85/MAX_TEMP=72/' "$T/config"
steady 2 40
run_fc
assert_contains "MIN_TEMP kept" "$(cat "$T/config")" "MIN_TEMP=70"
assert_contains "HYSTERESIS kept" "$(cat "$T/config")" "HYSTERESIS=3"
assert_not_contains "MAX_TEMP corrected" "$(cat "$T/config")" "MAX_TEMP=72"

echo "[32] TERM during the loop sleep exits at once, writes EXIT_PWM and leaves no sleep behind"
new_env
cat >"$T/bin/sleep" <<EOF2
#!/bin/bash
if [[ "\$1" == "2" ]]; then exit 0; fi
echo \$\$ >"$T/sleeppid"
exec /bin/sleep 30
EOF2
chmod +x "$T/bin/sleep"
(
    PATH="$T/bin:$PATH" FAN_CONTROL_CONFIG_FILE="$T/config" FAN_CONTROL_TEMP_STATE_FILE="$T/temp_state" \
        FAN_CONTROL_HWMON_BASE="$T/hwmon" FAN_CONTROL_VERSION_FILE="$T/VERSION" FAN_CONTROL_DRIVE_DEV_DIR="$T/dev" \
        FAN_CONTROL_OPTIMAL_PWM_FILE="$T/optimal" FAN_CONTROL_PID_FILE="$T/pid" \
        timeout 60 bash "$SCRIPT" >"$T/stdout" 2>&1 &
    echo $! >"$T/daemonpid"
    wait $!
    echo $? >"$T/rc"
) &
bg=$!
for _ in $(seq 1 100); do [[ -s "$T/sleeppid" ]] && break; /bin/sleep 0.1; done
start=$(date +%s)
# Signal only the daemon itself (its pid file). Signalling `timeout` would hit the
# whole process group, including the sleep, and hide the behaviour under test.
dpid=$(cat "$T/pid" 2>/dev/null)
[[ -n "$dpid" ]] && kill -TERM "$dpid" 2>/dev/null
wait "$bg"
elapsed=$(($(date +%s) - start))
if ((elapsed <= 3)); then pass "exited within ${elapsed}s"; else fail "slow exit (${elapsed}s)"; fi
assert_eq "EXIT_PWM written" "$(cat "$T/hwmon/hwmon0/pwm1")" "77"
sp=$(cat "$T/sleeppid" 2>/dev/null || echo 0)
assert_eq "background sleep gone" "$(kill -0 "$sp" 2>/dev/null && echo alive || echo gone)" "gone"

echo
if ((FAILURES > 0)); then
    echo "$FAILURES assertion(s) failed"
    exit 1
fi
echo "all assertions passed"
exit 0
