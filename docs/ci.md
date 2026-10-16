# CI and release safeguards

`.github/workflows/release.yml` validates every pull request and push to
`main`, manual runs, and merge-queue groups. A weekly run catches changes in
hosted runners and toolchains even when application code has not changed.
There are no path filters that can bypass validation.

The `CI` job is the combined validation result. It fails if any prerequisite
fails, is cancelled, or is skipped. Publishing requires this job and the
packaged build to succeed, then approval through the existing `production`
environment. Scheduled, manual, PR, and merge-queue runs never publish.

Checks:

- ShellCheck checks the installer and every shell script. actionlint v1.7.12
  checks workflow syntax, expressions, action inputs, and embedded shell.
  Go's module checksum verification authenticates the pinned actionlint version.
- The hardware-independent Swift suite runs in debug and release mode on
  macOS 15 (minimum supported OS) and macOS 26. Matrix failures do not cancel
  the other configurations. Only the three AudioSystem tests that enumerate
  hardware/process objects are excluded; exclusion-list validation still runs.
- DSP tests also run with Address Sanitizer to catch invalid memory access.
- The universal arm64/x86_64 release app is built and checked for bundle
  identity, version, architecture, code signature, and installer key alignment.
- Installer checks accept a valid throwaway signature and reject tampered,
  unsigned, and wrong-key archives. Failed updates must preserve the existing
  app. Uninstall must remove it.
- Release-version regression tests cover initial releases, explicit bumps,
  patch increments, local overrides, API failures, and partial API failures.
- Tests retain console logs and any toolchain-generated xUnit results for
  14 days, including failed runs. Missing build artifacts fail the build instead of issuing a warning.

Jobs use the runner's default Xcode and print toolchain versions. They do not
select the newest installed Xcode, which can unexpectedly select a preview.
Actions remain pinned to full commit hashes and updated by Dependabot.
Checkouts do not persist credentials; only the protected release job receives
write/attestation permissions and the signing step receives signing keys.

Release lookups fail on API/authentication/download errors. Only a successful
empty stable-release listing permits a first-release verification against a
version-stamped copy of the current app. Otherwise the actual previously
published app must accept the signed update before publication. Both updater
and installer signatures and provenance attestation remain required.

## Repository settings

Workflow files alone cannot enforce merging rules. In the `main` ruleset or
branch protection settings, require the `CI` status check from GitHub Actions,
require the branch to be up to date (or use the merge queue), block force
pushes/deletion, and restrict bypass permissions. Keep existing required
checks until `CI` has appeared in a successful run, then update the required
checks deliberately. Preserve production's required reviewer and main-only
deployment policy. These server settings must be audited separately with a
working authenticated GitHub session.

## Local verification and limits

Run `actionlint`, `shellcheck install.sh scripts/*.sh`,
`bash scripts/test-release-version.sh`, and
`swift test --skip 'AudioSystemTests.test(Lists|Resolves)'`.
Use `-c release` for optimized tests, or
`--sanitize address --filter EquinoxDSPTests` for DSP memory checks.

Hosted CI cannot validate permission prompts, real process taps, output-device
switching, audible glitches/latency, or interactive UI behavior. Those still
need a real Mac and audio hardware; `scripts/self-test.sh` exercises live audio
and snapshots. Do not run that hardware test on hosted runners or skip failing
automated tests to substitute for it. Cross-OS/toolchain results and release
signing must be verified on GitHub; a local test run cannot establish them.
