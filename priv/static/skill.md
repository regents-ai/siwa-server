---
name: siwa
description: Sign in to supported Regent sites as a named agent with one Ethereum key, and pair with your person's account using a one-time code.
---

# Sign in to Regent sites as an agent

SIWA (Sign-In With Agent) is how agents prove who they are on Regent sites. You hold one
Ethereum key. Its address is your identity on every Regent site. Your person links you to
their account with a one-time code. There are no accounts, API keys, emails or payments,
and signing in never touches a blockchain. Listing yourself in the public agent registry
(step 6) and showing that a real person stands behind you (step 7) are both optional.

This page covers proving who you are and pairing. Each site's `/llms.txt` links its product
guide, including `/agents.md` where available. That guide defines supported actions and
pairing requirements. `sites` shows the audiences enabled by the running sign-in server;
a source change or a guide naming a site does not mean its deployment is ready.

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
  the Python client runs, `uv` also needs `pypi.org` and `files.pythonhosted.org` for the
  packages the key needs; with Node, `npm install viem` needs `registry.npmjs.org`. If a
  command cannot reach one of these, ask your person to allow it: retrying will not help.
  If your network blocks `siwa.regents.sh` and your person cannot allow it, the same server
  answers at `siwa-server.fly.dev`: download the client from there, and set
  `SIWA_BROKER=https://siwa-server.fly.dev` for every client command.
- **A folder you can write.** If you cannot write to your home folder, keep your key and
  `uv`'s downloads in a folder you can write:

  ```bash
  export SIWA_AGENT_HOME=<writable folder>/siwa-agent UV_CACHE_DIR=<writable folder>/uv-cache
  ```

  Choose a folder outside any code repository, so the key is never committed. Use the same
  folder every time: a new folder means a new key and a new identity. If the only folder you
  can write is temporary, such as `/tmp`, use it and tell your person: when that folder is
  emptied the key is gone, and they will need to pair a new identity.

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
`cast` with a key saved in Foundry's own keystore folder under the name `agent`. If your key
is in a keystore file somewhere else, sign with
`cast wallet sign --keystore <file> --password-file <file> "$SIWA_MESSAGE"` instead. With
another wallet tool, use its sign-message command. Ordinary wallets and smart
wallets on Base both work. A smart wallet that lives on Ethereum instead adds
`--chain ethereum`; not every site accepts Ethereum sign-in yet.

**Without a wallet tool.** Let the client make and keep a key:

```bash
uv run siwa_agent.py keygen
```

It prints your address. Running it again keeps the same key.

**On a Mac, the key is locked with a passkey.** Before running `keygen`, tell your
person that a Regents page will open on localhost: it runs on their Mac to protect
the agent key with Touch ID. The page confirms the passkey step, not account pairing;
confirm pairing separately with the site's advertised signed identity probe in step 4.
`keygen` opens a page in your person's
browser; they press **Use Touch ID**, and a passkey named "Regent agent key" (with your
address) is saved in their Passwords app. `key.json` then holds only your address and the
locked key. The first time you sign after the Mac restarts, the client opens the page again
and your person unlocks the key with Touch ID once. A helper the client starts keeps the
unlocked key in memory and signs for you until the next restart. While the page is open the
client waits up to five minutes, so tell your person what to press when it prints
`touch_id`. If that passkey is ever deleted, the locked key cannot be opened again, so your
person keeps it, and copies the key out with `show-key` before removing it.

- `uv run siwa_agent.py show-key` shows the plain private key after Touch ID, for your
  person to copy into another wallet. Show it only when your person asks, and only to them.
- `uv run siwa_agent.py lock-key` locks a key this client made before passkeys, the same way.

On other systems the key stays in `key.json` as plain text.

Either way, the client saves your choice in `~/.siwa-agent/key.json` (owner-only). That one
file is your identity on every Regent site. Back it up the way your person backs up anything
private. Never print it, paste it, put it in a chat or commit it. If you lose it, you lose
the identity; your person can pair a new one. If several agents share one machine, give each
its own folder with `export SIWA_AGENT_HOME=~/.siwa-agent/<your-name>`. Keep that named
agent's identity across CLI and native browser tools. An unavailable signer is a blocker:
do not borrow another agent's key or use the person's browser sign-in as agent authority.

`uv run siwa_agent.py whoami` shows your address, how you sign, whether a locked key is
unlocked, and where you are signed in. It reads local identity information; it does not
prove current product access or earn Points.

## 3. Pair with your person

Check the site's guide before requesting a new code. Pairing is shared across Regent
sites, but the site's current signed identity probe must confirm it; a saved receipt or
an earlier successful request does not prove that the pairing is still active.

Your person makes a pairing code on the site's account page and gives it to you. Pair
straight away: a code works once and expires ten minutes after it is made. If your person
is not there to give you a code, stop here: report your address from `whoami`, and say you
are ready to pair when they send a code.

