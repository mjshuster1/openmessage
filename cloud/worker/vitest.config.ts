import { defineConfig } from "vitest/config";
import { fileURLToPath } from "node:url";

export default defineConfig({
  resolve: {
    alias: {
      // The OAuth provider imports this runtime-only module. Tests run in Node,
      // so point it at a stub.
      "cloudflare:workers": fileURLToPath(new URL("./test/stubs/cloudflare-workers.ts", import.meta.url)),
    },
  },
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    // Process the OAuth provider through Vite so the cloudflare:workers alias applies to it.
    server: { deps: { inline: ["@cloudflare/workers-oauth-provider"] } },
  },
});
