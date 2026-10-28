#!/usr/bin/env node
// Developer-only headless screenshots. Never imports into the product and never uses an owner
// browser profile, live server, credential, movie, decoder or playback engine.
import { installCaptureMedia } from "./web-showcase-media.mjs";
import { createRequire } from "node:module";
import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { startShowcaseFixture, SHOWCASE_NOW } from "./web-showcase-fixture.mjs";

const require = createRequire(import.meta.url);
const usage = "Usage: node scripts/capture-web-showcase.mjs --check | --web-root PATH --showcase-root PATH --output PATH [--version VERSION] [--report PATH]\nSet NODE_PATH or AURELIA_PLAYWRIGHT_NODE_MODULES for an existing Playwright installation; AURELIA_CHROMIUM_EXECUTABLE optionally selects a headless Chrome executable.";
const args = process.argv.slice(2), options = {};
if (args.includes("--help")) { console.log(usage); process.exit(0); }
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--check") options.check = true;
  else if (["--web-root", "--showcase-root", "--output", "--version", "--report"].includes(args[i]) && args[i + 1] && !args[i + 1].startsWith("--")) options[args[i].slice(2)] = args[++i];
  else throw new Error(usage);
}
let chromium;
try { ({ chromium } = require("playwright")); }
catch { throw new Error("Playwright is not available. Set NODE_PATH to an existing node_modules folder; this script does not install packages."); }
const candidates = [process.env.AURELIA_CHROMIUM_EXECUTABLE, chromium.executablePath(),
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Chromium.app/Contents/MacOS/Chromium", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
  "/usr/bin/chromium", "/usr/bin/chromium-browser", "/usr/bin/google-chrome"].filter(Boolean);
let executablePath;
for (const candidate of candidates) { try { await access(candidate, constants.X_OK); executablePath = candidate; break; } catch { /* Try an available executable. */ } }
if (!executablePath) throw new Error("No headless Chromium executable is installed. Set AURELIA_CHROMIUM_EXECUTABLE; nothing is downloaded automatically.");
if (options.check) { console.log(JSON.stringify({ playwright: require.resolve("playwright"), executablePath, headless: true })); process.exit(0); }
for (const key of ["web-root", "showcase-root", "output"]) if (!options[key]) throw new Error(usage);


let fixture, browser;
const failures = [];
try {
  fixture = await startShowcaseFixture({ webRoot: resolve(options["web-root"]), showcaseRoot: resolve(options["showcase-root"]), version: options.version });
  const featured = fixture.model.home.recommendation, target = fixture.model.plan(featured.id).target;
  if (!target?.backdrop?.path) throw new Error("The invented player target needs a generated backdrop.");
  browser = await chromium.launch({ executablePath, headless: true, args: ["--disable-background-networking", "--disable-component-update", "--disable-sync", "--mute-audio"] });
  const context = await browser.newContext({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1, locale: "en-US", timezoneId: "UTC", colorScheme: "dark", reducedMotion: "reduce", serviceWorkers: "block" });
  await context.route("**/*", async (route) => {
    const request = route.request(), address = new URL(request.url());
    if (address.origin !== fixture.origin || request.resourceType() === "media") { failures.push(`Blocked unexpected ${request.resourceType()} request to ${address.origin}${address.pathname}`); await route.abort(); }
    else await route.continue();
  });
  await context.addInitScript(installCaptureMedia, { now: SHOWCASE_NOW, poster: fixture.origin + target.backdrop.path, duration: (target.progress?.durationMilliseconds ?? 2880000) / 1000 });
  const page = await context.newPage();
  page.setDefaultTimeout(15000);
  page.on("pageerror", (error) => failures.push(error.message));
  page.on("console", (message) => { if (message.type() === "error") failures.push(message.text()); });
  async function ready() {
    await page.waitForLoadState("networkidle");
    await page.evaluate(async () => {
      await document.fonts.ready;
      const visible = [...document.images].filter((image) => { const box = image.getBoundingClientRect(); return box.top < innerHeight && box.bottom > 0 && box.left < innerWidth && box.right > 0; });
      await Promise.all(visible.map((image) => Promise.race([image.decode().catch(() => {}), new Promise((resolve) => setTimeout(resolve, 2000))])));
      if (visible.some((image) => !image.complete || !image.naturalWidth)) throw new Error("A visible showcase picture did not load.");
    });
  }
  await mkdir(options.output, { recursive: true });
  const captures = [];
  async function capture(name) {
    console.log(`Capturing ${name}…`);
    await ready();
    if (failures.length || fixture.violations.length) throw new Error([...failures, ...fixture.violations].join("\n"));
    const path = join(options.output, `web-${name}.jpg`);
    await page.screenshot({ path, type: "jpeg", quality: 82, animations: "disabled", ...(name === "home" ? { fullPage: true, clip: { x: 0, y: 0, width: 1600, height: 1250 } } : {}) });
    const data = await readFile(path); captures.push({ name: `web-${name}.jpg`, bytes: data.length, sha256: createHash("sha256").update(data).digest("hex") });
  }
  await page.goto(fixture.origin + "/"); await page.locator(".hero-title").waitFor();
  await page.locator(".rail").first().scrollIntoViewIfNeeded(); await ready(); await page.evaluate(() => scrollTo(0, 0)); await capture("home");
  await page.goto(`${fixture.origin}/title/${featured.id}`); await page.locator(".detail-hero .hero-title").waitFor(); await capture("detail");
  await page.locator(".detail-hero .primary-button").click(); await page.locator(".player.paused").waitFor(); await page.waitForFunction(() => document.querySelector(".player-start")?.hidden && getComputedStyle(document.querySelector(".player-start")).opacity === "0"); await capture("player");
  const media = await page.evaluate(() => ({ ...globalThis.__aureliaCaptureMedia, paused: document.querySelector("video")?.paused, nativeSource: document.querySelector("video")?.getAttribute("src") }));
  if (!media.paused || media.nativeSource || media.simulatedPlayCalls !== 1) throw new Error("The capture must show only a paused simulated player with no native media source.");
  await page.goto(fixture.origin + "/settings/playback"); await page.getByRole("heading", { name: "Playback" }).waitFor(); await capture("settings");
  await context.close();
  const report = { generator: "scripts/make-showcase.swift", showcaseHash: fixture.model.showcaseHash, titles: fixture.model.page.items.length, pictures: fixture.model.artwork.size, captures, media, violations: fixture.violations, failures, browser: await browser.version() };
  if (options.report) { await mkdir(resolve(options.report, ".."), { recursive: true }); await writeFile(options.report, JSON.stringify(report, null, 2) + "\n"); }
  console.log(JSON.stringify(report, null, 2));
} finally {
  try { await browser?.close(); } finally { await fixture?.close(); }
}
