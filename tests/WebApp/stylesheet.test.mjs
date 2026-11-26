// The browser app's stylesheet: one stray brace once put every rule after it into a wide-window
// block, so phones lost the setup, cinema and admin styles. Every block must close where it opens.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("every block in app.css closes, so no rule falls into the wrong media query", () => {
  const css = readFileSync(new URL("../../src/Aurelia.Server/WebApp/app.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  let depth = 0, line = 1;
  for (const character of css) {
    if (character === "\n") line++;
    if (character === "{") depth++;
    if (character === "}") depth--;
    assert.ok(depth >= 0, `A closing brace without an opening one on line ${line}.`);
  }
  assert.equal(depth, 0, "A block is never closed.");
  // The rules added last must stay at the top level, outside any media query.
  const last = css.lastIndexOf(".welcome-finish");
  const before = css.slice(0, last);
  assert.equal((before.match(/{/g) ?? []).length, (before.match(/}/g) ?? []).length);
});

test("text fields inside vertical editor fields do not collapse under flex: 1", () => {
  const css = readFileSync(new URL("../../src/Aurelia.Server/WebApp/app.css", import.meta.url), "utf8");
  assert.match(css, /\.editor-field\s+\.text-field[^{]*\{[^}]*flex:\s*(?:none|0\s+0\s+auto)/);
});

test("palette color swatches keep their gradient backgrounds and increased-contrast + skip-link rules exist", () => {
  const css = readFileSync(new URL("../../src/Aurelia.Server/WebApp/app.css", import.meta.url), "utf8");
  assert.doesNotMatch(css, /\.picture-choice,\s*\.palette-choice\s*\{[^}]*background:\s*none/);
  assert.match(css, /\.statistics-body\s*\{[^}]*padding:\s*0\s+var\(--gutter\)/);
  assert.match(css, /\.skip-link\s*\{/);
  assert.match(css, /@media\s*\(prefers-contrast:\s*more\)/);
});

test("path containers preserve repeated spaces and sidebar resize handle has a keyboard focus style", () => {
  const css = readFileSync(new URL("../../src/Aurelia.Server/WebApp/app.css", import.meta.url), "utf8");
  assert.match(css, /\.mono\s*\{[^}]*white-space:\s*pre-wrap/);
  assert.match(css, /\.import-path\s*\{[^}]*white-space:\s*pre-wrap/);
  assert.match(css, /\.health-file\s*\{[^}]*white-space:\s*pre-wrap/);
  assert.match(css, /\.folder-entry\s*\{[^}]*white-space:\s*pre-wrap/);
  assert.match(css, /\.sidebar-resize:focus-visible\s*\{/);
});
