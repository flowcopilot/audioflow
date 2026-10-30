// The live_base and live_ai_elements packages are symlinks into deps/. Bare
// imports inside them resolve from their real paths, which have no
// node_modules, so the shared peers are aliased to this directory's copies.
// `mix assets.build` sets NODE_PATH to the Mix build path for the colocated hooks.
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);

if (!process.env.NODE_PATH) {
  throw new Error("NODE_PATH is not set. Run `mix assets.build`.");
}

const buildPath = process.env.NODE_PATH.split(path.delimiter)
  .filter(Boolean)
  .map((entry) => path.resolve(entry));

export default {
  input: "js/app.js",
  platform: "browser",
  resolve: {
    modules: ["node_modules", ...buildPath],
    alias: Object.fromEntries(
      [
        "@floating-ui/dom",
        "@rive-app/webgl2",
        "embla-carousel",
        "embla-carousel-autoplay",
        "motion",
      ].map((name) => [name, require.resolve(name)]),
    ),
  },
  output: { dir: "../priv/static/assets", format: "iife" },
  onwarn(warning, warn) {
    // An unresolved import becomes a missing global and stops LiveView at load.
    if (["UNRESOLVED_IMPORT", "MISSING_GLOBAL_NAME"].includes(warning.code)) {
      throw new Error(`${warning.code}: ${warning.message}`);
    }

    warn(warning);
  },
};
