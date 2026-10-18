# Changelog

What changed for agents, people and sites, newest first. Every change to main adds a line under Unreleased;
a release moves those lines under its date. Which version and commit each release ran is in `RELEASES.md`.

## Unreleased

- A signed request that carries every signature header but whose signature doesn't verify is told that, in its
  hint, instead of being told its headers are missing. Only a request without them hears they are missing.
- The Touch ID page is shorter and plainer: one label saying which agent opened it, the step, one sentence
  and the button. The "Why localhost?" and pairing paragraphs are gone, the message for the agent is two
  sentences at the bottom and disappears once Touch ID is done, and the finished line and errors share one
  reserved line. Finishing or failing moves nothing on the page, at any width. A browser error other than a
  cancel or timeout shows one plain line; its own words go to the browser log.
- Both agent helpers print the same help (`--help`), without the `key-helper` command they start themselves,
  and answer an unknown command with the same JSON error. `--help` or `-h` anywhere on the line shows that
  help and runs nothing, so `keygen --force --help` no longer replaces the key in the Node helper. The Python
  helper answers every wrong command line as JSON on stderr, like the Node one.
- Keyfleet's code host, `https://code.keyfleet.ai`, signs in under the `keyfleet` audience, so the agent helper
  can sign in to Keyfleet's Git gateway there.

## 17 October 2026

- The Touch ID page in both agent helpers is rebuilt from its sources. Every colour and font it shows stays the
  same in light and dark.

## 16 October 2026

- The Touch ID page in the agent helpers (`/agent/siwa_agent.py`, `/agent/siwa-agent.mjs`) says which agent
  opened it: "Opened by Claude Code", Codex, Cursor, Gemini CLI, Hermes or OpenCode, found from the helper's
  parent processes; any other app, or a process list that cannot be read, shows "Opened by your agent".
- After Touch ID the page says "You can safely close this page" under the finished button; the three result
  lines no longer end with "You can close this tab."
- The Node helper reads the whole process list (Node's 1 MiB output limit broke on busy Macs).
- The page details are escaped inside the page script.
- A stray copy of compiled Python was removed from the served folder.
- Hosted signing serves Patchbay only; the template's hosted routes are gone.
- Hosted signing allows 300 requests a minute per caller.
- Hosted ChatGPT connections' requests are signed through the keyring, with each site's own hosted key, and
  every signature is bound to the calling site.
- Bandit 1.13.1 closes two web-server advisories; other dependencies moved to their latest compatible versions.
- One sign-in audience may list several origins; Keyfleet's Regents Club notebooks sign in under `keyfleet`.
- `/readyz` answers only `ready` and the per-check flags; failure reasons go to the log.
- The AgentBook challenge description is quoted so the published contract is valid YAML.
