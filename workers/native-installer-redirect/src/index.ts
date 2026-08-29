const STABLE_PATH = "/isos/native/v1/snosi-installer-latest-x86-64.iso";
const HEALTH_PATH = "/isos/native/v1/healthz";
const INDEX_KEY = "isos/native/v1/SHA256SUMS";
const ISO_KEY_PREFIX = "isos/native/v1/";
const PUBLIC_BASE = "https://repository.frostyard.org/isos/native/v1/";
const MAX_INDEX_BYTES = 16 * 1024;

const NO_STORE_HEADERS = {
  "Cache-Control": "no-store, max-age=0",
  Expires: "0",
};

const INDEX_LINE = /^([0-9a-f]{64})  (\S+)$/;
const INSTALLER_NAME = /^snosi-installer_[0-9]{14}_x86-64\.iso$/;

class ResolutionError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

export function installerNameFromIndex(index: string): string {
  const matches: string[] = [];

  for (const line of index.split("\n")) {
    if (line === "") continue;

    const entry = INDEX_LINE.exec(line);
    if (!entry) throw new ResolutionError("malformed_index");

    const name = entry[2];
    if (INSTALLER_NAME.test(name)) matches.push(name);
  }

  if (matches.length === 0) throw new ResolutionError("installer_missing");
  if (matches.length !== 1) throw new ResolutionError("installer_ambiguous");
  return matches[0];
}

function plainResponse(request: Request, body: string, status: number, headers: HeadersInit = {}): Response {
  return new Response(request.method === "HEAD" ? null : body, {
    status,
    headers: {
      ...NO_STORE_HEADERS,
      "Content-Type": "text/plain; charset=utf-8",
      ...headers,
    },
  });
}

function jsonResponse(request: Request, body: unknown, status: number, headers: HeadersInit = {}): Response {
  return new Response(request.method === "HEAD" ? null : JSON.stringify(body), {
    status,
    headers: {
      ...NO_STORE_HEADERS,
      "Content-Type": "application/json; charset=utf-8",
      ...headers,
    },
  });
}

// Resolves the currently-published installer name and confirms the ISO
// object it names actually exists in R2. This is the one dependency
// (`env.REPOSITORY`) required to serve the stable redirect, so both the
// redirect handler and the /healthz probe below share this exact check —
// health must fail whenever the redirect itself would fail.
async function resolveInstallerName(env: Env): Promise<string> {
  const indexObject = await env.REPOSITORY.get(INDEX_KEY);
  if (!indexObject) throw new ResolutionError("index_missing");
  if (indexObject.size > MAX_INDEX_BYTES) throw new ResolutionError("index_oversized");

  const name = installerNameFromIndex(await indexObject.text());
  if (!(await env.REPOSITORY.head(`${ISO_KEY_PREFIX}${name}`))) {
    throw new ResolutionError("installer_object_missing");
  }
  return name;
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === HEALTH_PATH) {
      if (request.method !== "GET" && request.method !== "HEAD") {
        return plainResponse(request, "Method not allowed\n", 405, { Allow: "GET, HEAD" });
      }

      try {
        await resolveInstallerName(env);
        return jsonResponse(request, { status: "ok" }, 200);
      } catch (error) {
        const code = error instanceof ResolutionError ? error.code : "r2_failure";
        console.error(JSON.stringify({ event: "installer_redirect_unhealthy", code }));
        return jsonResponse(request, { status: "unhealthy", reason: code }, 503, {
          "Retry-After": "60",
        });
      }
    }

    if (url.pathname !== STABLE_PATH) {
      return plainResponse(request, "Not found\n", 404);
    }

    if (request.method !== "GET" && request.method !== "HEAD") {
      return plainResponse(request, "Method not allowed\n", 405, { Allow: "GET, HEAD" });
    }

    try {
      const name = await resolveInstallerName(env);

      return new Response(null, {
        status: 302,
        headers: {
          ...NO_STORE_HEADERS,
          Location: new URL(name, PUBLIC_BASE).href,
        },
      });
    } catch (error) {
      const code = error instanceof ResolutionError ? error.code : "r2_failure";
      console.error(JSON.stringify({ event: "installer_redirect_failed", code }));
      return plainResponse(request, "Installer download is temporarily unavailable\n", 503, {
        "Retry-After": "60",
      });
    }
  },
} satisfies ExportedHandler<Env>;
