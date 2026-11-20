import { defineConfig } from "@playwright/test";

// The specs use no browser fixture, so they run without installed browsers.
export default defineConfig({ testDir: "e2e", reporter: "list" });
