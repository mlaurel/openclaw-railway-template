// Checks documentation/RAILWAY_TEMPLATE.md, the source of the published
// template's readme. Railway strips anything that looks like an HTML tag when
// the readme is saved, so a placeholder such as <tailnet> silently disappears
// and leaves addresses like https://openclaw..ts.net on the public page.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";

const readme = await readFile(new URL("../documentation/RAILWAY_TEMPLATE.md", import.meta.url), "utf8");

test("uses no angle-bracket placeholders Railway would strip", () => {
  assert.deepEqual(readme.match(/<[^>\s]+>/g) ?? [], []);
});

test("has no address left empty by a stripped placeholder", () => {
  assert.doesNotMatch(readme, /\.\.ts\.net/);
});

test("names the only variable the template asks for", () => {
  assert.match(readme, /`TS_AUTHKEY`/);
});
