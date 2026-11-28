import { test } from "node:test";
import assert from "node:assert/strict";
import { pickReleases, label } from "../../website/releases.mjs";

function release(tag, names, { prerelease = false, draft = false } = {}) {
  return {
    tag_name: tag,
    prerelease,
    draft,
    html_url: `https://example.invalid/${tag}`,
    assets: names.map((name) => ({ name, browser_download_url: `https://example.invalid/${tag}/${name}` })),
  };
}

test("takes the newest beta when no stable release has Tarven downloads", () => {
  const picked = pickReleases([
    release("3.0.0-190", ["Tarven-3.0.0-190-macOS-arm64.dmg", "Tarven-3.0.0-190-macOS-x64.dmg"], { prerelease: true }),
    release("2.30.0-189", ["Aurelia-2.30.0-189-macOS-arm64.dmg"], { prerelease: true }),
    release("2.12.1-170", ["Aurelia-2.12.1-170-macOS-arm64.dmg"]),
  ]);
  assert.equal(picked.mac.version, "3.0.0");
  assert.equal(picked.mac.build, 190);
  assert.equal(picked.mac.beta, true);
  assert.equal(picked.mac.assets.arm64, "https://example.invalid/3.0.0-190/Tarven-3.0.0-190-macOS-arm64.dmg");
  assert.equal(picked.mac.assets.x64, "https://example.invalid/3.0.0-190/Tarven-3.0.0-190-macOS-x64.dmg");
  assert.equal(picked.mac.newerBeta, null);
});

test("ignores the Aurelia bridge packages in a server release", () => {
  const picked = pickReleases([
    release("server-3.1.0-181", [
      "Aurelia-Server-3.1.0-181-linux-x64.tar.gz",
      "Tarven-Server-3.1.0-181-linux-x64.tar.gz",
      "Tarven-Server-3.1.0-181-linux-arm64.tar.gz",
      "SHA256SUMS",
    ], { prerelease: true }),
  ]);
  assert.match(picked.server.assets.x64, /Tarven-Server-3\.1\.0-181-linux-x64\.tar\.gz$/);
  assert.match(picked.server.assets.arm64, /Tarven-Server-3\.1\.0-181-linux-arm64\.tar\.gz$/);
});

test("prefers stable and names a newer beta", () => {
  const picked = pickReleases([
    release("linux-app-2.18.0-47", ["Tarven-Desktop-2.18.0-47-amd64.deb"], { prerelease: true }),
    release("linux-app-2.17.0-46", ["Tarven-Desktop-2.17.0-46-amd64.deb", "Tarven-Desktop-2.17.0-46-x86_64.flatpak"]),
  ]);
  assert.equal(picked.linux.version, "2.17.0");
  assert.equal(picked.linux.beta, false);
  assert.equal(picked.linux.newerBeta.version, "2.18.0");
  assert.ok(picked.linux.assets.flatpakX64);
});

test("orders by build number, not by list order", () => {
  const picked = pickReleases([
    release("server-3.0.0-180", ["Tarven-Server-3.0.0-180-linux-x64.tar.gz"]),
    release("server-3.2.0-183", ["Tarven-Server-3.2.0-183-linux-x64.tar.gz"]),
  ]);
  assert.equal(picked.server.build, 183);
});

test("skips drafts, other products' tags and missing products", () => {
  const picked = pickReleases([
    release("server-3.2.0-183", ["Tarven-Server-3.2.0-183-linux-x64.tar.gz"], { draft: true }),
    release("linux-app-2.17.0-46", ["Tarven-3.0.0-190-macOS-arm64.dmg"]),
  ]);
  assert.equal(picked.server, null);
  assert.equal(picked.linux, null);
  assert.equal(picked.mac, null);
});

test("labels beta versions", () => {
  assert.equal(label({ version: "3.0.0", build: 190, beta: true }), "Version 3.0.0 (190), beta");
  assert.equal(label({ version: "2.17.0", build: 46, beta: false }), "Version 2.17.0 (46)");
});
