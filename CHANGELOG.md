# Changelog

What changed for agents, people and sites, newest first. Every change to main adds a line under Unreleased;
a release moves those lines under its date. Which version and commit each release ran is in `RELEASES.md`.

## Unreleased

## 19 November 2026, kit

- **A site's check in Python, and types for the Node one.** `/site/siwa_site.py` is the
  Node example's twin: one file on the standard library alone (Python 3.11 or newer) whose
  `check_agent(method, path, host, headers, body)` asks SIWA about a request and answers
  `(agent, refusal)`, and which runs as a practice site with `python3 siwa_site.py <port>`.
  `/site/siwa-site.d.mts` gives a TypeScript server the types of `checkAgent`: after the
  refusal is returned, `agent` is an `Agent`. `make check` now walks both examples as
  practice sites, with the second visit sent by the Node client from the same key, and
  typechecks the guide's own usage against the declarations (TypeScript 7.0.2, a check
  dependency only). The websites guide's Practice section shows all three. Nothing in the
  service's answers changes.

## 19 November 2026, Patchbay

- Patchbay's ChatGPT app can check in from its own address. Patchbay is now also reached at
  https://open.patchbay.help, so agents sign in for Patchbay there as well as at
  https://patchbay.help, and its hosted connection may sign `GET /api/agents/v1/me`, the
  check-in read Keyfleet's, the template's and Chainagent's connectors already sign. Before,
  a hosted identity registered and then every signed request for the new address was refused.

## 18 November 2026, site guide

- The guide for sites says how to try a practice site with nobody at the computer (an agent that
  signs with a wallet tool instead of a Touch ID key), names the Node agent client beside the
  Python one, takes the test key from any place secrets are kept, says the port must be the one
  in the site's address, and names the code for an unsigned request. Found by two fresh agents
  given only the guide's address and a test key; both reached a first accepted request in under
  two minutes.
- The example served at `/site/siwa-site.mjs` starts when it is run by a full path through a linked
  folder, such as `/tmp` on a Mac; before, it exited without a word.
- The guide for sites at `/websites.md` is rewritten for a site that holds a server key. It
  walks through opening an account and making a key, running a practice site on your own
  computer and sending it a signed request, the one check your server sends, the answer and
  the caller ID to store, what a passed check proves and what it does not, the refusals and
  which ones an agent may see, going to production, billing, limits, reading an agent's
  wallet on the chain, and credit to the original SIWA project. The example check it starts
  from is served at `/site/siwa-site.mjs`: one Node file with no dependencies, which runs as
  a practice site that answers each signed request with the agent that sent it, or which a
  Node server imports to check its own agents.
- An example site, in `examples/phoenix`: a small Phoenix app that accepts agents with its
  server key, and the demo at https://demo.regents.sh. `GET /api/hello` tells a signed agent
  its caller ID, whether it is back this billing period, its registry listing and how many
  agents its person backs; `GET /api/lounge` opens only for an agent with a listing. A
  refusal that is the site's own (its key, billing, cap, origin proof, rate limit, or the
  service being unreachable) reaches the agent as one `503 service_unavailable`, and only
  the site's log says which. It stores nothing. This server is unchanged.

## 18 November 2026, practice site

- Both served clients are 2.13. `request` and `headers` take `--handle HANDLE`, so an agent
  reaches a practice site on its person's own computer: with `--handle`, the address must be
  `http://localhost:<port>`, the client signs in for HANDLE (the site's audience, as its
  Sites page shows it) and never asks `GET /api/shared/siwa/audience`, which answers 404 for
  every sandbox site. Any other address with `--handle` is refused on the computer and
  nothing is sent. The site checks those requests with its test key, and they are never
  counted or billed. Without `--handle` nothing changes.

## 17 November 2026, no profile

- When a site says an agent is paired with a person who has no profile there yet (the site
  answers the pairing read with `409` and `{"code": "person_has_no_profile"}`), the agent now
  gets `409 hello_card_person_has_no_profile`, with a hint to ask that person to sign in on
  that site with a wallet and then run `hello-card` again, instead of
  `502 hello_card_site_unavailable`. No card is issued.

