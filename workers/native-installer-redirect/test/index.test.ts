import { env, exports } from "cloudflare:workers";
import { afterEach, describe, expect, it } from "vitest";
import { installerNameFromIndex } from "../src/index";

const STABLE_URL =
  "https://repository.frostyard.org/isos/native/v1/snosi-native-installer-latest-x86-64.iso";
const INDEX_KEY = "isos/native/v1/SHA256SUMS";
const VERSION = "20260717123456";
const ISO_NAME = `snosi-native-installer_${VERSION}_x86-64.iso`;
const ISO_KEY = `isos/native/v1/${ISO_NAME}`;
const HASH = "a".repeat(64);

async function clearBucket(): Promise<void> {
  let cursor: string | undefined;
  do {
    const page = await env.REPOSITORY.list({ cursor });
    if (page.objects.length > 0) await env.REPOSITORY.delete(page.objects.map(({ key }) => key));
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
}

async function putValidPublication(): Promise<void> {
  await env.REPOSITORY.put(INDEX_KEY, `${HASH}  ${ISO_NAME}\n`);
  await env.REPOSITORY.put(ISO_KEY, "fixture");
}

afterEach(clearBucket);

describe("installerNameFromIndex", () => {
  it("selects the one installer entry among other valid entries", () => {
    const index = `${"b".repeat(64)}  release-notes.txt\n${HASH}  ${ISO_NAME}\n`;
    expect(installerNameFromIndex(index)).toBe(ISO_NAME);
  });

  it.each([
    ["an empty index", ""],
    ["a malformed hash", `xyz  ${ISO_NAME}\n`],
    ["non-canonical spacing", `${HASH} ${ISO_NAME}\n`],
    ["a carriage return", `${HASH}  ${ISO_NAME}\r\n`],
    ["no installer", `${HASH}  release-notes.txt\n`],
    ["multiple installers", `${HASH}  ${ISO_NAME}\n${"b".repeat(64)}  snosi-native-installer_20260718123456_x86-64.iso\n`],
  ])("rejects %s", (_description, index) => {
    expect(() => installerNameFromIndex(index)).toThrow();
  });
});

describe("native installer redirect", () => {
  it("redirects GET to the indexed immutable ISO without caching", async () => {
    await putValidPublication();

    const response = await exports.default.fetch(STABLE_URL, { redirect: "manual" });

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      `https://repository.frostyard.org/isos/native/v1/${ISO_NAME}`,
    );
    expect(response.headers.get("cache-control")).toBe("no-store, max-age=0");
    expect(await response.text()).toBe("");
  });

  it("redirects HEAD and ignores query parameters", async () => {
    await putValidPublication();

    const response = await exports.default.fetch(`${STABLE_URL}?source=docs`, {
      method: "HEAD",
      redirect: "manual",
    });

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      `https://repository.frostyard.org/isos/native/v1/${ISO_NAME}`,
    );
    expect(await response.text()).toBe("");
  });

  it("rejects unsupported methods", async () => {
    const response = await exports.default.fetch(STABLE_URL, { method: "POST" });

    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("GET, HEAD");
    expect(response.headers.get("cache-control")).toBe("no-store, max-age=0");
  });

  it("rejects suffix paths caught by the route wildcard", async () => {
    const response = await exports.default.fetch(`${STABLE_URL}.backup`);
    expect(response.status).toBe(404);
  });

  it("returns 503 when the index is missing", async () => {
    const response = await exports.default.fetch(STABLE_URL);

    expect(response.status).toBe(503);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(response.headers.get("cache-control")).toBe("no-store, max-age=0");
  });

  it("returns 503 when the index is malformed", async () => {
    await env.REPOSITORY.put(INDEX_KEY, `not-a-hash  ${ISO_NAME}\n`);

    const response = await exports.default.fetch(STABLE_URL);
    expect(response.status).toBe(503);
  });

  it("returns 503 when the index is oversized", async () => {
    await env.REPOSITORY.put(INDEX_KEY, "x".repeat(16 * 1024 + 1));

    const response = await exports.default.fetch(STABLE_URL);
    expect(response.status).toBe(503);
  });

  it("returns 503 rather than redirecting to a missing object", async () => {
    await env.REPOSITORY.put(INDEX_KEY, `${HASH}  ${ISO_NAME}\n`);

    const response = await exports.default.fetch(STABLE_URL);
    expect(response.status).toBe(503);
  });
});
