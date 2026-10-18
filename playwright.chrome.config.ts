import { defineConfig } from "@playwright/test";
import base from "./playwright.config";
// Installed Chrome uses fresh, test-owned contexts; never attach the user's profile.
export default defineConfig({
  ...base,
  outputDir: "test-results/chrome",
  use: { ...base.use, channel: "chrome" },
});
