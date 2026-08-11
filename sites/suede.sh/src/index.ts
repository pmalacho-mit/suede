const REPO = "https://raw.githubusercontent.com/pmalacho-mit/suede";
const SCRIPTS = "/scripts";
const DEFAULT_REF = "refs/heads/main";

/** Paths that map to a specific file instead of getting `.sh` appended. */
const ALIASES: Record<string, string> = {
  "/suede": "/suede.py",
};

/** Extensions served verbatim. Anything else gets `.sh` appended. */
const PASSTHROUGH = [".sh", ".py"];

const cache = {
  cacheTtl: 60,
  cacheEverything: true,
} satisfies RequestInitCfProperties;

/**
 * `?ref=` pins a version. Without it, requests track `main`.
 *   ?ref=v2.0.0          -> refs/tags/v2.0.0
 *   ?ref=86abeeb         -> that commit
 *   ?ref=refs/heads/dev  -> verbatim
 * Returns null for anything that isn't a plausible ref, rather than silently
 * falling back — a typo'd pin should fail, not quietly serve `main`.
 */
function resolveRef(raw: string | null): string | null {
  if (!raw) return DEFAULT_REF;
  if (!/^[A-Za-z0-9._\-\/]+$/.test(raw) || raw.includes("..")) return null;
  if (/^[0-9a-f]{7,40}$/.test(raw)) return raw;
  if (raw.startsWith("refs/")) return raw;
  return `refs/tags/${raw}`;
}

function resolvePath(pathname: string): string | null {
  let decoded: string;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return null;
  }
  if (decoded.includes("..")) return null;
  const aliased = ALIASES[decoded] ?? decoded;
  return PASSTHROUGH.some((e) => aliased.endsWith(e)) ? aliased : aliased + ".sh";
}

function text(body: string, status: number): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

const index = `<!DOCTYPE html>
<html lang="en">
<head>
	<meta charset="UTF-8">
	<meta name="viewport" content="width=device-width, initial-scale=1.0">
	<title>suede.sh</title>
	<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css">
</head>
<body>
	<main class="container">
		<h1>suede.sh</h1>

		<p>This service provides cached access to scripts from:</p>
		<pre><code>${REPO}/${DEFAULT_REF}${SCRIPTS}</code></pre>

		<p>Requests may omit the <code>.sh</code> extension. Files ending in
		<code>.sh</code> or <code>.py</code> are served verbatim.</p>

		<h2>Examples</h2>
		<pre><code>curl -fsSL https://suede.sh/suede            # -> scripts/suede.py
curl -fsSL https://suede.sh/install/release  # the install bootstrap
curl -fsSL https://suede.sh/suede?ref=v2.0.0 # pinned to a tag</code></pre>

		<h2>Pinning</h2>
		<p>Add <code>?ref=</code> to pin a tag, branch or commit. Without it,
		requests track <code>main</code>. Pin in CI so installs stay reproducible.</p>

		<h2>Verifying</h2>
		<p>This worker is a proxy. To bypass it entirely, fetch the same file
		straight from GitHub — the content is identical:</p>
		<pre><code>curl -fsSL ${REPO}/${DEFAULT_REF}${SCRIPTS}/suede.py</code></pre>

		<hr>
		<p>Browse available scripts at
			<a href="https://github.com/pmalacho-mit/suede/tree/main/scripts">github.com/pmalacho-mit/suede</a>
		</p>
		<p>Source code for this worker:
			<a href="https://github.com/pmalacho-mit/suede/blob/sites/suede.sh/src/index.ts">github.com/pmalacho-mit/suede/tree/sites/suede.sh</a>
		</p>
	</main>
</body>
</html>`;

export default {
  async fetch(request, env, ctx): Promise<Response> {
    if (request.method !== "GET" && request.method !== "HEAD")
      return text("suede.sh: only GET and HEAD are supported\n", 405);

    const url = new URL(request.url);

    if (url.pathname === "/")
      return new Response(index, {
        headers: { "content-type": "text/html; charset=utf-8" },
      });

    const ref = resolveRef(url.searchParams.get("ref"));
    if (ref === null)
      return text(`suede.sh: invalid ref '${url.searchParams.get("ref")}'\n`, 400);

    const path = resolvePath(url.pathname);
    if (path === null) return text("suede.sh: invalid path\n", 400);

    const upstream = `${REPO}/${ref}${SCRIPTS}${path}`;

    // Deliberately do NOT forward client headers upstream: doing so leaks any
    // Authorization or Cookie the caller happened to send to a third party.
    const resp = await fetch(upstream, {
      method: request.method,
      headers: { "user-agent": "suede.sh-worker" },
      cf: cache,
    });

    if (!resp.ok)
      return text(
        `suede.sh: could not fetch '${path}' at ref '${ref}' (upstream ${resp.status})\n` +
          `upstream: ${upstream}\n` +
          `If you piped this into a shell, re-run with 'curl -fsSL' so the failure is caught.\n`,
        resp.status,
      );

    return new Response(resp.body, {
      status: resp.status,
      headers: {
        "content-type": "text/plain; charset=utf-8",
        "cache-control": "public, max-age=60",
        "x-suede-ref": ref,
      },
    });
  },
} satisfies ExportedHandler<Env>;
