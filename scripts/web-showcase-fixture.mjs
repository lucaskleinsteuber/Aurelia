// Developer-only loopback fixture. It serves production browser assets and JSON/artwork made by
// make-showcase.swift; it is never embedded in the server or reachable from an installed app.
import http from "node:http";
import { readFile, readdir, lstat } from "node:fs/promises";
import { join, extname } from "node:path";
import { createHash } from "node:crypto";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const SHOWCASE_NOW = Date.parse("2026-10-20T20:00:00Z");
const profile = { id: "00000000-0000-0000-0000-000000000006", username: "Alex", role: "owner", accessMode: "entireLibrary", pinProtectionEnabled: true, needsPinSetup: false, profileRevision: 1 };
const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; font-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".webmanifest": "application/manifest+json" };
async function assets(directory, prefix = "") {
  const result = new Map();
  for (const name of await readdir(directory)) {
    const path = join(directory, name), relative = prefix + name, stat = await lstat(path);
    if (stat.isSymbolicLink()) throw new Error("Showcase assets must not contain symbolic links.");
    if (stat.isDirectory()) for (const [key, value] of await assets(path, relative + "/")) result.set(key, value);
    else if (stat.isFile() && types[extname(name)]) result.set(relative, { body: await readFile(path), type: types[extname(name)] });
  }
  return result;
}
export async function loadShowcase(directory) {
  const json = async (name) => {
    const path = join(directory, name), stat = await lstat(path);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("Showcase JSON must be an ordinary generated file.");
    return JSON.parse(await readFile(path, "utf8"));
  };
  const [home, collections, page] = await Promise.all([json("home.json"), json("collections.json"), json("catalog-all.json")]);
  if (!Array.isArray(page.items) || page.items.length !== 13 || !Array.isArray(collections) || !home.recommendation) throw new Error("Expected the 13-title make-showcase.swift library.");
  const details = new Map(), items = new Map();
  for (const [index, item] of page.items.entries()) {
    if (item.id !== `a0000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`) throw new Error("Expected invented showcase title IDs.");
    const detail = await json(`items/${item.id}.json`); details.set(item.id, detail); items.set(item.id, item);
    for (const season of detail.seasons ?? []) for (const episode of season.episodes ?? []) items.set(episode.item.id, episode.item);
  }
  const artwork = new Map();
  for (const name of await readdir(join(directory, "artwork"))) {
    if (!name.endsWith(".jpg") || !UUID.test(name.slice(0, -4))) throw new Error("Unexpected showcase artwork file.");
    const path = join(directory, "artwork", name);
    if ((await lstat(path)).isSymbolicLink()) throw new Error("Showcase artwork must not be linked.");
    artwork.set(`/api/v1/artwork/${name.slice(0, -4)}`, await readFile(path));
  }
  const plan = (id) => {
    const item = items.get(id); if (!item) return null;
    const queue = item.kind === "series" ? (details.get(id)?.seasons ?? []).flatMap((season) => season.episodes.map((episode) => episode.item)) : [];
    const target = item.kind === "series" ? queue.find((entry) => entry.progress) ?? queue[0] ?? null : item;
    return { target, seriesId: item.kind === "series" ? item.id : item.parentId ?? null, queue: queue.filter((entry) => entry.id !== target?.id), action: target?.progress ? "resume" : "play", continueWatchingEligible: true };
  };
  const showcaseHash = createHash("sha256").update(JSON.stringify({ home, collections, page })).digest("hex");
  return { home, collections, page, details, items, artwork, plan, showcaseHash };
}
export async function startShowcaseFixture({ webRoot, showcaseRoot, version = "Showcase" }) {
  const [files, model] = await Promise.all([assets(webRoot), loadShowcase(showcaseRoot)]);
  const violations = [], requests = [];
  let ticket = 0;
  function send(res, status, body, type = "application/json") {
    res.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store", ...(type === "text/html" ? { "Content-Security-Policy": CSP } : {}) });
    res.end(body == null ? undefined : Buffer.isBuffer(body) || typeof body === "string" ? body : JSON.stringify(body));
  }
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1"), path = url.pathname;
    requests.push({ method: req.method, path });
    if (path.startsWith("/api/v1/streams/")) { violations.push("A media stream was requested."); return send(res, 403, { code: "showcase_no_media", message: "Showcase captures never load media." }); }
    if (req.method === "GET" && path === "/api/v1/server/info") return send(res, 200, { serverId: "00000000-0000-0000-0000-000000000004", name: "Home Server", version, isSetup: true, capabilities: ["live-conversion-v1", "library-state-v1"] });
    if (req.method === "GET" && path === "/api/v1/auth/me") return send(res, 200, profile);
    if (req.method === "GET" && path === "/api/v1/home") return send(res, 200, model.home);
    if (req.method === "GET" && path === "/api/v1/catalog/collections") return send(res, 200, model.collections.slice(Number(url.searchParams.get("offset") ?? 0), Number(url.searchParams.get("offset") ?? 0) + Number(url.searchParams.get("limit") ?? 100)));
    if (req.method === "GET" && model.artwork.has(path)) return send(res, 200, model.artwork.get(path), "image/jpeg");
    const detail = /^\/api\/v1\/catalog\/items\/([^/]+)$/.exec(path);
    if (req.method === "GET" && detail && model.details.has(detail[1])) return send(res, 200, model.details.get(detail[1]));
    const plan = /^\/api\/v1\/media\/([^/]+)\/playback-plan$/.exec(path);
    if (req.method === "GET" && plan && model.plan(plan[1])) return send(res, 200, model.plan(plan[1]));
    const playback = /^\/api\/v1\/media\/([^/]+)\/playback$/.exec(path);
    if (req.method === "POST" && playback && model.items.has(playback[1])) {
      const item = model.items.get(playback[1]);
      return send(res, 200, { id: `00000000-0000-0000-0000-${String(++ticket).padStart(12, "0")}`, streamPath: `/api/v1/streams/showcase-${ticket}`, contentType: "video/mp4", expiresAt: new Date(SHOWCASE_NOW + 6 * 3600000).toISOString(), progress: item.progress });
    }
    if (req.method === "GET" && /^\/api\/v1\/media\/[^/]+\/notes$/.test(path)) return send(res, 200, []);
    if (req.method === "PUT" && /^\/api\/v1\/media\/[^/]+\/progress$/.test(path)) return send(res, 200, { revision: 4 });
    if (req.method === "DELETE" && /^\/api\/v1\/playback\/[^/]+$/.test(path)) return send(res, 204);
    if (path.startsWith("/api/")) { violations.push(`Unexpected fixture API request: ${req.method} ${path}`); return send(res, 404, { code: "showcase_unknown_request", message: "No real server is connected." }); }
    const name = path.startsWith("/web/") ? path.slice(5) : "index.html";
    const file = files.get(name);
    if (req.method !== "GET" || !file) return send(res, 404, "Not found", "text/plain");
    send(res, 200, file.body, file.type);
  });
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
  const origin = `http://127.0.0.1:${server.address().port}`;
  return { origin, model, requests, violations, close: async () => { const done = new Promise((resolve) => server.close(resolve)); server.closeAllConnections(); await done; } };
}
