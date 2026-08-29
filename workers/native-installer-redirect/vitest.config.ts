import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
    }),
  ],
  test: {
    coverage: {
      // The Cloudflare workers pool runs tests inside workerd, where the v8
      // provider's node:inspector/promises dependency is unavailable; istanbul
      // is the only provider that instruments successfully in this pool.
      provider: "istanbul",
      include: ["src/**"],
      reporter: ["text", "lcov"],
    },
  },
});