## 17 November 2026, profile code

- A hello card's `person` is the person's profile code: the random id of their Regent
  profile, never a name. The README, the guide for websites and the contract said "the
  person's name"; they now say the code, and that a page says "paired with a person on
  <site>" and never greets anyone with it. What the server accepts and signs is unchanged.

## 17 November 2026, hello card

- Hello cards. An agent paired with a person on a Regent site asks for one with a signed
  request to `POST /api/shared/siwa/hello-card`, body `{"pairedOn": "<site>"}`. This server
  asks that site at `POST /api/agents/v1/pairing`, with a 60-second service token it signs,
  and when the site answers the agent's `name`, its `person` and `pairedAt`, it answers a
  card it signs, good for a day. Sites check a card against the keys at
  `GET /.well-known/jwks.json`. A card says only that the site has the agent paired with that
  person: not that the person approved anything, nor that the agent is paired anywhere else.
  Nothing is stored. The new answers are `404 hello_card_site_unknown`,
  `404 hello_card_not_paired`, `502 hello_card_site_unavailable` and
  `503 hello_card_not_configured`; cards are limited to 60 a minute per computer.
- Both served clients are 2.12. `hello-card <site>` gets a card from a site you are paired on
  and keeps it; `request ... --hello-card <site>` sends the kept card in `x-siwa-hello-card`.
  With no card kept, or an expired one, the client stops and sends nothing.
- For whoever releases: hello cards stay off, answering `503 hello_card_not_configured` with an
  empty key list, until `SIWA_CARD_KEYS` (a secret, one or two keys; the README says how to
  make one) is set. No migration. A site answers the pairing read only once it builds
  `POST /api/agents/v1/pairing`; until then its agents get `502 hello_card_site_unavailable`.

## 17 November 2026, billing

- Customers pay through Stripe. `POST /api/control/v1/billing/checkout` answers a Stripe
  Checkout page where the person subscribes their customer: 99 dollars a month for up to
  1,000 agents, then 9.9 cents for each agent after. `POST /api/control/v1/billing/portal`
  answers Stripe's billing page for it, and `GET /api/control/v1/billing/invoices` lists its
  invoices from Stripe, with the agents each bills. Both pages send the person back only to
  an https page on one of `SIWA_PORTAL_ORIGINS`.
- `GET /api/control/v1/account` adds `billing`: whether billing runs on this server, and the
  customer's subscription status as Stripe last gave it.
- A paid customer's production sites take agents only while its subscription is active,
  trialing or past due; otherwise `http-verify` answers `402 billing_required`. Each billing
  period is the subscription's period. Internal customers are unchanged.
- Each period's agent count goes to Stripe's meter every 5 minutes while it rises, and a
  final time just after the period ends. Then the meter and the finalised invoice are checked
  against the count; a meter that disagrees holds the invoice as a draft and is logged as
  `billing check failed`. Nothing changes a count.
- Stripe's notices arrive at `POST /api/stripe/webhook`, signed; each is kept once and acted
  on after reading Stripe again.
- For whoever releases: billing stays off, answering `503 billing_not_configured`, until
  `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` (secrets) are set; `STRIPE_PRICE_ID`,
  `STRIPE_METER_EVENT_NAME` and `SIWA_PORTAL_ORIGINS` are in `fly.toml`. The price there is in
  Stripe's test mode, and people come back from Stripe's pages only to
  https://template.regents.sh or https://regents.sh. Until a paid
  customer subscribes, its production sites answer `402 billing_required`. Migration
  `20261115120000` adds nullable or defaulted columns to `customers` and `billing_periods`
  and a new `stripe_events` table; the release before it ignores them.
- When the database fails while a site's keyed check is used up and its agent counted, `http-verify`
  answers `503 verification_unavailable` instead of a bare `500`. Nothing is used up or counted, so
  the agent can send the request again, signed fresh.
- For whoever releases: migration `20261116120000` drops the trigger `siwa_request_replays_hashed_key`
  and its function, which hashed the plain keys of releases before v90. After it runs, never roll back
  to v89 or earlier; a rollback to v90 or later needs nothing, and the migration's undo puts the
  trigger back.

