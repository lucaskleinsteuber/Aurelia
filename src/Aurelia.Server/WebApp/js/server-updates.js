// A Linux package's updater runs outside the server. Only its small status endpoint is polled;
// a restart may briefly disconnect the browser, and an expired management window needs unlock.
import { h, icon, clear } from "./dom.js";

const POLL_MILLISECONDS = 2000;
const busy = (status) => status?.state === "checking" || status?.state === "installing";

function checkedStatus(value) {
  if (!value || typeof value.available !== "boolean" || typeof value.installed !== "string"
    || !["idle", "checking", "installing", "failed"].includes(value.state)
    || typeof value.updateAvailable !== "boolean"
    || (value.newest != null && typeof value.newest !== "string")
    || (value.checkedAt != null && typeof value.checkedAt !== "string")
    || (value.message != null && typeof value.message !== "string"))
    throw new Error("The server returned an unreadable update status. Try again.");
  return value;
}

export function updateSummary(status) {
  if (!status.available) return "Updates are available on Linux servers installed from the Aurelia package.";
  if (status.state === "checking") return "Looking for a new version…";
  if (status.state === "installing") return `Installing ${status.newest ?? "the update"}… The server restarts during the update.`;
  if (status.state === "failed") return status.message || "The last update did not work.";
  if (status.updateAvailable) return "A new version is ready to install.";
  return status.checkedAt ? "The server is up to date." : "Not checked yet.";
}

