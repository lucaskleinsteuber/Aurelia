import test from "node:test";
import assert from "node:assert/strict";
import { Player } from "../../src/Aurelia.Server/WebApp/js/player.js";
import { ApiError } from "../../src/Aurelia.Server/WebApp/js/api.js";
import { closedLabel, goodNight, isScreenTimeCode, noMoreTitles, rulesFromForm, sameRules, todaySummary, DEFAULT_SCREEN_TIME }
  from "../../src/Aurelia.Server/WebApp/js/screen-time.js";
import { installDOM } from "./dom-fixture.mjs";

// Local times so the expected clock does not depend on the test machine's time zone.
const local = (hour, minute) => new Date(2027, 10, 9, hour, minute).toISOString();
const closed = (reason = "bedtime", extra = {}) => ({ state: "closed", reason, opensAt: local(7, 0), watchedMinutesToday: 60, limitMinutes: 60,
  lockScope: "playbackOnly", ending: "finishTitle", oneMoreTitleAvailable: false, ...extra });

test("only the last title or a closed profile stops the next one", () => {
  assert.equal(noMoreTitles(null), false);
  assert.equal(noMoreTitles({ state: "open" }), false);
  assert.equal(noMoreTitles({ state: "lastTitle" }), true);
  assert.equal(noMoreTitles(closed()), true);
  assert.equal(isScreenTimeCode("screen_time_bedtime"), true);
  assert.equal(isScreenTimeCode("media_not_found"), false);
});

test("the good-night screen names the profile and when Aurelia opens", () => {
  assert.deepEqual(goodNight(closed(), "Robin"), { title: "Good night, Robin", text: "See you at 07:00." });
  assert.deepEqual(goodNight(closed("limit"), "Robin"), { title: "That's all for today, Robin", text: "See you tomorrow at 07:00." });
  assert.equal(goodNight(null).title, "Good night");
  assert.equal(closedLabel({ closedUntil: local(7, 30) }), "Good night · back at 07:30");
  assert.equal(closedLabel({ closedUntil: null }), null);
  assert.equal(todaySummary(closed("limit", { oneMoreTitleAvailable: true })), "60 of 60 min watched today · Time is up, opens at 07:00 · One more title allowed");
  assert.equal(todaySummary({ state: "open", watchedMinutesToday: 12, limitMinutes: null, closesAt: local(19, 30) }), "12 min watched today · Closes at 19:30");
});

test("the editor's fields become rules, with a clear message for a wrong value", () => {
  const form = { enabled: true, lockScope: "wholeProfile", ending: "stopNow", overtime: "15",
    schoolNight: { bedtime: "19:30", wakeTime: "07:00", limit: "60" }, weekend: { bedtime: "", wakeTime: "08:00", limit: "" } };
  const { rules } = rulesFromForm(form);
  assert.deepEqual(rules, { enabled: true, lockScope: "wholeProfile", ending: "stopNow", maxOvertimeMinutes: 15,
    schoolNight: { bedtime: "19:30", wakeTime: "07:00", dailyLimitMinutes: 60 }, weekend: { bedtime: null, wakeTime: "08:00", dailyLimitMinutes: null } });
  assert.match(rulesFromForm({ ...form, schoolNight: { ...form.schoolNight, bedtime: "25:00" } }).error, /school-night bedtime/);
  assert.match(rulesFromForm({ ...form, weekend: { ...form.weekend, limit: "2" } }).error, /weekend daily limit/);
  assert.match(rulesFromForm({ ...form, overtime: "500" }).error, /run over/);
  assert.equal(sameRules(rules, structuredClone(rules)), true);
  assert.equal(sameRules(rules, DEFAULT_SCREEN_TIME), false);
});

function endedPlayer(t, status, options = {}) {
  installDOM(t);
  const calls = { next: 0, goodNight: [] };
  const player = new Player({
    api: { ownScreenTime: async () => ({ status }) },
    item: { id: "current", kind: "episode", title: "Synthetic" }, profileName: "Robin",
    next: async () => ({ id: "next", kind: "episode", title: "Next" }),
    onPlayNext: () => { calls.next += 1; }, onGoodNight: (value) => calls.goodNight.push(value), onClose() {}, ...options,
  });
  player.screenTime = { state: "open" };
  player.preferences.automaticallyPlayNextEpisode = true;
  player.showControls = () => {};
  player.updatePlayState = () => {};
  player.saveNow = () => {};
  player.video.pause = () => {};
  player.close = () => { player.closed = true; };
  return { player, calls };
}

test("at the end of the last episode the good-night screen comes instead of the next one", async (t) => {
  const { player, calls } = endedPlayer(t, closed());
  await player.finish();
  assert.equal(calls.next, 0);
  assert.equal(player.endScreen.hidden, false);
  assert.match(player.endScreen.textContent, /Good night, Robin/);
  assert.match(player.endScreen.textContent, /See you at 07:00\./);
  player.endScreen.querySelector("button").click();
  assert.equal(player.closed, true);
  assert.equal(calls.goodNight.length, 1);
});

test("an open profile still plays the next episode", async (t) => {
  const { player, calls } = endedPlayer(t, { state: "open" });
  await player.finish();
  assert.equal(calls.next, 1);
});

test("a refused new title shows the good-night screen, not an error", async (t) => {
  const { player } = endedPlayer(t, closed("limit"));
  player.fail(new ApiError(403, "screen_time_limit", "That's all for today."));
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(player.endScreen.hidden, false);
  assert.match(player.endScreen.textContent, /That's all for today, Robin/);
});

test("the last title of the day hides Up Next and says so once", async (t) => {
  const { player } = endedPlayer(t, null);
  player.screenTime = { state: "lastTitle", reason: "bedtime" };
  player.upNextItem = { id: "next", kind: "episode", title: "Next" };
  Object.defineProperty(player.video, "duration", { value: 1500 });
  player.video.currentTime = 1495;
  await player.updateUpNext();
  assert.equal(player.upNext.hidden, true);
  assert.match(player.notice.textContent, /last episode before bedtime/);
});
