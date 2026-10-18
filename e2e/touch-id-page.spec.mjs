// The Touch ID page the agent helpers open on a Mac, checked in headless Chromium with a
// virtual Touch ID authenticator: what a person reads, that nothing on the page moves when
// a step finishes or fails, and the real helper locking and showing a key through it.

import { test, expect } from "@playwright/test";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

const helper = new URL("../priv/static/agent/siwa_agent.py", import.meta.url).pathname;
const source = readFileSync(helper, "utf8");
const template = source.slice(source.indexOf('PASSKEY_PAGE = """') + 18, source.indexOf('"""', source.indexOf('PASSKEY_PAGE = """') + 18));
const address = "0x00000000000000000000000000000000000a11ce";
const pageUrl = "http://localhost:4999/page";

// Words that belong to how the page works, not to what a person needs to read.
const internal = /localhost|passkey|private key|terminal|credential|prf|webauthn/i;

// Each step's title and sentence, before Touch ID and after it.
const steps = {
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
};

// A virtual Touch ID; the returned function removes it.
async function touchId(page, options = {}) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
      hasPrf: true,
      ...options,
    },
  });
  return () => cdp.send("WebAuthn.removeVirtualAuthenticator", { authenticatorId });
}

// Serves the page the way the helper does, and answers its POST with `status`.
async function open(page, mode, credentialId, status = 204) {
  const setup = JSON.stringify({ mode, address, credentialId, opener: "Claude Code" }).replaceAll("<", "\\u003c");
  const posts = [];
  await page.route(pageUrl, (route) => {
    if (route.request().method() === "POST") {
      posts.push(JSON.parse(route.request().postData()));
      return route.fulfill({ status });
    }
    return route.fulfill({ contentType: "text/html; charset=utf-8", body: template.replace("__SETUP__", setup) });
  });
  await page.goto(pageUrl);
  return posts;
}

const visibleText = (page) => page.locator("body").innerText();
const top = async (page, selector) => (await page.locator(selector).boundingBox()).y;
// Where the button, the address box and the footer sit; finishing or failing must not move them.
const layout = async (page) => [await top(page, "#go"), await top(page, ".identity"), await top(page, "footer")];

for (const scheme of ["light", "dark"]) {
  test(`a person locks, unlocks and shows a key in ${scheme} mode`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: scheme });
    await touchId(page);
    let credentialId = null;

    for (const mode of ["lock", "unlock", "show"]) {
      const posts = await open(page, mode, credentialId);
      const [before, after] = steps[mode];

      await expect(page.locator("h1")).toHaveText(before[0]);
      await expect(page.locator("#lead")).toHaveText(before[1]);
      await expect(page.locator("#lead")).toBeVisible();
      await expect(page.locator("#opener")).toHaveText("Opened by Claude Code");
      await expect(page.locator("#address")).toHaveText(address);
      await expect(page.locator("#done")).toBeHidden();
      expect(await visibleText(page)).not.toMatch(internal);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      const placed = await layout(page);

      await page.getByRole("button", { name: "Use Touch ID" }).click();

      await expect(page.locator("h1")).toHaveText(after[0]);
      await expect(page.locator("#lead-done")).toHaveText(after[1]);
      await expect(page.locator("#lead-done")).toBeVisible();
      await expect(page.locator("#lead")).toBeHidden();
      await expect(page.locator("#go")).toHaveText("✓ Done");
      await expect(page.locator("#done")).toHaveText("You can safely close this page");
      await expect(page.locator("#done")).toBeVisible();
      await expect(page.locator("#share")).toBeHidden();
      await expect(page.locator("#note")).toHaveText("");
      expect(await visibleText(page)).not.toMatch(internal);
      expect(await layout(page)).toEqual(placed);
      expect(posts).toHaveLength(1);
      expect(posts[0].secret).toMatch(/^[0-9a-f]{64}$/);
      if (credentialId) expect(posts[0].credential_id).toBe(credentialId);
      credentialId = posts[0].credential_id;
      await page.unroute(pageUrl);
    }
  });
}

test("finishing moves nothing at any width from 300 to 1280", async ({ page }, info) => {
  test.skip(info.project.name !== "1280", "one sweep covers every width");
  test.setTimeout(60_000);
  const moved = [];
  for (let width = 300; width <= 1280; width += 20) {
    await page.setViewportSize({ width, height: 900 });
    // A fresh Touch ID for each width: the virtual one holds only a few keys.
    const remove = await touchId(page);
    let credentialId = null;
    for (const mode of ["lock", "unlock", "show"]) {
      // Unlock and show use the key made in lock mode at this width.
      const posts = await open(page, mode, credentialId);
      const placed = await layout(page);
      await page.getByRole("button", { name: "Use Touch ID" }).click();
      await expect(page.locator("#done"), `${mode} at ${width}`).toBeVisible();
      if (JSON.stringify(await layout(page)) !== JSON.stringify(placed)) moved.push(`${mode} at ${width}`);
      if (mode === "lock") credentialId = posts[0].credential_id;
      await page.unroute(pageUrl);
    }
    await remove();
  }
  expect(moved).toEqual([]);
});

test("cancelled Touch ID says so and lets the person try again", async ({ page }) => {
  await touchId(page, { isUserVerified: false });
  await open(page, "lock", null);
  const placed = await layout(page);
  await page.getByRole("button", { name: "Use Touch ID" }).click();
  await expect(page.locator("#note")).toHaveText("Touch ID was cancelled or timed out. Try again when you’re ready.");
  await expect(page.getByRole("button", { name: "Use Touch ID" })).toBeEnabled();
  await expect(page.locator("#share")).toBeVisible();
  expect(await layout(page)).toEqual(placed);
});

