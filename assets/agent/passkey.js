const setup = __SETUP__;
// Each step's title and sentence, before Touch ID and after it.
const [words, result] = {
  lock: [
    ["Protect your agent key", "Confirm with Touch ID to keep your agent’s key safe."],
    ["Agent key protected", "Go back to your agent to finish setting up."],
  ],
  unlock: [
    ["Unlock your agent key", "Confirm with Touch ID so your agent can sign in. You’re asked once after each Mac restart."],
    ["Agent key unlocked", "Go back to your agent to continue."],
  ],
  show: [
    ["Show your agent key", "Confirm with Touch ID to show the key in the window where you asked for it. Only continue if you asked."],
    ["Touch ID confirmed", "Go back to the window where you asked for the key."],
  ],
}[setup.mode];
const $ = (id) => document.getElementById(id);
// A message written for the person; any other error shows one plain line.
class Plain extends Error {}
document.title = words[0] + " · Regents";
$("title").textContent = words[0];
$("lead").textContent = words[1];
$("lead-done").textContent = result[1];
$("opener").textContent = "Opened by " + setup.opener;
$("address").textContent = setup.address;
$("copy").onclick = async () => {
  try {
    await navigator.clipboard.writeText($("message").textContent);
    $("copy").textContent = "✓ Copied";
  } catch {
    $("copy").textContent = "Couldn’t copy. Select the message instead.";
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
  if (!first) throw new Plain("This browser can’t use Touch ID here. Open this page in Safari or Chrome.");
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
    if (!sent?.ok) throw new Plain("Your agent stopped waiting. Ask it to try again.");
    $("title").textContent = result[0];
    $("lead").setAttribute("data-hidden", "");
    $("lead-done").removeAttribute("data-hidden");
    $("title").setAttribute("aria-describedby", "lead-done");
    document.title = result[0] + " · Regents";
    $("go").textContent = "✓ Done";
    $("go").setAttribute("data-complete", "");
    $("done").setAttribute("data-shown", "");
    $("share").hidden = true;
    $("go").setAttribute("aria-busy", "false");
    $("title").focus();
  } catch (error) {
    if (error.name === "NotAllowedError") {
      $("note").textContent = "Touch ID was cancelled or timed out. Try again when you’re ready.";
    } else if (error instanceof Plain) {
      $("note").textContent = error.message;
    } else {
      console.error(error);
      $("note").textContent = "Touch ID couldn’t finish. Try again, or open this page in Safari or Chrome.";
    }
    $("go").disabled = false;
    $("go").textContent = "Use Touch ID";
    $("go").setAttribute("aria-busy", "false");
  }
};
