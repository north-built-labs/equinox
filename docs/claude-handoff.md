# Claude Code handoff — 2026-10-15

## Sources inspected

- `~/.claude/settings.json` and `~/.claude/settings.local.json`.
- Recent conversations in `~/.claude/projects/-Users-pie-Developer-equinox/`.
- Current package, release workflow and local git history.

No global or Equinox-specific `CLAUDE.md` was found at the inspected user,
Developer or repository roots. Equinox's Claude memory directory was empty.
The relevant durable guidance is now in the root `AGENTS.md`.

## Configuration mapping

| Claude setting | Codex handoff |
| --- | --- |
| Empty commit/PR attribution; no session URL | Recorded in `AGENTS.md` |
| Auto permission mode | Continue authorized work autonomously within this environment's actual permissions; Claude allowlists do not grant Codex permissions |
| frontend-design | Preserve existing UI conventions; plugin not installed by this handoff |
| context7 | Use available primary documentation tools; Claude MCP connection not migrated |
| superpowers | Existing project specs and plans remain under `docs/superpowers/`; plugin hooks not migrated |
| security-guidance | Security review preference recorded; plugin hooks not migrated |
| code-simplifier | Clarity/simplification preference recorded; plugin not installed |
| swift-lsp | Use available Swift compiler/tools; Claude LSP integration not migrated |
| claude-seo | Claude plugin remains installed there; not installed into Codex |
| Dark/fullscreen UI, status line, turn duration, auto-compaction | Claude UI settings not copied into Codex configuration |

Claude's global settings also contain Ontario Sunshine List/Railway policies
and local shell-diagnostic allowlists. These are unrelated to Equinox and
were not applied to this repository. No credentials were copied.
Global Codex configuration was left unchanged; this handoff is scoped to
Equinox. Claude's original settings and conversations remain unchanged.

## Recovered checkpoint

- PR #3 fixed idle background daemons appearing in the mixer. It was merged
  at `e290fe3`; the local history confirms that merge.
- PR #4 hardened releases: installer signature verification, pinned workflow
  actions, and provenance attestations. Local history confirms its merge at
  `e6f2f21`, which was HEAD at handoff.
- The latest substantive Claude discussion concerned solo-maintainer branch
  review settings and a production environment approval gate. The workflow
  currently targets `production`; actual GitHub protection settings were
  not queried during this configuration handoff.
- Earlier conversations mention successful lint/build/tests, but those are
  historical results. No application tests were rerun for this docs-only
  handoff, and no pending feature task was inferred or started.

Future work should begin from the user's next request and current repository
state, using this checkpoint to avoid repeating completed work.