## 17 November 2026, plug

- Plug 1.20.4 closes EEF-CVE-2026-120287: the multipart parser did not count part and header
  framing towards its length limit. This service parses only JSON bodies, at most 64 KB, so
  it was not open to it; the fixed version is in anyway. Bandit 1.15.0 comes with it and
  closes GHSA-j9wq-h5xx-5qx5 (a small compressed HTTP/2 trailer section could cost much CPU
  and log volume), and Telemetry moves from 1.4.2 to 1.4.3 beside them. Phoenix 1.8.16 and
  Plug Crypto 2.2.1 were already the newest. No route, answer or setting changes.

## 17 November 2026, empty body

- No body and an empty body are the same signed request (Sean, 16 Nov). A request without a
  body verifies whether the agent signed no `content-digest` or the empty body's, and whether
  the site reports no `body_digest` or the empty body's; either way it is used once. A request
  that signed a body which did not arrive is refused as `401 http_body_binding_invalid`
  ("content-digest does not match the request body"), and its next step now says a request
  with no body leaves `--body` off. The reasons `request_body_required` and
  `missing_content_digest`, and the code `http_body_binding_missing`, are gone from the
  contract (26f6ba8e), and both served clients carry it. The clients sign as before:
  `--body ''` signs the empty body's digest and no `--body` signs none, and both are valid.
  No allowed hosted request has an empty body, so hosted signing is unchanged.
- The shared library pin is elixir-utils e40068b, which brings the body rule. It also moves the
  address rule a customer's site file is read under to the shared outbound package
  (`RegentHttp.Public`); the rule and every limit of that read are unchanged, and the MCP
  Events package is no longer a dependency. The Privy package now brings Phoenix LiveView and
  Phoenix HTML into the build for its own sign-in pages; the token check the control API
  uses is unchanged. Nothing the service uses from the chain package changed.

## 14 November 2026, site proof

- A company proves its production site's addresses are its own. Each site has a public
  token; the company puts it in a file at `/.well-known/siwa-site.txt` on each of the
  site's addresses and asks for a check with `POST /api/control/v1/sites/{id}/proof`. When
  every address shows the token, the site is verified and starts taking agents. When one
  does not, the site says which address failed and why, and stays unverified. The check
  reads only public https addresses, follows no redirect, and gives up after 5 seconds or
  1 KB. A site can be checked 10 times a minute.
- The site's `originProof` is now an object, not a word: its `state`, `token`, the
  `fileUrls` to publish at, `checkedAt`, `verifiedAt`, and the last `failureReason` and
  `failedOrigin`. A sandbox site's is still null.
- Agents find the audience for a site with `GET /api/shared/siwa/audience?origin=`, one
  exact address at a time. It answers for the Regent sites and for customers' verified
  production sites, and the same 404 for every other address. Both agent clients now ask
  here; their `sites` command still prints the Regent sites.
- A customer's site may have 6,000 of its agents' requests checked a minute, however many
  of its servers ask. Past that it answers `429 site_rate_limited`, before the request is
  checked, used up or its agent counted for billing.
- For whoever releases: migration `20261114200000` only adds columns to `sites`. Postgres
  writes each existing site its own token as the column is added, which rewrites the small
  `sites` table once inside the migration.

## 14 November 2026, counting

- The Regent sites' activity read names only the Regent sites; a customer's site never appears in it.
- A customer's site checks its agents' signed requests at `http-verify` with its server key
  as the bearer. A key that is unknown, revoked or whose site is archived is refused
  (`401 site_key_invalid`) before the agent's request is looked at, so the agent can send it
  again. A production site whose origins are not proven answers `403 site_not_verified`.
  The answer adds the agent's `subject`.
- A production site's agent is counted once per customer in its current billing period, in
  the same step that uses the request up, and the answer adds `usage`. A customer with no
  period running answers `402 billing_required`, and one whose cap has no room for another
  new agent `402 agent_cap_reached`; either way the request is not used up. An agent already
  counted always passes, and a lease never runs past the period's end. A sandbox site counts
  nothing.
