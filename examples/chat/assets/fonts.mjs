// Copies the docs fonts into priv/static/assets/fonts. Tailwind does not copy
// the font files that @fontsource stylesheets reference, so the layout links
// these copies directly. Only the files each stylesheet names are copied.
import { cpSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);
const out = path.resolve(import.meta.dirname, "../priv/static/assets/fonts");

for (const [name, sheets] of [
  ["@fontsource-variable/bricolage-grotesque", ["standard.css"]],
  ["@fontsource/ibm-plex-mono", ["400.css", "600.css"]],
]) {
  const root = path.dirname(require.resolve(`${name}/package.json`));
  const dest = path.join(out, path.basename(name));

  for (const sheet of sheets) {
    const css = readFileSync(path.join(root, sheet), "utf8");
    const files = [sheet, ...css.matchAll(/url\(\.\/([^)]+)\)/g).map((m) => m[1])];

    for (const file of files) cpSync(path.join(root, file), path.join(dest, file));
  }
}
