# Changelog

Releases are Fly versions of the `siwa-server` app, newest first, each with the commit it runs.
Every commit to main adds a line under Unreleased; a release moves those lines under its version.

## Unreleased

- Keyfleet's code host, `https://code.keyfleet.ai`, signs in under the `keyfleet` audience, so the agent helper
  can sign in to Keyfleet's Git gateway there.

## v62 — beba083 (2026-10-17 01:12Z)

- The Touch ID page in both agent helpers is rebuilt from its sources, `assets/agent/passkey.js` and
  design-system f9b0e25 (whose `standalone/agent-key.html` now has the opener and close-this-page lines), so
  `scripts/build_agent_page.py --check` passes again. Only the bundled colour tokens change; every colour and
  font the page shows stays the same in light and dark.
- The Touch ID page's script source (`assets/agent/passkey.js`) carries the v61 page changes.
- Started this changelog.

## v61 — 37e2a85 (2026-10-16 16:14Z)

- The Touch ID page in the agent helpers (`/agent/siwa_agent.py`, `/agent/siwa-agent.mjs`) says which agent
  opened it: "Opened by Claude Code", Codex, Cursor, Gemini CLI, Hermes or OpenCode, found from the helper's
  parent processes; any other app, or a process list that cannot be read, shows "Opened by your agent".
- After Touch ID the page says "You can safely close this page" under the finished button; the three result
  lines no longer end with "You can close this tab."
- The Node helper reads the whole process list (Node's 1 MiB output limit broke on busy Macs).
- The page details are escaped inside the page script.
- Python bytecode is ignored (`__pycache__/`), and a stray copy was removed from the served folder.

## v60 — e9a822d (2026-10-16 06:23Z)

- Hosted signing serves Patchbay only; the template's hosted routes are gone.
- Hosted signing allows 300 requests a minute per caller, which stays inside one CPU.
- `fly.toml` notes that the key store and hosted signers need exactly one machine.

## v59 — bd29db2 (2026-10-16 06:15Z)

- Hosted ChatGPT connections' requests are signed through the keyring, with each site's own hosted key, and
  every signature is bound to the calling site.
- Shared libraries pinned to elixir-utils 17141b2.

## v58 — 37a9c4e (2026-10-16 05:23Z)

- Bandit 1.13.1 closes two web-server advisories; other dependencies moved to their latest compatible versions.

## v57 — 530fbb6 (2026-10-16 04:04Z)

- One sign-in audience may list several origins; Keyfleet's Regents Club notebooks sign in under `keyfleet`.
- `/readyz` answers only `ready` and the per-check flags; failure reasons go to the log.
- The AgentBook challenge description is quoted so the contract is valid YAML; `repo.yaml` no longer names a
  missing file.