- Agents sign in for a customer's sandbox site, or production site with proven origins, from
  the site's own origins. The public audience list still names only the Regent sites. A
  customer's site's audience sent to `http-verify` without its key is refused
  (`401 site_key_required`); Regent sites asking with their audience alone are unchanged.
- The control API shows the customer's `capCents` and its `usage` this billing period, sets
  the cap with `PUT /api/control/v1/cap` (at least 9900 cents, never below the fee already
  reached) and lists the period's agents, newest first, with `GET /api/control/v1/agents`.
- For whoever releases: migration `20261114180000` only adds the `billing_periods` and
  `monthly_active_agents` tables, a nullable `customers.cap_cents`, and the `btree_gist`
  extension, which the production database role must be allowed to create.

## 14 November 2026, control API

- The control API is on at siwa.regents.sh for people signed in with the Regent sites' Privy app
  (`PRIVY_APP_ID` and `PRIVY_VERIFICATION_KEY` in `fly.toml`, both public values).
- New control API at `/api/control/v1`, for the paid sign-in product. A Regent site trades its
  signed-in person's Privy sign-in for a 15-minute control token, then manages that person's
  customer, sites and site server keys. A site's audience is taken for good and never one
  already served; a sandbox site lists local origins, a production one `https://` origins
  that start unverified. A server key is shown once and kept only as a hash, at most five
  per site. Nothing uses a server key yet. Agent sign-in, `http-verify`, the audience list
  and hosted signing are unchanged.
- For whoever releases: the control API stays off, answering `503 control_not_configured`,
  until `PRIVY_APP_ID` and `PRIVY_VERIFICATION_KEY` are set; the server starts without them.
  Migration `20261114120000` only adds the `customers`, `sites` and `site_credentials`
  tables and one check function.

## 14 November 2026, later

- A used signed request is kept only as a hash of what was signed, so the database no longer
  holds each request's path and query until it expires. Requests already used before the
  release are hashed when it starts. A request used once is still refused every time after,
  including on a machine still running the previous release during the switch, or after a
  rollback to its image. There, a repeat that has also expired can read `401
  http_signature_invalid` ("signed request has expired") rather than `409 request_replayed`.
- For whoever releases: a database trigger (`siwa_request_replays_hashed_key`, migration
  `20261113150000`) hashes the plain keys the previous release writes. Roll back by image only,
  with the trigger left in place; never by undoing the migration. A later release removes the
  trigger with its own migration, once rolling back past this release is no longer needed.

## 14 November 2026

- Chainagent is a site agents can sign in to: the audience `chainagent` signs for
  `https://chainagent.ai`. Its Claude connector may use hosted signing as the template's does
  (`whoami`, `me` and pairing for the `claude` harness) once Chainagent's own key is placed in
  `SIWA_HOSTED_SIGNERS`; until then nothing signs for it.

## 13 November 2026

- The old one-line-per-request activity record, unused since 14 October, is removed from the
  database along with its cleanup. Sites read the same daily totals as before.

## 12 November 2026

- Security update: Ecto 3.14.3 closes EEF-CVE-2026-118391 (HIGH, a query cache that could grow
  without limit).
- One computer may ask for at most 3,000 signed-request checks a minute, whichever wallets it
  names. Each wallet's own limit of 600 a minute is unchanged. A site's server is far below
  this; it bounds a caller that names a new wallet every time.
- For whoever releases: `scripts/deploy.sh` holds `/tmp/regent-release-siwa-server.lock` for its
  whole run, so two releases of siwa-server take turns and never wait on another app's release.
- A challenge or sign-in lifetime, or the signed-request window, that is not a positive whole
  number now stops the service from starting, instead of letting it start and say it is not
  ready (`siwa_ttls`). An RPC address with no host now also fails its readiness address check.
- A signed request's single use is on the database's disk before http-verify answers, so a
  database crash can no longer let one request through twice. A verification now waits
  while the database's disk pauses.
- A wallet's accepted World ID person can no longer be changed or removed: the database refuses
  to change, delete or empty an accepted row. A wallet that has accepted already is told so at
  once, without a World Chain read.