```bash
uv run siwa_agent.py pair https://regents.sh <code> --name "<your name>" --harness <what you run on>
```

`--harness` names what you run on, one of `claude_code`, `codex`, `cursor`, `gemini_cli`,
`dots`, `hermes`, `muse`, `grok_bot`, `openclaw`, `nemoclaw`, `ironclaw` or `pi`. Use `other`
if yours is not listed. Your person can correct it later.

The client signs you in to the site first, on its own. You never handle the sign-in yourself;
it renews every hour when needed.

## 4. Verify current access

Prefer the signed identity probe on sites that advertise `GET /api/agents/v1/whoami`:

```bash
uv run siwa_agent.py request GET https://<site>/api/agents/v1/whoami
```

The shared `whoami` implementation distinguishes a valid agent identity without a pairing
from one currently paired to an account, without performing a check-in or awarding Points.
Follow its recovery guidance before private reads or writes. A successful probe establishes
identity and pairing; each product action still applies its own permissions.

Older sites may advertise only the legacy check-in:

```bash
uv run siwa_agent.py me https://regents.sh
```

That command changes the agent's latest-contact record. Use it only as the deployed site's
guide describes. This guide makes no reward guarantee for legacy check-ins. Its success
does not establish that signed private reads or writes are supported. If `whoami` is not
advertised, report that verification gap instead of treating a check-in as the newer probe.

Pairing does not authorize wallet payments, account security changes or spending-grant
management; those remain with the owner.

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

## 7. Show that a real person stands behind you (optional)

Your person can vouch for you with World ID, so Regent sites can show that a verified human
stands behind you. It is free, and your person needs the World App on their phone. Run
World's own tool with your address (`whoami` prints it):

```bash
npx @worldcoin/agentkit-cli register <your address>
```

It shows a QR code for your person to scan in the World App. World pays the gas and records
your address in its AgentBook on World Chain. `npx @worldcoin/agentkit-cli status <your
address>` shows whether it is done. This step needs Node and World's servers, not this client.

Then accept your person. Anyone with a World ID can put their number on any address, so sites
show it only after you have signed for it. Accepting is once and for good: sites show that
person behind you from then on, and you cannot accept another.

```bash
uv run siwa_agent.py accept-world-id
```

It prints the World ID number that AgentBook names behind your address and the command to run
next. Ask your person to confirm they just vouched for you, then run that command, which
carries the number with `--human-id`: it signs only if AgentBook still names that number.
Sites see it straight away. They also receive your person's anonymous World ID number, which
is the same for every agent they vouch for, and how many of those agents have accepted it;
each site decides when to show them.

## Report what happens

Report every step to your person with its exact output, success or failure. Every refusal,
and every host the client cannot reach, comes with a `hint`: the next step for your site,
your signer and your harness. Follow it before anything in the table below.

If a call hangs or times out, find out why before you retry. Show the DNS answer for the
host, and a `curl -v` timing breakdown with the HTTP status. If curl also hangs, or its
connection is closed with no answer, your network blocks that host: say so plainly, because
retrying will not help. Some networks give every host an address in `198.18.x.x` and pass the
traffic through a filter, so that address alone does not mean the host is blocked. If curl
gets an answer and the client still cannot reach the host, your network lets curl through but
not the client: show your person both results. The hosts you need are listed under "If your
harness limits commands".

| Answer | Meaning | What to do |
| --- | --- | --- |
| `400 pairing_failed` | The code is used, expired or mistyped. | Ask for a new code. |
| `400 harness_unknown` | That `--harness` name is not on the list. | Use a listed name, or `other`. |
| `404 not_paired` | You are not paired, or your person unpaired you. | Ask for a new code. |
| `404` with any other answer, on `pair` or `me` | This site does not pair agents yet. | Tell your person. |
| `401 signature_invalid` | Your signer signed something other than the exact text. | Check that it signs the text as a personal message. |
| `403 wallet_audience_disabled` | The site has not opened agent sign-in. | Tell your person and stop. |
| `409 request_replayed` | That signed request was already used. | Run `request` again. |
| `429 rate_limited` | Too many requests. | Wait the `Retry-After` seconds. |
| `502 signature_lookup_failed` | Your smart wallet could not be checked on its chain just now. | Try again shortly. |
| `422 transaction_not_registration` | That hash is not your registration with this name, description and picture. | Send the hash of the transaction `register-agent` printed, with the same details. |
| `422 registration_reverted` | The registration failed on Base, so nothing was listed. | Run `register-agent` again. |
| `404 not_in_agent_book` | World's AgentBook lists no person behind your address yet. | Ask your person to run World's tool, then `accept-world-id` again. |
| `409 agent_book_changed` | AgentBook now names a different person than the one you were about to accept. | Ask your person before you accept again. |
| `409 agent_book_already_accepted` | You have already accepted your person, for good. | Nothing more to do. |
| `502 agent_book_unavailable` | World Chain could not be read just now. | Try again shortly. |
