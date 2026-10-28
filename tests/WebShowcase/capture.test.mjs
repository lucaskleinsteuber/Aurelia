import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm, symlink, chmod } from "node:fs/promises";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { startShowcaseFixture } from "../../scripts/web-showcase-fixture.mjs";
import { installCaptureMedia } from "../../scripts/web-showcase-media.mjs";
async function testRoot(prefix) {
  const cache = process.platform === "darwin" ? join(homedir(), "Library", "Caches")
    : process.env.XDG_CACHE_HOME || join(homedir(), ".cache");
  const parent = join(cache, "Aurelia", "TestRuns");
  await mkdir(parent, { recursive: true });
  return mkdtemp(join(parent, prefix));
}
async function fixture(t) {
  const root = await testRoot("aurelia-web-showcase-test-");
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, "web")); await mkdir(join(root, "showcase/items"), { recursive: true }); await mkdir(join(root, "showcase/artwork"));
  await writeFile(join(root, "web/index.html"), "<html>Invented fixture only</html>");
  const items = Array.from({ length: 13 }, (_value, index) => ({ id: `a0000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`, title: `Invented ${index}`, kind: "movie" }));
  for (const item of items) await writeFile(join(root, `showcase/items/${item.id}.json`), JSON.stringify({ item, metadata: {}, seasons: [] }));
  for (const [name, value] of Object.entries({ "catalog-all.json": { items }, "home.json": { recommendation: items[0] }, "collections.json": [] })) await writeFile(join(root, "showcase", name), JSON.stringify(value));
  return { root, webRoot: join(root, "web"), showcaseRoot: join(root, "showcase") };
}
test("developer fixture is loopback-only, serves invented JSON and rejects every real media request", async (t) => {
  const paths = await fixture(t), server = await startShowcaseFixture(paths); t.after(() => server.close());
  assert.match(server.origin, /^http:\/\/127\.0\.0\.1:\d+$/);
  const user = await fetch(server.origin + "/api/v1/auth/me").then((r) => r.json()); assert.equal(user.username, "Alex");
  const home = await fetch(server.origin + "/api/v1/home").then((r) => r.json()); assert.equal(home.recommendation.title, "Invented 0");
  assert.equal((await fetch(server.origin + "/api/v1/streams/anything")).status, 403); assert.deepEqual(server.violations, ["A media stream was requested."]);
  assert.equal((await fetch(server.origin + "/api/v1/unknown")).status, 404);
});
test("fixture refuses linked web assets instead of reading outside its explicit source root", async (t) => {
  const paths = await fixture(t); await writeFile(join(paths.root, "private.js"), "never serve"); await symlink(join(paths.root, "private.js"), join(paths.webRoot, "linked.js"));
  await assert.rejects(startShowcaseFixture(paths), /symbolic links/);
});
test("capture media intercepts src, load and play before any native media implementation can run", async (t) => {
  const keys = ["Date", "HTMLMediaElement", "HTMLVideoElement", "MediaSource", "ManagedMediaSource", "fetch", "location", "__aureliaCaptureMedia"];
  const prior = keys.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]);
  t.after(() => { for (const [key, descriptor] of prior) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key]; } });
  class Media extends EventTarget {
    get src() { throw new Error("native src must never run"); } set src(_value) { throw new Error("native src must never run"); }
    setAttribute(name) { if (name === "src") throw new Error("native src attribute must never run"); }
    removeAttribute() {} load() { throw new Error("native load must never run"); } play() { throw new Error("native play must never run"); } pause() { throw new Error("native pause must never run"); }
  }
  class Video extends Media {}
  globalThis.HTMLMediaElement = Media; globalThis.HTMLVideoElement = Video; globalThis.location = { href: "http://127.0.0.1:1234/" }; globalThis.fetch = async () => "fixture-fetch";
  installCaptureMedia({ now: 1234567890000, poster: "http://127.0.0.1:1234/generated.jpg", duration: 2880 });
  const video = new Video(); video.src = "/not-a-real-video"; video.load(); await video.play(); video.pause(); video.currentTime = 123; await Promise.resolve();
  assert.equal(video.paused, true); assert.equal(video.duration, 2880); assert.equal(video.currentTime, 123); assert.equal(video.poster, "http://127.0.0.1:1234/generated.jpg");
  assert.equal(Date.now(), 1234567890000); assert.equal(globalThis.MediaSource, undefined);
  assert.deepEqual(globalThis.__aureliaCaptureMedia, { simulatedPlayCalls: 1, simulatedLoadCalls: 1 });
});

