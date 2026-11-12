# Releases

The record of what ran where, for whoever releases and rolls back. People and agents read `CHANGELOG.md`.

Each release is a Fly version of the `siwa-server` app, running one commit of this repository; it rolls back to
the version before it. Times are UTC.

| Fly version | Commit | Released | Notes |
| --- | --- | --- | --- |
| v86 | 310fc0d | 2026-11-12 00:43Z | State gaps, deeper modules and registry links (Sean 11 Nov "1 - 4 need to be merged and shipped", items 1-3): signed-request single use waits for the disk, World ID acceptances can never change, five-minute registry owner check, 300 s signed-request cap (service will not start below 120), any-tool registry links (`agent_registry_links`), /websites.md; migrations 20261108150000 and 20261109150000; elixir-utils e4494c0; staged removal of KEYSTORE_BACKEND and KEYSTORE_PATH went out with it; both machines on 310fc0d, /readyz all true including the new hosted_keys check, served files match; rolls back to v85 a0731b4 (the two new tables and the acceptance trigger stay; v85 never reads them) |
| v85 | a0731b4 | 2026-11-06 02:16Z | The usual release script on two machines, for its record: both run a0731b4, /readyz all true, served files match; sign-in limit shared across the machines (30 requests to each, then the next on each refused); rolls back to v83 |
| v84 | a0731b4 | 2026-11-06 02:15Z | Failed and changed nothing: Fly could not start the machine that runs migrations; both machines stayed on v83 |
| v83 | a0731b4 | 2026-11-06 02:14Z | Two shared-cpu-2x 2 GB machines (28655996be2728, 8111752f997408, iad) in place of one performance-2x 4 GB (Sean "1. a" 5 Nov); the volume is no longer mounted. flyctl refuses to drop a mounted volume without `--yes`, so this one release ran by hand: `fly deploy --image` of the image deploy.sh had built, with `--yes`, then `fly scale count 2 --yes`. The volume `siwa_data` (vol_42k97729y72yy334) is kept, unattached. Rolls back to v82 only by mounting the volume again: v82's image with its fly.toml (one performance-2x 4 GB machine) |
| v82 | 3662583 | 2026-11-06 00:56Z | Hosted connection keys and request limits move into the sign-in database, step one of two machines (Sean "1. yes" and "1. a" 5 Nov); elixir-utils 6f0f3de (siwa_keyring 0.3.0); the copy found no key files on the volume, matching 30 days of hosted signing with one refused request and none signed; still one machine with the volume; rolls back to v81 567b7c4 |
| v81 | 567b7c4 | 2026-11-02 16:07Z | SIWA v2: every signed request names its site (`@authority`), hard cutover in one window with six sites, Sentinel, regents-cli 1.10.22 and the phone backend (Sean "1. a" 31 Oct); elixir-utils 6447536; rolls back to v80 894570c |
| v80 | 894570c | 2026-10-31 22:19Z | Bandit 1.14.1 closes EEF-CVE-2026-116078 (HTTP/2 one-byte body pieces amplify memory, HIGH); mix.lock only; rolls back to v79 3e5efab |
| v79 | 3e5efab | 2026-10-30 22:03Z | Docs only: README and agent guide say a person's World ID number is public (Sean "3. a" 30 Oct 16:18Z); rolls back to v78 ecb2382 |
| v78 | ecb2382 | 2026-10-29 17:43Z | Docs only: services contract lists `/api/agents/v1/me` for hosted requests and drops the stale "allowlisted free participation" wording; feature map and README name the template's connector (coordinator review); rolls back to v77 1217599 |
| v77 | 1217599 | 2026-10-29 17:32Z | Template (`ash-template`) Claude connector may use hosted signing: whoami, me, pairing for claude (Sean "1. a" 16:35Z); `SIWA_HOSTED_SIGNERS` gained the ash-template entry (read on the machine unprinted, Sean "1. a" 17:19Z; Patchbay and Keyfleet entries unchanged) and template-regents-sh `SIWA_HOSTED_SIGNING_KEY` staged; rolls back by restaging `SIWA_HOSTED_SIGNERS` without the ash-template entry, or to v76 9f12f1d |
| v76 | 9f12f1d | 2026-10-29 05:54Z | Used signed requests and sign-in codes cleaned up by the database clock (Sean "2. ok go"); Python helper reads the process list split on newlines only; request_replayed hint and guide output note; first try at 05:43Z stopped by Fly API 503s before deploying; rolls back to v75 b1da556 |
| v75 | b1da556 | 2026-10-28 15:16Z | Replay refusals labelled by what landed: expired only when no other copy went through, else repeat; accept rule unchanged (Sean 2. a); hosted bodies decoded once (Sean 1. a); rolls back to v74 |
| v74 | aacd18d | 2026-10-28 08:32Z | Settings, on v73's code (aacd18d adds only release-log lines): Keyfleet's hosted signing key added to SIWA_HOSTED_SIGNERS (Sean CONNECTOR-KEYS 1. a, staged by Keyfleet); rolls back to v73 by restaging Patchbay's entry alone |
| v73 | f209a97 | 2026-10-28 08:27Z | Keyfleet's Claude connector may use hosted signing (whoami, me, pairing as claude; inert until Keyfleet's key is in SIWA_HOSTED_SIGNERS); hosted bodies naming a key twice refused; first-signed-request check in make check; agent guide keep-it-working section |
| v72 | 48eb736 | 2026-10-27 16:59Z | Agent guide names the pairing message's start page (template words) |
| v71 | af02776 | 2026-10-27 07:50Z | Database pool as the template serves it: 5 connections (was POOL_SIZE 20), each replaced in its tenth minute, named siwa-server-web; aimed at the idle disconnects of 05:01-07:39Z |
| v70 | 6ec8c09 | 2026-10-27 07:41Z | elixir-utils 48a2e1c (Siwa.sign_request: agents sign from their sign-in answer); hosted signing unchanged |
| v69 | 6478f00 | 2026-10-27 07:33Z | New agents are told how to start (guide, client, keygen) in the missing-headers hint; both helpers name the guide when they have no key |
| v68 | a6ca6a9 | 2026-10-27 07:16Z | Settings only, on v67's image: activity readers keyfleet, patchbay, techtree, autolaunch added (Sean SIWA-READER-KF a); rolls back to v67 by restoring the earlier SIWA_ACTIVITY_READERS |
| v67 | a6ca6a9 | 2026-10-27 05:28Z | Internal signing routes closed (404), KEYRING_PROXY_SECRET unset; per-computer sign-in ceiling 300/min; elixir-utils e161a19. Rolling back to v66 needs a fresh KEYRING_PROXY_SECRET staged first (v66 requires it at boot) |
| v66 | 92dfd95 | 2026-10-27 04:26Z | Runtime image installs libsctp1 (OTP 29 boot warning gone) |
| v65 | d8e6c97 | 2026-10-27 04:24Z | Elixir 1.20.4 / OTP 29.1.2, libraries updated (Bandit 1.14.0), castore trust, Touch ID page from design-system 5dd1262 |
| v64 | 9d23ebb | 2026-10-23 15:24Z | Settings only, on v63's image: Keyfleet Classic #1's notebooks sign in |
| v63 | e436b61 | 2026-10-19 03:00Z | Touch ID page and helpers built from design-system 1107a28; Keyfleet code host signs in |
| v62 | beba083 | 2026-10-17 01:12Z | Touch ID page rebuilt from design-system f9b0e25 |
| v61 | 37e2a85 | 2026-10-16 16:14Z | |
| v60 | e9a822d | 2026-10-16 06:23Z | `fly.toml` notes the key store and hosted signers need exactly one machine |
| v59 | bd29db2 | 2026-10-16 06:15Z | Shared libraries pinned to elixir-utils 17141b2 |
| v58 | 37a9c4e | 2026-10-16 05:23Z | |
| v57 | 530fbb6 | 2026-10-16 04:04Z | |
