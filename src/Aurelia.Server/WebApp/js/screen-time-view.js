// The "Screen Time" part of the profile editor, like the Mac's: bedtime, daily limit, what closes
// and how a title ends, and today's exceptions (docs/SCREEN_TIME.md).

import { h, clear } from "./dom.js";
import { DEFAULT_SCREEN_TIME, rulesFromForm, todaySummary } from "./screen-time.js";

/**
 * @param {object} kit the editor's `input`, `field`, `choice` and `button`
 * @param {object|null} loaded the profile's screen time from the server, null for a new profile
 * @param {{ grant?: (body: object) => Promise<object> }} actions today's exceptions, for an existing profile
 */
export function screenTimeSection(kit, loaded, { grant } = {}) {
  const { input, field, choice, button } = kit;
  const rules = loaded?.rules ?? DEFAULT_SCREEN_TIME;
  const enabled = input("", { type: "checkbox", checked: Boolean(rules.enabled) });
  const scope = choice([["playbackOnly", "Playback only"], ["wholeProfile", "The whole profile"]], rules.lockScope ?? "playbackOnly");
  const ending = choice([["finishTitle", "Let the title finish"], ["stopNow", "Stop right away"]], rules.ending ?? "finishTitle");
  const overtime = input(String(rules.maxOvertimeMinutes ?? 30), { type: "number", min: 0, max: 180, step: 5, inputmode: "numeric" });
  const overtimeField = field("Finish within (minutes)", overtime, "A title that runs longer stops after this many minutes past the time.");
  const evening = (value) => ({
    bedtime: input(value?.bedtime ?? "", { type: "time" }),
    wakeTime: input(value?.wakeTime ?? "07:00", { type: "time", required: true }),
    limit: input(value?.dailyLimitMinutes == null ? "" : String(value.dailyLimitMinutes), { type: "number", min: 5, max: 1440, step: 5, inputmode: "numeric", placeholder: "No limit" }),
  });
  const school = evening(rules.schoolNight);
  const weekend = evening(rules.weekend);
  const eveningFields = (title, help, fields) => h("div", {},
    h("h4", {}, title), h("p", { class: "muted small" }, help),
    h("div", { class: "editor-grid" }, field("Bedtime", fields.bedtime), field("Wake time", fields.wakeTime), field("Daily limit (minutes)", fields.limit)));

  const today = h("div", { class: "screen-time-today" });
  const drawToday = (current) => {
    clear(today);
    if (!grant || !current?.status) return;
    const busy = (work) => async () => {
      for (const control of today.querySelectorAll("button")) control.disabled = true;
      try { drawToday(await work()); } catch (error) { today.append(h("p", { class: "error-text" }, error.message)); }
      finally { for (const control of today.querySelectorAll("button")) control.disabled = false; }
    };
    today.append(h("h4", {}, "Today"), h("p", { class: "muted small" }, todaySummary(current.status)),
      h("div", { class: "button-row" },
        ...[15, 30, 60].map((minutes) => button(`+${minutes} min`, busy(() => grant({ addMinutes: minutes })))),
        current.today?.bedtimeLifted ? null : button("No Bedtime Tonight", busy(() => grant({ liftBedtime: true }))),
        button("One More Episode", busy(() => grant({ oneMoreTitle: true })))),
      h("p", { class: "muted small" }, "Exceptions last until the next wake time."));
  };
  drawToday(loaded);

  const details = h("div", { class: "screen-time-details" },
    field("When time is up, close", scope, "Playback only keeps browsing open. The whole profile closes until the wake time."),
    field("A title that is playing", ending), overtimeField,
    eveningFields("School Nights", "Sunday to Thursday evening.", school),
    eveningFields("Weekend", "Friday and Saturday evening.", weekend),
    today);
  const element = h("div", { class: "screen-time-section" }, h("h3", {}, "Screen Time"),
    field("Screen Time", enabled, "A bedtime and a daily limit. The next episode does not start, and a good-night screen shows instead."), details);
  const update = () => {
    details.hidden = !enabled.checked;
    overtimeField.hidden = ending.value !== "finishTitle";
  };
  for (const control of [enabled, ending]) control.addEventListener("change", update);
  update();

  const values = (fields) => ({ bedtime: fields.bedtime.value, wakeTime: fields.wakeTime.value, limit: fields.limit.value });
  return {
    element,
    /** The rules to save, or `{ error }`. */
    collect: () => rulesFromForm({ enabled: enabled.checked, lockScope: scope.value, ending: ending.value, overtime: overtime.value,
      schoolNight: values(school), weekend: values(weekend) }),
  };
}
