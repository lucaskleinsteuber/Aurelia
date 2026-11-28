// The file watch ("file-checks-v1"): the words and numbers the settings and Library Health show.
// Pure, so tests check every text without a page.

export const FILE_CHECKS_FEATURE = "file-checks-v1";

export const DEPTH_CHOICES = [
  ["read", "Read Every Byte", "Finds places the drive can't read and, later, files that changed by themselves. Fast."],
  ["container", "Read Every Packet", "Also finds files that are cut off or have damaged packets. Recommended."],
  ["decode", "Decode Everything", "Also finds damage inside pictures and sound. Takes as long as playing on small computers."],
];

export const RECHECK_CHOICES = [
  [0, "Never"],
  [30, "Every 30 Days"],
  [90, "Every 90 Days"],
  [180, "Every 180 Days"],
];

export function supportsFileChecks(server) {
  return Boolean(server?.capabilities?.includes(FILE_CHECKS_FEATURE));
}

/** "1:02:10" or "4:05". */
export function clockText(seconds) {
  const total = Math.max(0, Math.round(Number(seconds) || 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const rest = String(total % 60).padStart(2, "0");
  return hours ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}` : `${minutes}:${rest}`;
}

/** "About 3 h 20 min left", or "". */
export function remainingText(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return "";
  const minutes = Math.max(1, Math.round(seconds / 60));
  if (minutes < 60) return `About ${minutes} min left`;
  const hours = Math.floor(minutes / 60);
  if (hours >= 48) return `About ${Math.round(hours / 24)} days left`;
  const rest = minutes % 60;
  return `About ${hours} h${rest ? ` ${rest} min` : ""} left`;
}

/** How far the watch is, from 0 to 1. */
export function fileCheckProgress(settings) {
  const total = settings?.totalCount ?? 0;
  if (!total) return 1;
  return Math.min(1, Math.max(0, (total - (settings?.pendingCount ?? 0)) / total));
}

/** The status line of the settings: "Off", "All 120 files examined", "40 of 120 files · …". */
export function fileCheckStatus(settings) {
  if (!settings) return "Loading…";
  if (!settings.enabled) return "Off";
  const total = settings.totalCount ?? 0;
  const pending = settings.pendingCount ?? 0;
  const problems = settings.problemCount ? ` · ${settings.problemCount} ${settings.problemCount === 1 ? "problem" : "problems"}` : "";
  if (pending === 0) return `All ${total} ${total === 1 ? "file" : "files"} examined${problems}`;
  const parts = [`${Math.max(0, total - pending)} of ${total} files${problems}`];
  if (settings.pausedForPlayback) parts.push("paused while someone watches");
  const left = remainingText(settings.estimatedSecondsRemaining);
  if (left) parts.push(left);
  return parts.join(" · ");
}

/** "Now: Movie · Reading every byte (40 %)", or "". */
export function fileCheckCurrent(settings) {
  if (!settings?.running || !settings.currentTitle) return "";
  const share = Number.isFinite(settings.currentFraction) ? ` (${Math.round(settings.currentFraction * 100)} %)` : "";
  return `Now: ${settings.currentTitle}${settings.currentStep ? ` · ${settings.currentStep}${share}` : ""}`;
}

export function fileProblemTitle(state) {
  switch (state) {
    case "unreadable": return "Unreadable";
    case "changedUnexpectedly": return "Changed by Itself";
    case "damaged": return "Damaged";
    case "notice": return "Notice";
    default: return "OK";
  }
}

/** "At about 1:02:10 of 1:45:00", "At about 1:02:10", or "". */
export function fileProblemWhere(problem) {
  if (!Number.isFinite(problem?.problemAtSeconds)) return "";
  const at = `At about ${clockText(problem.problemAtSeconds)}`;
  return Number.isFinite(problem.durationSeconds) && problem.durationSeconds > 0 ? `${at} of ${clockText(problem.durationSeconds)}` : at;
}

/** The small line under a problem: where, how many errors, when it was examined. */
export function fileProblemFacts(problem, now = new Date()) {
  const parts = [];
  const where = fileProblemWhere(problem);
  if (where) parts.push(where);
  if (problem?.errorCount > 1) parts.push(`${problem.errorCount} errors`);
  if (problem?.libraryName) parts.push(problem.libraryName);
  if (problem?.checkedAt) parts.push(`examined ${new Date(problem.checkedAt).toLocaleDateString(undefined, { day: "numeric", month: "short", year: new Date(problem.checkedAt).getFullYear() === now.getFullYear() ? undefined : "numeric" })}`);
  return parts.join(" · ");
}

export function driveStateTitle(state) {
  switch (state) {
    case "good": return "Good";
    case "warning": return "Warning";
    case "failing": return "Failing";
    default: return "Unknown";
  }
}

/** "35 °C · 10,000 hours · 12 bad sectors", from what the drive reports. */
export function driveFacts(drive) {
  const parts = [];
  if (Number.isFinite(drive?.temperatureCelsius)) parts.push(`${Math.round(drive.temperatureCelsius)} °C`);
  if (Number.isFinite(drive?.powerOnHours)) parts.push(`${drive.powerOnHours.toLocaleString("en-US")} hours`);
  if (Number.isFinite(drive?.badSectors) && drive.badSectors > 0) parts.push(`${drive.badSectors.toLocaleString("en-US")} bad sectors`);
  return parts.join(" · ");
}
