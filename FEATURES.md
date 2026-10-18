# What siwa-server does, and what proves it

Each line is something a person, an agent or a site can do, and the automated check that
proves it. `mix precommit` runs every check below. A line marked **gap** has no automated
check yet.

## Agents

| Behaviour | Proof |
| --- | --- |
| The Python and Node helpers sign every request the same way, byte for byte, as the siwa library's contract says | `test/siwa_server/agent_clients_conformance_test.exs` |
| Both helpers show the same help, without the command they only start themselves, and answer a wrong command with the same JSON error | `test/siwa_server/agent_clients_conformance_test.exs` |
| Both helpers carry the signing contract the library generates | `mix siwa_server.agent_clients --check` |
| Both helpers carry the Touch ID page built from its sources | `scripts/build_agent_page.py --check` (run by hand with the design-system folder; **gap**: not in precommit, because it needs that checkout) |
| `keygen` locks a new key with Touch ID, and `show-key` opens it again | `e2e/touch-id-page.spec.mjs`, the real Python helper on a Mac; **gap**: the Node helper's own run (its page is the same bytes) |
| A request without signed headers is told where to get the newest client | `test/siwa_server_web/controllers/agent_siwa_controller_test.exs` |
| An agent lists itself in the agent registry on Base, and its profile is served | `test/siwa_server_web/controllers/agent_registration_controller_test.exs` |
| An agent accepts the person World ID's AgentBook names, once | `test/siwa_server_web/controllers/agent_book_controller_test.exs`, `test/siwa_server/agent_book_test.exs` |

## People, on the Touch ID page

| Behaviour | Proof |
| --- | --- |
| The page says who opened it, what Touch ID does in each step (protect, unlock, show) and that it is safe to close, in plain words, at 390 and 1280 wide, light and dark | `e2e/touch-id-page.spec.mjs` |
| Finishing, cancelling or failing never moves the rest of the page | `e2e/touch-id-page.spec.mjs` |
| A cancelled Touch ID, an agent that stopped waiting and a browser that cannot do it each get their own plain line; any other browser error gets one plain line, its own words go to the log | `e2e/touch-id-page.spec.mjs` |
| Safari | **gap**: WebKit is not run on the Mac |

## Sites

| Behaviour | Proof |
| --- | --- |
| A site checks a signed agent request: window, body digest, path and query, audience, receipt binding, replay | `test/siwa_server/http_verifier_test.exs` |
| A request is used once, even across connections | `test/siwa_server/wallet_concurrency_test.exs`, `test/siwa_server/replay_store_test.exs`, `test/siwa_server/replay_store_commit_test.exs` |
| A wallet signs in to a site's audience, for each origin it lists | `test/siwa_server_web/controllers/wallet_siwa_controller_test.exs`, `test/siwa_server/wallet_origins_test.exs`; **gap**: a property check that host matching never accepts a lookalike |
| A site reads one wallet's activity, registry listing and AgentBook person | `test/siwa_server_web/controllers/activity_controller_test.exs`, `test/siwa_server/activity_readers_test.exs` |
| Patchbay's hosted ChatGPT connections sign only for Patchbay | `test/siwa_server/hosted_requests_test.exs` |
| Requests are limited per wallet, chain, audience and address | `test/siwa_server_web/plugs/rate_limit_test.exs` |

## Operations

| Behaviour | Proof |
| --- | --- |
| The internal key store creates wallets and signs, and refuses bad signatures | `test/siwa_server_web/internal/keyring_router_test.exs` |
| Expired challenges and used requests are cleaned up in batches | `test/siwa_server/cleanup_worker_test.exs`, `test/siwa_server/nonce_store_test.exs` |
| `/readyz` says which checks failed | `test/siwa_server/readiness_test.exs` |
| The database settings fit Fly's managed Postgres | `test/siwa_server/database_config_test.exs` |
| Configuration and secrets stay inside this repository's list | `test/siwa_server/runtime_config_test.exs`, `test/siwa_server/secret_allowlist_test.exs` |
| The served services contract matches the routes | `mix check.services_contract` |
