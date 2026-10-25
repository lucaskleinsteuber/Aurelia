// Settings, with the Mac app's pages: General (this browser and the profile), Playback (this
// browser's player) and Server (for owners and administrators). Server management is unlocked
// with the Server Password for ten minutes, as on the Mac; the browser never keeps the password.
// Changes the server guards ask it for a one-time approval of exactly that change.

import { h, icon, clear } from "./dom.js";
import { ApiError } from "./api.js";
import { PLAYBACK_DEFAULTS, PLAYBACK_RATES, rateLabel } from "./logic.js";
import { loadPreferences, savePreferences } from "./player.js";

const PAGES = [
  ["general", "General", "gear"],
  ["playback", "Playback", "play"],
  ["server", "Server", "library"],
];

/**
 * @param {object} app  what settings needs from the app: api, state, navigate, toast, handleError,
 *                      profilePicture, switchProfile, confirmSignOut
 */
export function createSettings(app) {
  const { api, state } = app;
  const canManage = () => state.profile?.role === "owner" || state.profile?.role === "admin";

  async function settingsScreen(route) {
    const page = route.page === "server" && !canManage() ? "general" : route.page;
    const content = page === "playback" ? playbackPage() : page === "server" ? await serverPage() : generalPage();
    return h("div", { class: "settings page-enter" },
      h("div", { class: "page-header" }, h("h1", {}, "Settings")),
      h("nav", { class: "settings-tabs", "aria-label": "Settings" }, PAGES.filter(([name]) => name !== "server" || canManage()).map(([name, label, symbol]) =>
        h("a", { class: `settings-tab ${page === name ? "selected" : ""}`, href: name === "general" ? "/settings" : `/settings/${name}`, "data-route": true, "aria-current": page === name ? "page" : null },
          icon(symbol, { size: 18 }), label))),
      h("div", { class: "settings-content" }, content));
  }

  function section(title, symbol, description, ...children) {
    return h("section", { class: "settings-section" },
      h("div", { class: "settings-section-header" },
        h("span", { class: "settings-symbol" }, icon(symbol, { size: 18 })),
        h("div", {}, h("h2", {}, title), description ? h("p", { class: "muted small" }, description) : null)),
      h("div", { class: "settings-rows" }, children));
  }

  function row(label, control, note) {
    return h("div", { class: "settings-row" },
      h("div", { class: "settings-label" }, h("div", {}, label), note ? h("div", { class: "muted small" }, note) : null),
      h("div", { class: "settings-control" }, control));
  }

  function value(text) {
    return h("span", { class: "settings-value" }, text ?? "—");
  }

  function toggle(checked, onChange, label) {
    const input = h("input", { type: "checkbox", class: "switch", checked, "aria-label": label });
    input.addEventListener("change", () => onChange(input.checked));
    return input;
  }

  function select(options, current, onChange, label) {
    const element = h("select", { class: "select", "aria-label": label }, options.map(([optionValue, text]) =>
      h("option", { value: String(optionValue), selected: String(optionValue) === String(current) }, text)));
    element.addEventListener("change", () => onChange(element.value));
    return element;
  }

  // MARK: General

  function generalPage() {
    const server = state.server ?? {};
    const profile = state.profile;
    return h("div", { class: "settings-stack" },
      section("Aurelia in This Browser", "gear", "The browser app comes from your Aurelia Server, so it always has the server's version and updates with it.",
        row("Version", value(server.version ? `${server.version}` : "—"), "The same as the server's version."),
        row("Server", value(server.name ?? "Aurelia")),
        row("Address", value(location.origin)),
        row("Live Conversion", value(server.capabilities?.includes("live-conversion-v1") ? "Available" : "Not available"),
          "Lets this browser play MKV and other files the server converts while they play.")),
      section("Profile", "lock", null,
        h("div", { class: "settings-profile" }, app.profilePicture(profile.id, profile.username, "medium settings-avatar"),
          h("div", {}, h("div", { class: "settings-profile-name" }, profile.username), h("div", { class: "muted small" }, roleTitle(profile.role)))),
        h("div", { class: "button-row" },
          h("button", { class: "secondary-button", onclick: () => app.switchProfile() }, "Switch Profile"),
          h("button", { class: "secondary-button danger", onclick: () => app.confirmSignOut() }, "Sign Out of This Browser"))),
      section("Interface", "gear", null,
        row("Appearance", value("Dark Cinema")),
        row("Reduced Motion", value("Follows System Settings")),
        row("Reduced Transparency", value("Follows System Settings"))));
  }

  // MARK: Playback

  function playbackPage() {
    let preferences = loadPreferences();
    const save = (change) => {
      preferences = savePreferences({ ...preferences, ...change });
      app.toast("Saved for this browser.");
    };
    const volumeLabel = h("span", { class: "settings-value narrow" }, `${Math.round(preferences.defaultVolume * 100)}%`);
    const volume = h("input", { class: "volume settings-slider", type: "range", min: "0", max: "1", step: "0.05", value: String(preferences.defaultVolume), "aria-label": "Default Volume" });
    volume.style.setProperty("--fill", `${preferences.defaultVolume * 100}%`);
    volume.addEventListener("input", () => {
      volumeLabel.textContent = `${Math.round(volume.value * 100)}%`;
      volume.style.setProperty("--fill", `${volume.value * 100}%`);
    });
    volume.addEventListener("change", () => save({ defaultVolume: Number(volume.value) }));
    const seek = h("span", { class: "settings-value narrow" }, `${preferences.seekInterval} seconds`);
    const step = (delta) => {
      const next = Math.min(60, Math.max(5, preferences.seekInterval + delta));
      save({ seekInterval: next });
      seek.textContent = `${next} seconds`;
    };
    return h("div", { class: "settings-stack" },
      section("Playback", "play", "Choose how Aurelia starts, controls and finishes playback in this browser.",
        row("Automatic Resume", toggle(preferences.automaticResume, (on) => save({ automaticResume: on }), "Automatic Resume")),
        row("Automatically Play Next Episode", toggle(preferences.automaticallyPlayNextEpisode, (on) => save({ automaticallyPlayNextEpisode: on }), "Automatically Play Next Episode")),
        row("Keep the Screen On During Playback", toggle(preferences.keepScreenOn, (on) => save({ keepScreenOn: on }), "Keep the Screen On During Playback")),
        row("Night Mode", toggle(preferences.nightMode, (on) => save({ nightMode: on }), "Night Mode"), "Softens loud scenes and makes quiet dialogue easier to hear."),
        h("div", { class: "settings-divider" }),
        row("Default Playback Rate", select(PLAYBACK_RATES.map((rate) => [rate, rate === 1 ? "Standard" : rateLabel(rate)]), preferences.defaultPlaybackRate,
          (rate) => save({ defaultPlaybackRate: Number(rate) }), "Default Playback Rate")),
        row("Default Volume", h("div", { class: "inline-control" }, volume, volumeLabel)),
        row("Controls Auto-Hide Delay", select([2, 3, 5, 8].map((seconds) => [seconds, `${seconds} seconds`]), preferences.controlsAutoHideDelay,
          (seconds) => save({ controlsAutoHideDelay: Number(seconds) }), "Controls Auto-Hide Delay")),
        row("Seek Interval", h("div", { class: "inline-control" },
          h("button", { class: "stepper", "aria-label": "Shorter", onclick: () => step(-5) }, "−"), seek,
          h("button", { class: "stepper", "aria-label": "Longer", onclick: () => step(5) }, "+"))),
        h("div", { class: "settings-divider" }),
        h("div", { class: "button-row" }, h("button", {
          class: "secondary-button",
          onclick: () => {
            savePreferences({ ...PLAYBACK_DEFAULTS });
            app.navigate({ name: "settings", page: "playback" }, { replace: true });
          },
        }, "Restore Playback Defaults"))));
  }

  // MARK: Server

  async function serverPage() {
    let status;
    try {
      status = await api.serverStatus();
    } catch (error) {
      if (error instanceof ApiError && (error.code === "management_locked" || error.status === 403)) return unlockPage(error.code === "management_locked");
      throw error;
    }
    const [updates, libraries, jobs, users, devices, power, backups] = await Promise.all([
      api.serverUpdates().catch(() => null),
      api.libraries().catch(() => []),
      api.metadataJobs().catch(() => []),
      api.serverUsers().catch(() => []),
      api.devices().catch(() => []),
      api.serverPower().catch(() => null),
      api.serverBackups().catch(() => []),
    ]);
    const refresh = () => app.navigate({ name: "settings", page: "server" }, { replace: true });
    const act = async (button, work, done) => {
      button.disabled = true;
      try {
        await work();
        if (done) app.toast(done);
        refresh();
      } catch (error) {
        button.disabled = false;
        if (!app.handleError(error)) app.toast(error.message);
      }
    };
    const button = (label, work, done, kind = "secondary-button") => {
      const element = h("button", { class: kind });
      element.textContent = label;
      element.addEventListener("click", () => act(element, work, done));
      return element;
    };

    return h("div", { class: "settings-stack" },
      section("Your Server", "library", null,
        row("Name", value(state.server?.name ?? "Aurelia")),
        row("Status", value(status.readiness?.state === "ready" || status.state === "ok" ? "Running" : capitalize(status.readiness?.state ?? status.state))),
        row("Version", value(status.version)),
        row("Running For", value(duration(status.uptimeSeconds))),
        row("Playing Now", value(`${status.activeStreams} stream${status.activeStreams === 1 ? "" : "s"}`)),
        row("Free Disk Space", value(status.freeDiskBytes != null ? bytes(status.freeDiskBytes) : "—")),
        h("div", { class: "button-row" }, button("Lock Server Management", () => api.lockManagement(), "Server management is locked."))),

      updates?.available ? section("Updates", "power", null,
        row("Installed", value(updates.installed)),
        row("Newest", value(updates.newest ?? (updates.checkedAt ? "Up to date" : "Not checked yet"))),
        updates.message ? h("p", { class: "muted small" }, updates.message) : null,
        h("div", { class: "button-row" },
          button("Check for Updates", () => api.checkForUpdates(), "Checking for updates…"),
          updates.updateAvailable ? button(`Install ${updates.newest}`, () => api.approved("/api/v1/server/updates/install"), "The server installs the update and restarts.", "primary-button") : null)) : null,

      section("Storage Locations", "library", "Aurelia only reads your media; scans never change files.",
        libraries.length ? libraries.map((library) => h("div", { class: "settings-card" },
          h("div", { class: "settings-card-main" },
            h("div", { class: "settings-card-title" }, library.name),
            h("div", { class: "muted small mono" }, library.path),
            h("div", { class: "muted small" }, [
              library.availability === "available" ? "Connected" : "Offline",
              library.lastScanCompletedAt ? `last scanned ${new Date(library.lastScanCompletedAt).toLocaleString()}` : "not scanned yet",
            ].join(" · "))),
          h("div", { class: "settings-card-actions" },
            h("label", { class: "inline-control small" }, toggle(library.monitoringEnabled, async (on) => {
              try {
                await api.setLibraryMonitoring(library.id, on);
              } catch (error) {
                if (!app.handleError(error)) app.toast(error.message);
              }
            }, `Watch ${library.name} for changes`), "Watch for Changes"),
            button("Scan Now", () => api.scanLibrary(library.id), `Scanning ${library.name}…`)))) : h("p", { class: "muted" }, "No storage locations yet. Add one in Aurelia on the Mac."),
        libraries.length > 1 ? h("div", { class: "button-row" }, button("Scan All", () => api.scanAllLibraries(), "Scanning all storage locations…")) : null),

      section("Movie Info", "star", "Titles, artwork and episode details from The Movie Database.",
        jobs.slice(0, 3).map((job) => row(`${capitalize(job.mode)} · ${new Date(job.createdAt).toLocaleString()}`,
          value(`${capitalize(job.state)} · ${job.itemsProcessed}/${job.itemsTotal}${job.itemsNeedingReview ? ` · ${job.itemsNeedingReview} to review` : ""}`))),
        h("div", { class: "button-row" },
          button("Find Missing Info", () => api.startMetadataJob({ mode: "incremental" }), "Looking up missing movie info…"),
          state.profile.role === "owner" ? button("Refresh All Info", () => api.startMetadataJob({ mode: "fullRefresh" }), "Refreshing all movie info…") : null)),

      users.length ? section("Profiles", "lock", "Add or edit profiles in Aurelia on the Mac.",
        users.map((entry) => row(h("span", { class: "inline-control" }, app.profilePicture(entry.user.id, entry.user.username), entry.user.username),
          value(`${roleTitle(entry.user.role)}${entry.isEnabled ? "" : " · Disabled"}`)))) : null,

      section("Signed-In Devices", "lock", "Devices and browsers signed in to this account.",
        (devices ?? []).filter((device) => !device.revokedAt).map((device) => h("div", { class: "settings-card" },
          h("div", { class: "settings-card-main" },
            h("div", { class: "settings-card-title" }, device.deviceName, device.isCurrent ? h("span", { class: "tag" }, "This Browser") : null),
            h("div", { class: "muted small" }, `Last used ${new Date(device.lastSeenAt).toLocaleString()}`)),
          device.isCurrent ? null : h("div", { class: "settings-card-actions" },
            button("Sign Out", () => api.approved(`/api/v1/auth/sessions/${device.id}`, { method: "DELETE" }), `${device.deviceName} is signed out.`))))),

      power?.available ? powerSection(power, act) : null,

      section("Backups", "library", "The server backs up its database every day.",
        (backups ?? []).slice(0, 3).map((backup) => row(new Date(backup.createdAt).toLocaleString(), value(`${capitalize(backup.kind)} · ${bytes(backup.bytes)}`))),
        h("div", { class: "button-row" }, button("Back Up Now", () => api.approved("/api/v1/server/backups/database"), "Backup created."))));
  }

  function powerSection(power, act) {
    const mode = select([["off", "Keep Running"], ["stop", "Stop Aurelia Server"], ["sleep", "Sleep the Computer"]], power.mode, () => {}, "When Unused");
    const choices = [...new Set([5, 10, 15, 30, 60, 120, power.idleMinutes])].sort((a, b) => a - b);
    const minutes = select(choices.map((value) => [value, `${value} minutes`]), power.idleMinutes, () => {}, "After");
    const save = h("button", { class: "secondary-button" }, "Save");
    save.addEventListener("click", () => act(save, () => api.saveServerPower({
      mode: mode.value, idleMinutes: Number(minutes.value), awakeFrom: power.awakeFrom, awakeUntil: power.awakeUntil,
    }), "Power settings saved."));
    return section("Power", "power", "What the server computer does when nobody uses it. Aurelia on a Mac wakes it with Wake-on-LAN.",
      row("When Unused", mode),
      row("After", minutes),
      h("div", { class: "button-row" }, save));
  }

  function unlockPage(locked) {
    if (!locked) {
      return h("div", { class: "settings-stack" }, section("Server", "lock", "Only the server's owner and administrators manage it."));
    }
    const password = h("input", { class: "text-field", type: "password", autocomplete: "current-password", placeholder: "Server Password", "aria-label": "Server Password" });
    const message = h("p", { class: "error-text", role: "alert" });
    const submit = h("button", { class: "primary-button", type: "submit" }, "Unlock");
    const form = h("form", { class: "unlock-form" }, password, submit);
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (!password.value) return;
      submit.disabled = true;
      try {
        await api.unlockManagement(password.value);
        password.value = "";
        app.navigate({ name: "settings", page: "server" }, { replace: true });
      } catch (error) {
        submit.disabled = false;
        password.value = "";
        message.textContent = error instanceof ApiError && error.status === 401 ? "The Server Password is incorrect." : error.message;
        password.focus();
      }
    });
    setTimeout(() => password.focus(), 0);
    return h("div", { class: "settings-stack" },
      section("Unlock Server Management", "lock", "Enter the Server Password to manage this server for ten minutes, as in Aurelia on the Mac. The browser doesn't keep it.",
        form, message));
  }

  return { settingsScreen };
}

function roleTitle(role) {
  return { owner: "Owner", admin: "Administrator", user: "Profile" }[role] ?? "Profile";
}

function capitalize(text) {
  const value = String(text ?? "");
  return value ? value[0].toUpperCase() + value.slice(1).replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase() : "—";
}

function duration(seconds) {
  const total = Math.max(0, Math.floor(seconds ?? 0));
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (days) return `${days} day${days === 1 ? "" : "s"}, ${hours} h`;
  if (hours) return `${hours} h ${minutes} min`;
  return `${minutes} min`;
}

function bytes(value) {
  const units = ["bytes", "KB", "MB", "GB", "TB"];
  let size = Number(value) || 0;
  let unit = 0;
  while (size >= 1000 && unit < units.length - 1) {
    size /= 1000;
    unit += 1;
  }
  return `${size >= 10 || unit === 0 ? Math.round(size) : size.toFixed(1)} ${units[unit]}`;
}
