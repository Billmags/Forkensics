import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        // SPIKE_SECRET must be set for the Miniflare environment.
        // Tests inject env directly via worker.fetch(req, env, ctx);
        // this value is only used to satisfy the binding requirement.
        bindings: { SPIKE_SECRET: "test-spike-secret" },
      },
    }),
  ],
});
