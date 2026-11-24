// SPDX-License-Identifier: LGPL-2.1-or-later
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const root = new URL("../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");
const firstWord = (text) => text.trim().split(/\s+/)[0]
  .replace(/[^\p{L}\p{N}]/gu, "").toLowerCase();

test("AGENTS.md counts the Frostyard policy scopes", () => {
  const claim = read("AGENTS.md").match(/\b([a-z]+)\s+Frostyard\s+scopes\b/i);
  assert.ok(claim, "AGENTS.md must give a number word before 'Frostyard scopes'");
  const policy = JSON.parse(read("shared/bootc-secure/tree/etc/containers/policy.json"));
  const scopes = new Set(Object.keys(policy.transports.docker)
    .filter((key) => /^ghcr\.io\/frostyard\/[^/]+$/.test(key)));
  const words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];
  assert.ok(scopes.size >= 1 && scopes.size <= words.length,
    `Frostyard scope count ${scopes.size} must have a number word from 1 to 10`);
  assert.equal(claim[1].toLowerCase(), words[scopes.size - 1],
    `AGENTS.md says '${claim[1]} Frostyard scopes'; policy has ${scopes.size}`);
});

test("the Current Sysexts table lists every sysext image", () => {
  const formats = imageFormats(new URL("mkosi.images/", root));
  for (const [name, format] of formats) {
    assert.notEqual(format, null,
      `cannot classify mkosi.images/${name}: no Format= in mkosi.conf or mkosi.conf.d/*.conf`);
  }
  const images = [...formats].filter(([, format]) => format === "sysext")
    .map(([name]) => name);
  assert.ok(images.length > 0, "mkosi.images must contain sysext images");

  const doc = read("docs/design/sysexts.md");
  const heading = /^## Current Sysexts[ \t]*\r?\n/m.exec(doc);
  assert.ok(heading, "sysexts.md must have a ## Current Sysexts section");
  const section = doc.slice(heading.index + heading[0].length).split(/^#/m)[0];
  const rows = [...section.matchAll(/^\|\s*\*\*([^*]+)\*\*\s*\|/gm)]
    .map((match) => match[1]);
  assert.ok(rows.length > 0, "the Current Sysexts table must contain names");
  assert.equal(new Set(rows).size, rows.length, "the Current Sysexts table must not repeat names");

  const missing = images.filter((name) => !rows.includes(name)).sort();
  const extra = rows.filter((name) => !images.includes(name)).sort();
  assert.deepEqual(rows.sort(), images.sort(),
    `Sysexts with no row: ${missing.join(", ") || "none"}; rows with no sysext: ${extra.join(", ") || "none"}`);
});

test("the ADR index agrees with every ADR status", () => {
  const index = read("docs/README.md");
  const heading = /^### Decisions \(ADRs\)[ \t]*\r?\n/m.exec(index);
  assert.ok(heading, "docs/README.md must have a ### Decisions (ADRs) section");
  const section = index.slice(heading.index + heading[0].length).split(/^#/m)[0];
  const entries = [...section.matchAll(/^[-*][ \t]+.*(?:\r?\n[ \t]+.*)*/gm)]
    .map(([entry]) => entry);
  const files = readdirSync(new URL("docs/adr/", root))
    .filter((name) => /^\d{4}-.+\.md$/.test(name));
  for (const file of files) {
    const status = /^- \*\*Status:\*\*[ \t]*(.+)$/m.exec(read(`docs/adr/${file}`));
    assert.ok(status, `${file} must have a - **Status:** line`);
    const matches = entries.filter((entry) =>
      /^[-*][ \t]+\[[^\]]*\]\(([^)\s]+)\)/.exec(entry)?.[1] === `adr/${file}`);
    assert.equal(matches.length, 1, `${file} must have exactly 1 ADR index entry`);
    const marker = /\) — \*\*([^*]+?):?\*\*/.exec(matches[0]);
    const statusWord = firstWord(status[1]);
    if (statusWord === "proposed") {
      assert.ok(marker, `${file} is Proposed and must have an ADR index status marker`);
    }
    if (marker) {
      assert.equal(firstWord(marker[1]), statusWord,
        `${file}: ADR index status '${firstWord(marker[1])}' differs from ADR status '${statusWord}'`);
    }
  }
  assert.ok(files.length > 40, `expected more than 40 checked ADRs, got ${files.length}`);
});

