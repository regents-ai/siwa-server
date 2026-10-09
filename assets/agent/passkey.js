const setup = __SETUP__;
const words = {
  lock: ["Secure your agent key", "Create a passkey with Touch ID to protect your agent’s key."],
  unlock: ["Unlock your agent key", "Use Touch ID to let your agent sign in. Asked once after each Mac restart."],
  show: ["Reveal your agent key", "Use Touch ID to reveal the private key in your terminal. Only continue if you requested it."],
}[setup.mode];
const $ = (id) => document.getElementById(id);
document.title = words[0] + " · Regents";
$("title").textContent = words[0];
$("lead").textContent = words[1];
$("address").textContent = setup.address;
$("message").textContent = "I’m on the Regents Touch ID page you opened. Its address is localhost because it runs on my Mac, not on a website. Touch ID there protects your agent key (" + setup.address + ") with my fingerprint, and the secret that unlocks it never leaves this computer. It does not pair you with my account: once I’m done, run your client’s “me” command to check pairing. Agent guide: https://siwa.regents.sh/skill.md. Questions: https://patchbay.help";
$("copy").onclick = async () => {
  try {
    await navigator.clipboard.writeText($("message").textContent);
    $("copy").textContent = "✓ Copied";
  } catch {
    $("copy").textContent = "Couldn’t copy. Select the message and copy it.";
  }
};
const hex = (bytes) => [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
const unhex = (text) => new Uint8Array(text.match(/../g).map((h) => parseInt(h, 16)));
const random = (size) => crypto.getRandomValues(new Uint8Array(size));
const salt = () => crypto.subtle.digest("SHA-256", new TextEncoder().encode("regent agent key"));

async function secretOf(credentialId) {
  const credential = await navigator.credentials.get({ publicKey: {
    challenge: random(32),
    rpId: "localhost",
    allowCredentials: [{ type: "public-key", id: unhex(credentialId) }],
    userVerification: "required",
    extensions: { prf: { eval: { first: await salt() } } },
  } });
  const first = credential.getClientExtensionResults().prf?.results?.first;
  if (!first) throw new Error("This browser can't open the passkey. Open this page in Safari or Chrome.");
  return { credential_id: credentialId, secret: hex(first) };
}

async function makePasskey() {
  const credential = await navigator.credentials.create({ publicKey: {
    rp: { name: "Regent agent key", id: "localhost" },
    user: { id: random(16), name: setup.address, displayName: "Regent agent key" },
    challenge: random(32),
    pubKeyCredParams: [{ type: "public-key", alg: -7 }, { type: "public-key", alg: -257 }],
    authenticatorSelection: { residentKey: "required", userVerification: "required" },
    extensions: { prf: { eval: { first: await salt() } } },
  } });
  // A passkey store may give the secret only when the passkey is next used.
  const first = credential.getClientExtensionResults().prf?.results?.first;
  return first ? { credential_id: hex(credential.rawId), secret: hex(first) } : secretOf(hex(credential.rawId));
}

$("go").onclick = async () => {
  $("go").disabled = true;
  $("go").textContent = "Waiting for Touch ID…";
  $("go").setAttribute("aria-busy", "true");
  $("note").textContent = "";
  try {
    const answer = setup.mode === "lock" ? await makePasskey() : await secretOf(setup.credentialId);
    const sent = await fetch(location.pathname, { method: "POST", body: JSON.stringify(answer) }).catch(() => null);
    if (!sent?.ok) throw new Error("Your agent stopped waiting. Run its command again.");
    const result = {
      lock: ["Passkey created", "Return to your agent to finish setup and pairing. You can close this tab."],
      unlock: ["Touch ID confirmed", "Return to your agent to continue. You can close this tab."],
      show: ["Touch ID confirmed", "Return to your terminal to view the key. You can close this tab."],
    }[setup.mode];
    $("title").textContent = result[0];
    $("lead").textContent = result[1];
    document.title = result[0] + " · Regents";
    $("state").textContent = "✓ Confirmed";
    $("go").textContent = "✓ Touch ID complete";
    $("go").setAttribute("data-complete", "");
    $("go").setAttribute("aria-busy", "false");
    $("title").focus();
  } catch (error) {
    $("note").textContent = error.name === "NotAllowedError"
      ? "Touch ID was cancelled or timed out. Try again when you’re ready."
      : error.message;
    $("go").disabled = false;
    $("go").textContent = "Use Touch ID";
    $("go").setAttribute("aria-busy", "false");
  }
};
