// Security in the browser: Settings › Profiles and Devices › Security for the owner (log, new
// devices, Block and the block list, how long the log is kept), the owner's note when a new device
// signs in, and "Confirm on Another Device" when Face ID or Touch ID is required for administrators.
// Face ID itself lives in the iPhone, iPad and Mac apps: the browser keeps no keys.

import { h, icon, clear } from "./dom.js";
import { confirmSheet } from "./sheet.js";
import {
  SECURITY_LOG_FILTERS, newDeviceNote, remoteUnlockState, securityDeviceLine, securityEventText, securityEventsQuery,
  unansweredDevices
} from "./security.js";

const when = (value) => (value ? new Date(value).toLocaleString() : "");

/** Asks the owner before blocking: the device is signed out at once and can't come back. */
function confirmBlock(device) {
  return confirmSheet({ symbol: "lock", title: `Block “${device.deviceName}”?`, confirm: "Block",
    message: "It is signed out at once and can’t sign in or pair again until you unblock it." });
}

function confirmSignOutDevice(device) {
  return confirmSheet({ symbol: "lock", title: `Sign Out “${device.deviceName}”?`, confirm: "Sign Out",
    message: "It needs a new code to use Aurelia again." });
}

/**
 * Shown where the Server Password was refused because Face ID or Touch ID is required: asks an
 * iPhone, iPad or Mac of this profile (or the owner's) to confirm, and waits for the answer.
 */
export function remoteUnlockPanel({ api, onUnlocked, delay = 2000 }) {
  const status = h("p", { class: "muted small", role: "status", "aria-live": "polite" });
  const code = h("div", { class: "code-display", hidden: true });
  const ask = h("button", { type: "button", class: "primary-button" }, "Confirm on Another Device");
  const panel = h("div", { class: "remote-unlock" },
    h("p", {}, "Face ID or Touch ID is required to manage this server. Confirm on an iPhone, iPad or Mac where you set it up."),
    code, status, h("div", { class: "button-row" }, ask));
  let timer = 0;
  const stop = () => clearTimeout(timer);
  ask.addEventListener("click", async () => {
    ask.disabled = true;
    stop();
    try {
      const request = await api.startRemoteUnlock();
      code.hidden = false;
      code.className = "code-display";
      code.textContent = request.code;
      status.textContent = remoteUnlockState({ state: "pending" }).text + " Check that it shows this code.";
      const poll = async () => {
        if (!panel.isConnected) return;
        try {
          const shown = remoteUnlockState(await api.remoteUnlockStatus(request.id));
          if (!panel.isConnected) return;
          if (!shown.done) { timer = setTimeout(poll, delay); return; }
          status.textContent = shown.text;
          ask.disabled = false;
          ask.textContent = "Ask Again";
          if (!shown.unlocked) code.className = "code-display expired";
          else onUnlocked?.();
        } catch (error) {
          if (!panel.isConnected) return;
          status.textContent = error.message;
          ask.disabled = false;
        }
      };
      timer = setTimeout(poll, delay);
    } catch (error) {
      status.textContent = error.message;
      ask.disabled = false;
    }
  });
  return panel;
}

