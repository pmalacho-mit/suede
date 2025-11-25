const base = 'https://raw.githubusercontent.com/pmalacho-mit/suede/refs/heads/main/scripts';
const cache = {
	cacheTtl: 60,
	cacheEverything: true,
} satisfies RequestInitCfProperties;

export default {
	async fetch(request, env, ctx): Promise<Response> {
		const url = new URL(request.url);
		let { pathname } = url;

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
