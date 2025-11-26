const base = 'https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts';
const cache = {
	cacheTtl: 60,
	cacheEverything: true,
} satisfies RequestInitCfProperties;

const index = `<!DOCTYPE html>
<html>
<head>
<title>suede.sh</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@picocss/pico@2/css/pico.min.css">
</head>
<body>
<main class="container">
<p>This is a proxy for <code>${base}</code>.</p>
<p>You can request files here and optionally omit the <code>.sh</code> suffix.</p>
<p><strong>Example:</strong> <code>curl https://suede.sh/utils/degit</code></p>
<p>View available scripts at <a href="https://github.com/pmalacho-mit/suede/tree/main/scripts">github.com/pmalacho-mit/suede</a></p>
</main>
</body>
</html>`

export default {
	async fetch(request, env, ctx): Promise<Response> {
		const url = new URL(request.url);
		let { pathname } = url;

		if (pathname === '/')
			return new Response(index, {
				headers: { 'Content-Type': 'text/html' },
			});

		if (!pathname.endsWith('.sh')) pathname += '.sh';

		const upstream = new URL(base + pathname);

		const resp = await fetch(upstream.toString(), {
			method: request.method,
			headers: request.headers,
			cf: cache,
		});

		return new Response(resp.body, {
			status: resp.status,
			statusText: resp.statusText,
			headers: resp.headers,
		});
	},
} satisfies ExportedHandler<Env>;
