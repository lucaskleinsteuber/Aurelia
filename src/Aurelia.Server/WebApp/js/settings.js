// Settings, with the Mac app's structured categories: General, Playback, Library, Metadata,
// Profiles and Devices, Server, Power (only on a Linux package server), Updates, and Advanced
// (with Danger Zone).
// A search field filters settings across categories in real time.

import { h, icon, clear } from "./dom.js";
import { ApiError } from "./api.js";
import {
  MAXIMUM_PHOTO_BYTES, PHOTO_PICTURE, PICTURE_PALETTES, PICTURE_SYMBOLS, PLAYBACK_DEFAULTS, PLAYBACK_RATES,
  ageLimitSummary, loadManagementSections, managementPermissions, normalizeGeneralPreferences, parsePicture,
  rateLabel, scrubPreviewUsageText, shownName, transcodingSummary, DIALOGUE_BOOST_CHOICES, VOLUME_LEVELING_CHOICES, INTRO_SKIPPING_CHOICES,
  TOP_BAR_SECTIONS, moveSection, POWER_IDLE_CHOICES, powerPayload, wakeOnAccessOffered, rememberWakeOnAccess,
  powerModesFor, appHostName
} from "./logic.js";
import { loadPreferences, savePreferences } from "./player.js";
import { applyAppearance, loadGeneral, saveGeneral } from "./preferences.js";
import { createManagementEditors } from "./settings-editors.js";
import { createServerUpdates } from "./server-updates.js";
import { createAdminTools } from "./settings-admin.js";
import { createImportPreview } from "./import-preview.js";
import { cropPhoto } from "./photo-crop.js";
import { serverSegmentsSection, SEGMENTS_FEATURE } from "./segments-view.js";
import { serverSpeechSection } from "./speech-view.js";

const CATEGORIES = [
  { id: "general", label: "General", symbol: "gear", adminOnly: false },
  { id: "playback", label: "Playback", symbol: "play", adminOnly: false },
  { id: "library", label: "Library", symbol: "library", adminOnly: true },
  { id: "metadata", label: "Metadata", symbol: "star", adminOnly: true },
  { id: "profiles", label: "Profiles and Devices", symbol: "lock", adminOnly: false },
  { id: "server", label: "Server", symbol: "tv", adminOnly: true },
  { id: "power", label: "Power", symbol: "power", adminOnly: true, ownerOnly: true, needsPower: true },
  { id: "updates", label: "Updates", symbol: "arrow", adminOnly: false },
  { id: "advanced", label: "Advanced", symbol: "gear", adminOnly: true },
  { id: "about", label: "About", symbol: "star", adminOnly: false },
];

/**
 * @param {object} app  what settings needs from the app: api, state, navigate, toast, handleError,
 *                      profilePicture, switchProfile, confirmSignOut
 */
