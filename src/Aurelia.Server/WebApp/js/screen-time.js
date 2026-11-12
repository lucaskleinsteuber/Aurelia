// Screen time of children's profiles (docs/SCREEN_TIME.md): what the player, the profile picker and
// the profile editor show. The server decides; these only describe what it said.

export const SCREEN_TIME_CAPABILITY = "screen-time-v1";
export const SCREEN_TIME_CODES = Object.freeze(["screen_time_bedtime", "screen_time_limit", "profile_screen_time_closed"]);

/** The player checks the profile's screen time this often while a title plays. */
export const SCREEN_TIME_REFRESH_MS = 60_000;

/** The default rules of a new children's profile; the server sends the same. */
export const DEFAULT_SCREEN_TIME = Object.freeze({
  enabled: false, lockScope: "playbackOnly", ending: "finishTitle", maxOvertimeMinutes: 30,
  schoolNight: Object.freeze({ bedtime: "19:30", wakeTime: "07:00", dailyLimitMinutes: null }),
  weekend: Object.freeze({ bedtime: "20:30", wakeTime: "08:00", dailyLimitMinutes: null }),
});

/** No new title may start: no Up Next, no suggestions, and the good-night screen at the end. */
export function noMoreTitles(status) {
  return status?.state === "lastTitle" || status?.state === "closed";
}

/** A refusal that means "screen time is over", not an error. */
export function isScreenTimeCode(code) {
  return SCREEN_TIME_CODES.includes(code);
}

/** "07:00" in the viewer's clock, or "" without a time. */
export function clockTime(value) {
  const date = value ? new Date(value) : null;
  if (!date || Number.isNaN(date.getTime())) return "";
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

/** The good-night screen's heading and line. */
export function goodNight(status, name = "") {
  const who = String(name ?? "").trim();
  const opens = clockTime(status?.opensAt);
  if (status?.reason === "limit")
    return { title: who ? `That's all for today, ${who}` : "That's all for today", text: opens ? `See you tomorrow at ${opens}.` : "See you tomorrow." };
  return { title: who ? `Good night, ${who}` : "Good night", text: opens ? `See you at ${opens}.` : "Sleep well." };
}

/** The quiet note in the player while the last title of the day plays. */
export function lastTitleNote(status) {
  return status?.reason === "limit" ? "This is the last title for today." : "This is the last episode before bedtime.";
}

/** "Good night · back at 07:00" for a closed profile in "Who's watching?", null when it is open. */
export function closedLabel(profile) {
  if (!profile?.closedUntil) return null;
  const opens = clockTime(profile.closedUntil);
  return opens ? `Good night · back at ${opens}` : "Good night";
}

/** "42 of 60 min watched today · Closes at 19:30" for the parents' "Today" line. */
export function todaySummary(status) {
  if (!status) return "Screen time is off.";
  const watched = status.limitMinutes != null ? `${status.watchedMinutesToday} of ${status.limitMinutes} min watched today`
    : `${status.watchedMinutesToday} min watched today`;
  if (status.state === "closed") {
    const opens = clockTime(status.opensAt);
    const why = status.reason === "limit" ? "Time is up" : "Bedtime";
    return `${watched} · ${why}${opens ? `, opens at ${opens}` : ""}${status.oneMoreTitleAvailable ? " · One more title allowed" : ""}`;
  }
  const closes = clockTime(status.closesAt);
  return closes ? `${watched} · Closes at ${closes}` : watched;
}

/** A time field's value ("" for none) as the server expects it. */
function time(value) {
  const text = String(value ?? "").trim();
  return /^([01]\d|2[0-3]):[0-5]\d$/.test(text) ? text : null;
}

function minutes(value) {
  const text = String(value ?? "").trim();
  if (!text) return null;
  const number = Number(text);
  return Number.isInteger(number) ? number : NaN;
}

/**
 * The rules from the editor's fields, or `{ error }` with the first problem. Each evening has
 * `bedtime` (may be empty), `wakeTime` and `limit` (minutes, may be empty).
 */
export function rulesFromForm({ enabled, lockScope, ending, overtime, schoolNight, weekend }) {
  const day = (values, label) => {
    const bedtime = String(values.bedtime ?? "").trim();
    if (bedtime && !time(bedtime)) return { error: `Enter the ${label} bedtime like 19:30.` };
    if (!time(values.wakeTime)) return { error: `Enter the ${label} wake time like 07:00.` };
    const limit = minutes(values.limit);
    if (Number.isNaN(limit) || (limit != null && (limit < 5 || limit > 1440))) return { error: `The ${label} daily limit is 5 to 1440 minutes.` };
    return { rule: { bedtime: bedtime || null, wakeTime: time(values.wakeTime), dailyLimitMinutes: limit } };
  };
  const school = day(schoolNight, "school-night");
  if (school.error) return school;
  const free = day(weekend, "weekend");
  if (free.error) return free;
  const over = minutes(overtime) ?? 0;
  if (Number.isNaN(over) || over < 0 || over > 180) return { error: "A title may run over by 0 to 180 minutes." };
  return { rules: { enabled: Boolean(enabled), lockScope: lockScope === "wholeProfile" ? "wholeProfile" : "playbackOnly",
    ending: ending === "stopNow" ? "stopNow" : "finishTitle", maxOvertimeMinutes: over, schoolNight: school.rule, weekend: free.rule } };
}

/** Whether two rule sets say the same. */
export function sameRules(a, b) {
  return JSON.stringify(normalize(a)) === JSON.stringify(normalize(b));
}

function normalize(rules) {
  const day = (value) => ({ bedtime: value?.bedtime ?? null, wakeTime: value?.wakeTime ?? null, dailyLimitMinutes: value?.dailyLimitMinutes ?? null });
  return { enabled: Boolean(rules?.enabled), lockScope: rules?.lockScope ?? null, ending: rules?.ending ?? null,
    maxOvertimeMinutes: rules?.maxOvertimeMinutes ?? null, schoolNight: day(rules?.schoolNight), weekend: day(rules?.weekend) };
}
