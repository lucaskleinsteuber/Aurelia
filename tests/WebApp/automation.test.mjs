import test from "node:test";
import assert from "node:assert/strict";
import {
  homeAssistantExample, homeAssistantUrl, playerStateFor, shouldReport, splitHomeAssistantUrl, supportsAutomation,
  webhookFormProblem, webhookHost, webhookRequest, webhookStatus, webhookUrlProblem,
} from "../../src/Aurelia.Server/WebApp/js/automation.js";

test("video events become the states the player reports", () => {
  assert.equal(playerStateFor("playing"), "playing");
  assert.equal(playerStateFor("pause"), "paused");
  assert.equal(playerStateFor("waiting"), "buffering");
  assert.equal(playerStateFor("ended"), "finished");
  assert.equal(playerStateFor("timeupdate"), null);
});

test("only changes are reported, and nothing but playing follows the end", () => {
  assert.equal(shouldReport(undefined, "playing"), true);
  assert.equal(shouldReport("playing", "playing"), false);
  assert.equal(shouldReport("playing", "paused"), true);
  assert.equal(shouldReport("finished", "paused"), false);
  assert.equal(shouldReport("finished", "playing"), true);
  assert.equal(shouldReport("playing", null), false);
});

test("Home Assistant's webhook address is built from its address and ID", () => {
  assert.equal(homeAssistantUrl("homeassistant.local", "aurelia_lights"), "http://homeassistant.local:8123/api/webhook/aurelia_lights");
  assert.equal(homeAssistantUrl("http://10.0.0.20:8123/", "abc-1"), "http://10.0.0.20:8123/api/webhook/abc-1");
  assert.equal(homeAssistantUrl("https://ha.example.com", "abc"), "https://ha.example.com/api/webhook/abc");
  assert.equal(homeAssistantUrl("homeassistant.local", "bad id!"), null);
  assert.equal(homeAssistantUrl("", "abc"), null);
  assert.deepEqual(splitHomeAssistantUrl("http://homeassistant.local:8123/api/webhook/aurelia_lights"),
    { base: "http://homeassistant.local:8123", webhookId: "aurelia_lights" });
  assert.deepEqual(splitHomeAssistantUrl("https://example.com/hook"), { base: "", webhookId: "" });
});

test("addresses follow the server's rule: https anywhere, http only at home", () => {
  assert.equal(webhookUrlProblem("http://homeassistant.local:8123/api/webhook/a"), null);
  assert.equal(webhookUrlProblem("http://10.0.0.5/hook"), null);
  assert.equal(webhookUrlProblem("https://hooks.example.com/aurelia"), null);
  assert.match(webhookUrlProblem("http://hooks.example.com/aurelia"), /https/);
  assert.match(webhookUrlProblem("https://169.254.169.254/x"), /can't receive/);
  assert.match(webhookUrlProblem("https://user:pw@example.com/"), /user name/);
  assert.match(webhookUrlProblem(""), /Enter/);
});

test("the form checks name, address and events before saving", () => {
  const good = { name: "Lights", url: "http://homeassistant.local:8123/api/webhook/a", events: ["playback.started"] };
  assert.equal(webhookFormProblem(good), null);
  assert.match(webhookFormProblem({ ...good, name: " " }), /name/);
  assert.match(webhookFormProblem({ ...good, events: [] }), /event/);
  const request = webhookRequest({ ...good, events: ["playback.started", "playback.started"], preset: "other" });
  assert.deepEqual(request.events, ["playback.started"]);
  assert.equal(request.preset, "homeAssistant");
  assert.equal(request.includeTitles, true);
});

test("the list says how the last delivery went and shows only the host", () => {
  assert.equal(webhookStatus({ enabled: false }).text, "Off");
  assert.equal(webhookStatus({ enabled: true, pausedReason: "x" }).tone, "warning");
  assert.equal(webhookStatus({ enabled: true, lastDelivery: { state: "succeeded", durationMilliseconds: 12 } }).text, "Last delivery 12 ms");
  assert.equal(webhookStatus({ enabled: true }).text, "Nothing sent yet");
  assert.equal(webhookHost("http://homeassistant.local:8123/api/webhook/secret-id"), "homeassistant.local:8123");
});

test("the example automation uses the webhook ID and Home Assistant's trigger", () => {
  const yaml = homeAssistantExample("aurelia_lights", "Living Room");
  assert.match(yaml, /webhook_id: aurelia_lights/);
  assert.match(yaml, /playback\.started/);
  assert.match(yaml, /Living Room/);
  assert.equal(supportsAutomation(["automation-v1"]), true);
  assert.equal(supportsAutomation(undefined), false);
});
