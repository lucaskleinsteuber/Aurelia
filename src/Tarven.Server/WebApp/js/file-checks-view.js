// The file watch in the browser, as on the Mac: the owner's settings with progress, and Library
// Health's File Problems and Drives.

import { h, clear } from "./dom.js";
import { keepsPolling } from "./logic.js";
import {
  DEPTH_CHOICES, RECHECK_CHOICES, driveFacts, driveStateTitle, fileCheckCurrent, fileCheckProgress, fileCheckStatus,
  fileProblemFacts, fileProblemTitle,
} from "./file-checks.js";

function button(label, onclick, { kind = "secondary-button small", title } = {}) {
  return h("button", { type: "button", class: kind, title, "aria-label": title ? `${label}. ${title}` : label, onclick }, label);
}

function choice(label, choices, onchange) {
  return h("select", { class: "select-input", "aria-label": label, onchange: (event) => onchange(event.target.value) },
    choices.map(([value, text]) => h("option", { value: String(value) }, text)));
}

/** Settings › Server › File Watch, for the owner. */
export function serverFileChecksSection({ api, section, row, toggle }) {
  const state = h("span", { class: "settings-value" }, "Loading…");
  const bar = h("progress", { class: "segments-progress", max: "1", value: "0" });
  const current = h("p", { class: "muted small" });
  const message = h("p", { class: "muted small", role: "status", "aria-live": "polite" });
  const depthHint = h("p", { class: "muted small" });
  let settings = null;
  const enabled = toggle(false, (on) => change({ enabled: on }), "Watch Files");
  const depth = choice("How Thoroughly", DEPTH_CHOICES, (value) => change({ enabled: settings?.enabled ?? false, depth: value }));
  const recheck = choice("Read Again", RECHECK_CHOICES, (value) => change({ enabled: settings?.enabled ?? false, recheckDays: Number(value) }));
  const element = section("File Watch", "library",
    "The server reads every file in the background, only while nobody watches, and tells you in Library Health when one is damaged, can't be read or changed by itself. Files are only read, never changed.",
    row("Watch Files", enabled, "Off until you turn it on. The first round reads the whole library once."),
    row("How Thoroughly", depth),
    depthHint,
    row("Read Again", recheck, "Reads every file again in this rhythm and compares it with the first time, to find bit rot."),
    row("Progress", h("div", { class: "segments-status" }, bar, state)),
    current,
    message);

  async function change(body) {
    try { render(await api.saveServerFileChecks(body)); message.textContent = ""; }
    catch (error) { message.textContent = error.message; }
  }
  function render(value) {
    settings = value;
    const input = (wrapper) => wrapper.querySelector?.("input") ?? wrapper;
    input(enabled).checked = value.enabled;
    depth.value = value.depth;
    recheck.value = String(value.recheckDays);
    const usable = DEPTH_CHOICES.filter(([key]) => value.canInspect || key === "read");
    for (const option of depth.options) option.disabled = !usable.some(([key]) => key === option.value);
    depthHint.textContent = (DEPTH_CHOICES.find(([key]) => key === value.depth)?.[2] ?? "")
      + (value.canInspect ? "" : " This server has no ffmpeg, so it can only read every byte.");
    bar.value = fileCheckProgress(value);
    state.textContent = fileCheckStatus(value);
    current.textContent = fileCheckCurrent(value);
  }
  const startedAt = Date.now();
  let everConnected = false;
  const polling = () => {
    everConnected ||= element.isConnected;
    return keepsPolling({ connected: element.isConnected, everConnected, startedAt, now: Date.now() });
  };
  // A hidden tab asks nothing; the reads say they are the page's own, so an open page never
  // keeps the server awake (audit W7, S15).
  const tick = async () => {
    if (!polling()) return;
    if (globalThis.document?.hidden) { setTimeout(tick, 5000); return; }
    try { render(await api.background(() => api.serverFileChecks())); } catch (error) { message.textContent = error.message; }
    if (polling()) setTimeout(tick, 5000);
  };
  tick();
  return element;
}

