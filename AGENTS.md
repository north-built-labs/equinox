# Equinox working instructions

## Continuity from Claude Code

This project was handed from Claude Code to Codex on 2026-10-15. Follow
the working preferences below in this session and future sessions.

- Carry authorized development work through implementation and appropriate
  verification. Avoid unnecessary confirmation prompts; obey the active
  environment's permission and approval requirements.
- Keep commit and PR attribution free of automatic assistant credits or
  assistant session links (Claude's attribution settings were empty/disabled).
- Review changed code for security issues and simplify where it improves
  clarity. Report what was actually tested, including GUI or hardware limits.
- Consult current primary documentation when needed. Do not assume a Claude
  plugin or MCP tool is available just because it was enabled there.
- Read the relevant existing design and phase plan under
  `docs/superpowers/` before substantial feature work. Preserve established
  architecture and UI conventions.
- If a `CLAUDE.md` is added later, read it for shared project guidance too.

## Project

Equinox is a native macOS audio application, built with Swift Package Manager.
`Package.swift` targets macOS 15+, Swift tools 6.0 and Swift language mode 5.

- `Sources/EquinoxDSP`: signal processing.
- `Sources/EquinoxAudio`: Core Audio integration.
- `Sources/EquinoxCore`: application state and shared logic.
- `Sources/Equinox`: executable and UI.
- `Tests/`: DSP, audio and core tests.
- `scripts/build-app.sh --release`: packaged universal application.
- `swift test`: test suite; CI uses `swift test --skip AudioSystemTests`
  because hosted runners lack real audio hardware.
- `shellcheck install.sh scripts/*.sh`: shell lint used by CI.
- `scripts/verify-release.sh`: packaged app/release verification; read its
  arguments and environment requirements before using it.

## GitHub and releases

Repository: `north-built-labs/equinox`. Default branch: `main`.
Pull requests run lint and build checks. A push to `main` also starts the
release workflow, whose signing/publishing job uses the `production`
environment. Preserve that approval gate and signing protections.
Read `.github/workflows/release.yml` before modifying release behavior.
Check live GitHub state before claiming a PR, check or release is complete.

### Pull request bodies

All agents must use `.github/pull_request_template.md` when creating or
updating a PR, including through CLI or API tools that do not automatically
load the template. Keep its headings and order, replace the guidance with
concrete details, and remove HTML comments from the submitted body. Report
only validation actually performed; use "None identified" for risks when
applicable. Keep the title and body aligned with the final scope of the change.

## Handoff reference

Read `docs/claude-handoff.md` for the recovered project checkpoint and
configuration compatibility notes. Treat historical conversation claims as
context, and verify them against current files or live services.
