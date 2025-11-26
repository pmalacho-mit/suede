const base = 'https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts';
const cache = {
	cacheTtl: 60,
	cacheEverything: true,
} satisfies RequestInitCfProperties;

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
		<pre><code>${base}</code></pre>
		
		<p>Requests may omit the <code>.sh</code> file extension for convenience.</p>
		
		<h2>Example</h2>
		<pre><code>curl https://suede.sh/utils/degit</code></pre>
		
		<p>Returns the content of:</p>
		<pre><code>https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts/utils/degit.sh</code></pre>
		
		<hr>
		
		<p>
			Browse available scripts at 
			<a href="https://github.com/pmalacho-mit/suede/tree/main/scripts">github.com/pmalacho-mit/suede</a>
		</p>
		
		<p>
			Source code for this worker: 
			<a href="https://github.com/pmalacho-mit/suede-cloudflare-worker">github.com/pmalacho-mit/suede-cloudflare-worker</a>
		</p>
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