/** Library Health › File Problems: the open problems, or the ones set aside. */
export async function renderFileProblems({ api, container, app, onEdit, ignored = false, rerender }) {
  const problems = await api.fileProblems({ ignored, offset: 0, limit: 100 });
  clear(container);
  const show = h("select", { class: "select-input", "aria-label": "Show", onchange: (event) => rerender(event.target.value === "aside") },
    h("option", { value: "open", selected: !ignored }, "Open Problems"),
    h("option", { value: "aside", selected: ignored }, "Set Aside"));
  container.append(
    h("p", { class: "muted" }, "Files the file watch found a problem in. Play a title to check it, and replace a damaged file from a backup or a new copy; then choose Examine Again. Tarven never changes files."),
    h("div", { style: { marginBottom: "16px" } }, show));
  if (!problems.length) {
    container.append(h("p", { class: "muted" }, ignored ? "No problem is set aside." : "No file has a problem."));
    return;
  }
  for (const problem of problems) {
    container.append(h("div", { class: "health-item-row" },
      h("div", { style: { display: "flex", flexDirection: "column", gap: "2px", flex: 1, minWidth: 0 } },
        h("div", { style: { fontWeight: "600" } }, `${problem.title} · ${fileProblemTitle(problem.state)}`),
        h("div", { style: { fontSize: "13px", wordBreak: "break-all" } }, problem.fileName),
        problem.detail ? h("div", { class: "small" }, problem.detail) : null,
        h("div", { class: "muted small" }, fileProblemFacts(problem))),
      h("div", { class: "button-row" },
        button("Examine Again", async () => {
          try { await api.recheckFile(problem.mediaId); app.toast("The file is examined again in the background."); rerender(ignored); }
          catch (error) { app.toast(error.message); }
        }, { title: "Reads the file again from the start and keeps it as the new reference." }),
        button(ignored ? "Bring Back" : "Set Aside", async () => {
          try { await api.ignoreFileProblem(problem.mediaId, !ignored); rerender(ignored); }
          catch (error) { app.toast(error.message); }
        }, { title: ignored ? "Shows the problem with the open ones again." : "Keeps the problem out of the count, for a file you know about." }),
        onEdit ? button("Edit Metadata…", () => onEdit(problem)) : null)));
  }
}

/** Library Health › Drives: what the drives with storage locations report about themselves. */
export async function renderDrives({ api, container, app, refresh = false }) {
  const answer = refresh ? await api.refreshDrives() : await api.drives();
  clear(container);
  container.append(h("p", { class: "muted" },
    "How the drives with your storage locations are doing, as they report it themselves (SMART). Many USB cases and network shares don't report it."));
  for (const drive of answer.drives ?? []) {
    const facts = driveFacts(drive);
    container.append(h("div", { class: "health-item-row" },
      h("div", { style: { display: "flex", flexDirection: "column", gap: "2px", flex: 1, minWidth: 0 } },
        h("div", { style: { fontWeight: "600" } }, `${drive.name} · ${driveStateTitle(drive.state)}`),
        h("div", { class: "muted small" }, (drive.libraries ?? []).join(", ")),
        drive.detail ? h("div", { class: drive.state === "failing" ? "error-text small" : "small" }, drive.detail) : null,
        facts ? h("div", { class: "muted small" }, facts) : null)));
  }
  if (!answer.drives?.length) container.append(h("p", { class: "muted" }, "There are no storage locations yet."));
  container.append(h("div", { class: "button-row", style: { marginTop: "12px" } },
    h("span", { class: "muted small" }, answer.checkedAt ? `Asked ${new Date(answer.checkedAt).toLocaleString()}` : ""),
    button("Ask Again", async () => {
      try { await renderDrives({ api, container, app, refresh: true }); }
      catch (error) { app.toast(error.message); }
    })));
}
