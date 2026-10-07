#!/bin/bash
###############################################################################
# install.sh flow tests: rollback behaviour, health wait, hash pin.
# Uses a fake systemctl and mktemp directories only. install.sh insists on
# root, so a copy without that single check is used.
###############################################################################
set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

FAILURES=0
pass() { echo "    ok: $1"; }
fail() {
    echo "    FAIL: $1"
    FAILURES=$((FAILURES + 1))
}
assert_eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (expected '$3', got '$2')"; }
assert_not_contains() { grep -qF -- "$3" <<<"$2" && fail "$1 (unexpected '$3')" || pass "$1"; }
assert_contains() { grep -qF -- "$3" <<<"$2" && pass "$1" || fail "$1 (missing '$3')"; }

TMP_DIRS=()
cleanup_tmp() {
    if ((${#TMP_DIRS[@]} > 0)); then
        rm -rf "${TMP_DIRS[@]}"
    fi
}
trap cleanup_tmp EXIT

# new_world: fresh sandbox in $W with a payload directory src/ and a fake systemctl.
# FAKE_FAILSTART=1 makes the "service" die right after it is started.
new_world() {
    W=$(mktemp -d)
    TMP_DIRS+=("$W")
    mkdir -p "$W/src" "$W/bin" "$W/state" "$W/inst" "$W/svc"
    cp "$REPO_ROOT/fan-control.sh" "$REPO_ROOT/uninstall.sh" "$REPO_ROOT/fan-control.service" "$W/src/"
    echo 9.9.9 >"$W/src/VERSION"
    sed 's/if \[\[ "\$(id -u)" -ne 0 \]\]; then/if false; then/' "$REPO_ROOT/install.sh" >"$W/src/install.sh"
    cat >"$W/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$W_LOG"
case "$1" in
    is-active) [ -f "$W_STATE/active" ] && exit 0 || exit 1 ;;
    is-enabled) [ -f "$W_STATE/enabled" ] && exit 0 || exit 1 ;;
    enable) touch "$W_STATE/enabled"; [ "${FAKE_FAILSTART:-0}" = 1 ] || touch "$W_STATE/active"; exit 0 ;;
    disable) rm -f "$W_STATE/enabled"; exit 0 ;;
    stop) rm -f "$W_STATE/active"; exit 0 ;;
    restart) if [ "${FAKE_FAILSTART:-0}" = 1 ]; then rm -f "$W_STATE/active"; else touch "$W_STATE/active"; fi; exit 0 ;;
    show) echo 0; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$W/bin/systemctl"
}

# run_install [ENV=VALUE ...]: run the sandboxed installer from a throwaway cwd.
run_install() {
    (
        cd "$W" || exit 1
        env PATH="$W/bin:$PATH" W_LOG="$W/log" W_STATE="$W/state" \
            FAN_CONTROL_INSTALL_DIR="$W/inst" FAN_CONTROL_SERVICE_FILE="$W/svc/fan-control.service" \
            FAN_CONTROL_SYSTEMCTL="$W/bin/systemctl" FAN_CONTROL_ALLOW_CHOWN_FAILURE=1 \
            FAN_CONTROL_HEALTH_WAIT=2 "$@" bash "$W/src/install.sh" 2>&1
    )
}

echo "[I1] Fresh install succeeds and enables the service"
new_world
out=$(run_install)
assert_contains "success message" "$out" "Installation successful"
assert_eq "script installed" "$([[ -x "$W/inst/fan-control.sh" ]] && echo yes || echo no)" "yes"
assert_eq "version recorded" "$(cat "$W/inst/VERSION")" "9.9.9"
assert_eq "enabled" "$([[ -f "$W/state/enabled" ]] && echo yes || echo no)" "yes"

echo "[I2] Failed update restores the old files and keeps the service enabled"
new_world
echo OLDSCRIPT >"$W/inst/fan-control.sh"
echo 0.0.1 >"$W/inst/VERSION"
echo OLDUNIT >"$W/svc/fan-control.service"
touch "$W/state/active" "$W/state/enabled"
out=$(run_install FAKE_FAILSTART=1)
assert_contains "failure reported" "$out" "did not become active and stay running"
assert_eq "old script back" "$(head -1 "$W/inst/fan-control.sh")" "OLDSCRIPT"
assert_eq "old version back" "$(cat "$W/inst/VERSION")" "0.0.1"
assert_eq "old unit back" "$(head -1 "$W/svc/fan-control.service")" "OLDUNIT"
assert_eq "still enabled" "$([[ -f "$W/state/enabled" ]] && echo yes || echo no)" "yes"

echo "[I3] Failed fresh install leaves nothing behind and is disabled"
new_world
out=$(run_install FAKE_FAILSTART=1)
assert_contains "failure reported" "$out" "did not become active and stay running"
assert_eq "no script" "$([[ -e "$W/inst/fan-control.sh" ]] && echo present || echo gone)" "gone"
assert_eq "no unit" "$([[ -e "$W/svc/fan-control.service" ]] && echo present || echo gone)" "gone"
assert_eq "disabled" "$([[ -f "$W/state/enabled" ]] && echo yes || echo no)" "no"