test("an agent that stopped waiting is named in plain words", async ({ page }) => {
  await touchId(page);
  await open(page, "lock", null, 404);
  const placed = await layout(page);
  await page.getByRole("button", { name: "Use Touch ID" }).click();
  await expect(page.locator("#note")).toHaveText("Your agent stopped waiting. Ask it to try again.");
  expect(await layout(page)).toEqual(placed);
});

test("a browser that cannot hand over the key's secret is told which browsers work", async ({ page }) => {
  await touchId(page, { hasPrf: false });
  await open(page, "lock", null);
  const placed = await layout(page);
  await page.getByRole("button", { name: "Use Touch ID" }).click();
  await expect(page.locator("#note")).toHaveText("This browser can’t use Touch ID here. Open this page in Safari or Chrome.");
  expect(await layout(page)).toEqual(placed);
});

test("any other browser error shows one plain line and keeps the browser's words in the log", async ({ page }) => {
  const raw = "Resident credentials or empty 'allowCredentials' lists are not supported at this time.";
  await page.addInitScript((message) => {
    navigator.credentials.create = () => Promise.reject(new DOMException(message, "NotSupportedError"));
  }, raw);
  const logged = [];
  page.on("console", (line) => line.type() === "error" && logged.push(line.text()));
  await open(page, "lock", null);
  const placed = await layout(page);
  await page.getByRole("button", { name: "Use Touch ID" }).click();
  await expect(page.locator("#note")).toHaveText("Touch ID couldn’t finish. Try again, or open this page in Safari or Chrome.");
  expect(await visibleText(page)).not.toContain(raw);
  expect(logged.join("\n")).toContain(raw);
  expect(await layout(page)).toEqual(placed);
});

// The real Python helper, its own page server and the key file it writes.
test("keygen locks a new key with Touch ID and show-key opens it again", async ({ page }, info) => {
  test.skip(process.platform !== "darwin", "the helper locks keys with Touch ID only on a Mac");
  test.skip(info.project.name !== "1280", "one run of the real helper is enough");
  // uv starts the helper twice, and the first start may install its two libraries.
  test.setTimeout(120_000);
  const home = mkdtempSync(join(tmpdir(), "siwa-e2e-"));
  // A do-nothing `open`, so the helper never opens the person's own browser.
  const bin = mkdtempSync(join(tmpdir(), "siwa-e2e-bin-"));
  writeFileSync(join(bin, "open"), "#!/bin/sh\nexit 0\n");
  chmodSync(join(bin, "open"), 0o755);
  const env = { ...process.env, SIWA_AGENT_HOME: home, PATH: `${bin}:${process.env.PATH}` };
  const children = [];
  await touchId(page);

  // The page address the helper prints, and how it ended; an early end fails with its own words.
  const run = (command) => {
    const child = spawn("uv", ["run", "-q", helper, command], { env });
    children.push(child);
    const out = [];
    let err = "";
    child.stdout.on("data", (chunk) => out.push(chunk));
    const done = new Promise((resolve) => child.on("exit", (code) => resolve({ code, out: Buffer.concat(out).toString(), err })));
    const pageAddress = new Promise((resolve, reject) => {
      child.stderr.on("data", (chunk) => {
        err += chunk;
        const line = err.split("\n").find((text) => text.includes('"page"'));
        if (line) resolve(JSON.parse(line).page);
      });
      done.then(({ code }) => reject(new Error(`${command} ended (${code}) before opening its page: ${err}`)));
    });
    return { pageAddress, done };
  };

  try {
    const keygen = run("keygen");
    await page.goto(await keygen.pageAddress);
    await page.getByRole("button", { name: "Use Touch ID" }).click();
    await expect(page.locator("h1")).toHaveText("Agent key protected");
    const made = await keygen.done;
    expect(made.code, made.err).toBe(0);
    const key = JSON.parse(readFileSync(join(home, "key.json"), "utf8"));
    expect(key.private_key).toBeUndefined();
    expect(key.locked.box).toMatch(/^[0-9a-f]+$/);

    const show = run("show-key");
    await page.goto(await show.pageAddress);
    await page.getByRole("button", { name: "Use Touch ID" }).click();
    await expect(page.locator("h1")).toHaveText("Touch ID confirmed");
    const shown = await show.done;
    expect(shown.code, shown.err).toBe(0);
    expect(JSON.parse(shown.out)).toMatchObject({ address: key.address, private_key: expect.stringMatching(/^0x[0-9a-f]{64}$/) });
  } finally {
    for (const child of children) child.kill();
    // keygen leaves a helper holding the unlocked key until the Mac restarts; stop it.
    if (existsSync(join(home, "key.json"))) {
      const { address: made } = JSON.parse(readFileSync(join(home, "key.json"), "utf8"));
      const folder = execFileSync("getconf", ["DARWIN_USER_TEMP_DIR"], { encoding: "utf8" }).trim();
      const socket = join(folder, `siwa-agent-${createHash("sha256").update(made).digest("hex").slice(0, 16)}.sock`);
      await new Promise((resolve) => {
        const connection = createConnection(socket, () => connection.write('{"op": "stop"}\n'));
        connection.on("data", () => connection.destroy()).on("close", resolve).on("error", resolve);
      });
    }
    rmSync(home, { recursive: true, force: true });
    rmSync(bin, { recursive: true, force: true });
  }
});