test("canceling the wrapper terminates its capture child and removes only its unique fixture folder", async (t) => {
  const root = await testRoot("aurelia-web-capture-cancel-");
  t.after(() => rm(root, { recursive: true, force: true }));
  const bin = join(root, "bin"); await mkdir(bin);
  const swift = join(bin, "swift"), node = join(bin, "node");
  await writeFile(swift, '#!/bin/sh\nprintf "%s\\n" "$2" > "$AURELIA_CAPTURE_FIXTURE_TRACE"\n');
  await writeFile(node, '#!/bin/sh\nif [ "$2" = "--check" ]; then exit 0; fi\nprintf "%s\\n" "$$" > "$AURELIA_CAPTURE_PID_TRACE"\nexec sleep 30\n');
  await chmod(swift, 0o700); await chmod(node, 0o700);
  const fixtureTrace = join(root, "fixture"), pidTrace = join(root, "pid");
  const script = fileURLToPath(new URL("../../scripts/capture-web-showcase.sh", import.meta.url));
  const child = spawn("sh", [script], { env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, AURELIA_NODE: node, AURELIA_OTHER_ROOT: join(root, "Local"), AURELIA_CAPTURE_FIXTURE_TRACE: fixtureTrace, AURELIA_CAPTURE_PID_TRACE: pidTrace }, stdio: "ignore" });
  t.after(() => { if (child.exitCode == null) child.kill("SIGTERM"); });
  let capturePID;
  for (let attempt = 0; attempt < 200; attempt++) {
    try { capturePID = Number((await readFile(pidTrace, "utf8")).trim()); break; } catch { await new Promise((resolve) => setTimeout(resolve, 20)); }
  }
  assert.ok(capturePID > 0, "The isolated capture child did not start.");
  const exited = once(child, "exit"); child.kill("SIGTERM"); const [code] = await exited; assert.equal(code, 143);
  assert.throws(() => process.kill(capturePID, 0), { code: "ESRCH" });
  const generated = (await readFile(fixtureTrace, "utf8")).trim();
  assert.match(generated, /web-showcase\.[^/]+\/Showcase$/);
  await assert.rejects(readFile(join(generated, "..", "not-present")), { code: "ENOENT" });
  const { stat } = await import("node:fs/promises"); await assert.rejects(stat(join(generated, "..")), { code: "ENOENT" });
});

test("the approved web-only entrypoint dispatches before any native workspace or UI command", async (t) => {
  const root = await testRoot("aurelia-web-showcase-route-");
  t.after(() => rm(root, { recursive: true, force: true }));
  const scripts = join(root, "scripts"); await mkdir(scripts);
  const wrapper = fileURLToPath(new URL("../../scripts/capture-showcase.sh", import.meta.url));
  await writeFile(join(scripts, "capture-showcase.sh"), await readFile(wrapper));
  await writeFile(join(scripts, "capture-web-showcase.sh"), '#!/bin/sh\nprintf "web-only dispatched: %s\\n" "$1"\n');
  await writeFile(join(scripts, "workspace-paths.sh"), 'echo "native path entered" >&2; exit 99\n');
  const child = spawn("zsh", [join(scripts, "capture-showcase.sh"), "--web-only", "--help"], { stdio: ["ignore", "pipe", "pipe"] });
  let output = "", errors = ""; child.stdout.on("data", (chunk) => { output += chunk; }); child.stderr.on("data", (chunk) => { errors += chunk; });
  const [code] = await once(child, "exit");
  assert.equal(code, 0); assert.equal(errors, ""); assert.equal(output, "web-only dispatched: --help\n");
});