/** The security log in a sheet: newest first, a filter, and Load More. */
export function openSecurityLog({ api, toast }) {
  const list = h("div", { class: "settings-card-list security-log" });
  const more = h("button", { type: "button", class: "secondary-button", hidden: true }, "Load More");
  const filter = h("select", { class: "select", "aria-label": "Show" },
    SECURITY_LOG_FILTERS.map(([value, label]) => h("option", { value }, label)));
  const dialog = h("dialog", { class: "sheet settings-editor security-log-sheet", "aria-label": "Security Log" },
    h("div", { class: "security-log-header" }, h("h2", {}, "Security Log"), filter),
    list, h("div", { class: "button-row" }, more),
    h("div", { class: "button-row end" }, h("button", { class: "primary-button", onclick: () => dialog.close() }, "Done")));
  let before = null;
  let generation = 0;
  const load = async (append) => {
    const run = ++generation;
    more.disabled = true;
    try {
      const page = await api.securityEvents(securityEventsQuery({ outcome: filter.value, before: append ? before : null }));
      if (run !== generation || !dialog.isConnected) return;
      if (!append) clear(list);
      for (const event of page?.events ?? []) {
        const text = securityEventText(event);
        list.append(h("div", { class: `settings-card small${text.failed ? " security-failed" : ""}` },
          h("div", { class: "settings-card-main" },
            h("div", { class: "settings-card-title" }, text.title),
            text.subtitle ? h("div", { class: "muted small" }, text.subtitle) : null),
          h("div", { class: "muted small" }, when(event.at))));
      }
      if (!list.children.length) list.append(h("p", { class: "muted small" }, "Nothing recorded yet."));
      before = page?.before ?? null;
      more.hidden = !before;
    } catch (error) {
      if (dialog.isConnected) toast(error.message);
    } finally {
      more.disabled = false;
    }
  };
  filter.addEventListener("change", () => load(false));
  more.addEventListener("click", () => load(true));
  dialog.addEventListener("close", () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
  load(false);
}

/**
 * Settings › Profiles and Devices › Security, for the owner. Fills itself after the page shows.
 * @param {object} kit  the settings page's section, row, value and select builders
 */
export function securitySection({ api, app, kit, refresh }) {
  const { section, row, value, select } = kit;
  const devices = h("div", { class: "settings-card-list" }, h("p", { class: "muted small" }, "Loading…"));
  const blocked = h("div", { class: "settings-card-list" });
  const settingsRows = h("div", {});
  // A locked management asks for the Server Password and runs the change again (audit S6).
  const run = async (work, done) => {
    try {
      let cancelled = false;
      await unlocked(api, work, () => { cancelled = true; });
      if (cancelled) return;
      if (done) app.toast(done);
      refresh();
    } catch (error) {
      if (!app.handleError(error)) app.toast(error.message);
    }
  };
  const element = section("Security", "lock",
    "Who signed in when and from which device, failed attempts and changes. Face ID and Touch ID are set up in the iPhone, iPad and Mac apps.",
    settingsRows,
    h("h3", { class: "settings-subheading" }, "Signed-In Devices"), devices,
    blocked,
    h("div", { class: "button-row" }, h("button", { type: "button", class: "secondary-button", onclick: () => openSecurityLog({ api, toast: app.toast }) }, "Show Security Log…")));

  (async () => {
    let devicesFailed = null;
    const [settings, deviceList, blockedList] = await Promise.all([
      api.securitySettings().catch(() => null), api.securityDevices().catch((error) => { devicesFailed = error; return []; }), api.blockedDevices().catch(() => []),
    ]);
    if (settings) {
      settingsRows.append(
        row("Face ID or Touch ID for Administrators", value(settings.requirePasskeysForAdministrators ? "Required" : "Optional"),
          "Changed in the iPhone, iPad or Mac app, where the keys are. On the server computer itself the Server Password always works."),
        row("Keep the Log", select([30, 60, 90, 180, 365].map((days) => [days, `${days} days`]), settings.securityLogDays,
          (days) => run(() => api.saveSecuritySettings({ securityLogDays: Number(days), requirePasskeysForAdministrators: settings.requirePasskeysForAdministrators }), "Saved."),
          "Keep the Log")));
    }
    clear(devices);
    for (const device of deviceList ?? []) {
      const line = securityDeviceLine(device.platform, device.ipAddress);
      devices.append(h("div", { class: "settings-card" },
        h("div", { class: "settings-card-main" },
          h("div", { class: "settings-card-title" }, device.deviceName,
            device.isCurrent ? h("span", { class: "tag" }, "This Browser") : null,
            device.isNew ? h("span", { class: "tag tag-new" }, "New") : null),
          h("div", { class: "muted small" }, [device.userName, line, `last used ${when(device.lastSeenAt)}`].filter(Boolean).join(" · "))),
        h("div", { class: "settings-card-actions" },
          device.isNew ? h("button", { type: "button", class: "secondary-button", onclick: () => run(() => api.acknowledgeDevice(device.id)) }, "That Was Me") : null,
          !device.isCurrent ? h("button", { type: "button", class: "secondary-button", onclick: async () => {
            if (await confirmSignOutDevice(device)) run(() => api.approved(`/api/v1/auth/sessions/${device.id}`, { method: "DELETE" }), `${device.deviceName} is signed out.`);
          } }, "Sign Out…") : null,
          device.canBlock ? h("button", { type: "button", class: "secondary-button danger", onclick: async () => {
            if (await confirmBlock(device)) run(() => api.blockDevice(device.id), `${device.deviceName} is blocked and signed out.`);
          } }, "Block…") : null)));
    }
    // A failed read says so; it isn't "no devices" (audit S7).
    if (devicesFailed) devices.append(h("div", { class: "error-banner", role: "alert" }, icon("warning", { size: 16 }), h("span", {}, `Couldn’t load the devices: ${devicesFailed.message}`),
      h("button", { type: "button", class: "secondary-button small", onclick: () => refresh() }, "Try Again")));
    else if (!devices.children.length) devices.append(h("p", { class: "muted small" }, "No devices are signed in."));
    if (blockedList?.length) {
      blocked.append(h("h3", { class: "settings-subheading" }, "Blocked Devices"));
      for (const device of blockedList) {
        blocked.append(h("div", { class: "settings-card" },
          h("div", { class: "settings-card-main" },
            h("div", { class: "settings-card-title" }, device.deviceName),
            h("div", { class: "muted small" }, [securityDeviceLine(device.platform, device.ipAddress), `blocked ${when(device.blockedAt)}`].filter(Boolean).join(" · "))),
          h("div", { class: "settings-card-actions" },
            h("button", { type: "button", class: "secondary-button", onclick: (event) => { event.currentTarget.disabled = true; run(() => api.unblockDevice(device.id), `${device.deviceName} is unblocked.`); } }, "Unblock"))));
      }
    }
  })();
  return element;
}

/**
 * The owner's notes about new devices, at the top of the page while a profile is open: "That Was
 * Me" or "Block". Long-polls the server, so a sign-in shows within seconds.
 */
export function createSecurityAlerts({ api, toast, handleError }) {
  const answered = new Set();
  const container = h("div", { class: "security-alerts", role: "region", "aria-label": "Security notes" });
  let controller = null;

  function render(devices) {
    clear(container);
    for (const device of unansweredDevices(devices, answered).slice(0, 3)) {
      const answer = async (work, done) => {
        answered.add(device.id);
        render(devices);
        try {
          await work();
          if (done) toast(done);
        } catch (error) {
          if (!handleError(error)) toast(error.message);
        }
      };
      container.append(h("div", { class: "security-alert" },
        h("div", {}, h("div", { class: "security-alert-title" }, newDeviceNote(device)),
          h("div", { class: "muted small" }, [device.userName, when(device.createdAt)].filter(Boolean).join(" · "))),
        h("div", { class: "button-row" },
          h("button", { type: "button", class: "secondary-button danger", onclick: async () => {
            if (await confirmBlock(device)) answer(() => api.blockDevice(device.id), `${device.deviceName} is blocked and signed out.`);
          } }, "Block…"),
          h("button", { type: "button", class: "primary-button", onclick: () => answer(() => api.acknowledgeDevice(device.id)) }, "That Was Me"))));
    }
    if (container.children.length && !container.isConnected) document.body.append(container);
    if (!container.children.length) container.remove();
  }

  function start() {
    stop();
    const current = new AbortController();
    controller = current;
    (async () => {
      let version = 0;
      let failures = 0;
      while (!current.signal.aborted) {
        try {
          const alerts = await api.securityAlerts(version, version === 0 ? 0 : 25, { signal: current.signal });
          if (current.signal.aborted) return;
          version = alerts?.version ?? version;
          render(alerts?.newDevices ?? []);
          failures = 0;
        } catch (error) {
          if (current.signal.aborted || error?.name === "AbortError") return;
          // A refused read (an older server, or the profile ended) stops the notes quietly.
          if (error?.status === 401 || error?.status === 403 || error?.status === 404) return;
          failures += 1;
          await new Promise((resolve) => setTimeout(resolve, Math.min(60_000, 5_000 * failures)));
        }
      }
    })();
  }

  function stop() {
    controller?.abort();
    controller = null;
    clear(container);
    container.remove();
  }

  return { start, stop };
}

/**
 * Runs a management change; when management is locked, asks for the Server Password (or a
 * confirmation on another device) once and runs it again. Returns undefined when cancelled.
 */
export async function unlocked(api, work, onCancel) {
  try {
    return await work();
  } catch (error) {
    if (error?.code !== "management_locked") throw error;
  }
  const ok = await new Promise((resolve) => {
    const password = h("input", { type: "password", class: "text-field", autocomplete: "current-password", "aria-label": "Server Password" });
    const message = h("p", { class: "error-text", role: "alert" });
    const body = h("div", {});
    const submit = h("button", { type: "button", class: "primary-button" }, "Unlock");
    let settled = false;
    const finish = (value) => { if (!settled) { settled = true; resolve(value); } dialog.close(); };
    const dialog = h("dialog", { class: "sheet" },
      h("h2", {}, "Unlock Server Management"),
      h("p", { class: "muted small" }, "Enter the Server Password to make this change. Management stays unlocked for ten minutes."),
      body, password, message,
      h("div", { class: "button-row end" }, h("button", { type: "button", class: "secondary-button", onclick: () => finish(false) }, "Cancel"), submit));
    submit.addEventListener("click", async () => {
      if (!password.value) return;
      submit.disabled = true;
      try {
        await api.unlockManagement(password.value);
        finish(true);
      } catch (error) {
        submit.disabled = false;
        if (error?.code === "passkey_required") {
          password.hidden = true;
          submit.hidden = true;
          body.append(remoteUnlockPanel({ api, onUnlocked: () => finish(true) }));
          return;
        }
        message.textContent = error?.code === "invalid_credentials" ? "The Server Password is incorrect." : error?.message ?? "";
      } finally {
        password.value = "";
      }
    });
    password.addEventListener("keydown", (event) => { if (event.key === "Enter") { event.preventDefault(); submit.click(); } });
    dialog.addEventListener("cancel", () => finish(false));
    dialog.addEventListener("close", () => { if (!settled) { settled = true; resolve(false); } dialog.remove(); });
    document.body.append(dialog);
    dialog.showModal();
    password.focus();
  });
  if (!ok) onCancel?.();
  return ok ? work() : undefined;
}
