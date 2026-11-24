// SPDX-License-Identifier: LGPL-2.1-or-later
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
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

test("shellcheck lint mode enforces the mise.toml version pin", () => {
  const pin = /^shellcheck = "([^"]+)"$/m.exec(read("mise.toml"))?.[1];
  assert.ok(pin, "mise.toml must pin ShellCheck");
  const dir = mkdtempSync(join(tmpdir(), "snosi-shellcheck-"));
  try {
    for (const version of [pin, "0.0.1", `${pin}.1`, null]) {
      writeFileSync(join(dir, "shellcheck"), `#!/bin/sh
if [ "$1" = --version ]; then
  echo 'ShellCheck - shell script analysis tool'
  ${version === null ? ":" : `echo 'version: ${version}'`}
fi
exit 0
`, { mode: 0o755 });
      const result = spawnSync("bash", ["scripts/shellcheck.sh"], {
        cwd: root, encoding: "utf8",
        env: { ...process.env, PATH: `${dir}:/usr/bin:/bin` },
      });
      assert.ifError(result.error);
      if (version === pin) {
        assert.equal(result.status, 0, result.stderr);
      } else {
        assert.notEqual(result.status, 0, `must reject version ${version}`);
        assert.ok(result.stderr.includes(`mise.toml pins ${pin}`), result.stderr);
        if (version === null) {
          assert.ok(result.stderr.includes("found version unknown"), result.stderr);
        }
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
