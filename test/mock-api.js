// Mock tardisec API + OIDC issuer for the act e2e. No deps.
import { createHash } from "node:crypto";
import { createServer } from "node:http";

const OIDC_TOKEN = "test-oidc-token";
const files = {
	".tardisec.json": JSON.stringify(
		{
			$schema: "https://tardisec.com/schemas/0.0.0/schema.json",
			dns: { txt: ["tardisec-verification=vrfy1234"] },
			http: {
				headers: {
					"Content-Security-Policy": "default-src 'self'",
					"X-Content-Type-Options": "nosniff",
				},
			},
		},
		null,
		4,
	),
	".tardisec.sveltekit.json": JSON.stringify(
		{ csp: { directives: { "default-src": ["self"] } } },
		null,
		4,
	),
};

createServer((req, res) => {
	const url = new URL(req.url, "http://localhost");
	if (url.pathname === "/oidc") {
		// GitHub's runtime endpoint: requires the request token, echoes an OIDC JWT.
		if (req.headers.authorization !== "Bearer req-token") {
			res.writeHead(401).end();
			return;
		}
		res.writeHead(200, { "content-type": "application/json" });
		res.end(JSON.stringify({ value: OIDC_TOKEN }));
		return;
	}
	const match = url.pathname.match(/^\/v1\/config-action\/example\.com\/(.+)$/);
	const body = match && files[match[1]];
	if (!body) {
		res.writeHead(404).end();
		return;
	}
	if (req.headers.authorization !== `Bearer ${OIDC_TOKEN}`) {
		res.writeHead(403).end();
		return;
	}
	const etag = `"sha256-${createHash("sha256").update(body).digest("hex")}"`;
	if (req.headers["if-none-match"] === etag) {
		res.writeHead(304, { etag }).end();
		return;
	}
	res.writeHead(200, { "content-type": "application/json", etag });
	res.end(body);
}).listen(8787, () => console.log("mock api on :8787"));
