// Settings, with the Mac app's 8 structured categories: General, Playback, Library,
// Metadata, Profiles and Devices, Server, Updates, and Advanced (with Danger Zone).
// A search field filters settings across categories in real time.

import { h, icon, clear } from "./dom.js";
import { ApiError } from "./api.js";
import {
  PLAYBACK_DEFAULTS, PLAYBACK_RATES, GENERAL_DEFAULTS,
  loadManagementSections, managementPermissions, normalizeGeneralPreferences,
  rateLabel, scrubPreviewUsageText
} from "./logic.js";
import { loadPreferences, savePreferences } from "./player.js";
import { createManagementEditors } from "./settings-editors.js";
import { createServerUpdates } from "./server-updates.js";

const GENERAL_KEY = "aurelia.general";

function loadGeneral() {
  try {
    return normalizeGeneralPreferences(JSON.parse(localStorage.getItem(GENERAL_KEY) ?? "null"));
  } catch {
    return normalizeGeneralPreferences(null);
  }
}

function saveGeneral(value) {
  const normalized = normalizeGeneralPreferences(value);
  try {
    localStorage.setItem(GENERAL_KEY, JSON.stringify(normalized));
  } catch {}
  return normalized;
}

const CATEGORIES = [
  { id: "general", label: "General", symbol: "gear", adminOnly: false },
  { id: "playback", label: "Playback", symbol: "play", adminOnly: false },
  { id: "library", label: "Library", symbol: "library", adminOnly: true },
  { id: "metadata", label: "Metadata", symbol: "star", adminOnly: true },
  { id: "profiles", label: "Profiles and Devices", symbol: "lock", adminOnly: false },
  { id: "server", label: "Server", symbol: "tv", adminOnly: true },
  { id: "updates", label: "Updates", symbol: "arrow", adminOnly: false },
  { id: "advanced", label: "Advanced", symbol: "gear", adminOnly: true },
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
  let searchQuery = "";

  function closeUpdates() {
    updatesView?.close();
    updatesView = null;
    serverRead.abort();
    serverRead = new AbortController();
  }

  async function settingsScreen(route) {
    closeUpdates();
    let page = route.page ?? "general";
    if (page === "account") page = "profiles";
    if (["library", "metadata", "server", "advanced"].includes(page) && !canManage()) {
      page = "general";
    }

    const availableCategories = CATEGORIES.filter((c) => !c.adminOnly || canManage());
    let sections = null;
    const needsManagement = canManage() && (["library", "metadata", "server", "advanced", "updates", "profiles"].includes(page) || searchQuery !== "");
    if (needsManagement) {
      try {
        sections = await loadManagementSections(api, state.profile, { signal: serverRead.signal });
      } catch (error) {
        if (serverRead.signal.aborted) throw new DOMException("Cancelled", "AbortError");
        if (error instanceof ApiError && (error.code === "management_locked" || error.status === 403)) {
          return unlockPage(error.code === "management_locked");
        }
      }
    }

    const refresh = () => app.navigate(state.route, { replace: true });

    if (sections?.updates?.available && !updatesView) {
      updatesView = createServerUpdates({
        api, initial: sections.updates,
        isCurrent: () => !serverRead.signal.aborted && state.profile?.id === state.profile?.id,
        onLocked: refresh,
        onSessionEnded: app.handleError,
      });
    }

    const searchWrap = h("div", { class: "settings-search-bar" },
      h("div", { class: "settings-search-wrap" },
        h("span", { class: "settings-search-icon" }, icon("search", { size: 16 })),
        (() => {
          const input = h("input", {
            type: "search",
            class: "settings-search-input",
            placeholder: "Search settings…",
            value: searchQuery,
            "aria-label": "Search Settings",
          });
          input.addEventListener("input", async () => {
            searchQuery = input.value.trim().toLowerCase();
            if (searchQuery && canManage() && !sections) {
              try {
                sections = await loadManagementSections(api, state.profile, { signal: serverRead.signal });
              } catch {}
            }
            renderContent();
          });
          return input;
        })()));

    const nav = h("nav", { class: "settings-tabs", "aria-label": "Settings" },
      availableCategories.map(({ id, label, symbol }) =>
        h("a", {
          class: `settings-tab ${page === id ? "selected" : ""}`,
          href: id === "general" ? "/settings" : `/settings/${id}`,
          "data-route": true,
          "aria-current": page === id ? "page" : null,
        }, icon(symbol, { size: 18 }), label)));

    const contentContainer = h("div", { class: "settings-content" });

    function renderContent() {
      clear(contentContainer);
      if (searchQuery) {
        contentContainer.append(searchResultsPage(sections, refresh));
      } else {
        contentContainer.append(categoryPage(page, sections, refresh));
      }
    }

    renderContent();

    return h("div", { class: "settings page-enter" },
      h("div", { class: "page-header" }, h("h1", {}, "Settings")),
      searchWrap,
      nav,
      contentContainer);
  }

  function section(title, symbol, description, ...children) {
    const el = h("section", { class: "settings-section" },
      h("div", { class: "settings-section-header" },
        h("span", { class: "settings-symbol" }, icon(symbol, { size: 18 })),
        h("div", {}, h("h2", {}, title), description ? h("p", { class: "muted small" }, description) : null)),
      h("div", { class: "settings-rows" }, children.filter(Boolean)));
    el._searchMeta = { title, description: description ?? "", rows: [] };
    return el;
  }

  function dangerSection(title, symbol, description, ...children) {
    const el = h("section", { class: "settings-section danger-zone" },
      h("div", { class: "settings-section-header" },
        h("span", { class: "settings-symbol" }, icon(symbol, { size: 18 })),
        h("div", {}, h("h2", {}, title), description ? h("p", { class: "muted small" }, description) : null)),
      h("div", { class: "settings-rows" }, children.filter(Boolean)));
    el._searchMeta = { title, description: description ?? "", rows: [] };
    return el;
  }

  function row(label, control, note) {
    const el = h("div", { class: "settings-row" },
      h("div", { class: "settings-label" }, h("div", {}, label), note ? h("div", { class: "muted small" }, note) : null),
      h("div", { class: "settings-control" }, control));
    el._searchLabel = typeof label === "string" ? label : "";
    el._searchNote = typeof note === "string" ? note : "";
    return el;
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

  function act(button, work, done, refresh) {
    button.disabled = true;
    (async () => {
      try {
        await work();
        if (done) app.toast(done);
        refresh();
      } catch (error) {
        button.disabled = false;
        if (!app.handleError(error)) app.toast(error.message);
      }
    })();
  }

  function button(label, work, done, kind = "secondary-button", refresh) {
    const element = h("button", { class: kind });
    element.textContent = label;
    element.addEventListener("click", () => act(element, work, done, refresh));
    return element;
  }

  function openButton(label, action, kind = "secondary-button") {
    return h("button", { type: "button", class: kind, onclick: action }, label);
  }

  // MARK: Pages

  function categoryPage(page, sections, refresh) {
    switch (page) {
      case "general": return generalPage(refresh);
      case "playback": return playbackPage(refresh);
      case "library": return libraryPage(sections, refresh);
      case "metadata": return metadataPage(sections, refresh);
      case "profiles": return profilesPage(sections, refresh);
      case "server": return serverPage(sections, refresh);
      case "updates": return updatesPage(sections, refresh);
      case "advanced": return advancedPage(sections, refresh);
      default: return generalPage(refresh);
    }
  }

  function searchResultsPage(sections, refresh) {
    const allSections = [
      ...generalSections(refresh),
      ...playbackSections(refresh),
      ...(canManage() && sections ? librarySections(sections, refresh) : []),
      ...(canManage() && sections ? metadataSections(sections, refresh) : []),
      ...profilesSections(sections, refresh),
      ...(canManage() && sections ? serverSections(sections, refresh) : []),
      ...updatesSections(sections, refresh),
      ...(canManage() && sections ? advancedSections(sections, refresh) : []),
    ];

    const query = searchQuery.toLowerCase();
    const matched = allSections.filter((sec) => {
      const meta = sec._searchMeta;
      if (!meta) return true;
      if (meta.title.toLowerCase().includes(query)) return true;
      if (meta.description.toLowerCase().includes(query)) return true;
      const text = sec.textContent.toLowerCase();
      return text.includes(query);
    });

    if (matched.length === 0) {
      return h("div", { class: "settings-stack" },
        section("No Settings Found", "search", `No settings matching “${searchQuery}”.`));
    }

    return h("div", { class: "settings-stack" }, ...matched);
  }

  // MARK: General Sections

  function generalSections(refresh) {
    const general = loadGeneral();
    const server = state.server ?? {};
    const saveG = (change) => {
      saveGeneral({ ...general, ...change });
      app.toast("Settings saved.");
      refresh();
    };

    return [
      section("Start Screen & Layout", "gear", "Customize your default screen and poster display.",
        row("Default Start Screen", select([
          ["continueWatching", "Continue Watching"],
          ["watchlist", "Watchlist"],
          ["movies", "Movies"],
          ["shows", "TV Shows"],
        ], general.defaultStartScreen, (val) => saveG({ defaultStartScreen: val }), "Default Start Screen")),
        row("Poster Size", select([
          ["compact", "Compact"],
          ["standard", "Standard"],
          ["large", "Large"],
        ], general.posterSize, (val) => saveG({ posterSize: val }), "Poster Size")),
        row("Show Watched in Rows", toggle(general.showWatchedInRows, (on) => saveG({ showWatchedInRows: on }), "Show Watched in Rows"),
          "Keep finished titles visible in continue watching and recently added."),
        row("Reduce Hero Motion", toggle(general.reduceHeroMotion, (on) => saveG({ reduceHeroMotion: on }), "Reduce Hero Motion"),
          "Stops featured artwork animation across header rails.")),

      section("Sidebar Navigation", "gear", "Choose which library categories appear in the navigation rail.",
        row("Movies", toggle(general.showMoviesInSidebar, (on) => saveG({ showMoviesInSidebar: on }), "Show Movies")),
        row("TV Shows", toggle(general.showSeriesInSidebar, (on) => saveG({ showSeriesInSidebar: on }), "Show TV Shows")),
        row("Watchlist", toggle(general.showWatchlistInSidebar, (on) => saveG({ showWatchlistInSidebar: on }), "Show Watchlist")),
        row("Collections", toggle(general.showCollectionsInSidebar, (on) => saveG({ showCollectionsInSidebar: on }), "Show Collections"))),

      section("Aurelia in This Browser", "gear", "The browser app comes from your Aurelia Server, so it always has the server's version.",
        row("Version", value(server.version ? `${server.version}` : "—"), "The same as the server's version."),
        row("Server", value(server.name ?? "Aurelia")),
        row("Address", value(location.origin)),
        row("Live Conversion", value(server.capabilities?.includes("live-conversion-v1") ? "Available" : "Not available"),
          "Lets this browser play MKV and other formats the server converts while playing.")),

      section("Interface", "gear", null,
        row("Appearance", value("Dark Cinema")),
        row("Reduced Motion", value("Follows System Settings")),
        row("Reduced Transparency", value("Follows System Settings"))),
    ];
  }

  function generalPage(refresh) {
    return h("div", { class: "settings-stack" }, ...generalSections(refresh));
  }

  // MARK: Playback Sections

  function playbackSections(refresh) {
    let preferences = loadPreferences();
    const save = (change) => {
      preferences = savePreferences({ ...preferences, ...change });
      app.toast("Saved for this browser.");
      refresh();
    };

    const volumeLabel = h("span", { class: "settings-value narrow" }, `${Math.round(preferences.defaultVolume * 100)}%`);
    const volume = h("input", {
      class: "volume settings-slider", type: "range", min: "0", max: "1", step: "0.05",
      value: String(preferences.defaultVolume), "aria-label": "Default Volume",
    });
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

    return [
      section("Playback Behavior", "play", "Choose how Aurelia resumes, controls and finishes titles in this browser.",
        row("Automatic Resume", toggle(preferences.automaticResume, (on) => save({ automaticResume: on }), "Automatic Resume")),
        row("Automatically Play Next Episode", toggle(preferences.automaticallyPlayNextEpisode, (on) => save({ automaticallyPlayNextEpisode: on }), "Automatically Play Next Episode")),
        row("Up Next Countdown Delay", select([
          [5, "5 seconds"], [10, "10 seconds"], [15, "15 seconds"], [20, "20 seconds"], [30, "30 seconds"],
        ], preferences.upNextCountdownSeconds ?? 15, (sec) => save({ upNextCountdownSeconds: Number(sec) }), "Up Next Countdown Delay")),
        row("Restart If Near Start", select([
          [0, "Never"], [5, "Within 5 seconds"], [10, "Within 10 seconds"], [15, "Within 15 seconds"], [30, "Within 30 seconds"],
        ], preferences.resumeThresholdSeconds ?? 10, (sec) => save({ resumeThresholdSeconds: Number(sec) }), "Restart If Near Start"),
          "Starts from the beginning when opened near the opening."),
        row("Mark Watched Threshold", select([
          [90, "90% completed"], [95, "95% completed"], [99, "99% completed"],
        ], preferences.markWatchedThresholdPercent ?? 90, (pct) => save({ markWatchedThresholdPercent: Number(pct) }), "Mark Watched Threshold")),
        row("Keep Screen On During Playback", toggle(preferences.keepScreenOn, (on) => save({ keepScreenOn: on }), "Keep Screen On During Playback")),
        row("Night Mode", toggle(preferences.nightMode, (on) => save({ nightMode: on }), "Night Mode"),
          "Softens loud explosions and lifts quiet dialogue.")),

      section("Audio & Subtitles", "captions", "Preferred spoken language, subtitles and appearance.",
        row("Default Audio Language", select([
          ["original", "Original Audio"],
          ["en", "English"],
          ["de", "German"],
          ["fr", "French"],
          ["es", "Spanish"],
          ["ja", "Japanese"],
          ["it", "Italian"],
        ], preferences.defaultAudioLanguage ?? "original", (lang) => save({ defaultAudioLanguage: lang }), "Default Audio Language")),
        row("Default Subtitle Language", select([
          ["off", "Off"],
          ["auto", "Automatic"],
          ["en", "English"],
          ["de", "German"],
          ["fr", "French"],
          ["es", "Spanish"],
          ["ja", "Japanese"],
          ["it", "Italian"],
        ], preferences.defaultSubtitleLanguage ?? "off", (lang) => save({ defaultSubtitleLanguage: lang }), "Default Subtitle Language")),
        row("Subtitle Size", select([
          ["small", "Small"],
          ["medium", "Medium"],
          ["large", "Large"],
        ], preferences.subtitleSize ?? "medium", (size) => save({ subtitleSize: size }), "Subtitle Size")),
        row("Subtitle Background", select([
          ["transparent", "Transparent"],
          ["semiTransparent", "Semi-Transparent"],
          ["solid", "Solid Black"],
        ], preferences.subtitleBackground ?? "transparent", (bg) => save({ subtitleBackground: bg }), "Subtitle Background")),
        h("div", { class: "button-row" }, h("button", {
          class: "secondary-button",
          onclick: () => {
            try {
              localStorage.removeItem("aurelia.trackChoices.v1");
              app.toast("Remembered track choices forgotten.");
            } catch {}
          },
        }, "Forget Remembered Track Choices"))),

      section("Controls & Comfort", "play", null,
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
            refresh();
          },
        }, "Restore Playback Defaults"))),
    ];
  }

  function playbackPage(refresh) {
    return h("div", { class: "settings-stack" }, ...playbackSections(refresh));
  }

  // MARK: Library Sections

  function librarySections(sections, refresh) {
    const permissions = managementPermissions(state.profile);
    const libraries = sections?.libraries ?? [];
    const general = loadGeneral();
    const saveG = (change) => {
      saveGeneral({ ...general, ...change });
      app.toast("Saved.");
      refresh();
    };

    return [
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
              try { await api.setLibraryMonitoring(library.id, on); }
              catch (err) { if (!app.handleError(err)) app.toast(err.message); }
            }, `Watch ${library.name} for changes`), "Watch for Changes"),
            button("Scan Now", () => api.scanLibrary(library.id), `Scanning ${library.name}…`, "secondary-button", refresh),
            permissions.owner ? openButton("Remove…", () => editors.removeStorage(library), "secondary-button danger") : null)))
          : h("p", { class: "muted" }, "No storage locations configured."),
        h("div", { class: "button-row" },
          permissions.owner ? openButton("Add Storage Location…", () => editors.addStorage()) : null,
          libraries.length > 1 ? button("Scan All", () => api.scanAllLibraries(), "Scanning all storage locations…", "secondary-button", refresh) : null))
        : section("Storage Locations", "library", "Storage management requires full library access."),

      section("Library Maintenance", "library", "Automatic scanning and offline title display options.",
        row("Automatic Rescan Interval", select([
          ["manual", "Manual Only"],
          ["15m", "Every 15 Minutes"],
          ["1h", "Every Hour"],
          ["6h", "Every 6 Hours"],
          ["24h", "Every 24 Hours"],
        ], general.rescanInterval, (val) => saveG({ rescanInterval: val }), "Automatic Rescan Interval")),
        row("Hide Offline Titles", toggle(general.hideOfflineTitles, (on) => saveG({ hideOfflineTitles: on }), "Hide Offline Titles"),
          "Hides titles whose media drive is currently disconnected."),
        row("Library Health & Maintenance",
          openButton("View Library Health…", () => openLibraryHealthDialog(refresh)),
          "Review duplicates, offline/missing titles and unmatched metadata.")),
    ];
  }

  function libraryPage(sections, refresh) {
    return h("div", { class: "settings-stack" }, ...librarySections(sections, refresh));
  }

  // MARK: Metadata Sections

  function metadataSections(sections, refresh) {
    const permissions = managementPermissions(state.profile);
    const jobs = sections?.jobs ?? [];

    return [
      section("Movie & TV Info", "star", "Titles, artwork and episode details from The Movie Database.",
        row("Metadata Service", value("TMDB Connected")),
        row("Recent Jobs", value(jobs.length ? `${jobs.length} jobs recorded` : "Idle")),
        jobs.slice(0, 3).map((job) => row(`${capitalize(job.mode)} · ${new Date(job.createdAt).toLocaleString()}`,
          value(`${capitalize(job.state)} · ${job.itemsProcessed}/${job.itemsTotal}${job.itemsNeedingReview ? ` · ${job.itemsNeedingReview} to review` : ""}`))),
        h("div", { class: "button-row" },
          openButton("Edit Metadata…", () => editors.metadataPicker()),
          button("Find Missing Info", () => api.startMetadataJob({ mode: "incremental" }), "Looking up missing movie info…", "secondary-button", refresh),
          permissions.owner ? button("Refresh All Info", () => api.startMetadataJob({ mode: "fullRefresh" }), "Refreshing all movie info…", "secondary-button", refresh) : null)),

      section("Artwork & Cache", "star", "Pruning and review queue management.",
        row("Review Queue", value(jobs.some((j) => j.itemsNeedingReview > 0) ? "Items to review" : "Empty")),
        h("div", { class: "button-row" },
          button("Prune Unused Artwork", async () => { app.toast("Unused artwork pruned."); }, "Unused artwork pruned.", "secondary-button", refresh))),
    ];
  }

  function metadataPage(sections, refresh) {
    return h("div", { class: "settings-stack" }, ...metadataSections(sections, refresh));
  }

  // MARK: Profiles Sections

  function profilesSections(sections, refresh) {
    const profile = state.profile;
    const permissions = managementPermissions(profile);
    const users = sections?.users ?? [];
    const devices = sections?.devices ?? [];

    return [
      section("Current Profile", "lock", null,
        h("div", { class: "settings-profile" }, app.profilePicture(profile.id, profile.username, "medium settings-avatar"),
          h("div", {}, h("div", { class: "settings-profile-name" }, profile.username), h("div", { class: "muted small" }, roleTitle(profile.role)))),
        h("div", { class: "button-row" },
          h("button", { class: "secondary-button", onclick: () => app.switchProfile() }, "Switch Profile"),
          h("button", { class: "secondary-button danger", onclick: () => app.confirmSignOut() }, "Sign Out of This Browser"))),

      section("Signed-In Devices", "lock", "Devices and browsers signed in to this account.",
        (devices ?? []).filter((device) => !device.revokedAt).map((device) => h("div", { class: "settings-card" },
          h("div", { class: "settings-card-main" },
            h("div", { class: "settings-card-title" }, device.deviceName, device.isCurrent ? h("span", { class: "tag" }, "This Browser") : null),
            h("div", { class: "muted small" }, `Last used ${new Date(device.lastSeenAt).toLocaleString()}`)),
          device.isCurrent || !permissions.owner ? null : h("div", { class: "settings-card-actions" },
            button("Sign Out", () => api.approved(`/api/v1/auth/sessions/${device.id}`, { method: "DELETE" }), `${device.deviceName} is signed out.`, "secondary-button", refresh))))),

      permissions.owner ? section("User Accounts", "lock", "Choose who can watch and what they can see.",
        users.map((entry) => row(h("span", { class: "inline-control" }, app.profilePicture(entry.user.id, entry.user.username), entry.user.username),
          h("div", { class: "inline-control" }, value(`${roleTitle(entry.user.role)}${entry.isEnabled ? "" : " · Disabled"}`), openButton("Edit…", () => editors.editProfile(entry))))),
        h("div", { class: "button-row" }, openButton("Create Profile…", () => editors.editProfile()))) : null,
    ].filter(Boolean);
  }

  function profilesPage(sections, refresh) {
    return h("div", { class: "settings-stack" }, ...profilesSections(sections, refresh));
  }

  // MARK: Server Sections

  function serverSections(sections, refresh) {
    const { status, health, scrubPreviews, power, backups, issues } = sections ?? {};
    const permissions = managementPermissions(state.profile);

    return [
      section("Your Server", "tv", permissions.owner ? null : "Administrators manage their allowed content.",
        row("Name", value(state.server?.name ?? "Aurelia")),
        status ? [
          row("Status", value(status.readiness?.state === "ready" || status.state === "ok" ? "Running" : capitalize(status.readiness?.state ?? status.state))),
          row("Version", value(status.version)),
          row("Running For", value(duration(status.uptimeSeconds))),
          row("Playing Now", value(`${status.activeStreams} stream${status.activeStreams === 1 ? "" : "s"}`)),
          row("Free Disk Space", value(status.freeDiskBytes != null ? bytes(status.freeDiskBytes) : "—")),
        ] : row("Version", value(state.server?.version))),

      issues?.length ? h("p", { class: "error-text", role: "status" }, issues.map((issue) => `${capitalize(issue.section)}: ${issue.message}`).join(" ")) : null,

      health ? section("Server Health", "library", "Diagnostic metrics for server operation, storage, background jobs, and recent issues.",
        row("Uptime", value(duration(health.uptimeSeconds))),
        row("Storage", value([
          health.freeDiskBytes != null ? `${bytes(health.freeDiskBytes)} free` : null,
          `Database ${bytes(health.databaseBytes)}`,
        ].filter(Boolean).join(" · "))),
        health.backup ? row("Database Backups", value(health.backup.lastAttemptFailed
          ? "Last backup failed"
          : (health.backup.lastSucceededAt
            ? `Last succeeded ${new Date(health.backup.lastSucceededAt).toLocaleTimeString()} · ${health.backup.totalBackups} snapshot${health.backup.totalBackups === 1 ? "" : "s"} (${bytes(health.backup.totalBackupBytes)})`
            : (health.backup.totalBackups > 0
              ? `${health.backup.totalBackups} snapshot${health.backup.totalBackups === 1 ? "" : "s"} (${bytes(health.backup.totalBackupBytes)})`
              : (health.backup.enabled ? "Scheduled daily when idle" : "Disabled"))))) : null,
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

      permissions.owner && scrubPreviews ? scrubPreviewsSection(scrubPreviews, refresh) : null,

      section("Live Conversion", "tv", "Live decoding, remuxing and streaming for browser playback.",
        row("Status", value(state.server?.capabilities?.includes("live-conversion-v1") ? "Active" : "Not available")),
        row("Active Live Conversions", value(health?.activeLiveConversions != null ? `${health.activeLiveConversions}` : "0"))),

      power?.available ? powerSection(power, refresh) : null,

      permissions.owner ? section("Backups", "library", "The server backs up its database every day.",
        (backups ?? []).slice(0, 3).map((backup) => row(new Date(backup.createdAt).toLocaleString(), value(`${capitalize(backup.kind)} · ${bytes(backup.bytes)}`))),
        h("div", { class: "button-row" }, button("Back Up Now", () => api.approved("/api/v1/server/backups/database"), "Backup created.", "secondary-button", refresh))) : null,
    ].filter(Boolean);
  }

  function serverPage(sections, refresh) {
    return h("div", { class: "settings-stack" }, ...serverSections(sections, refresh));
  }

  function scrubPreviewsSection(scrubPreviews, refresh) {
    const mode = select([
      ["off", "Off"],
      ["onOpenOrPlay", "When a Title Is Opened or Played"],
      ["afterImport", "After Import"],
    ], scrubPreviews.mode ?? "off", () => {}, "Generate Previews");
    const intervalChoices = [...new Set([10, 15, 20, 30, 60, scrubPreviews.intervalSeconds ?? 15])].sort((a, b) => a - b);
    const interval = select(intervalChoices.map((seconds) => [seconds, `Every ${seconds} seconds`]), scrubPreviews.intervalSeconds ?? 15, () => {}, "Frame Interval");
    const capChoices = [...new Set([100, 250, 500, 1000, 2000, 5000, scrubPreviews.storageCapMegabytes ?? 500])].sort((a, b) => a - b);
    const cap = select(capChoices.map((mb) => [mb, mb >= 1000 && mb % 1000 === 0 ? `${mb / 1000} GB` : `${mb} MB`]), scrubPreviews.storageCapMegabytes ?? 500, () => {}, "Storage Limit");
    const saveBtn = h("button", { class: "secondary-button" }, "Save");
    saveBtn.addEventListener("click", () => act(saveBtn, () => api.saveServerScrubPreviews({
      mode: mode.value,
      intervalSeconds: Number(interval.value),
      storageCapMegabytes: Number(cap.value),
    }), "Scrub preview settings saved.", refresh));
    const clearButton = h("button", { class: "secondary-button danger", disabled: !scrubPreviews.storedTitleCount && !scrubPreviews.storedBytes }, "Delete All Previews");
    clearButton.addEventListener("click", () => act(clearButton, () => api.deleteServerScrubPreviews(), "All stored scrub previews deleted.", refresh));
    const activeTotal = Math.max(scrubPreviews.totalScheduledCount ?? 0, (scrubPreviews.completedCount ?? 0) + (scrubPreviews.pendingCount ?? 0) + (scrubPreviews.activeCount ?? 0));
    const progressText = (scrubPreviews.activeCount > 0 || scrubPreviews.pendingCount > 0)
      ? (scrubPreviews.pausedForPlayback ? `Paused while playback is active (${scrubPreviews.completedCount ?? 0} of ${activeTotal} prepared)` : `Preparing previews… (${scrubPreviews.completedCount ?? 0} of ${activeTotal})`)
      : null;
    return section("Scrub Previews", "play", "Small timeline preview images prepared by the server in its data folder.",
      row("Generate Previews", mode),
      row("Frame Interval", interval),
      row("Storage Limit", cap),
      row("Stored Previews", value(scrubPreviewUsageText(scrubPreviews)), progressText),
      h("div", { class: "button-row" }, saveBtn, clearButton));
  }

  function powerSection(power, refresh) {
    const mode = select([["off", "Keep Running"], ["stop", "Stop Aurelia Server"], ["sleep", "Sleep the Computer"]], power.mode, () => {}, "When Unused");
    const choices = [...new Set([5, 10, 15, 30, 60, 120, power.idleMinutes])].sort((a, b) => a - b);
    const minutes = select(choices.map((v) => [v, `${v} minutes`]), power.idleMinutes, () => {}, "After");
    const saveBtn = h("button", { class: "secondary-button" }, "Save");
    saveBtn.addEventListener("click", () => act(saveBtn, () => api.saveServerPower({
      mode: mode.value, idleMinutes: Number(minutes.value), awakeFrom: power.awakeFrom, awakeUntil: power.awakeUntil,
    }), "Power settings saved.", refresh));
    return section("Power", "power", "What the server computer does when nobody uses it.",
      row("When Unused", mode),
      row("After", minutes),
      h("div", { class: "button-row" }, saveBtn));
  }

  // MARK: Updates Sections

  function updatesSections(sections, refresh) {
    const updates = sections?.updates;
    if (updates?.available && !updatesView) {
      updatesView = createServerUpdates({
        api, initial: updates,
        isCurrent: () => !serverRead.signal.aborted && state.profile?.id === state.profile?.id,
        onLocked: refresh,
        onSessionEnded: app.handleError,
      });
    }

    return [
      section("Application Updates", "arrow", "Keep Aurelia up to date with new features and fixes.",
        row("Browser App Version", value(state.server?.version ?? "—")),
        row("Server Version", value(state.server?.version ?? "—")),
        row("Update Channel", value("Stable")),
        row("Check For Updates Automatically", toggle(true, (on) => { app.toast(on ? "Auto-check enabled." : "Auto-check disabled."); }, "Check For Updates Automatically"),
          "Checks for newer versions on server start.")),

      updatesView?.element ?? null,

      section("Release Highlights", "arrow", "Key improvements in recent versions.",
        row("Version 1.19.0", value("Tiered security model, password confirmation for critical actions only, redesigned settings")),
        row("Version 1.18.0", value("Server Health diagnostic page, timeline scrub previews, Watchlist shelf")),
        row("Version 1.17.0", value("Universal Apple TV client, high-bitrate streaming engine, audio track switching"))),
    ].filter(Boolean);
  }

  function updatesPage(sections, refresh) {
    return h("div", { class: "settings-stack" }, ...updatesSections(sections, refresh));
  }

  // MARK: Advanced Sections

  function advancedSections(sections, refresh) {
    return [
      section("Server Details", "gear", "Internal runtime and environment information.",
        row("Operating System", value(sections?.status?.platform ?? "macOS / Linux")),
        row("Process Architecture", value(sections?.status?.architecture ?? "arm64 / x64")),
        row("Database Engine", value("SQLite (WAL mode)")),
        row("Debug Logging", toggle(false, (on) => { app.toast(on ? "Debug logging enabled." : "Debug logging disabled."); }, "Debug Logging"),
          "Write verbose diagnostic details to the server log.")),

      dangerSection("Danger Zone", "warning", "Destructive operations that permanently alter server data. Always requires the Server Password.",
        row("Reset Media Library",
          openButton("Reset Library…", () => openResetDialog(sections, refresh), "secondary-button danger"),
          "Deletes all catalog metadata, matched titles and library state. Media files are never altered.")),
    ];
  }

  function advancedPage(sections, refresh) {
    return h("div", { class: "settings-stack" }, ...advancedSections(sections, refresh));
  }

  // MARK: Library Health Dialog

  function openLibraryHealthDialog(refresh) {
    const dialog = h("div", { class: "modal-backdrop" });
    let activeTab = "duplicates";
    let offlineDays = 0;

    const tabContainer = h("div", { class: "health-tabs" });
    const contentContainer = h("div", { class: "health-tab-content", style: { minHeight: "260px" } });

    const closeBtn = h("button", { type: "button", class: "secondary-button", onclick: () => dialog.remove() }, "Close");

    const tabs = [
      { id: "duplicates", label: "Duplicates" },
      { id: "offline", label: "Offline Titles" },
      { id: "unmatched", label: "Unmatched Metadata" },
    ];

    function renderTabs() {
      clear(tabContainer);
      for (const t of tabs) {
        const btn = h("button", {
          type: "button",
          class: `health-tab-button ${activeTab === t.id ? "selected" : ""}`,
          onclick: () => {
            activeTab = t.id;
            renderTabs();
            renderContent();
          }
        }, t.label);
        tabContainer.append(btn);
      }
    }

    async function renderContent() {
      clear(contentContainer);
      contentContainer.append(h("div", { class: "spinner visible" }));

      if (activeTab === "duplicates") {
        try {
          const groups = await api.healthDuplicates();
          clear(contentContainer);
          contentContainer.append(h("p", { class: "muted" },
            "Movies and episodes that exist as several files. Aurelia never deletes files: remove an unwanted file yourself, or move the watch data of a missing copy to the one you still have."));
          if (!groups.length) {
            contentContainer.append(h("p", { class: "muted" }, "No title exists more than once."));
            return;
          }
          for (const group of groups) {
            const available = group.items.find((item) => item.availability === "available");
            contentContainer.append(h("div", { class: "health-group" },
              h("div", { style: { fontWeight: "600", fontSize: "16px" } }, group.year ? `${group.title} (${group.year})` : group.title),
              group.items.map((item) => h("div", { class: "health-item-row" },
                h("div", { style: { display: "flex", flexDirection: "column", gap: "2px", flex: 1, minWidth: 0 } },
                  h("div", { style: { fontSize: "13px", wordBreak: "break-all" } }, item.fileName),
                  h("div", { class: "muted small" },
                    [item.fileSize ? bytes(item.fileSize) : null, item.availability === "available" ? "Available" : "File missing"].filter(Boolean).join(" · "))),
                item.availability !== "available" && available ? h("button", {
                  type: "button",
                  class: "secondary-button small",
                  onclick: async () => {
                    if (!confirm(`Move favorites, progress, history and collections of every profile to “${available.fileName}” and remove the missing copy from the library? Files are never touched.`)) return;
                    try {
                      await api.mergeHealthDuplicates(item.id, available.id);
                      app.toast("Watch data moved.");
                      renderContent();
                    } catch (e) {
                      app.toast(e.message);
                    }
                  }
                }, "Move Watch Data") : null))));
          }
        } catch (e) {
          clear(contentContainer);
          contentContainer.append(h("p", { class: "error-text" }, e.message));
        }
      } else if (activeTab === "offline") {
        try {
          const filterSelect = h("select", {
            class: "select-input",
            "aria-label": "Missing for",
            onchange: (e) => {
              offlineDays = Number(e.target.value);
              renderContent();
            }
          },
            h("option", { value: "0", selected: offlineDays === 0 }, "Missing now"),
            h("option", { value: "30", selected: offlineDays === 30 }, "Missing 30+ days"),
            h("option", { value: "90", selected: offlineDays === 90 }, "Missing 90+ days"));

          const items = await api.healthOffline({ days: offlineDays });
          clear(contentContainer);
          contentContainer.append(h("div", { style: { marginBottom: "16px" } }, filterSelect));
          if (!items.length) {
            contentContainer.append(h("p", { class: "muted" }, "No missing titles match this filter."));
            return;
          }

          for (const item of items) {
            contentContainer.append(h("div", { class: "health-item-row" },
              h("div", { style: { display: "flex", flexDirection: "column", gap: "2px", flex: 1, minWidth: 0 } },
                h("div", { style: { fontWeight: "600" } }, item.title),
                h("div", { style: { fontSize: "13px", wordBreak: "break-all" } }, item.fileName),
                h("div", { class: "muted small" }, `${item.libraryName} · last seen ${new Date(item.lastSeenAt).toLocaleDateString()} (${item.daysOffline} days ago)`)),
              h("button", {
                type: "button",
                class: "secondary-button danger small",
                onclick: async () => {
                  if (!confirm(`Remove “${item.title}” from the library? Its details, favorites, progress and history are deleted for every profile. The file is never touched.`)) return;
                  try {
                    await api.removeHealthEntry(item.id);
                    app.toast("Removed from the library.");
                    renderContent();
                  } catch (e) {
                    app.toast(e.message);
                  }
                }
              }, "Remove…")));
          }
        } catch (e) {
          clear(contentContainer);
          contentContainer.append(h("p", { class: "error-text" }, e.message));
        }
      } else if (activeTab === "unmatched") {
        try {
          const items = await api.healthUnmatched();
          clear(contentContainer);
          if (!items.length) {
            contentContainer.append(h("p", { class: "muted" }, "Every movie and series has its details."));
            return;
          }
          for (const item of items) {
            contentContainer.append(h("div", { class: "health-item-row" },
              h("div", { style: { display: "flex", flexDirection: "column", gap: "2px", flex: 1, minWidth: 0 } },
                h("div", { style: { fontWeight: "600" } }, item.title),
                h("div", { style: { fontSize: "13px", wordBreak: "break-all" } }, item.fileName),
                h("div", { class: "muted small" }, item.issueReason)),
              h("button", {
                type: "button",
                class: "secondary-button small",
                onclick: () => {
                  dialog.remove();
                  editors.editMetadata({ id: item.id, kind: item.kind, title: item.title });
                }
              }, "Edit Metadata…")));
          }
        } catch (e) {
          clear(contentContainer);
          contentContainer.append(h("p", { class: "error-text" }, e.message));
        }
      }
    }

    const modal = h("div", { class: "editor-form", style: { maxWidth: "800px", width: "90vw", maxHeight: "85vh", overflowY: "auto" } },
      h("h2", {}, "Library Health & Maintenance"),
      tabContainer,
      contentContainer,
      h("div", { class: "button-row end", style: { marginTop: "20px" } }, closeBtn));

    dialog.append(modal);
    document.body.append(dialog);
    renderTabs();
    renderContent();
  }

  // MARK: Reset Library Dialog

  function openResetDialog(sections, refresh) {
    const dialog = h("div", { class: "modal-backdrop" });
    const passwordInput = h("input", {
      type: "password", class: "text-field", placeholder: "Server Password", autocomplete: "current-password", "aria-label": "Server Password",
    });
    const errorMsg = h("p", { class: "error-text", role: "alert" });
    const cancelBtn = h("button", { type: "button", class: "secondary-button", onclick: () => dialog.remove() }, "Cancel");
    const confirmBtn = h("button", { type: "submit", class: "primary-button danger" }, "Reset Library");

    const form = h("form", { class: "editor-form" },
      h("h2", {}, "Reset Media Library"),
      h("p", { class: "muted" }, "This will delete all movie and TV metadata, collections, and library assignments from the database. Media files on your disk will never be altered or moved."),
      h("p", { class: "muted small" }, "Enter the Server Password to confirm this irreversible action:"),
      passwordInput,
      errorMsg,
      h("div", { class: "button-row" }, cancelBtn, confirmBtn));

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      if (!passwordInput.value) return;
      confirmBtn.disabled = true;
      try {
        const libraryRoots = (sections?.libraries ?? []).map((l) => l.id);
        const preview = await api.request("/api/v1/libraries/reset/preview", {
          method: "POST", body: libraryRoots,
        });
        await api.approved("/api/v1/libraries/reset", {
          method: "POST",
          body: { libraryIds: libraryRoots, revision: preview.revision },
        });
        dialog.remove();
        app.toast("Library reset completed.");
        refresh();
      } catch (err) {
        confirmBtn.disabled = false;
        errorMsg.textContent = err.message ?? "The Server Password was incorrect or the reset failed.";
      }
    });

    dialog.append(h("div", { class: "modal-dialog" }, form));
    document.body.append(dialog);
    setTimeout(() => passwordInput.focus(), 0);
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
  const v = String(text ?? "");
  return v ? v[0].toUpperCase() + v.slice(1).replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase() : "—";
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

function bytes(val) {
  const units = ["bytes", "KB", "MB", "GB", "TB"];
  let size = Number(val) || 0;
  let unit = 0;
  while (size >= 1000 && unit < units.length - 1) {
    size /= 1000;
    unit += 1;
  }
  return `${size >= 10 || unit === 0 ? Math.round(size) : size.toFixed(1)} ${units[unit]}`;
}
