# Changelog

All notable changes to the UCG Max Fan Control project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0](https://github.com/ZZZColin/unifi-fan-control/compare/v1.2.2...v1.3.0) (2026-10-07)


### Features

* Add comprehensive logging for fan control operations ([f9807a4](https://github.com/ZZZColin/unifi-fan-control/commit/f9807a4cb05ccf54fad5b3f9790455fd8aaee434))
* Add external configuration file and enhance safety ([ae9e181](https://github.com/ZZZColin/unifi-fan-control/commit/ae9e1813502a7422e80927674467323ac1d43a1d))
* Add intelligent service management to installer ([6ae13ca](https://github.com/ZZZColin/unifi-fan-control/commit/6ae13ca3e47cfa80cee59a8d043787e9380b8194))
* add version identity and automated tagged releases ([#29](https://github.com/ZZZColin/unifi-fan-control/issues/29)) ([372168f](https://github.com/ZZZColin/unifi-fan-control/commit/372168f94ebf735c530be2793b25508fd2c34335))
* clarity ([42cf63f](https://github.com/ZZZColin/unifi-fan-control/commit/42cf63fba6c3aa91667912dc85b902d4e29a97e0))
* clarity on PWM steps ([fedf707](https://github.com/ZZZColin/unifi-fan-control/commit/fedf70758e513da2e8be6db1068ed2b8a4160220))
* Enhance logging with current and average temperatures ([9b1523c](https://github.com/ZZZColin/unifi-fan-control/commit/9b1523cc7481a056b59db78f56fa6680e867c997))
* Enhanced optimal PWM logic. Readme clarity. ([73f6b81](https://github.com/ZZZColin/unifi-fan-control/commit/73f6b81995b28b2eb19a72def32a4375542554c3))
* Fix locale issues. ([166cf20](https://github.com/ZZZColin/unifi-fan-control/commit/166cf20b1c89c2c915caffdd2d07a36f77e0367c))
* Fix locale issues. ([9548612](https://github.com/ZZZColin/unifi-fan-control/commit/95486125a61ea570700b5b91d84a487634f3a907))
* Fix locale issues. ([3d2de09](https://github.com/ZZZColin/unifi-fan-control/commit/3d2de09ee4f07f41fbf2171ee9fb435a12b8fdf2))
* Fix locale issues. ([a2d9798](https://github.com/ZZZColin/unifi-fan-control/commit/a2d979803ee45c9c4f0e70ce87880bc889c332f3))
* Fix locale issues. ([9ce0056](https://github.com/ZZZColin/unifi-fan-control/commit/9ce0056e641f68dbceef49ac043dcda4bbeeeee4))
* Implement three-state fan control logic with rolling average and taper period ([72de836](https://github.com/ZZZColin/unifi-fan-control/commit/72de836c4869dfea7728b30d53eb50fbd485f519))
* Improve error handling with atomic writes and logging ([f027d5d](https://github.com/ZZZColin/unifi-fan-control/commit/f027d5d0816b242c33487a9bae619ef67b6869d4))
* Improved error handling and structure ([e89185d](https://github.com/ZZZColin/unifi-fan-control/commit/e89185d29d48083a79215c01d15aef6ad67bca38))
* Integrate Covert-Agenda's heuristic logic and streamline README ([ebe8e2e](https://github.com/ZZZColin/unifi-fan-control/commit/ebe8e2e1c68db9e82c63b9e87613ea998eac12ed))
* log the deployed fan-control version ([476d02c](https://github.com/ZZZColin/unifi-fan-control/commit/476d02c3fd38fcd82ac3ad896c7cd92722cbf74d))
* logging limits ([99efddc](https://github.com/ZZZColin/unifi-fan-control/commit/99efddccd84706cbfb2d832e89029cd183ee62b8))
* overhaul fan control algorithm and logging ([ddb380c](https://github.com/ZZZColin/unifi-fan-control/commit/ddb380c9f01f9592ffb27c9d7e2b85f70174584e))
* Refactor temperature smoothing and PWM logic for better precision and reliability ([77dd413](https://github.com/ZZZColin/unifi-fan-control/commit/77dd4133bb70436940e72e6bd2be2775b33f1416))
* use drive temperature as an independent PWM floor ([#38](https://github.com/ZZZColin/unifi-fan-control/issues/38)) ([aa46301](https://github.com/ZZZColin/unifi-fan-control/commit/aa46301f934d25922d5acba6c2c967bcb4e5e2c9))
* verify release downloads before installing ([36bcb31](https://github.com/ZZZColin/unifi-fan-control/commit/36bcb31241c9dc873cd7a869cc3356efe13a3a81))
* verify release downloads before installing ([#32](https://github.com/ZZZColin/unifi-fan-control/issues/32)) ([0cb6750](https://github.com/ZZZColin/unifi-fan-control/commit/0cb6750038881883af6ab102b652bb0b15de1a24))


### Bug Fixes

* accept SemVer prerelease versions in the startup log ([435edc2](https://github.com/ZZZColin/unifi-fan-control/commit/435edc24d2ad9c56aaea8d0d017531f52a805758))
* bound archive size before decompression and install ([bac93be](https://github.com/ZZZColin/unifi-fan-control/commit/bac93be172b69ed4460f2ba214a5a0907232f78c))
* clamp sub-activation temp_diff so fan does not speed up while cooling ([9beba63](https://github.com/ZZZColin/unifi-fan-control/commit/9beba63f7f7cc6564b9546c740d84c4725a6ed03)), closes [#26](https://github.com/ZZZColin/unifi-fan-control/issues/26)
* clamp sub-activation temp_diff so fan does not speed up while cooling ([#26](https://github.com/ZZZColin/unifi-fan-control/issues/26)) ([c2c6c51](https://github.com/ZZZColin/unifi-fan-control/commit/c2c6c51bb6350017efc1becd925ee1ace0f6daf7))
* compute real |saved-raw| absolute difference in saved-temp bootstrap ([#22](https://github.com/ZZZColin/unifi-fan-control/issues/22)) ([8c82c2a](https://github.com/ZZZColin/unifi-fan-control/commit/8c82c2aad408c1f0021b8c8ae27b1024a660c5b5))
* Correct variable handling in fan control transitions ([b7f90c2](https://github.com/ZZZColin/unifi-fan-control/commit/b7f90c24a1474d63598e63b03880417c8034d370))
* curve ([cfa5071](https://github.com/ZZZColin/unifi-fan-control/commit/cfa5071eb075d84a314505db107f8c0784e073e6))
* curve ([358c84b](https://github.com/ZZZColin/unifi-fan-control/commit/358c84b7f2a7a5c7997a2962a64739dc7c8eb2c8))
* curve ([9d2bc8b](https://github.com/ZZZColin/unifi-fan-control/commit/9d2bc8b5a84220d0e99ad9f9c2f0066d17c18f11))
* curve ([2456d0a](https://github.com/ZZZColin/unifi-fan-control/commit/2456d0a857245bf0c7657baaa05957c139bbf205))
* diagnose install failures precisely and harden the tar header walk ([#44](https://github.com/ZZZColin/unifi-fan-control/issues/44)) ([a014711](https://github.com/ZZZColin/unifi-fan-control/commit/a0147114001ad1f2c905a445385bd8eada0e4f60))
* drive floor follows the hottest drive across all readable drives ([#43](https://github.com/ZZZColin/unifi-fan-control/issues/43)) ([8859849](https://github.com/ZZZColin/unifi-fan-control/commit/885984983db81dc09b08669472dc9c17505df5d4))
* Ensure fan PWM is set to 0 during uninstallation to prevent unintended behavior ([24c7fd9](https://github.com/ZZZColin/unifi-fan-control/commit/24c7fd9bb20e9ee7aa8c089a29173268a22de4a7))
* keep fans stopped at startup under control and cut steady-state log volume ([#47](https://github.com/ZZZColin/unifi-fan-control/issues/47)) ([a3e310b](https://github.com/ZZZColin/unifi-fan-control/commit/a3e310bde286659f43ca6c3da9298eaee7d8a968)), closes [#42](https://github.com/ZZZColin/unifi-fan-control/issues/42) [#46](https://github.com/ZZZColin/unifi-fan-control/issues/46)
* logging ([70ae391](https://github.com/ZZZColin/unifi-fan-control/commit/70ae39102ca5e3f90b902b7a716ae145b67fc5b1))
* logging ([e87be52](https://github.com/ZZZColin/unifi-fan-control/commit/e87be5280c4a1f991174599518612ebc180b17c9))
* logging ([609db7e](https://github.com/ZZZColin/unifi-fan-control/commit/609db7e0cc090b202cef2f61a6301287c382e0a5))
* logging ([372a9d4](https://github.com/ZZZColin/unifi-fan-control/commit/372a9d41e584d3524eee17f2bfaed326734c2929))
* logging ([1306346](https://github.com/ZZZColin/unifi-fan-control/commit/1306346b7a95263be0a680ab98b87fce38c60c86))
* make test harness stubs portable across bash images ([cc379b7](https://github.com/ZZZColin/unifi-fan-control/commit/cc379b78da10ba098a2b94189a3a6dd37a6710d6))
* min pwm ([2cc66b5](https://github.com/ZZZColin/unifi-fan-control/commit/2cc66b5fd3df05f9129fc3614651d39dfd5d607d))
* off state ([6f9f819](https://github.com/ZZZColin/unifi-fan-control/commit/6f9f819b82c3c6f09f4628a18ff4f622f10a4c57))
* PID ([f3a069c](https://github.com/ZZZColin/unifi-fan-control/commit/f3a069ce274c19db29d05a899080e24eb6af3040))
* register cleanup trap and instance lock in parent shell, make sensor fail-safe fire ([#17](https://github.com/ZZZColin/unifi-fan-control/issues/17), [#18](https://github.com/ZZZColin/unifi-fan-control/issues/18)) ([281e49a](https://github.com/ZZZColin/unifi-fan-control/commit/281e49a51abf37063a905978690c063ba613fcdf))
* Replace incorrect temperature unit symbols in logs ([c7ad108](https://github.com/ZZZColin/unifi-fan-control/commit/c7ad108d1ad5dec42d5880b6cfbb4cd6039d4df5))
* resolve substantive shellcheck findings ([b1824dc](https://github.com/ZZZColin/unifi-fan-control/commit/b1824dc2f36d8bb427dba5a23d0b0ef222817d5a))
* restrict install and config permissions ([d8c6f5d](https://github.com/ZZZColin/unifi-fan-control/commit/d8c6f5da2051a28d86f676e7de10859207b8a9ed))
* safety trap, sensor fail-safe, and test suite ([#17](https://github.com/ZZZColin/unifi-fan-control/issues/17), [#18](https://github.com/ZZZColin/unifi-fan-control/issues/18)) ([6959dc5](https://github.com/ZZZColin/unifi-fan-control/commit/6959dc59516deadd6403139fa0370b3347b5060e))
* start temp ([6da8722](https://github.com/ZZZColin/unifi-fan-control/commit/6da8722fa895570b5fa01310814446b37e60658c))
* suppress core dump when the archive size cap trips ([93240fa](https://github.com/ZZZColin/unifi-fan-control/commit/93240fa3beea30241c8a837ebe366d9f303de1ae))

## [1.2.2](https://github.com/iceteaSA/unifi-fan-control/compare/v1.2.1...v1.2.2) (2026-08-09)


### Bug Fixes

* keep fans stopped at startup under control and cut steady-state log volume ([#47](https://github.com/iceteaSA/unifi-fan-control/issues/47)) ([a3e310b](https://github.com/iceteaSA/unifi-fan-control/commit/a3e310bde286659f43ca6c3da9298eaee7d8a968)), closes [#42](https://github.com/iceteaSA/unifi-fan-control/issues/42) [#46](https://github.com/iceteaSA/unifi-fan-control/issues/46)

## [1.2.1](https://github.com/iceteaSA/unifi-fan-control/compare/v1.2.0...v1.2.1) (2026-08-09)


### Bug Fixes

* diagnose install failures precisely and harden the tar header walk ([#44](https://github.com/iceteaSA/unifi-fan-control/issues/44)) ([a014711](https://github.com/iceteaSA/unifi-fan-control/commit/a0147114001ad1f2c905a445385bd8eada0e4f60))
* drive floor follows the hottest drive across all readable drives ([#43](https://github.com/iceteaSA/unifi-fan-control/issues/43)) ([8859849](https://github.com/iceteaSA/unifi-fan-control/commit/885984983db81dc09b08669472dc9c17505df5d4))

## [Unreleased]

### Fixed

* Diagnose failed verified-release downloads by curl failure class. DNS failures
  now name the failing host and explain GitHub's release-asset redirect.
* Add a tag-scoped `FAN_CONTROL_ALLOW_UNVERIFIED` fallback for a verified download
  that cannot complete. The fallback is explicit and still validates its payload.

## [1.2.0](https://github.com/iceteaSA/unifi-fan-control/compare/v1.1.1...v1.2.0) (2026-08-09)


### Features

* use drive temperature as an independent PWM floor ([#38](https://github.com/iceteaSA/unifi-fan-control/issues/38)) ([aa46301](https://github.com/iceteaSA/unifi-fan-control/commit/aa46301f934d25922d5acba6c2c967bcb4e5e2c9))

## [1.1.1](https://github.com/iceteaSA/unifi-fan-control/compare/v1.1.0...v1.1.1) (2026-08-09)


### Bug Fixes

* restrict install and config permissions ([d8c6f5d](https://github.com/iceteaSA/unifi-fan-control/commit/d8c6f5da2051a28d86f676e7de10859207b8a9ed))

## [1.1.0](https://github.com/iceteaSA/unifi-fan-control/compare/v1.0.0...v1.1.0) (2026-08-09)


### Features

* verify release downloads before installing ([#32](https://github.com/iceteaSA/unifi-fan-control/issues/32)) ([0cb6750](https://github.com/iceteaSA/unifi-fan-control/commit/0cb6750038881883af6ab102b652bb0b15de1a24))

## 1.0.0 (2026-08-09)

First tagged release. The code has been running on people's routers for months
— what's new is that it now has a version number, verified downloads, and a
test suite. Everything below is relative to installing from `main` before today.

### Four cooling bugs fixed

* **Fan sped up as the device cooled** ([#26](https://github.com/iceteaSA/unifi-fan-control/issues/26)) — `calculate_speed` squared a signed `temp_diff`, mirroring the response curve below the activation temperature. Between `MIN_TEMP` and `FAN_ACTIVATION_TEMP` the fan got *louder* as the router got cooler, and 60 °C produced the same PWM as 70 °C. A reporter measured 603 PWM writes in 21 hours on an idle UCG-Fiber.
* **Sensor fail-safe never fired** ([#18](https://github.com/iceteaSA/unifi-fan-control/issues/18)) — `get_smoothed_temp` was called through `$(...)`, so its failure counter and smoothed temperature died in the subshell. The 3-strike fail-safe that forces `MAX_PWM` on sensor failure was unreachable code, and temperature smoothing never accumulated.
* **Cleanup trap fired at startup** ([#17](https://github.com/iceteaSA/unifi-fan-control/issues/17)) — the trap and `flock` were registered inside a subshell that exited immediately, so the PID file was deleted at launch, exit cleanup never ran, and the single-instance guard did nothing.
* **Stale temperature reused on hot restart** ([#22](https://github.com/iceteaSA/unifi-fan-control/issues/22)) — the guard on the persisted temperature stripped the minus sign from each operand instead of computing `|saved - raw|`, so it only protected one direction. A hot boot with a stale low value kept the fan off for a full check interval.

### Verified installs

* Releases are tagged, and each one ships a tarball plus `SHA256SUMS`.
* `install.sh` downloads, verifies the checksum, validates every archive entry, and syntax-checks the scripts before anything is written to `/data`. Archive entries are checked by raw tar header, not just filename, so an archive carrying a symlink under a legitimate name is rejected.
* Pin a version with `FAN_CONTROL_VERSION=v1.0.0`; omit it to get the latest release.
* Previously the installer fetched loose files from `main`, and a 404 could be written to disk and executed as root, because `curl` was called without `-f`.

### Version identity

The daemon logs `CONFIG: fan-control vX.Y.Z starting`, and `VERSION` is installed alongside it. Previously there was no way to tell which build a device was running short of hashing the script against git history.

### Testing and CI

* 11 sandboxed tests that need no device and no root, including a regression test per bug above.
* CI runs them on bash 4.4, 5.1, 5.2 and native Ubuntu, all under mawk — matching the UCG-Max, which runs bash 5.1.4 and mawk 1.3.4.
* shellcheck and shfmt are enforced at zero findings.

## [Unreleased]

### Added
- Tagged release automation with verified runtime tarballs and `SHA256SUMS`.
- Verified release installation with latest-release resolution and
  `FAN_CONTROL_VERSION` pinning.
- Archive allowlist, checksum, syntax, and rollback validation before installer
  files replace the running deployment.
- `VERSION` identity file and startup logging for the deployed daemon version.
- Test suite (`tests/`) — sandboxed, no-root, dependency-free bash tests covering config bootstrap, PWM detection, state machine, and regression tests for #17 and #18.
- Env-var seams for testability: `FAN_CONTROL_CONFIG_FILE`, `FAN_CONTROL_TEMP_STATE_FILE`, `FAN_CONTROL_PID_FILE`, `FAN_CONTROL_OPTIMAL_PWM_FILE`, `FAN_CONTROL_HWMON_BASE`.
- CONTRIBUTING.md with contribution guidelines
- CHANGELOG.md for tracking version history
- TROUBLESHOOTING.md for common issues and solutions
- SECURITY.md for security policy
- CODE_OF_CONDUCT.md for community guidelines
- GitHub issue templates for bug reports and feature requests
- GitHub pull request template

### Fixed
- [#17](https://github.com/iceteaSA/unifi-fan-control/issues/17): Lock and cleanup trap were registered in a subshell that exited immediately. Moved `flock` and `trap` to the parent shell so the lock is held for the daemon's lifetime, cleanup runs on actual exit, and single-instance guard is authoritative.
- [#18](https://github.com/iceteaSA/unifi-fan-control/issues/18): `get_smoothed_temp` was called via `$(...)`, losing `TEMP_READ_FAILURES` and `SMOOTHED_TEMP` mutations in subshells. Rewrote to communicate via globals; added a sensor fail-safe in `update_fan_state` that forces `MAX_PWM` after 3 consecutive read failures, bypassing state-machine and ramp limits.
- Fan speed no longer increases as the device cools below the activation temperature; the quadratic curve now clamps sub-activation `temp_diff` to zero (#26).
- Saved-temp bootstrap used `(( ${saved_temp#-} - ${raw_temp#-} < 15 ))` to guard against re-initialising to a stale persisted smoothed temp. The `${var#-}` form strips a leading minus from *each operand independently* and does **not** compute `|saved - raw|`, so only the `saved > raw` direction was guarded. On a hot restart with a stale low saved temp (`raw > saved`), the difference was negative, always `< 15`, and `SMOOTHED_TEMP` was re-initialised to the stale low value — leaving the coldstart fan-OFF decision at line 774 to run against a too-low temp and keeping the fan OFF for one full `CHECK_INTERVAL`. Replaced with a real absolute difference; added `tests/test_regression_saved_temp_bootstrap.sh`.

## Recent Changes (Based on Git History)

### [2025-01-13] - Enhanced Reliability and Precision

#### Changed
- Removed locale settings and enhanced temperature smoothing precision
- Refactored temperature smoothing and PWM logic for better precision and reliability
- Improved error handling with atomic writes and logging

#### Fixed
- Ensured fan PWM is set to 0 during uninstallation to prevent unintended behavior

### Previous Features

#### Temperature Management
- Four operational states: OFF, TAPER, ACTIVE, EMERGENCY
- Quadratic response curve for progressive cooling
- Exponential smoothing for noise-resistant temperature tracking
- State transition hysteresis to prevent rapid oscillation

#### Safety Systems
- Emergency override for critical temperatures
- Speed limits and thermal protection
- Hardware validation on startup
- Sensor failure detection and recovery
- Configuration validation with automatic correction

#### Adaptive Learning
- Enhanced adaptive learning system
- Intelligent PWM optimization
- Temperature trend analysis
- Efficiency optimization strategies

#### Configuration
- User-configurable temperature thresholds
- Adjustable fan speed ranges
- Customizable smoothing factors
- Flexible check intervals and taper duration

#### Installation
- One-line installation command
- Support for branch-specific installations
- Smart service management (fresh install or hot update)
- Automatic configuration file creation with defaults

#### Monitoring
- Comprehensive logging system
- Real-time status updates
- Temperature delta tracking
- Learning activity logs
- Configuration change notifications

---

## Version History Format

Future releases will follow this format:

## [X.Y.Z] - YYYY-MM-DD

### Added
- New features

### Changed
- Changes in existing functionality

### Deprecated
- Soon-to-be removed features

### Removed
- Removed features

### Fixed
- Bug fixes

### Security
- Security improvements or fixes

---

**Note**: This changelog was created on 2025-11-13. Previous changes were reconstructed from git commit history and README documentation.
