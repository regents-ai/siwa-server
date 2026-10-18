import { defineConfig } from "@playwright/test";

// Headless Chromium only; the Touch ID page is checked at phone and desktop widths.
export default defineConfig({
  testDir: ".",
  fullyParallel: true,
  reporter: "list",
  use: { browserName: "chromium", headless: true },
  projects: [
    { name: "390", use: { viewport: { width: 390, height: 844 } } },
    { name: "1280", use: { viewport: { width: 1280, height: 800 } } },
  ],
});
