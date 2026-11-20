// SPDX-License-Identifier: LGPL-2.1-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const root = new URL("../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");

test("make verify and validate.yml use the shared shellcheck script", () => {
  const makefile = read("Makefile");
  const recipe = /^verify:\r?\n((?:\t[^\n]*\n)+)/m.exec(makefile);
  assert.ok(recipe, "Makefile must have a verify recipe");
  assert.ok(recipe[1].split("\n").includes("\t./scripts/shellcheck.sh"),
    "verify must run the shared shellcheck script");
  assert.equal(read(".github/workflows/validate.yml")
    .split("./scripts/shellcheck.sh").length - 1, 1,
    "validate.yml must call the shared script exactly once");
  assert.ok(!makefile.includes("shellcheck -S"),
    "Makefile must not duplicate shellcheck flags");
  for (const entry of readdirSync(new URL(".github/workflows/", root),
    { recursive: true, withFileTypes: true })) {
    if (entry.isFile()) {
      const text = readFileSync(join(entry.parentPath, entry.name), "utf8");
      assert.ok(!text.includes("shellcheck -S"),
        `${entry.name} must not duplicate shellcheck flags`);
    }
  }
  assert.ok(read("scripts/shellcheck.sh").includes('shellcheck -S warning -x "${files[@]}"'),
    "the shared script must retain warning severity and source following");
});

test("shellcheck --list includes tracked shell scripts and excludes saved-unused", () => {
  const output = execFileSync("bash", ["scripts/shellcheck.sh", "--list"],
    { cwd: root, encoding: "utf8" });
  const files = output.trim().split("\n");
  assert.ok(files.length > 200, `expected more than 200 shell scripts, got ${files.length}`);
  assert.ok(files.includes("scripts/shellcheck.sh"), "the shared script must lint itself");
  assert.ok(files.every((path) => !path.startsWith("saved-unused/")),
    "saved-unused scripts must remain excluded");
});