- When the key store password does not open the stored hosted connection keys, the service
  says it is not ready (`hosted_keys`), and each hosted connection's register or sign answers
  `503 hosted_key_unreadable` instead of a refusal; no new key is made under that password.
- The verify answer drops a listing the agent registry no longer names as the wallet's. Every
  five minutes the service reads the registry on Base for each wallet's listing; a listing
  comes back once the registry names the wallet again.
- A signed request that lasts longer than the signature tolerance (300 seconds) is refused
  (`401 http_signature_invalid`, "signed request lasts longer than the signature
  tolerance"), and a used request stays used until it expires, so http-verify cannot accept it
  twice. `SIWA_HTTP_SIGNATURE_TOLERANCE_SECONDS` must be at least 120, the contract's signing
  lifetime; below that the service does not start. The shared sign-in library
  (elixir-utils e4494c0, contract version 2, contract d04115bc) makes the rule; both served
  helpers sign for two minutes and carry the new contract.
- The unused settings `KEYSTORE_BACKEND` and `KEYSTORE_PATH` are removed from the server; they
  were staged on 6 November and go with this release.
- An agent listed in the Base agent registry with another tool can link that listing with
  `link-agent --agent-id <id>`, once the registry names its address as the agent's owner or
  agent wallet; its wallet signs to confirm. Sites then see that listing in
  `agentRegistration`: the one the agent registered or linked last. `profileUrl` is null when
  the listing has no `https://` or `ipfs://` profile address.
- Websites outside Regents have a guide, https://siwa.regents.sh/websites.md: how to join,
  how to check an agent's request (curl and TypeScript), and an example that gives one free
  trial to each verified person.

## 6 November 2026

- Sign-in runs on two smaller machines on separate hosts instead of one large one, so one
  machine stopping no longer stops sign-in. Each has 2 shared processors and 2 GB of memory,
  about four times the most the service has used. The disk the keys used to live on is no
  longer mounted, and its two settings (`KEYSTORE_BACKEND`, `KEYSTORE_PATH`) are no longer read.
- Hosted connections' signing keys are kept in the sign-in database, encrypted exactly as
  before, instead of in files on the server's disk. The release copies every existing key
  across unchanged, so each connection keeps its agent and address. Nothing changes for
  sites or agents; it lets the service run on more than one machine.
- Request limits are counted in the sign-in database, so every machine counts against the
  same allowance. The limits themselves are unchanged.

## 2 November 2026

- Every signed request names the site it is for. The shared sign-in library (elixir-utils
  6447536, contract version 2) adds the host the request is sent to (`@authority`) to what
  an agent signs, and a site sends the host it received the request at to
  `/api/shared/siwa/http-verify` as `authority`. The server accepts it only when that host
  is one of the audience's origins in `SIWA_WALLET_ORIGINS`, so a request signed for one
  site is refused at every other (`401 http_signature_invalid`, "signed request is for
  another site"). A request from an older client, which does not sign the host, is refused
  as missing signature headers and told to get the newest client. Both served helpers
  (2.11) sign it, and hosted signing signs it for the host the calling site names, which
  must be one of its own.
- Run anywhere but production, `SIWA_WALLET_ORIGINS` also accepts `http://localhost:<port>`,
  so a site run locally can check its agents' requests against a local server.
- The agent registration transaction ends with Regent's Base Builder Code, as every
  transaction built by the shared chain library now does; contracts ignore it, and the
  registration is still matched when a wallet adds its own code.

## 31 October 2026

- The web server (Bandit 1.14.1) closes EEF-CVE-2026-116078, where an HTTP/2 request body
  sent as one-byte pieces could use far more memory than its size. Nothing else changes.

## 30 October 2026

- The README and the agent guide now say plainly that a person's World ID number is public:
  anyone can read it from World's AgentBook with the agent's address.

## 29 October 2026

- The published services contract now lists `GET /api/agents/v1/me` among the hosted
  requests and says plainly what a site's hosted connection may sign.

## 29 October 2026

- The template's Claude connector can use hosted signing, as Keyfleet's does: with the template's
  own key in `SIWA_HOSTED_SIGNERS`, it may sign only `GET /api/agents/v1/whoami`,
  `GET /api/agents/v1/me` and pairing for the `claude` harness under the `ash-template` audience.
  No other site's requests change, and no site can sign another's.
- Nothing changes for agents or sites. Used signed requests and sign-in codes are forgotten by
  the database's clock, the same clock that checks them, so a clock gap between the server and
  its database can no longer let one request through twice or refuse a sign-in that is still
  valid.
- The Python helper no longer fails to make or open a key with Touch ID when another app on the
  Mac has certain Unicode line separators in its command line; it reads the list of running apps
  the way the Node helper does.
- The hint on a `409 request_replayed` refusal now says another copy of the request already went
  through, and it and the agent guide tell agents to read whether a write landed before sending it
  again. The guide also says where each client's output goes: answers on standard output; the
  Touch ID step and errors on standard error, where some Python builds also add warnings.

## 28 October 2026

- A signed request is refused as expired (`401 http_signature_invalid`, "signed request has
  expired") only when no other copy of it went through, including one whose time ran out while the
  server was recording its single use; an agent then signs it again. Whenever another copy went
  through, it is refused as a repeat (`409 request_replayed`), so an agent never sends again a request
  that already took effect. Which requests are accepted is unchanged.
- Hosted signing reads each request body once, and the checks now cover a key named twice inside a
  Patchbay tool call's arguments and name the exact refusal for a pairing body changed after signing.
- The agent guide (`/skill.md`) says how to keep signing working: the client renews its hour-long
  sign-in itself, what to do when pairing ends or the signer stops, how long to wait after `429`,
  `502` or `503`, and to check whether a lost write landed before sending it again. A new
  `400 invalid_request` row says to get the current client.
- Keyfleet's Claude connector can use hosted signing: with Keyfleet's own key in
  `SIWA_HOSTED_SIGNERS`, it may sign only `GET /api/agents/v1/whoami`, `GET /api/agents/v1/me` and
  pairing for the `claude` harness. Patchbay keeps exactly its own requests; neither site can sign
  the other's. It works only while `SIWA_WALLET_ORIGINS` lists a Keyfleet origin, as it does today.
  Hosted signing now refuses a request body that names one key twice, for both sites.
- A new agent's first signed request is now checked end to end on every `make check`: the served
  Python and Node clients each start from a new key, sign in and sign their first `whoami` and
  pairing requests for two sites against this server on a local port, and each site checks them
  the way it checks every agent. Each is accepted once for the right agent and site, a repeat is
  refused, the other site refuses it, and a pairing whose body changed after signing is refused.
  `make check` now installs the e2e libraries before the tests, and the tests need `uv` (and the
  network the first time).
- `.env.example` lists every setting the server reads: `WORLD_RPC_URL`, `SIWA_HOSTED_SIGNERS`,
  `KEYSTORE_BACKEND` and `KEYSTORE_PATH` are added, with the production-only ones named. The
  settings allowlist adds `WORLD_RPC_URL` and `SIWA_RELEASE_COMMAND`, and a test now fails when
  `config/runtime.exs` or any file under `lib/` reads a setting that either file leaves out.
  Production's key store path is set by the `KEYSTORE_PATH` Fly secret; the docs no longer name a
  `/data` default.
- `make check` is the one check, as in the template; it runs `mix precommit`.
- Releases go through `scripts/deploy.sh`: it refuses a changed tree, a commit not on `origin/main`,
  an app without exactly one machine, or a commit without the live one; builds from `git archive`;
  deploys with `--ha=false`; keeps Fly's logs from before the deploy to after its checks; then
  checks that one machine runs the commit, `/readyz`, and that the served helpers and guide match
  git. Every check runs even when one fails, and a failure always ends with a "deployed but a
  check failed" line.
- README.md says how the key store volume is backed up (Fly's daily snapshots, kept 5 days) and
  how a restore would go (stop the machine, clone it from a snapshot, prove it with a real
  signature, then remove the old machine); the restore has never been rehearsed.

## 27 October 2026

- The agent guide (`/skill.md`) says that a pairing message ending "Once paired, start at <page>" names the
  page where the agent's person wants it to begin, in the template's words.
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
