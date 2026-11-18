# SIWA example site

A small Phoenix app that accepts AI agents signed in with SIWA, the way your own site
would: it checks each signed request with the SIWA service using the site's server key,
then answers from what the service says about the agent. It has no database and stores
nothing. Regent runs it as the demo at https://demo.regents.sh.

It has two routes for agents:

- `GET /api/hello` tells the agent what the site learned about it.
- `GET /api/lounge` opens only for an agent listed in the agent registry, and tells any
  other agent how to list itself.

```http
GET /api/hello
200 {
  "caller": "eip155:8453:0x1111111111111111111111111111111111111111",
  "wallet": "0x1111111111111111111111111111111111111111",
  "returning": false,
  "listing": {"agentId": "eip155:8453:0x8004...:42", "profileUrl": "https://agents.example/42.json"},
  "person": {"agentCount": 2},
  "message": "Hello, nice to meet you."
}

GET /api/lounge
200 {"agentId": "eip155:8453:0x8004...:42", "message": "Welcome to the lounge."}
403 {"error": {"code": "listing_required", "message": "...", "hint": "...register-agent... link-agent..."}}
```

- `caller` is the agent's subject: the same on every visit, from its wallet.
- `returning` is true when the agent was already counted this billing period, on this site
  or another live site of the same account. A practice site counts nothing, so it leaves
  `returning` out.
- `listing` is null, or the agent's registry listing.
- `person` is null, or how many agents the person who vouched for this one with World ID
  backs. The service also sends the person's anonymous World ID number (`humanId`); the
  site never passes it on.

## Run it

You need Elixir 1.20 (the demo is built with 1.20.4 on Erlang/OTP 29.1.2), and the agent
client from https://siwa.regents.sh/skill.md for the agent's side.

1. On your SIWA account's Sites page, make a practice (sandbox) site with the origin
   `http://localhost:4000`, and note its handle.
2. Make a server key for it. A practice site's key starts `siwa_sk_test_` and is shown once.
3. Copy `.env.example` to `.env`, set `SIWA_SERVER_KEY` and `SIWA_HANDLE`, then load it:
   `set -a; . ./.env; set +a`. The app will not start without both.
4. Fetch the dependencies and start the site:

   ```bash
   mix setup
   mix phx.server
   ```

5. Open http://localhost:4000 for the page. As the agent, ask who you are and knock on
   the lounge door:

   ```bash
   uv run siwa_agent.py request GET http://localhost:4000/api/hello --handle <handle>
   uv run siwa_agent.py request GET http://localhost:4000/api/lounge --handle <handle>
   ```

   A practice site is on your own computer, so the service cannot find it by its address;
   `--handle` tells the client which site to sign in for. A live site needs none.

`mix test` runs the tests, which never reach the service. `mix precommit` runs every check.

## Files

| File | What it does |
| --- | --- |
| `lib/siwa_demo_web/agent_auth.ex` | The one place that guards the agent routes: the plug's options, the three hooks, and every refusal an agent can get. |
| `lib/siwa_demo/siwa_client.ex` | Asks the service about one signed request, with the server key. |
| `lib/siwa_demo_web/agent_controller.ex` | `/api/hello` and `/api/lounge`, answered from the service's answer. |
| `lib/siwa_demo_web/page_controller.ex` | The page, `/healthz`, and `/.well-known/siwa-site.txt`. |
| `lib/siwa_demo_web/page_html/home.html.eex` | The page. `priv/static/site.css` is its only style sheet. |
| `lib/siwa_demo_web/router.ex` | The routes. Only `/api` goes through the agent check. |
| `config/runtime.exs` | Reads the settings in `.env.example`. |
| `Dockerfile`, `fly.toml` | How Regent builds and runs the demo on Fly. |
| `test/` | The routes against a stand-in service, and the client against a local one. |

## Refusals

Every refusal is `{"error": {"code", "message", "hint"}}`. What the agent gets depends on
whose problem it is.

| The service or the site says | The agent gets |
| --- | --- |
| No signed headers at all (checked here, before asking the service) | `401 signature_required` |
| A signed header sent twice, a query string, or a body (refused by the plug) | `401 duplicate_proof`, `unsupported_query` or `missing_signed_body` |
| `400`, `401` or `409` about the agent's request: a bad or expired signature, a receipt for another site, a request used twice | `401` with the service's code and message |
| `401 site_key_invalid`, `site_audience_mismatch`, `site_key_required` | `503 service_unavailable` |
| `402 billing_required`, `agent_cap_reached` | `503 service_unavailable` |
| `403 site_not_verified` | `503 service_unavailable` |
| `429 site_rate_limited` or `rate_limited` | `503 service_unavailable` |
| `502 signature_lookup_failed`, `503 verification_unavailable` | `503 service_unavailable` |
| Any answer without a verdict, such as a redirect, or the service unreachable | `503 service_unavailable` |

The agent's own refusals carry a hint pointing to the agent guide, so it can sign again.

Everything else is the site's business. An agent cannot fix the site's key, its bills,
its cap or its proof of address, and telling every caller about them would publish the
state of the site's account to strangers. So the agent hears only "try again in a few
minutes", and the site's log gets one line with the real reason:

```text
[error] SIWA could not check an agent request for this site: %{reason: :siwa_http_402, siwa_code: "billing_required", siwa_message: "...", siwa_status: 402}
```

The line never holds the server key or the agent's signed headers. Watch for it: a
`site_key_invalid` or `billing_required` there means no agent can get in until you act.

## Choices

- **No query, no body.** Both routes are `GET` with neither, so the plug keeps its
  defaults: a query string is refused (`query: :refuse`), and so is a body, because nothing
  reads it and an unread body is one the signature cannot be checked against. A route
  that takes a query sets `query: :signed`; one that takes a body reads it first with
  `Plug.Parsers` and `Siwa.AgentAuthPlug.read_body/3` as its body reader, which keeps the
  exact bytes the signature covers.
- **Every request is checked.** `read_only` stays off. With it on, the service hands out a
  lease of about ten minutes and later requests are checked on the site, so `usage` and
  `listing` would be the first request's for that long, and `returning` would be wrong.
- **Unsigned requests stop early.** A request with no signed header at all is refused on
  the site, without a call to the service.
- **No redirects.** The client never follows one, so the key goes only to the service.

## Go live

1. Make a live (production) site on the Sites page with your real origin, such as
   `https://demo.example.com`, and a live key (`siwa_sk_live_`).
2. Set `SIWA_SERVER_KEY` to the live key, `SIWA_HANDLE` to the live site's handle,
   `PHX_HOST` to your host, and `SIWA_SITE_TOKEN` to the site's token from the Sites page.
   The site serves that token at `/.well-known/siwa-site.txt`.
3. Deploy, then ask the Sites page to check your address. Until it passes, every agent
   request answers `503` and the log says `site_not_verified`.
4. A live site's agents count toward its billing period, so it needs a running period
   (otherwise the log says `billing_required`).

The app needs no `SECRET_KEY_BASE`: it has no sessions, cookies or sockets.

To run it on Fly as Regent does, see `fly.toml`. Keep the server key a secret:

```bash
fly secrets set SIWA_SERVER_KEY=siwa_sk_live_...
```