export function createServerUpdates({ api, initial, isCurrent = () => true, onLocked = () => {}, onSessionEnded = () => {},
  schedule = (work, delay) => setTimeout(work, delay), cancel = (timer) => clearTimeout(timer) }) {
  const lifetime = new AbortController();
  const rows = h("div", { class: "settings-rows" });
  const element = h("section", { class: "settings-section", "aria-label": "Server Updates" },
    h("div", { class: "settings-section-header" }, h("span", { class: "settings-symbol" }, icon("power", { size: 18 })),
      h("div", {}, h("h2", {}, "Updates"), h("p", { class: "muted small" }, "The server checks daily. Installing waits for you."))), rows);
  let status;
  let message = "";
  let result = "";
  let working = false;
  let reading = false;
  let reconnecting = false;
  let locked = false;
  let sessionError = null;
  let timer;
  let dialog;
  let operation;
  let installedBefore;
  let remainingPolls = 0;
  const current = () => !lifetime.signal.aborted && isCurrent();
  const row = (label, value) => h("div", { class: "settings-row" }, h("div", { class: "settings-label" }, label), h("span", { class: "settings-value" }, value ?? "—"));
  const stopTimer = () => { if (timer != null) cancel(timer); timer = undefined; };

  function close() {
    lifetime.abort();
    stopTimer();
    dialog?.close();
    dialog = null;
  }

  function pollLater() {
    stopTimer();
    if (!current() || locked || sessionError || !(busy(status) || reconnecting)) return;
    if (remainingPolls <= 0) {
      reconnecting = false;
      message = "The update is taking longer than expected. Check its status again before trying another installation.";
      render();
      return;
    }
    timer = schedule(() => { timer = undefined; remainingPolls--; void refresh(); }, POLL_MILLISECONDS);
  }

  function accept(value) {
    const next = checkedStatus(value);
    if (next.state === "installing" && operation !== "install") {
      operation = "install";
      installedBefore = status?.installed ?? next.installed;
      remainingPolls = 480;
    } else if (next.state === "checking" && !operation) {
      operation = "check";
      remainingPolls = 90;
    }
    if (operation === "install" && next.state === "idle") {
      result = next.installed !== installedBefore
        ? `The server is now running ${next.installed}.`
        : `The server is back, still on ${next.installed}. The update was not installed; check for updates and try again.`;
      operation = undefined;
    } else if (operation === "check" && next.state === "idle") {
      // The answer is the status itself: a new version, or none.
      result = next.updateAvailable ? `Aurelia Server ${next.newest ?? "update"} is ready to install.` : `No new version found. The server is up to date (${next.installed}).`;
      operation = undefined;
    }
    if (next.state === "failed") operation = undefined;
    status = next;
    reconnecting = false;
    message = "";
    locked = false;
    sessionError = null;
  }

  function fail(error) {
    if (!current() || error?.name === "AbortError") return;
    if (error?.code === "management_locked") {
      locked = true;
      reconnecting = false;
      message = "Server management is locked. Unlock it to check progress or try again.";
    } else if (error?.status === 401 || (error?.status === 403 && /session|profile|device/.test(error.code ?? ""))) {
      sessionError = error;
      reconnecting = false;
      message = operation === "install" || status?.state === "installing"
        ? "The server restarted. Choose your profile again to check the installed version."
        : "Your profile session ended. Choose your profile again to continue.";
    } else if (error?.offline && (busy(status) || operation || reconnecting)) {
      reconnecting = true;
      message = operation === "install" || status?.state === "installing"
        ? "The server is restarting or is temporarily out of reach. Waiting to reconnect…"
        : "The server is temporarily out of reach. Waiting for the update check…";
    } else {
      reconnecting = false;
      message = error?.message || "The update status could not be read. Try again.";
    }
  }

  async function refresh({ retry = false } = {}) {
    if (!current() || reading || working) return;
    stopTimer();
    if (retry) remainingPolls = operation === "install" || status?.state === "installing" ? 480 : 90;
    reading = true;
    render();
    try {
      const value = await api.serverUpdates({ signal: lifetime.signal });
      if (!current()) return;
      accept(value);
    } catch (error) { fail(error); }
    finally {
      reading = false;
      if (current()) { render(); pollLater(); }
    }
  }

  async function run(kind) {
    if (!current() || working || reading || busy(status) || reconnecting || locked || sessionError) return;
    working = true;
    operation = kind;
    installedBefore = status?.installed;
    remainingPolls = kind === "install" ? 480 : 90;
    message = result = "";
    render();
    try {
      const value = kind === "install"
        ? await api.approved("/api/v1/server/updates/install", { signal: lifetime.signal })
        : await api.checkForUpdates({ signal: lifetime.signal });
      if (!current()) return;
      accept(value);
    } catch (error) {
      // A refused approval must not cause a retry of the mutation. A later explicit click
      // obtains a fresh one-time grant; polling only ever reads the status endpoint.
      fail(error);
      if (!reconnecting) operation = undefined;
    } finally {
      working = false;
      if (current()) { render(); pollLater(); }
    }
  }

  function confirmInstall() {
    if (!current() || dialog || working || reading || busy(status) || !status?.updateAvailable) return;
    const confirm = h("button", { class: "primary-button", onclick: () => { sheet.close(); void run("install"); } }, "Install Update");
    const sheet = h("dialog", { class: "sheet" }, h("h2", {}, `Install Aurelia Server ${status.newest ?? "update"}?`),
      h("p", {}, "The server stops for about a minute while it updates. Accounts, library and settings stay."),
      h("div", { class: "button-row end" }, h("button", { class: "secondary-button", onclick: () => sheet.close() }, "Cancel"), confirm));
    dialog = sheet;
    sheet.addEventListener("close", () => { sheet.remove(); if (dialog === sheet) dialog = null; }, { once: true });
    document.body.append(sheet);
    sheet.showModal();
    confirm.focus();
  }

  function render() {
    if (!current()) return;
    clear(rows);
    const inProgress = working || busy(status) || reconnecting;
    if (status) rows.append(row("Installed", status.installed), row("Newest", status.newest ?? (status.checkedAt ? "Up to date" : "Not checked yet")),
      h("p", { class: status.state === "failed" ? "error-text" : "muted small", role: "status", "aria-live": "polite" }, updateSummary(status)));
    if (inProgress && !locked && !sessionError) rows.append(h("progress", { "aria-label": "Server update progress" }));
    if (result) rows.append(h("p", { class: "muted small", role: "status" }, result));
    if (message) rows.append(h("p", { class: "error-text", role: "alert" }, message));
    if (locked) rows.append(h("button", { class: "primary-button", onclick: () => { if (current()) onLocked(); } }, "Unlock Server Management"));
    else if (sessionError) rows.append(h("button", { class: "primary-button", onclick: () => { if (current()) onSessionEnded(sessionError); } }, "Choose Profile Again"));
    else {
      const disabled = inProgress || reading || !status?.available;
      rows.append(h("div", { class: "button-row" },
        h("button", { class: "secondary-button", disabled, onclick: () => void run("check") }, "Check for Updates"),
        status?.updateAvailable ? h("button", { class: "primary-button", disabled, onclick: confirmInstall }, "Install Update…") : null,
        message ? h("button", { class: "secondary-button", disabled: working || reading, onclick: () => void refresh({ retry: true }) }, "Check Status Again") : null));
    }
  }

  try {
    status = checkedStatus(initial);
    if (busy(status)) {
      operation = status.state === "installing" ? "install" : "check";
      installedBefore = status.installed;
      remainingPolls = operation === "install" ? 480 : 90;
    }
  } catch (error) { message = error.message; }
  render();
  pollLater();
  return { element, close, refresh };
}
