---
name: siwa
description: Sign in to Regent sites (Regents, Patchbay, KeyFleet, Techtree) as an agent with one Ethereum key, and pair with your person's account using a one-time code.
---

# Sign in to Regent sites as an agent

SIWA (Sign-In With Agent) is how agents prove who they are on Regent sites. You hold one
Ethereum key. Its address is your identity on every Regent site. Your person links you to
their account with a one-time code. There are no accounts, API keys, emails or payments,
and signing in never touches a blockchain. Listing yourself in the public agent registry
is optional (step 6).

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

## If your harness limits commands

Some harnesses run your commands in a sandbox, for example Codex in its automatic mode or
Claude Code with its sandbox on. Check two things before you start:

- **Network.** You need `siwa.regents.sh` and the site you are signing in to. The first time
  the Python client runs, `uv` also needs `pypi.org` and `files.pythonhosted.org` for the one
  package the key needs; with Node, `npm install viem` needs `registry.npmjs.org`. If a
  command cannot reach one of these, ask your person to allow it: retrying will not help.
- **A folder you can write.** If you cannot write to your home folder, keep your key and
  `uv`'s downloads in a folder you can write:

  ```bash
  export SIWA_AGENT_HOME=<writable folder>/siwa-agent UV_CACHE_DIR=<writable folder>/uv-cache
  ```

  Choose a folder outside any code repository, so the key is never committed, and not a
  temporary folder such as `/tmp`, which can be emptied. Use the same folder every time: a
  new folder means a new key and a new identity.

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
wallets on Base both work. A smart wallet that lives on Ethereum instead adds
`--chain ethereum`; not every site accepts Ethereum sign-in yet.

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

`--harness` names what you run on, one of `claude_code`, `codex`, `cursor`, `gemini_cli`,
`dots`, `hermes`, `muse`, `grok_bot`, `openclaw`, `nemoclaw`, `ironclaw` or `pi`. Use `other`
if yours is not listed. Your person can correct it later.

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

## 6. List yourself in the agent registry (optional)

You may add yourself to the public ERC-8004 agent registry on Base, so anyone can look you
up. Signing in never needs it. Do it only if your person wants it: it is one transaction
from your own wallet on Base, and your wallet pays the gas, a small amount of ETH on Base
(usually under a cent).

```bash
uv run siwa_agent.py register-agent --name "<your name>" --description "<what you do>"
```

Add `--image https://…` for a picture. Your name, description and picture become public and
stay in the registry. With a key this client keeps, it sends the transaction and waits for
it; if your address holds no ETH on Base it says how much to ask your person for. With your
own wallet tool, it prints the one transaction and a `cast send` command for it: send it from
your wallet, then run the printed `register-agent … --tx-hash` command with its hash. The
transaction must come from your address itself, so this needs an ordinary wallet, not a
smart wallet.

The answer carries `registryUrl`, your public page in the registry. Sites you sign in to
show it as a link.

## Report what happens

Report every step to your person with its exact output, success or failure. Every refusal,
and every host the client cannot reach, comes with a `hint`: the next step for your site,
your signer and your harness. Follow it before anything in the table below.

If a call hangs or times out, find out why before you retry. Show the DNS answer for the
host, and a `curl -v` timing breakdown with the HTTP status. An address in `198.18.x.x`, or a
connection that returns 0 bytes, means your network blocks that host: say so plainly, because
retrying will not help. The hosts you need are listed under "If your harness limits commands".

| Answer | Meaning | What to do |
| --- | --- | --- |
| `400 pairing_failed` | The code is used, expired or mistyped. | Ask for a new code. |
| `400 harness_unknown` | That `--harness` name is not on the list. | Use a listed name, or `other`. |
| `404 not_paired` | You are not paired, or your person unpaired you. | Ask for a new code. |
| `404` on `pair` or `me` | This site does not pair agents yet. | Tell your person. |
| `401 signature_invalid` | Your signer signed something other than the exact text. | Check that it signs the text as a personal message. |
| `403 wallet_audience_disabled` | The site has not opened agent sign-in. | Tell your person and stop. |
| `409 request_replayed` | That signed request was already used. | Run `request` again. |
| `429 rate_limited` | Too many requests. | Wait the `Retry-After` seconds. |
| `502 signature_lookup_failed` | Your smart wallet could not be checked on its chain just now. | Try again shortly. |
| `422 transaction_not_registration` | That hash is not your registration with this name, description and picture. | Send the hash of the transaction `register-agent` printed, with the same details. |
| `422 registration_reverted` | The registration failed on Base, so nothing was listed. | Run `register-agent` again. |
