// Settings, with the Mac app's pages: General (this browser and the profile), Playback (this
// browser's player) and Server (for owners and administrators). Server management is unlocked
// with the Server Password for ten minutes, as on the Mac; the browser never keeps the password.
// Changes the server guards ask it for a one-time approval of exactly that change.

import { h, icon, clear } from "./dom.js";
import { ApiError } from "./api.js";
import { PLAYBACK_DEFAULTS, PLAYBACK_RATES, loadManagementSections, managementPermissions, rateLabel, scrubPreviewUsageText } from "./logic.js";
import { loadPreferences, savePreferences } from "./player.js";
import { createManagementEditors } from "./settings-editors.js";
import { createServerUpdates } from "./server-updates.js";

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
  const editors = createManagementEditors({ ...app, onSaved: () => app.navigate(state.route, { replace: true }) });
  let updatesView;
  let serverRead = new AbortController();
  function closeUpdates() {
    updatesView?.close();
    updatesView = null;
    serverRead.abort();
    serverRead = new AbortController();
  }

  async function settingsScreen(route) {
    closeUpdates();
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
    const permissions = managementPermissions(state.profile);
    const profileID = state.profile.id;
    const signal = serverRead.signal;
    let sections;
    try {
      sections = await loadManagementSections(api, state.profile, { signal });
    } catch (error) {
      if (signal.aborted || state.profile?.id !== profileID) throw new DOMException("Cancelled", "AbortError");
      if (error instanceof ApiError && (error.code === "management_locked" || error.status === 403)) return unlockPage(error.code === "management_locked");
      throw error;
    }
    if (signal.aborted || state.profile?.id !== profileID) throw new DOMException("Cancelled", "AbortError");
    const { status, health, updates, libraries, jobs, users, devices, power, scrubPreviews, backups, issues } = sections;
    const refresh = () => app.navigate({ name: "settings", page: "server" }, { replace: true });
    const act = async (button, work, done) => {
      button.disabled = true;
      try {
        await work();
        if (profileID !== state.profile?.id || !button.isConnected) return;
        if (done) app.toast(done);
        refresh();
      } catch (error) {
        if (profileID !== state.profile?.id || !button.isConnected) return;
        button.disabled = false;
        if (error.code === "management_locked") return refresh();
        if (!app.handleError(error)) app.toast(error.message);
      }
    };
    const button = (label, work, done, kind = "secondary-button") => {
      const element = h("button", { class: kind });
      element.textContent = label;
      element.addEventListener("click", () => act(element, work, done));
      return element;
    };
    const openButton = (label, action, kind = "secondary-button") => h("button", { type: "button", class: kind, onclick: action }, label);
    if (updates?.available) updatesView = createServerUpdates({
      api, initial: updates,
      isCurrent: () => !signal.aborted && state.profile?.id === profileID,
      onLocked: refresh,
      onSessionEnded: app.handleError,
    });

    return h("div", { class: "settings-stack" },
      section("Your Server", "library", permissions.owner ? null : "Server management is unlocked. Administrators manage their allowed content.",
        row("Name", value(state.server?.name ?? "Aurelia")),
        status ? [row("Status", value(status.readiness?.state === "ready" || status.state === "ok" ? "Running" : capitalize(status.readiness?.state ?? status.state))),
          row("Version", value(status.version)), row("Running For", value(duration(status.uptimeSeconds))),
          row("Playing Now", value(`${status.activeStreams} stream${status.activeStreams === 1 ? "" : "s"}`)),
          row("Free Disk Space", value(status.freeDiskBytes != null ? bytes(status.freeDiskBytes) : "—"))] : row("Version", value(state.server?.version)),
        h("div", { class: "button-row" }, button("Lock Server Management", () => api.lockManagement(), "Server management is locked."))),
      issues.length ? h("p", { class: "error-text", role: "status" }, issues.map((issue) => `${capitalize(issue.section)}: ${issue.message}`).join(" ")) : null,

      health ? section("Server Health", "library", "Diagnostic metrics for server operation, storage, background jobs, and recent issues.",
        row("Uptime", value(duration(health.uptimeSeconds))),
        row("Storage", value([
          health.freeDiskBytes != null ? `${bytes(health.freeDiskBytes)} free` : null,
          `Database ${bytes(health.databaseBytes)}`,
        ].filter(Boolean).join(" · "))),
        row("Scrub Previews", value(health.scrubPreviewTitleCount > 0
          ? `${health.scrubPreviewTitleCount} title${health.scrubPreviewTitleCount === 1 ? "" : "s"} (${bytes(health.scrubPreviewBytes)})${health.scrubPreviewPendingCount > 0 ? ` · ${health.scrubPreviewPendingCount} pending` : ""}`
          : "None prepared")),
        row("Streaming & Conversion", value([
          `${health.activeStreams} stream${health.activeStreams === 1 ? "" : "s"}`,
          `${health.activeLiveConversions} live conversion${health.activeLiveConversions === 1 ? "" : "s"}`,
        ].join(" · "))),
        row("Library Scan", value(health.lastScan
          ? `${capitalize(health.lastScan.state)}${health.lastScan.completedAt ? ` · ${new Date(health.lastScan.completedAt).toLocaleTimeString()}` : " (running)"} (${health.lastScan.addedFiles} added, ${health.lastScan.missingFiles} missing)`
          : "No scans recorded")),
        row("Offline Titles", value(health.offlineMediaCount > 0 ? `${health.offlineMediaCount} title${health.offlineMediaCount === 1 ? "" : "s"} offline` : "All titles available")),
        row("Background Jobs", value([
          health.backgroundJobs.activeScans > 0 ? `${health.backgroundJobs.activeScans} scan active` : null,
          health.backgroundJobs.activeMetadataJobs > 0 ? `${health.backgroundJobs.activeMetadataJobs} metadata job active` : null,
          health.backgroundJobs.activeScrubPreviewJobs > 0 ? `${health.backgroundJobs.activeScrubPreviewJobs} preview task active` : null,
        ].filter(Boolean).join(" · ") || "Idle")),
        row("Recent Warnings & Errors", value(health.recentIssues.length > 0
          ? `${health.recentIssues.length} event${health.recentIssues.length === 1 ? "" : "s"}`
          : "No warnings or errors")),
        health.recentIssues.length ? h("div", { class: "settings-card-list" },
          health.recentIssues.slice(0, 10).map((issue) => h("div", { class: "settings-card small" },
            h("div", { class: "settings-card-main" },
              h("div", { class: issue.severity === "error" ? "error-text" : "muted" }, issue.code),
              h("div", { class: "muted small" }, new Date(issue.at).toLocaleString()))))) : null) : null,

      updatesView?.element ?? null,

      permissions.storage ? section("Storage Locations", "library", "Aurelia only reads your media; scans never change files.",
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
            button("Scan Now", () => api.scanLibrary(library.id), `Scanning ${library.name}…`),
            permissions.owner ? openButton("Remove…", () => editors.removeStorage(library), "secondary-button danger") : null))) : h("p", { class: "muted" }, "No storage locations yet."),
        h("div", { class: "button-row" }, permissions.owner ? openButton("Add Storage Location…", () => editors.addStorage()) : null,
          libraries.length > 1 ? button("Scan All", () => api.scanAllLibraries(), "Scanning all storage locations…") : null))
        : section("Storage Locations", "library", "Storage management requires full library access. This administrator profile is limited to selected titles."),

      section("Movie Info", "star", "Titles, artwork and episode details from The Movie Database.",
        jobs.slice(0, 3).map((job) => row(`${capitalize(job.mode)} · ${new Date(job.createdAt).toLocaleString()}`,
          value(`${capitalize(job.state)} · ${job.itemsProcessed}/${job.itemsTotal}${job.itemsNeedingReview ? ` · ${job.itemsNeedingReview} to review` : ""}`))),
        h("div", { class: "button-row" },
          openButton("Edit Metadata…", () => editors.metadataPicker()),
          button("Find Missing Info", () => api.startMetadataJob({ mode: "incremental" }), "Looking up missing movie info…"),
          state.profile.role === "owner" ? button("Refresh All Info", () => api.startMetadataJob({ mode: "fullRefresh" }), "Refreshing all movie info…") : null)),

      permissions.owner ? section("Profiles", "lock", "Choose who can watch and what they can see.",
        users.map((entry) => row(h("span", { class: "inline-control" }, app.profilePicture(entry.user.id, entry.user.username), entry.user.username),
          h("div", { class: "inline-control" }, value(`${roleTitle(entry.user.role)}${entry.isEnabled ? "" : " · Disabled"}`), openButton("Edit…", () => editors.editProfile(entry))))),
        h("div", { class: "button-row" }, openButton("Create Profile…", () => editors.editProfile()))) : null,

      section("Signed-In Devices", "lock", "Devices and browsers signed in to this account.",
        (devices ?? []).filter((device) => !device.revokedAt).map((device) => h("div", { class: "settings-card" },
          h("div", { class: "settings-card-main" },
            h("div", { class: "settings-card-title" }, device.deviceName, device.isCurrent ? h("span", { class: "tag" }, "This Browser") : null),
            h("div", { class: "muted small" }, `Last used ${new Date(device.lastSeenAt).toLocaleString()}`)),
          device.isCurrent || !permissions.owner ? null : h("div", { class: "settings-card-actions" },
            button("Sign Out", () => api.approved(`/api/v1/auth/sessions/${device.id}`, { method: "DELETE" }), `${device.deviceName} is signed out.`))))),

      power?.available ? powerSection(power, act) : null,

      permissions.owner && scrubPreviews ? scrubPreviewsSection(scrubPreviews, act) : null,

      permissions.owner ? section("Backups", "library", "The server backs up its database every day.",
        (backups ?? []).slice(0, 3).map((backup) => row(new Date(backup.createdAt).toLocaleString(), value(`${capitalize(backup.kind)} · ${bytes(backup.bytes)}`))),
        h("div", { class: "button-row" }, button("Back Up Now", () => api.approved("/api/v1/server/backups/database"), "Backup created."))) : null);
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

  function scrubPreviewsSection(scrubPreviews, act) {
    const mode = select([
      ["off", "Off"],
      ["onOpenOrPlay", "When a Title Is Opened or Played"],
      ["afterImport", "After Import"],
    ], scrubPreviews.mode ?? "off", () => {}, "Generate Previews");
    const intervalChoices = [...new Set([10, 15, 20, 30, 60, scrubPreviews.intervalSeconds ?? 15])].sort((a, b) => a - b);
    const interval = select(intervalChoices.map((seconds) => [seconds, `Every ${seconds} seconds`]), scrubPreviews.intervalSeconds ?? 15, () => {}, "Frame Interval");
    const capChoices = [...new Set([100, 250, 500, 1000, 2000, 5000, scrubPreviews.storageCapMegabytes ?? 500])].sort((a, b) => a - b);
    const cap = select(capChoices.map((mb) => [mb, mb >= 1000 && mb % 1000 === 0 ? `${mb / 1000} GB` : `${mb} MB`]), scrubPreviews.storageCapMegabytes ?? 500, () => {}, "Storage Limit");
    const save = h("button", { class: "secondary-button" }, "Save");
    save.addEventListener("click", () => act(save, () => api.saveServerScrubPreviews({
      mode: mode.value,
      intervalSeconds: Number(interval.value),
      storageCapMegabytes: Number(cap.value),
    }), "Scrub preview settings saved."));
    const clearButton = h("button", { class: "secondary-button danger", disabled: !scrubPreviews.storedTitleCount && !scrubPreviews.storedBytes }, "Delete All Previews");
    clearButton.addEventListener("click", () => act(clearButton, () => api.deleteServerScrubPreviews(), "All stored scrub previews deleted."));
    const activeTotal = Math.max(scrubPreviews.totalScheduledCount ?? 0, (scrubPreviews.completedCount ?? 0) + (scrubPreviews.pendingCount ?? 0) + (scrubPreviews.activeCount ?? 0));
    const progressText = (scrubPreviews.activeCount > 0 || scrubPreviews.pendingCount > 0)
      ? (scrubPreviews.pausedForPlayback ? `Paused while playback is active (${scrubPreviews.completedCount ?? 0} of ${activeTotal} prepared)` : `Preparing previews… (${scrubPreviews.completedCount ?? 0} of ${activeTotal})`)
      : null;
    return section("Scrub Previews", "play", "Small timeline preview images prepared by the server in its data folder so scrubbing shows a frame right away. Converted video is never stored.",
      row("Generate Previews", mode),
      row("Frame Interval", interval),
      row("Storage Limit", cap),
      row("Stored Previews", value(scrubPreviewUsageText(scrubPreviews)), progressText),
      h("div", { class: "button-row" }, save, clearButton));
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

  return { settingsScreen, editMetadata: editors.editMetadata, closeEditors: () => { editors.close(); closeUpdates(); } };
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