test("the Plans index agrees with every linked plan status", () => {
  const index = read("docs/README.md");
  const heading = /^### Plans[ \t]*\r?\n/m.exec(index);
  assert.ok(heading, "docs/README.md must have a ### Plans section");
  const section = index.slice(heading.index + heading[0].length)
    .split(/^#{1,6}[ \t]/m)[0];
  const entries = [...section.matchAll(/^[-*][ \t]+.*(?:\r?\n[ \t]+.*)*/gm)];
  assert.ok(entries.length > 0, "the Plans section must contain list entries");
  for (const [entry] of entries) {
    const links = [...entry.matchAll(/\[[^\]]*\]\((plans\/[^)\s]+\.md)\)/g)];
    assert.ok(links.length > 0, `Plans entry must link a plan: ${entry}`);
    const lastLink = links.at(-1);
    const status = entry.slice(lastLink.index + lastLink[0].length)
      .match(/\*\*([^*]+)\*\*/);
    assert.ok(status, `Plans entry must have a bold status after its links: ${entry}`);
    const indexedWord = firstWord(status[1]);
    for (const [, path] of links) {
      let plan;
      try {
        plan = read(`docs/${path}`);
      } catch (error) {
        assert.fail(`Plans entry links an unreadable file ${path}: ${entry}\n${error.message}`);
      }
      const planStatus = /^\*\*Status:\*\*[ \t]*(.+)$/m.exec(plan);
      assert.ok(planStatus, `${path} must have a **Status:** line: ${entry}`);
      const planWord = firstWord(planStatus[1]);
      assert.equal(indexedWord, planWord,
        `Plans entry ${entry}\nIndex word '${indexedWord}' differs from ${path} word '${planWord}'`);
    }
  }
});

export function imageFormats(imagesDir) {
  const dir = imagesDir instanceof URL ? fileURLToPath(imagesDir) : imagesDir;
  const formats = new Map();
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const config = join(dir, entry.name, "mkosi.conf");
    const fragments = join(dir, entry.name, "mkosi.conf.d");
    const files = [config];
    if (existsSync(fragments)) {
      files.push(...readdirSync(fragments).filter((name) => name.endsWith(".conf"))
        .sort().map((name) => join(fragments, name)));
    }
    let format = null;
    for (const file of files) {
      if (!existsSync(file)) continue;
      for (const match of readFileSync(file, "utf8").matchAll(/^Format=(\S+)\s*$/gm)) {
        format = match[1];
      }
    }
    formats.set(entry.name, format);
  }
  return formats;
}

test("imageFormats reads ordered fragments and retains unclassified images", () => {
  const dir = mkdtempSync(join(tmpdir(), "snosi-image-formats-"));
  try {
    const configs = {
      "a/mkosi.conf": "Format=sysext\n",
      "b/mkosi.conf": "[Output]\n",
      "b/mkosi.conf.d/10-format.conf": "Format=sysext\n",
      "c/mkosi.conf": "Format=directory\n",
      "d/mkosi.conf": "[Output]\n",
      "e/mkosi.conf": "Format=directory\n",
      "e/mkosi.conf.d/20.conf": "Format=sysext\n",
    };
    for (const [name, text] of Object.entries(configs)) {
      const file = join(dir, name);
      mkdirSync(join(file, ".."), { recursive: true });
      writeFileSync(file, text);
    }
    assert.deepEqual(imageFormats(dir), new Map([
      ["a", "sysext"], ["b", "sysext"], ["c", "directory"],
      ["d", null], ["e", "sysext"],
    ]));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