echo "[I4] An enabled but stopped service stays enabled when the update fails"
new_world
echo OLD >"$W/inst/fan-control.sh"
echo 0.0.1 >"$W/inst/VERSION"
echo OLDUNIT >"$W/svc/fan-control.service"
touch "$W/state/enabled"
run_install FAKE_FAILSTART=1 >/dev/null
assert_eq "still enabled" "$([[ -f "$W/state/enabled" ]] && echo yes || echo no)" "yes"
assert_eq "old script back" "$(head -1 "$W/inst/fan-control.sh")" "OLD"

echo "[I5] A failure in the middle of replacing files never deletes an original that was not replaced"
new_world
echo O1 >"$W/inst/fan-control.sh"
echo O2 >"$W/inst/uninstall.sh"
echo O3 >"$W/svc/fan-control.service"
echo 0.0.1 >"$W/inst/VERSION"
# Make the third replacement fail
sed -i 's/if ! mv "\${NEW_FILES\[\$index\]}" "\${DESTINATIONS\[\$index\]}"; then/if [[ $index == 2 ]] || ! mv "${NEW_FILES[$index]}" "${DESTINATIONS[$index]}"; then/' "$W/src/install.sh"
out=$(run_install)
assert_contains "failure reported" "$out" "Failed to replace installation files"
assert_eq "script untouched" "$(cat "$W/inst/fan-control.sh")" "O1"
assert_eq "uninstall untouched" "$(cat "$W/inst/uninstall.sh")" "O2"
assert_eq "unit untouched" "$(cat "$W/svc/fan-control.service")" "O3"
assert_eq "version untouched" "$(cat "$W/inst/VERSION")" "0.0.1"

echo "[I6] The hash pin cannot be silently ignored; bad HEALTH_WAIT is rejected"
new_world
pin=$(printf 'a%.0s' $(seq 1 64))
out=$(run_install FAN_CONTROL_EXPECTED_SHA256="$pin")
assert_contains "local files: pin ignored with a warning" "$out" "only applies to release downloads"
new_world
# Local payload files take priority over a branch install, so run the installer
# from a directory that has no payload next to it.
mkdir -p "$W/solo"
cp "$W/src/install.sh" "$W/solo/install.sh"
out=$(
    cd "$W" || exit 1
    env PATH="$W/bin:$PATH" W_LOG="$W/log" W_STATE="$W/state" \
        FAN_CONTROL_INSTALL_DIR="$W/inst" FAN_CONTROL_SERVICE_FILE="$W/svc/fan-control.service" \
        FAN_CONTROL_SYSTEMCTL="$W/bin/systemctl" FAN_CONTROL_BRANCH=x FAN_CONTROL_EXPECTED_SHA256="$pin" \
        bash "$W/solo/install.sh" 2>&1
)
assert_contains "branch install: pin refused" "$out" "cannot be applied to an unverified install"
new_world
out=$(run_install FAN_CONTROL_HEALTH_WAIT='1;ls')
assert_contains "bad HEALTH_WAIT rejected" "$out" "must be a non-negative integer"

echo "[I7] Unit loses WatchdogSec/NotifyAccess when systemd-notify is missing"
new_world
# Hide systemd-notify by running with a minimal PATH that still has the basics
mkdir -p "$W/minbin"
for c in bash sh cat cp mv rm mkdir chmod chown sed grep awk tr wc dd od cmp diff sort tar gzip curl sha256sum mktemp dirname basename head tail id sleep ls env ln date readlink touch tee printf echo; do
    p=$(command -v "$c" 2>/dev/null) && [[ -x "$p" ]] && ln -sf "$p" "$W/minbin/$c"
done
out=$(
    cd "$W" || exit 1
    env PATH="$W/bin:$W/minbin" W_LOG="$W/log" W_STATE="$W/state" \
        FAN_CONTROL_INSTALL_DIR="$W/inst" FAN_CONTROL_SERVICE_FILE="$W/svc/fan-control.service" \
        FAN_CONTROL_SYSTEMCTL="$W/bin/systemctl" FAN_CONTROL_ALLOW_CHOWN_FAILURE=1 \
        FAN_CONTROL_HEALTH_WAIT=0 "$W/minbin/bash" "$W/src/install.sh" 2>&1
)
assert_contains "warning printed" "$out" "systemd-notify not found"
assert_eq "WatchdogSec removed" "$(grep -c '^WatchdogSec=' "$W/svc/fan-control.service")" "0"
assert_eq "NotifyAccess removed" "$(grep -c '^NotifyAccess=' "$W/svc/fan-control.service")" "0"

echo "[I8] Zero-padded HEALTH_WAIT is accepted as decimal"
new_world
out=$(run_install FAN_CONTROL_HEALTH_WAIT=08)
assert_contains "installs with 08" "$out" "Installation successful"
assert_not_contains "no arithmetic error" "$out" "value too great for base"

new_world
out=$(run_install FAN_CONTROL_HEALTH_WAIT=99999999999999999999)
assert_contains "huge HEALTH_WAIT rejected" "$out" "too large"
new_world
out=$(run_install FAN_CONTROL_HEALTH_WAIT=000)
assert_contains "all-zero HEALTH_WAIT accepted" "$out" "Installation successful"

echo
if ((FAILURES > 0)); then
    echo "$FAILURES assertion(s) failed"
    exit 1
fi
echo "all assertions passed"
exit 0
