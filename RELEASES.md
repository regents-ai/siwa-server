# Releases

The record of what ran where, for whoever releases and rolls back. People and agents read `CHANGELOG.md`.

Each release is a Fly version of the `siwa-server` app, running one commit of this repository; it rolls back to
the version before it. Times are UTC.

| Fly version | Commit | Released | Notes |
| --- | --- | --- | --- |
| v65 | d8e6c97 | 2026-10-27 04:24Z | Elixir 1.20.4 / OTP 29.1.2, libraries updated (Bandit 1.14.0), castore trust, Touch ID page from design-system 5dd1262 |
| v64 | 9d23ebb | 2026-10-23 15:24Z | Settings only, on v63's image: Keyfleet Classic #1's notebooks sign in |
| v63 | e436b61 | 2026-10-19 03:00Z | Touch ID page and helpers built from design-system 1107a28; Keyfleet code host signs in |
| v62 | beba083 | 2026-10-17 01:12Z | Touch ID page rebuilt from design-system f9b0e25 |
| v61 | 37e2a85 | 2026-10-16 16:14Z | |
| v60 | e9a822d | 2026-10-16 06:23Z | `fly.toml` notes the key store and hosted signers need exactly one machine |
| v59 | bd29db2 | 2026-10-16 06:15Z | Shared libraries pinned to elixir-utils 17141b2 |
| v58 | 37a9c4e | 2026-10-16 05:23Z | |
| v57 | 530fbb6 | 2026-10-16 04:04Z | |
