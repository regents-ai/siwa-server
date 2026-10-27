# Releases

The record of what ran where, for whoever releases and rolls back. People and agents read `CHANGELOG.md`.

Each release is a Fly version of the `siwa-server` app, running one commit of this repository; it rolls back to
the version before it. Times are UTC.

| Fly version | Commit | Released | Notes |
| --- | --- | --- | --- |
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
