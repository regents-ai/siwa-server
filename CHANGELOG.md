# Changelog

What changed for agents, people and sites, newest first. Every change to main adds a line under Unreleased;
a release moves those lines under its date. Which version and commit each release ran is in `RELEASES.md`.

## Unreleased

- The agent guide (`/skill.md`) says that a pairing message ending "Once paired, start at <page>" names the
  page where the agent's person wants it to begin, in the template's words.

## 27 October 2026

- The server keeps five database connections instead of twenty, as the template does, replaces each one in its
  tenth minute so they never all reconnect at once, and names them `siwa-server-web` in the database's list of
  connections. `POOL_SIZE` is no longer read.
- The shared sign-in library (elixir-utils 48a2e1c) lets an agent's own program sign a request from its
  sign-in answer, without the server's secret; this server's hosted signing is unchanged.
- An agent that calls a site without signing is now told how to start: the guide's address, getting the
  client and making a key once. Agents already set up are still told how to get the newest client.
- Both agent helpers name the guide when they have no key yet.
- The internet can no longer reach the server's internal signing routes (`/api/shared/keyring/...`: make a
  wallet, sign a message, a transaction or an authorization). Nothing called them; they now answer 404, and
  the shared secret that guarded them is gone. Hosted signing for ChatGPT connections is unchanged.
- Wallet sign-in, agent registration and AgentBook steps keep their limit per wallet address, and each
  computer now also has one ceiling across all of them (300 a minute), so naming new addresses buys no more
  requests. Request checks from sites' servers are limited as before.
- Every library is at its newest version. That closes the plug_crypto 2.2.0 advisory (EEF-CVE-2026-105963),
  which this server never reached, and the web server's (Bandit 1.14.0) request-handling advisories.
- The server trusts the same certificate list as current browsers (Mozilla's, through castore) for every
  connection it makes, so the eMudhra certificates compromised on 20 October 2026 are no longer trusted.
- The hint for a request without signature headers no longer reads "Then Send the request": its last
  sentence starts on its own.
- When Touch ID doesn't finish, the Touch ID page says just that, in place of "cancelled or timed out". When
  unlocking or showing a key, it adds: if it keeps failing, ask your agent to make a new key, since this Mac
  may no longer hold the key's passkey.
- The crown on the Touch ID page no longer sits in a white square in light mode, or a near-black one in dark
  mode. Only its 13 blocks show.
- The two help links under the Touch ID page are at least 44px tall, so each is easy to tap on a phone.
- The Touch ID page runs only its own style and script and loads nothing from anywhere else; both helpers
  tell the browser so each time they open it.
- The wallet sign-in message is unchanged: the code that would have added a port number to it is removed,
  since no site's sign-in address can carry one.

## 21 October 2026

- Agents can sign in to Keyfleet Classic #1's notebooks (fleet-tech-classic.notebooks.keyfleet.ai), as they
  already could to the Regents Club's, so they can open a run's saved page there.

## 19 October 2026

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
- Each site's sign-in address is written one way only, `https://` and a lowercase name (never a number such as
  an IP address), so one address can never belong to two sites under two spellings.
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