export function createSettings(app) {
  const { api, state } = app;
  const canManage = () => state.profile?.role === "owner" || state.profile?.role === "admin";
  const editors = createManagementEditors({ ...app, onSaved: () => app.navigate(state.route, { replace: true }),
    chooseServerFolder: (onPick, start) => admin.chooseServerFolder(onPick, start),
    reviewImport: (library) => importPreview.open(library, { onDone: () => app.navigate(state.route, { replace: true }) }) });
  const admin = createAdminTools({ api, app, editors });
  const importPreview = createImportPreview({ api, app, kit: editors.kit });
  let updatesView;
  let serverRead = new AbortController();
  let searchQuery = "";
  // Whether this server has power options (a Linux package server); unknown until first read.
  let powerAvailable = null;

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
    const owner = state.profile?.role === "owner";
    if (["library", "metadata", "server", "power", "advanced"].includes(page) && !canManage()) {
      page = "general";
    }
    if (page === "power" && !owner) page = "server";

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

    // The Power page needs only its own read.
    if (page === "power" && !needsManagement) {
      try {
        sections = { power: await api.serverPower({ signal: serverRead.signal }) };
      } catch (error) {
        if (serverRead.signal.aborted) throw new DOMException("Cancelled", "AbortError");
        if (error instanceof ApiError && (error.code === "management_locked" || error.status === 403)) {
          return unlockPage(error.code === "management_locked");
        }
      }
    }
    if (owner && sections?.power) powerAvailable = Boolean(sections.power?.available);
    else if (owner && powerAvailable === null) {
      try { powerAvailable = Boolean((await api.serverPower({ signal: serverRead.signal }))?.available); }
      catch { powerAvailable = false; }
    }
    if (page === "power" && !powerAvailable) page = "general";
    const availableCategories = CATEGORIES.filter((c) => (!c.adminOnly || canManage()) && (!c.ownerOnly || owner)
      && (!c.needsPower || powerAvailable));

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
      case "power": return h("div", { class: "settings-stack" }, ...powerSections(sections, refresh));
      case "updates": return updatesPage(sections, refresh);
      case "advanced": return advancedPage(sections, refresh);
      case "about": return h("div", { class: "settings-stack" }, ...aboutSections());
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
      ...(canManage() && sections ? powerSections(sections, refresh) : []),
      ...updatesSections(sections, refresh),
      ...(canManage() && sections ? advancedSections(sections, refresh) : []),
      ...aboutSections(),
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
          ["continueWatching", "Home"],
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
          "Keep finished titles in Favorites and Recently Added on Home."),
        row("Reduce Motion", toggle(general.reduceHeroMotion, (on) => saveG({ reduceHeroMotion: on }), "Reduce Motion"),
          "Turns off the moving background and the cards sliding in, as the system setting does.")),

      section("Top Bar", "gear", "Which sections the top bar shows after Home, and in which order.",
        ...general.sectionOrder.map((name, index, order) => {
          const label = Object.fromEntries(TOP_BAR_SECTIONS)[name];
          const key = { movies: "showMoviesInSidebar", shows: "showSeriesInSidebar", watchlist: "showWatchlistInSidebar", collections: "showCollectionsInSidebar" }[name];
          return row(label, h("div", { class: "inline-control" },
            h("button", { type: "button", class: "icon-button", "aria-label": `Move ${label} earlier`, disabled: index === 0, onclick: () => saveG({ sectionOrder: moveSection(order, name, -1) }) }, "↑"),
            h("button", { type: "button", class: "icon-button", "aria-label": `Move ${label} later`, disabled: index === order.length - 1, onclick: () => saveG({ sectionOrder: moveSection(order, name, 1) }) }, "↓"),
            key ? toggle(general[key], (on) => saveG({ [key]: on }), `Show ${label}`) : null));
        })),

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
      applyAppearance(loadGeneral(), preferences);
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
        row("Up Next Countdown", select([
          [5, "5 seconds"], [10, "10 seconds"], [15, "15 seconds"], [20, "20 seconds"], [30, "30 seconds"],
        ], preferences.upNextCountdownSeconds, (sec) => save({ upNextCountdownSeconds: Number(sec) }), "Up Next Countdown"),
          "How long before the end the next episode is offered."),
        state.server?.capabilities?.includes("media-segments-v2") ? row("Intros", select(INTRO_SKIPPING_CHOICES, preferences.introSkipping,
          (choice) => save({ introSkipping: choice }), "Intros"),
          "Your server finds where an episode’s intro is. Show Skip Intro offers a button while it plays (Return or S); Skip Automatically jumps past it once per episode, but never when you go back into it yourself.") : null,
        state.server?.capabilities?.includes("media-segments-v2") ? row("Offer Next Episode When Credits Begin",
          toggle(preferences.upNextAtCredits, (on) => save({ upNextAtCredits: on }), "Offer Next Episode When Credits Begin"),
          "Up Next appears when the credits begin, with the countdown above and Watch Credits. Turned off, or for episodes without known credits, it appears in the last seconds.") : null,
        state.server?.capabilities?.includes("suggestions-v1") ? row("Play Suggestions Automatically",
          toggle(preferences.playSuggestionsAutomatically, (on) => save({ playSuggestionsAutomatically: on }), "Play Suggestions Automatically"),
          "When a movie or a series’ last episode reaches its credits, your server suggests what to watch next, with Watch Now, Watch Credits and Done. Turned on, the suggestion starts by itself when the title ends; otherwise an end screen shows it with two more.") : null,
        row("Start Over If Barely Started", select([
          [0, "Never"], [30, "Under 30 seconds"], [60, "Under 1 minute"], [120, "Under 2 minutes"],
        ], preferences.resumeThresholdSeconds, (sec) => save({ resumeThresholdSeconds: Number(sec) }), "Start Over If Barely Started"),
          "Resume starts from the beginning when less than this was watched."),
        row("Keep Screen On During Playback", toggle(preferences.keepScreenOn, (on) => save({ keepScreenOn: on }), "Keep Screen On During Playback")),
        row("Dialogue Boost", select(DIALOGUE_BOOST_CHOICES, preferences.dialogueBoost, (choice) => save({ dialogueBoost: choice }), "Dialogue Boost"),
          "Lifts voices and lowers rumbling bass, so speech is easier to follow."),
        row("Volume Leveling", select(VOLUME_LEVELING_CHOICES, preferences.volumeLeveling, (choice) => save({ volumeLeveling: choice }), "Volume Leveling"),
          "Softens loud explosions and lifts quiet scenes. Sleep evens them out the most.")),

      section("Cinema Mode", "play", "A night at the cinema: before a film that starts from the beginning comes a made-up ad, trailers of films you haven’t watched, and the curtain.",
        row("Cinema Mode", toggle(preferences.cinemaMode, (on) => save({ cinemaMode: on }), "Cinema Mode"),
          state.server?.capabilities?.includes("cinema-trailers-v1") ? null : "Needs server 2.3.0 or newer."),
        row("Ads", toggle(preferences.cinemaAds, (on) => save({ cinemaAds: on }), "Ads"), "Aurelia’s own made-up ads. Nothing is for sale."),
        row("Trailers", select([[0, "None"], [1, "1 trailer"], [2, "2 trailers"], [3, "3 trailers"]], preferences.cinemaTrailers,
          (count) => save({ cinemaTrailers: Number(count) }), "Trailers"), "From the trailer files in your film folders.")),

      section("Audio & Subtitles", "captions", "Preferred spoken language, subtitles and appearance.",
        row("Default Audio Language", select([
          ["original", "Original Audio"],
          ["en", "English"],
          ["de", "German"],
          ["fr", "French"],
          ["es", "Spanish"],
          ["ja", "Japanese"],
          ["it", "Italian"],
        ], preferences.defaultAudioLanguage, (lang) => save({ defaultAudioLanguage: lang }), "Default Audio Language"),
          "Used until you choose a sound track for a series yourself."),
        row("Default Subtitle Language", select([
          ["off", "Off"],
          ["en", "English"],
          ["de", "German"],
          ["fr", "French"],
          ["es", "Spanish"],
          ["ja", "Japanese"],
          ["it", "Italian"],
        ], preferences.defaultSubtitleLanguage, (lang) => save({ defaultSubtitleLanguage: lang }), "Default Subtitle Language"),
          "Used until you choose subtitles for a series yourself."),
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
              library.importPreviewRequired ? "waiting for its import to be reviewed" : null,
              library.lastScanCompletedAt ? `last scanned ${new Date(library.lastScanCompletedAt).toLocaleString()}` : "not scanned yet",
            ].filter(Boolean).join(" · "))),
          h("div", { class: "settings-card-actions" },
            h("label", { class: "inline-control small" }, toggle(library.monitoringEnabled, async (on) => {
              try { await api.setLibraryMonitoring(library.id, on); }
              catch (err) { if (!app.handleError(err)) app.toast(err.message); }
            }, `Watch ${library.name} for changes`), "Watch for Changes"),
            library.importPreviewRequired
              ? openButton("Review Import…", () => importPreview.open(library, { onDone: refresh }), "primary-button")
              : button("Scan Now", () => api.scanLibrary(library.id), `Scanning ${library.name}…`, "secondary-button", refresh),
            openButton("Left Out…", () => admin.exclusions(library, refresh)),
            permissions.owner ? openButton("Remove…", () => editors.removeStorage(library), "secondary-button danger") : null)))
          : h("p", { class: "muted" }, "No storage locations configured."),
        h("div", { class: "button-row" },
          permissions.owner ? openButton("Add Storage Location…", () => editors.addStorage()) : null,
          libraries.length > 1 ? button("Scan All", () => api.scanAllLibraries(), "Scanning all storage locations…", "secondary-button", refresh) : null))
        : section("Storage Locations", "library", "Storage management requires full library access."),

      section("Library Maintenance", "library", "Offline titles and the health of the library. Use Watch for Changes above to rescan automatically.",
        row("Hide Offline Titles", toggle(general.hideOfflineTitles, (on) => saveG({ hideOfflineTitles: on }), "Hide Offline Titles"),
          "In this browser, hides titles whose file or drive is unavailable. Their details and progress stay."),
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
    const provider = sections?.metadataProvider;
    const subtitles = sections?.subtitleProvider;
    const reviewCount = jobs.reduce((sum, job) => sum + (job.itemsNeedingReview ?? 0), 0);

    return [
      section("Movie & TV Info", "star", "Titles, artwork and episode details from The Movie Database (TMDB).",
        row("Metadata Service", value(!provider ? "Unknown" : !provider.hasToken ? "Not set up" : provider.enabled ? "TMDB connected" : "Turned off"),
          provider && !provider.hasToken ? "Add a free TMDB token so titles get their details and artwork." : null),
        provider ? row("Artwork Storage", value(`${bytes(provider.artworkBytes)} of ${bytes(provider.artworkLimitBytes)}`)) : null,
        row("Recent Jobs", value(jobs.length ? `${jobs.length} jobs recorded` : "Idle")),
        jobs.slice(0, 3).map((job) => row(`${capitalize(job.mode)} · ${new Date(job.createdAt).toLocaleString()}`,
          value(`${capitalize(job.state)} · ${job.itemsProcessed}/${job.itemsTotal}${job.itemsNeedingReview ? ` · ${job.itemsNeedingReview} to review` : ""}`))),
        h("div", { class: "button-row" },
          permissions.owner ? openButton(provider?.hasToken ? "TMDB Settings…" : "Set Up TMDB…", () => admin.metadataService(refresh), provider?.hasToken ? "secondary-button" : "primary-button") : null,
          openButton("Edit Metadata…", () => editors.metadataPicker()),
          button("Find Missing Info", () => api.startMetadataJob({ mode: "incremental" }), "Looking up missing movie info…", "secondary-button", refresh),
          permissions.owner ? button("Refresh All Info", () => api.startMetadataJob({ mode: "fullRefresh" }), "Refreshing all movie info…", "secondary-button", refresh) : null)),

      section("Review Matches", "star", "Titles whose match the server wasn’t sure about. Pick the right one.",
        row("Waiting for Review", value(reviewCount ? `${reviewCount} title${reviewCount === 1 ? "" : "s"}` : "None")),
        h("div", { class: "button-row" }, openButton("Review Matches…", () => admin.reviewMatches(refresh), reviewCount ? "primary-button" : "secondary-button"))),

      permissions.owner ? section("Subtitles", "star", "Find subtitles for titles that have none, from OpenSubtitles.",
        row("OpenSubtitles", value(!subtitles ? "Unknown" : !subtitles.hasApiKey ? "Not set up" : subtitles.enabled ? `On · ${(subtitles.languages ?? []).join(", ") || "no languages"}` : "Turned off")),
        h("div", { class: "button-row" }, openButton("Subtitle Settings…", () => admin.subtitleService(refresh))),
        h("p", { class: "muted small" }, "Subtitles written from speech are made by Aurelia for Mac, which listens with macOS speech recognition. A browser can’t do that.")) : null,

      permissions.owner ? section("Artwork & Search", "star", "Housekeeping for pictures and the search index.",
        h("div", { class: "button-row" },
          button("Remove Unused Artwork", () => api.pruneArtwork(), "Unused artwork removed.", "secondary-button", refresh),
          button("Rebuild Search", () => api.rebuildSearch(), "The search index is being rebuilt.", "secondary-button", refresh))) : null,
    ].filter(Boolean);
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
        h("div", { class: "settings-profile" }, app.profilePicture(profile, "medium settings-avatar"),
          h("div", {}, h("div", { class: "settings-profile-name" }, shownName(profile)), h("div", { class: "muted small" }, roleTitle(profile.role)))),
        h("div", { class: "button-row" },
          h("button", { class: "secondary-button", onclick: () => app.switchProfile() }, "Switch Profile"),
          h("button", { class: "secondary-button danger", onclick: () => app.confirmSignOut() }, "Sign Out of This Browser"))),

      nameAndPicture(profile),

      permissions.owner ? section("Add a Device", "lock", "Connect a phone, tablet, Apple TV, computer or another browser to this server.",
        h("div", { class: "button-row" },
          openButton("Create Code…", () => admin.createCode(), "primary-button"),
          openButton("Enter Code from Device…", () => admin.enterCode()))) : null,

      section("Signed-In Devices", "lock", "Devices and browsers signed in to this account.",
        (devices ?? []).filter((device) => !device.revokedAt).map((device) => h("div", { class: "settings-card" },
          h("div", { class: "settings-card-main" },
            h("div", { class: "settings-card-title" }, device.deviceName, device.isCurrent ? h("span", { class: "tag" }, "This Browser") : null),
            h("div", { class: "muted small" }, `Last used ${new Date(device.lastSeenAt).toLocaleString()}`)),
          device.isCurrent || !permissions.owner ? null : h("div", { class: "settings-card-actions" },
            button("Sign Out", () => api.approved(`/api/v1/auth/sessions/${device.id}`, { method: "DELETE" }), `${device.deviceName} is signed out.`, "secondary-button", refresh))))),

      permissions.owner ? section("User Accounts", "lock", "Choose who can watch and what they can see.",
        users.map((entry) => row(h("span", { class: "inline-control" }, app.profilePicture(entry.user), shownName(entry.user)),
          h("div", { class: "inline-control" }, value(`${ageLimitSummary(entry.user.ageLimit) ?? roleTitle(entry.user.role)}${entry.isEnabled ? "" : " · Disabled"}`),
            openButton("Edit…", () => editors.editProfile(entry)),
            openButton("Devices…", () => admin.userSessions(entry)),
            openButton("Password…", () => admin.resetPassword(entry))))),
        h("div", { class: "button-row" }, openButton("Create Profile…", () => editors.editProfile()))) : null,
    ].filter(Boolean);
  }

  function profilesPage(sections, refresh) {
    return h("div", { class: "settings-stack" }, ...profilesSections(sections, refresh));
  }

  // MARK: Server Sections

  function serverSections(sections, refresh) {
    const { status, health, scrubPreviews, backups, issues, transcoding } = sections ?? {};
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

      permissions.owner && state.server?.capabilities?.includes(SEGMENTS_FEATURE) ? serverSegmentsSection({ api, section, row, toggle }) : null,

      permissions.owner && state.server?.capabilities?.includes("server-speech-v1") ? serverSpeechSection({ api, section }) : null,

      transcoding ? videoConversionSection(transcodingSummary(transcoding), transcoding.hint) : section("Live Conversion", "tv", "Live decoding, remuxing and streaming for browser playback.",
        row("Status", value(state.server?.capabilities?.includes("live-conversion-v1") ? "Active" : "Not available")),
        row("Active Live Conversions", value(health?.activeLiveConversions != null ? `${health.activeLiveConversions}` : "0"))),

      permissions.owner ? section("Backups", "library", "The server backs up its database every day. An encrypted backup also keeps accounts and settings and can move a server to another computer.",
        (backups ?? []).slice(0, 5).map((backup) => row(new Date(backup.createdAt).toLocaleString(),
          h("div", { class: "inline-control" }, value(`${capitalize(backup.kind)} · ${bytes(backup.bytes)}`), openButton("Check", () => admin.verifyBackup(backup))))),
        h("div", { class: "button-row" },
          button("Back Up Now", () => api.approved("/api/v1/server/backups/database"), "Backup created.", "secondary-button", refresh),
          sections?.capabilities?.encryptedBackups !== false ? openButton("Save Encrypted Backup…", () => admin.exportBackup()) : null,
          sections?.capabilities?.nativeHostOperations || sections?.capabilities?.linuxPackage
            ? openButton("Restore from Backup…", () => admin.restoreBackup(), "secondary-button danger") : null),
        sections?.capabilities && !sections.capabilities.nativeHostOperations && !sections.capabilities.linuxPackage
          ? h("p", { class: "muted small" }, "Restoring swaps the server’s data, which a server hosted by Aurelia for Mac or installed from the Linux package can do. Encrypted backups from here can be restored there.") : null) : null,

      permissions.owner ? section("Maintenance", "gear", "Restart the server or save a report of recent events for troubleshooting. The report holds no passwords, tokens or media paths.",
        h("div", { class: "button-row" },
          openButton("Restart Server…", () => admin.restart(refresh)),
          openButton("Download Diagnostics", () => admin.downloadDiagnostics()))) : null,
    ].filter(Boolean);
  }

  function videoConversionSection(summary, hint) {
    return section("Video Conversion", "tv", "Converts titles for browsers and for apps set to a streaming quality, in memory only.",
      row("Encoder", value(summary.encoder)),
      hint ? row("Video Chip", value(hint)) : null,
      row("Converting Now", value(summary.running)),
      ...summary.sessions.map((session) => row(session.title, value(session.detail))));
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

  // MARK: Power

  /** Settings › Power: what a Linux package server does when nobody uses it. Other servers show nothing. */
  function powerSections(sections, refresh) {
    const power = sections?.power;
    if (!power?.available) return [];
    rememberWakeOnAccess(power);
    const draft = { ...power, awakeHours: Boolean(power.awakeFrom), afterSleepTimer: power.afterSleepTimer !== false };
    const modes = powerModesFor(power);
    const computer = appHostName(power.hosting);
    const explanation = h("p", { class: "muted small power-explanation" });
    const mode = select(modes.map((choice) => [choice.id, choice.label]), draft.mode, (chosen) => { draft.mode = chosen; update(); }, "When Unused");
    const minutes = select([...new Set([...POWER_IDLE_CHOICES, draft.idleMinutes])].sort((a, b) => a - b)
      .map((count) => [count, count < 60 || count % 60 ? `${count} minutes` : `${count / 60} hour${count === 60 ? "" : "s"}`]),
    draft.idleMinutes, (chosen) => { draft.idleMinutes = Number(chosen); }, "After");
    const time = (key, label) => {
      const input = h("input", { type: "time", class: "text-field time-field", value: draft[key] ?? "", "aria-label": label });
      input.addEventListener("input", () => { draft[key] = input.value; });
      return input;
    };
    const from = time("awakeFrom", "Awake From");
    const until = time("awakeUntil", "Awake Until");
    const hoursNote = h("span", {});
    const hoursRow = row("Hours", h("div", { class: "inline-control" }, from, h("span", { class: "muted" }, "to"), until), hoursNote);
    const awakeToggle = toggle(draft.awakeHours, (on) => {
      draft.awakeHours = on;
      if (on && !draft.awakeFrom) { draft.awakeFrom = from.value = "17:00"; draft.awakeUntil = until.value = "23:30"; }
      update();
    }, "Keep Running at Set Hours");
    const wakeRow = row("Wake When a Device Connects", toggle(Boolean(draft.wakeOnAccess), (on) => { draft.wakeOnAccess = on; }, "Wake When a Device Connects"),
      "Opening Aurelia in a browser wakes the server too, from a device that reached it within the last minutes. Other devices still use Wake-on-LAN. Stray network traffic can wake it now and then; it powers down again after five unused minutes.");
    const unused = [row("After", minutes, "Without anyone watching, browsing or changing settings on any device. An app that is only open doesn't count, and nothing happens while a title plays."),
      row("Also After a Sleep Timer Ends", toggle(draft.afterSleepTimer, (on) => { draft.afterSleepTimer = on; }, "Also After a Sleep Timer Ends"),
        "When a player's sleep timer ends and nothing plays for five more minutes, it happens right away, at any time of day."),
      row("Keep Running at Set Hours", awakeToggle), hoursRow];
    function update() {
      explanation.textContent = modes.find((choice) => choice.id === draft.mode)?.explanation ?? "";
      for (const element of unused) element.hidden = draft.mode === "off";
      hoursRow.hidden = draft.mode === "off" || !draft.awakeHours;
      hoursNote.textContent = draft.mode === "stop"
        ? "Aurelia Server never stops during these hours."
        : "It never powers down during these hours and wakes itself at their start, so every device finds it then.";
      wakeRow.hidden = !wakeOnAccessOffered(power, draft.mode);
    }
    update();
    const save = h("button", { class: "primary-button" }, "Save");
    save.addEventListener("click", () => act(save, () => api.saveServerPower(powerPayload(draft, power)), "Power settings saved.", refresh));
    return [
      section("When Nobody Uses Aurelia", "power", computer
        ? `Aurelia Server runs inside the Aurelia app on a ${computer}. It can stop when nobody uses it, so the computer may sleep.`
        : "What the server computer does while nobody watches, browses or changes anything.",
        row("When Unused", mode), explanation, ...unused, wakeRow,
        h("div", { class: "button-row" }, save)),
    ];
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
      section("Server Version", "arrow", "The browser app comes with the server, so it is always the server's version.",
        row("Version", value(state.server?.version ?? "—"))),

      updatesView?.element ?? null,
    ].filter(Boolean);
  }

  // MARK: About

  function aboutSections() {
    return [
      section("About Aurelia", "star", "Your movies and shows from your own server, in this browser.",
        row("Version", value(state.server?.version ?? "—"), "The browser app comes with the server."),
        row("Source Code", h("a", { class: "link-button", href: "https://github.com/lucaskleinsteuber/Aurelia", target: "_blank", rel: "noopener" }, "Open on GitHub"),
          "Aurelia is open source. Its code, releases and full change history are on GitHub.")),
      section("Getting Started", "play", "Take the short tour of the browser app again.",
        h("div", { class: "button-row" }, h("button", { class: "secondary-button", onclick: () => app.startTour?.() }, "Show Tour"))),
      section("Legal", "lock", null,
        h("p", { class: "small" }, "© 2026 Lucas Kleinsteuber. Released under the MIT License."),
        h("p", { class: "small" }, h("a", { class: "link-button", href: "https://github.com/lucaskleinsteuber/Aurelia/blob/main/docs/PRIVACY.md", target: "_blank", rel: "noopener" }, "Privacy Policy")),
        h("p", { class: "muted small" }, "Movie and series details and pictures can come from TMDB when the server's owner turns it on; subtitles can come from OpenSubtitles. This product uses the TMDB API but is not endorsed or certified by TMDB, and Aurelia is not endorsed by OpenSubtitles.")),
    ];
  }

  // MARK: Name and Picture

  /** The signed-in profile chooses the name everyone sees and its picture. */
  function nameAndPicture(profile) {
    const supported = state.server?.capabilities?.includes("profile-personalization-v1");
    if (!supported) return null;
    let key = profile.pictureKey ?? null;
    let palette = parsePicture(key)?.palette ?? "blue";
    let photo = null;
    const name = h("input", { class: "text-field", type: "text", maxlength: "40", value: shownName(profile), "aria-label": "Your Name" });
    const preview = h("span", { class: "picture-preview" });
    const message = h("p", { class: "muted small", role: "status" });
    const symbols = h("div", { class: "picture-symbols" });
    const palettes = h("div", { class: "picture-palettes" });
    const paint = () => {
      clear(preview);
      if (photo) {
        const image = h("img", { class: "profile-photo", alt: "" });
        app.pictureAddress(photo).then((address) => { if (address) image.src = address; });
        preview.append(h("span", { class: "profile-picture medium" }, image));
      }
      else preview.append(app.profilePicture({ ...profile, displayName: name.value, pictureKey: key }, "medium"));
      clear(symbols);
      for (const symbol of PICTURE_SYMBOLS) {
        const candidate = `${symbol}:${palette}`;
        const chooser = h("button", { type: "button", class: `picture-choice ${key === candidate ? "selected" : ""}`, "aria-label": `Picture ${symbol}`, "aria-pressed": String(key === candidate),
          onclick: () => { key = candidate; photo = null; paint(); } },
        app.profilePicture({ id: profile.id, pictureKey: candidate }, "small"));
        symbols.append(chooser);
      }
      clear(palettes);
      for (const candidate of PICTURE_PALETTES) {
        palettes.append(h("button", { type: "button", class: `palette-choice palette-${PICTURE_PALETTES.indexOf(candidate)} ${palette === candidate ? "selected" : ""}`, "aria-label": `Color ${candidate}`, "aria-pressed": String(palette === candidate),
          onclick: () => {
            palette = candidate;
            const builtin = parsePicture(key);
            if (builtin) key = `${builtin.symbol}:${candidate}`;
            paint();
          } }));
      }
    };
    const file = h("input", { type: "file", accept: "image/jpeg,image/png,image/webp", hidden: true });
    file.addEventListener("change", async () => {
      const chosen = file.files?.[0];
      file.value = "";
      if (!chosen) return;
      if (chosen.size > MAXIMUM_PHOTO_BYTES * 4) {
        message.textContent = "Choose a photo smaller than 32 MB.";
        return;
      }
      // The photo is cropped to a square here, before anything is uploaded.
      const cropped = await cropPhoto(chosen);
      if (!cropped) return;
      if (cropped.size > MAXIMUM_PHOTO_BYTES) {
        message.textContent = "Choose a photo smaller than 8 MB.";
        return;
      }
      photo = cropped;
      key = PHOTO_PICTURE;
      message.textContent = "";
      paint();
    });
    name.addEventListener("input", () => { if (!photo && !key) paint(); });
    const save = h("button", { class: "primary-button", onclick: async () => {
      const wanted = name.value.trim();
      if (wanted.length < 1 || wanted.length > 40) {
        message.textContent = "Use a name with 1 to 40 characters.";
        return;
      }
      save.disabled = true;
      message.textContent = "Saving…";
      try {
        let user = null;
        if (wanted !== shownName(profile)) user = await api.renameProfile(wanted);
        if (photo) {
          user = await api.uploadPhoto(photo);
          app.rememberPhoto?.(user, photo);
        } else if (key !== (profile.pictureKey ?? null)) {
          user = await api.setPicture(key);
        }
        message.textContent = "Saved.";
        if (user) app.updateProfile?.(user);
      } catch (error) {
        if (!app.handleError(error)) message.textContent = error.message;
      } finally {
        save.disabled = false;
      }
    } }, "Save Name and Picture");
    paint();
    return section("Name and Picture", "star", "The name everyone sees on every device, and your picture.",
      row("Your Name", name),
      h("div", { class: "picture-editor" }, preview,
        h("div", { class: "button-row" },
          h("button", { type: "button", class: "secondary-button", onclick: () => file.click() }, "Choose Photo…"),
          h("button", { type: "button", class: "secondary-button", onclick: () => { key = null; photo = null; paint(); } }, "Use Initial"))),
      symbols, palettes, file,
      h("div", { class: "button-row" }, save), message);
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

  /**
   * The first steps on a server set up in this browser: media folders, movie info and power,
   * then a scan. Everything here is also in Settings.
   */
  async function welcomeScreen() {
    const refresh = () => app.navigate({ name: "welcome" }, { replace: true });
    let libraries = [];
    let provider = null;
    let power = null;
    try { libraries = (await api.libraries()) ?? []; } catch (error) { if (error?.code !== "management_locked") throw error; }
    try { provider = await api.metadataProvider(); } catch { provider = null; }
    try { power = await api.serverPower(); } catch { power = null; }
    const step = (number, title, text, done, ...actions) => h("section", { class: `welcome-step ${done ? "done" : ""}` },
      h("span", { class: "welcome-number", "aria-hidden": "true" }, done ? "✓" : String(number)),
      h("div", { class: "welcome-body" }, h("h2", {}, title), h("p", { class: "muted" }, text), h("div", { class: "button-row" }, ...actions)));
    return h("div", { class: "welcome page-enter" },
      h("header", { class: "welcome-header" },
        h("h1", {}, "Welcome to Aurelia"),
        h("p", { class: "muted" }, "Three steps and your library is ready. You can change all of this later in Settings.")),
      step(1, "Add your media", libraries.length
        ? `${libraries.map((library) => library.name).join(", ")}. Add more folders any time.`
        : "Choose the folders on the server that hold your films and shows. Aurelia only reads them.",
        libraries.length > 0,
        h("button", { class: libraries.length ? "secondary-button" : "primary-button", onclick: () => editors.addStorage() }, "Add a Folder…")),
      step(2, "Get movie and TV info", provider?.hasToken
        ? "Titles, artwork and episode details come from TMDB."
        : "A free token from The Movie Database (TMDB) gives your titles posters, descriptions and cast. Optional.",
        Boolean(provider?.hasToken),
        h("button", { class: "secondary-button", onclick: () => admin.metadataService(refresh) }, provider?.hasToken ? "TMDB Settings…" : "Set Up TMDB…")),
      power?.available ? step(3, "Choose how the server saves power", "Always on, sleeping when nobody watches, or stopping only Aurelia. Settings › Power.", false,
        h("a", { class: "secondary-button", href: "/settings/power", "data-route": true }, "Power Settings")) : null,
      h("div", { class: "welcome-finish" },
        button("Scan and Open Home", async () => {
          if (libraries.length) await api.scanAllLibraries();
          app.navigate({ name: "home" });
        }, libraries.length ? "Scanning your media. Titles appear as they are found." : null, "primary-button large", () => {}),
        h("p", { class: "muted small" }, "Add Aurelia to your phone’s home screen, or connect other devices with a code from Settings › Profiles and Devices.")));
  }

  return { settingsScreen, welcomeScreen, editMetadata: editors.editMetadata, closeEditors: () => { editors.close(); closeUpdates(); } };
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
