import { defineConfig } from "@playwright/test";

// Headless Chromium only, never retried; the Touch ID page is checked on two phones, a narrow window and a
// desktop.
export default defineConfig({
  testDir: ".",
  fullyParallel: true,
  reporter: "list",
  retries: 0,
  use: { browserName: "chromium", headless: true },
  projects: [
    { name: "320", use: { viewport: { width: 320, height: 640 }, isMobile: true, hasTouch: true } },
    { name: "390", use: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true } },
    { name: "480", use: { viewport: { width: 480, height: 800 } } },
    { name: "1280", use: { viewport: { width: 1280, height: 800 } } },
  ],
});
