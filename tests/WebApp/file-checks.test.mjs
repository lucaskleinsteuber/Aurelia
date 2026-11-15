import test from "node:test";
import assert from "node:assert/strict";
import {
  clockText, driveFacts, driveStateTitle, fileCheckCurrent, fileCheckProgress, fileCheckStatus, fileProblemFacts, fileProblemTitle,
  fileProblemWhere, remainingText, supportsFileChecks,
} from "../../src/Aurelia.Server/WebApp/js/file-checks.js";

test("the file watch is offered only by a server that reports it", () => {
  assert.equal(supportsFileChecks({ capabilities: ["file-checks-v1"] }), true);
  assert.equal(supportsFileChecks({ capabilities: ["media-segments-v2"] }), false);
  assert.equal(supportsFileChecks(null), false);
});

test("the status says off, done or how far the watch is", () => {
  assert.equal(fileCheckStatus({ enabled: false, totalCount: 10, pendingCount: 10 }), "Off");
  assert.equal(fileCheckStatus({ enabled: true, totalCount: 120, pendingCount: 0 }), "All 120 files examined");
  assert.equal(fileCheckStatus({ enabled: true, totalCount: 1, pendingCount: 0, problemCount: 1 }), "All 1 file examined · 1 problem");
  assert.equal(fileCheckStatus({ enabled: true, totalCount: 120, pendingCount: 80, problemCount: 2, pausedForPlayback: true, estimatedSecondsRemaining: 12_000 }),
    "40 of 120 files · 2 problems · paused while someone watches · About 3 h 20 min left");
  assert.equal(fileCheckProgress({ totalCount: 120, pendingCount: 30 }), 0.75);
  assert.equal(fileCheckProgress({ totalCount: 0 }), 1);
  assert.equal(remainingText(3 * 86_400), "About 3 days left");
  assert.equal(fileCheckCurrent({ running: true, currentTitle: "Show · S01E02", currentStep: "Reading every byte", currentFraction: 0.4 }),
    "Now: Show · S01E02 · Reading every byte (40 %)");
  assert.equal(fileCheckCurrent({ running: false, currentTitle: "Show" }), "");
});

test("a problem says what it is and where", () => {
  assert.equal(fileProblemTitle("changedUnexpectedly"), "Changed by Itself");
  assert.equal(fileProblemTitle("unreadable"), "Unreadable");
  assert.equal(clockText(3730), "1:02:10");
  assert.equal(clockText(245), "4:05");
  assert.equal(fileProblemWhere({ problemAtSeconds: 3730, durationSeconds: 6300 }), "At about 1:02:10 of 1:45:00");
  assert.equal(fileProblemWhere({ problemAtSeconds: null }), "");
  assert.equal(fileProblemFacts({ problemAtSeconds: 60, errorCount: 3, libraryName: "Movies" }), "At about 1:00 · 3 errors · Movies");
});

test("a drive shows its state and what it measured", () => {
  assert.equal(driveStateTitle("failing"), "Failing");
  assert.equal(driveStateTitle("unknown"), "Unknown");
  assert.equal(driveFacts({ temperatureCelsius: 35.4, powerOnHours: 10000, badSectors: 12 }), "35 °C · 10,000 hours · 12 bad sectors");
  assert.equal(driveFacts({ badSectors: 0 }), "");
});
