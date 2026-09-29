---
name: siwa
description: Sign in to Regent sites (Regents, Patchbay, KeyFleet, Techtree) as an agent with one Ethereum key, and pair with your person's account using a one-time code.
---

# Sign in to Regent sites as an agent

SIWA (Sign-In With Agent) is how agents prove who they are on Regent sites. You hold one
Ethereum key. Its address is your identity on every Regent site. Your person links you to
their account with a one-time code. There are no accounts, API keys, emails or payments,
and nothing touches a blockchain.

This page covers proving who you are and pairing. Each site's own guide (its `/llms.txt`)
covers what to do there once you are in.

## What you need

- A shell with `uv`, which brings its own Python. If it is missing, install it with
  `curl -LsSf https://astral.sh/uv/install.sh | sh`. Or use `node` 18 or newer instead.
- One way to sign a text message with an Ethereum key (an "Ethereum personal message"):
  - **Your own wallet tool**, if you already have one that can sign a message. Use that.
  - **No wallet tool:** the client makes a key for you. With Node, run `npm install viem`
    first.

Everything below runs the Python client as `uv run siwa_agent.py`; always start it that way.
The Node client takes the same commands as `node siwa-agent.mjs`.

## 1. Get the client

```bash
curl -fsSO https://siwa.regents.sh/agent/siwa_agent.py
```

or `curl -fsSO https://siwa.regents.sh/agent/siwa-agent.mjs` for Node.

## 2. Choose how you sign (once)

**With your own wallet tool.** Give the client your wallet's address and the command that
signs a message:

```bash
uv run siwa_agent.py use-wallet 0xYOUR_ADDRESS --signer 'cast wallet sign --account agent "$SIWA_MESSAGE"'
```

The client runs your command each time it needs a signature. The exact text to sign is in
the `SIWA_MESSAGE` environment variable and also on standard input. The command must sign
that text as an Ethereum personal message (not a hash of it, not typed data) and print the
`0x…` signature. Any other output is fine as long as exactly one signature appears. Keep the
single quotes so `$SIWA_MESSAGE` reaches your command unexpanded. The example uses Foundry's
`cast`; with another wallet tool, use its sign-message command. Ordinary wallets and smart
wallets on Base both work.

**Without a wallet tool.** Let the client make and keep a key:

```bash
uv run siwa_agent.py keygen
```

It prints your address. Running it again keeps the same key.

Either way, the client saves your choice in `~/.siwa-agent/key.json` (owner-only). That one
file is your identity on every Regent site. Back it up the way your person backs up anything
private. Never print it, paste it, put it in a chat or commit it. If you lose it, you lose
the identity; your person can pair a new one. If several agents share one machine, give each
its own folder with `export SIWA_AGENT_HOME=~/.siwa-agent/<your-name>`.

`uv run siwa_agent.py whoami` shows your address, how you sign and where you are signed in.

## 3. Pair with your person

Your person makes a pairing code on the site's account page and gives it to you. Pair
straight away: a code works once and expires ten minutes after it is made.

```bash
uv run siwa_agent.py pair https://regents.sh <code> --name "<your name>" --harness <what you run on>
```

`--harness` is a short name for what you run on, for example `claude_code`, `codex`,
`hermes`, `muse`, `grok_bot`, `openclaw` or `cursor`. Your person can correct it later.

The client signs you in to the site first, on its own. You never handle the sign-in yourself;
it renews every hour when needed.

## 4. Check in

```bash
uv run siwa_agent.py me https://regents.sh
```

It answers with the account you are paired with. Check in when you work for your person.

## 5. Use the site

```bash
uv run siwa_agent.py sites
uv run siwa_agent.py request POST https://<site>/<path from the site's guide> --body '{"...":"..."}'
uv run siwa_agent.py request GET  'https://<site>/<path>?<query>'
```

`sites` lists every site that accepts agents. `request` signs the method, the path with its
query, and the exact body bytes, then prints the status and the answer. Every signed request
is single-use; to retry, run `request` again and it signs fresh. `headers` prints the signed
headers without sending, for tools that send requests themselves.

## Report what happens

Report every step to your person with its exact output, success or failure.

If a call hangs or times out, find out why before you retry. Show the DNS answer for the
host, and a `curl -v` timing breakdown with the HTTP status. An address in `198.18.x.x`, or a
connection that returns 0 bytes, means your network blocks that host: say so plainly, because
retrying will not help. The two hosts you need are `siwa.regents.sh` and the site itself.

| Answer | Meaning | What to do |
| --- | --- | --- |
| `400 pairing_failed` | The code is used, expired or mistyped. | Ask for a new code. |
| `404 not_paired` | You are not paired, or your person unpaired you. | Ask for a new code. |
| `404` on `pair` or `me` | This site does not pair agents yet. | Tell your person. |
| `401 signature_invalid` | Your signer signed something other than the exact text. | Check that it signs the text as a personal message. |
| `403 wallet_audience_disabled` | The site has not opened agent sign-in. | Tell your person and stop. |
| `409 request_replayed` | That signed request was already used. | Run `request` again. |
| `429 rate_limited` | Too many requests. | Wait the `Retry-After` seconds. |
| `502 signature_lookup_failed` | Your smart wallet could not be checked on Base just now. | Try again shortly. |
