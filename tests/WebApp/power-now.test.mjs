import { test } from "node:test";
import assert from "node:assert/strict";
import { POWER_ACTIONS, powerNowActions, powerNowOptionsPath, supportsPowerNow } from "../../src/Aurelia.Server/WebApp/js/power-now.js";

test("power now is offered by new servers and by servers that had Smart Home", () => {
  assert.equal(supportsPowerNow(["power-now-v1"]), true);
  assert.equal(supportsPowerNow(["automation-v1"]), true);
  assert.equal(supportsPowerNow(["people-v1"]), false);
  assert.equal(supportsPowerNow(undefined), false);
});

test("the actions are read from the power address, or the old Smart Home overview", () => {
  assert.equal(powerNowOptionsPath(["power-now-v1", "automation-v1"]), "/api/v1/server/power/now");
  assert.equal(powerNowOptionsPath(["automation-v1"]), "/api/v1/server/automation");
  assert.deepEqual(powerNowActions({ actions: ["sleep", "shutdown", "stop"] }), ["sleep", "shutdown", "stop"]);
  assert.deepEqual(powerNowActions({ webhooks: [], powerActions: ["stop"] }), ["stop"]);
  assert.deepEqual(powerNowActions({ actions: ["reboot", "stop"] }), ["stop"]);
  assert.deepEqual(powerNowActions(null), []);
});

test("every action says what happens", () => {
  for (const words of Object.values(POWER_ACTIONS)) {
    assert.ok(words.title.endsWith("Now"));
    assert.ok(words.detail.length > 10);
  }
});
