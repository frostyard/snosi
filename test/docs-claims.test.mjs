// SPDX-License-Identifier: LGPL-2.1-or-later
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
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
