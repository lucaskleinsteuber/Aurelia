// Aurelia in a web browser: sign-in with a code approved on the Mac, profiles, the library
// and the player. The server serves this page, so every address here is its own.

import { h, icon, clear } from "./dom.js";
import { createApi, ApiError } from "./api.js";
import { createCatalogView } from "./catalog-view.js";
import * as logic from "./logic.js";
import { PROFILE_SYMBOL_PATHS } from "./profile-symbols.js";
import { createWatchTogether } from "./watch-together.js";
import { createMovieNightView } from "./movie-night-view.js";
import { createWishesView } from "./wishes-view.js";
import { supportsSecurity } from "./security.js";
import { createSecurityAlerts } from "./security-view.js";
import { describeWishError, formatWishNotification, supportsWishes, wishBadgeCount, wishPosterUrl } from "./wishes.js";
import { openWrapped, readyMonth, readyMonths, wrappedYears, monthIsNew, MONTHS } from "./wrapped.js";
import { Player } from "./player.js";
import { clockTime, closedLabel } from "./screen-time.js";
import { LIVE_FEATURE } from "./live-logic.js";
import { ADAPTIVE_FEATURE } from "./hls-logic.js";
import { createSettings } from "./settings.js";
import { createSetupMove, movedNotice } from "./server-move-view.js";
import { movedDestination } from "./server-move.js";
import { adScene, cinemaActs, cinemaWanted, comingUp, curtain, nextAd, AD_SECONDS, CURTAIN_EARLIEST, CURTAIN_LONGEST_WAIT, CURTAIN_OPENING, LAST_AD_KEY, TRAILER_LONGEST_SECONDS, TRAILER_START_SECONDS } from "./cinema.js";
import { loadPreferences } from "./player.js";
import { applyAppearance, loadGeneral, sidebarShows, startPath, visibleTitles } from "./preferences.js";
import { confirmSheet, openSheet } from "./sheet.js";

const SVG = "http://www.w3.org/2000/svg";

// Pages seen before show at once from what the server said last time; anything this browser
// changes on the server, and every change the server reports, forgets them.
const reads = logic.createReadCache();
const prefetches = logic.createPrefetcher();
const api = createApi(undefined, { onChange: (path) => {
  if (path.endsWith("/player/heartbeat")) return;
  reads.clear();
  prefetches.forget();
}, onMoved: (error) => showServerMoved(movedDestination(error)),
  // A page reloaded because the server reported a change is the page's own read (audit L4).
  isBackground: () => state.quietRefresh === true });
const remembered = (name, key, load) => reads.read(`${name}:${key}`, load, () => refreshSoon());
const cached = {
  home: () => remembered("home", "", () => api.home()),
  detail: (id) => remembered("detail", id, () => api.detail(id)),
  playbackPlan: (id) => remembered("plan", id, () => api.playbackPlan(id)),
  watchlist: () => remembered("watchlist", "", () => api.watchlist()),
  person: (who) => remembered("person", JSON.stringify(who), () => api.person(who)),
  personProfile: (key) => remembered("profile", key, () => api.personProfile(key)),
};
const root = document.getElementById("app");

const state = {
  server: null,
  profile: null,
  route: logic.parseRoute(location.pathname, location.search),
  renderToken: 0,
  sync: null,
  player: null,
  pendingRefresh: false,
  retryTimer: null,
  knockChain: 0,
  offSince: null,
  watchlistIds: new Set(),
  wishSummary: null,
  movedToken: null,
};

// Settings › General: open on the chosen page when the app starts at Home.
if (location.pathname === "/" && startPath() !== "/") {
  history.replaceState(null, "", startPath());
  state.route = logic.parseRoute(location.pathname, location.search);
}
applyAppearance();

const scrollMemory = new logic.ScrollMemory();
// The app puts each page where it was itself; the browser's own restoring would move the old page
// to the new page's place for a moment on Back.
try { history.scrollRestoration = "manual"; } catch { /* Older browsers restore by themselves. */ }
const OPEN_MARK = "aurelia.profileOpen";
let isRenderingRoute = false;

window.addEventListener("scroll", () => {
  if (isRenderingRoute || !state.profile) return;
  const currentPath = logic.routePath(state.route) || (location.pathname + location.search);
  scrollMemory.remember(currentPath, window.scrollY);
}, { passive: true });

// MARK: Start and connection

async function start() {
  clearTimeout(state.retryTimer);
  state.knockChain++;
  showConnecting();
  // Who is signed in is asked at the same time as the server's info, not after it (audit P4).
  const signedIn = api.request("/api/v1/auth/me").then((user) => ({ user }), (error) => ({ error }));
  try {
    state.server = await api.serverInfo();
    state.offSince = null;
    logic.rememberHosting(state.server?.hosting);
    document.title = state.server?.name && state.server.name !== "Aurelia" ? `Aurelia · ${state.server.name}` : "Aurelia";
  } catch (error) {
    return showServerOff(error);
  }
  // A server that moved to another computer still answers its public info, and says where it went.
  if (state.server?.moved) return showServerMoved(movedDestination(state.server));
  // A page reload keeps the open profile. A new tab, or the browser opened again, asks for the
  // profile (and its PIN) again, unless Settings › General keeps it open.
  const { user, error } = await signedIn;
  if (error instanceof ApiError && error.offline) return showServerOff(error);
  if (user?.id && (tabKeepsProfile() || loadGeneral().keepProfileOpen)) return enterProfile(user);
  if (user?.id) await api.endProfile().catch(() => {});
  await showProfiles();
}

/** Whether this tab already had a profile open: the mark lives only as long as the tab. */
function tabKeepsProfile() {
  try { return sessionStorage.getItem(OPEN_MARK) === "1"; } catch { return false; }
}

function markTabProfile(open) {
  try {
    if (open) sessionStorage.setItem(OPEN_MARK, "1");
    else sessionStorage.removeItem(OPEN_MARK);
  } catch { /* Without session storage the profile is asked for on every load. */ }
}

function showConnecting() {
  render(screenFrame(h("div", { class: "center-stack" }, h("div", { class: "spinner visible" }), h("p", { class: "muted" }, "Connecting…"))));
}

function showServerOff() {
  catalog.close();
  settings.closeEditors();
  stopSync();
  closeMiniRemote();
  const name = state.server?.name ? `“${state.server.name}”` : "The server";
  // A server inside Aurelia on a desktop or laptop is started there, not woken over the network.
  const computer = logic.appHostName(logic.rememberedHosting());
  const waking = !computer && logic.remembersWakeOnAccess();
  render(screenFrame(h("div", { class: "center-stack narrow" },
    h("div", { class: `status-icon${waking ? " waking" : ""}` }, icon("power", { size: 34 })),
    h("h1", {}, computer ? `Start Aurelia on Your ${computer}` : waking ? "Waking the Server…" : "The Server Is Asleep or Offline"),
    h("p", {}, computer
      ? `${name} runs inside the Aurelia app on a ${computer}. Open Aurelia there, or wake the ${computer}, and this page connects by itself.`
      : waking
      ? `${name} is waking because this page knocks. That takes a few seconds, or about a minute when it was turned off. If it doesn't wake, Aurelia on a Mac or your router can wake it with Wake-on-LAN.`
      : `${name} isn’t answering. The computer may be asleep or turned off. You can wake it with Aurelia on your Mac if Wake-on-LAN is set up, or check that the computer is turned on.`),
    computer ? null : h("p", { class: "muted" }, "This page connects by itself as soon as the server is on."),
    h("div", { class: "button-row" }, h("button", { class: "primary-button", onclick: () => start() }, "Try Again")))));
  // Several requests can fail at once; only one chain of knocks may run. A knock still waiting for
  // its answer belongs to an older chain once this page shows again, and then stops (audit C-L1).
  // Each quiet knock is a direct packet to the server, which wakes it when its power settings
  // allow; the page doesn't flicker.
  clearTimeout(state.retryTimer);
  const chain = ++state.knockChain;
  state.offSince ??= Date.now();
  const knock = async () => {
    try {
      await api.serverInfo({ signal: logic.timeoutSignal(8_000) });
    } catch {
      if (chain !== state.knockChain) return;
      state.retryTimer = setTimeout(knock, logic.wakeRetryDelay(state.offSince, Date.now()));
      return;
    }
    if (chain !== state.knockChain) return;
    state.offSince = null;
    start();
  };
  state.retryTimer = setTimeout(knock, logic.wakeRetryDelay(state.offSince, Date.now()));
}

// Settings needs these app functions; they are declarations, so they exist already.
const settings = createSettings({ api, state, navigate, toast, handleError, profilePicture, switchProfile, confirmSignOut, closeSettings: () => closeSettings(),
  rememberPhoto, updateProfile, pictureAddress, startTour: () => { navigate({ name: "home" }); setTimeout(() => startTour(), 400); } });

const catalog = createCatalogView({ api, navigate, artwork: (...args) => artwork(...args), progressBar: (progress) => progressBar(progress), posterCard, collectionCard, emptyState, openMenu, menuOption, handleError, toast,
  play: playTitle, canManage: () => logic.managementPermissions(state.profile).administrator,
  editMetadata: (item) => settings.editMetadata(item),
  isWatchlisted: (mediaId) => state.watchlistIds.has(mediaId),
  toggleWatchlist: async (mediaId, isWatchlisted, options) => {
    await api.setWatchlist(mediaId, isWatchlisted, options);
    if (isWatchlisted) state.watchlistIds.add(mediaId);
    else state.watchlistIds.delete(mediaId);
  },
  replaceRoute: (route) => { state.route = route; history.replaceState(null, "", logic.routePath(route)); },
  onChanged: () => renderRoute({ quiet: true }),
  showsTitle: (item) => visibleTitles([item], loadGeneral(), { keepWatched: true }).length > 0,
});

const movieNight = createMovieNightView({
  api,
  artwork: (...args) => artwork(...args),
  playTitle: (item) => playTitle(item),
  navigate: (route) => navigate(route),
  deviceName: logic.deviceName(navigator.userAgent, navigator.maxTouchPoints),
});

const wishes = createWishesView({
  api,
  profile: () => state.profile,
  navigate: (route) => navigate(route),
  toast,
  handleError,
  onSummaryChanged: (summary) => setWishSummary(summary),
});

const securityAlerts = createSecurityAlerts({ api, toast, handleError: (error) => handleError(error) });

function setWishSummary(summary, { notify = false } = {}) {
  const previous = state.wishSummary;
  state.wishSummary = summary ? { openCount: summary.openCount ?? 0, newlyFulfilledCount: summary.newlyFulfilledCount ?? 0 } : null;
  if (notify) {
    const note = formatWishNotification(previous, state.wishSummary, state.profile);
    if (note) {
      toast(note.body);
      if (typeof Notification === "function" && Notification.permission === "granted") {
        const browserNote = new Notification(note.title, { body: note.body });
        browserNote.onclick = () => { window.focus?.(); navigate(logic.parseRoute(note.route)); };
      }
    }
  }
  updateWishBadges();
}

function refreshWishSummary({ notify = false } = {}) {
  if (!state.profile || !supportsWishes(state.server)) return Promise.resolve();
  return api.wishSummary().then((summary) => {
    if (state.profile) setWishSummary(summary, { notify });
  }, () => {});
}

function updateWishBadges() {
  const count = supportsWishes(state.server) ? wishBadgeCount(state.wishSummary, state.profile) : 0;
  for (const badge of document.querySelectorAll("[data-wish-badge]")) {
    badge.textContent = count > 0 ? String(count) : "";
    badge.hidden = count <= 0;
  }
}

function settingsScreen(route) {
  return settings.settingsScreen(route);
}

/** Done (or Esc) in Settings: back to the page it was opened from. */
function closeSettings() {
  const back = state.beforeSettings ?? "/";
  const [pathname, search] = back.split("?");
  navigate(logic.parseRoute(pathname, search ?? ""));
}

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape" || event.defaultPrevented || state.route.name !== "settings" || !state.profile || state.player) return;
  if (document.querySelector("dialog[open], .popup-menu")) return;
  const target = event.target;
  // Esc in the search field clears it first, as on the Mac.
  if (target instanceof HTMLInputElement && target.classList.contains("settings-search-input") && target.value) return;
  if (target instanceof HTMLTextAreaElement || (target instanceof HTMLInputElement && target.type !== "checkbox" && !target.classList.contains("settings-search-input"))) return;
  event.preventDefault();
  closeSettings();
});

function screenFrame(...children) {
  return h("div", { class: "screen ambient" }, h("div", { class: "glow one" }), h("div", { class: "glow two" }), h("main", { class: "screen-content" }, children));
}

function render(element) {
  catalog.close();
  state.renderToken += 1;
  document.title = "Aurelia";
  clear(root);
  root.append(element);
}

// MARK: Pairing

async function showPairing(note) {
  catalog.close();
  settings.closeEditors();
  stopSync();
  document.title = "Aurelia";
  const token = ++state.renderToken;
  // A server nobody owns yet is set up here instead, with the code from the server computer.
  try {
    if ((await api.webSetupStatus())?.open) return token === state.renderToken ? setupMove.choose() : undefined;
  } catch { /* Older servers have no browser setup; pairing works as before. */ }
  if (token !== state.renderToken) return;
  let busy = false;
  // Every Aurelia app pairs the same way: the main device shows the code, this browser types it.
  const field = h("input", {
    class: "pairing-code pairing-input",
    type: "text",
    inputmode: "numeric",
    // The code is shown as "0000 0000"; the space must not fail the browser's own check.
    pattern: "[0-9]{4} ?[0-9]{4}",
    maxlength: "9",
    autocomplete: "one-time-code",
    placeholder: "0000 0000",
    "aria-label": "Pairing code",
  });
  const message = h("p", { class: "error-text", role: "alert" }, note ?? "");
  const submit = h("button", { class: "primary-button", type: "submit", disabled: true }, "Sign In");
  field.addEventListener("input", () => {
    const digits = logic.pairingDigits(field.value);
    field.value = logic.formatCode(digits);
    submit.disabled = busy || digits.length !== 8;
  });
  const form = h("form", { class: "center-stack narrow", onsubmit: async (event) => {
    event.preventDefault();
    const digits = logic.pairingDigits(field.value);
    if (busy || digits.length !== 8) return;
    busy = true;
    submit.disabled = true;
    message.textContent = "";
    try {
      await api.redeemPairingCode(digits, logic.deviceName(navigator.userAgent, navigator.maxTouchPoints));
      if (token !== state.renderToken) return;
      return showProfiles();
    } catch (error) {
      if (token !== state.renderToken) return;
      if (error instanceof ApiError && error.offline) return showServerOff();
      message.textContent = error.code === "invalid_pairing_code"
        ? "This code is wrong, used or expired. Create a new one on your Mac or Linux computer."
        : error.code === "forbidden" || error.code === "pairing_disabled"
          ? "Signing in new devices is turned off on this server. Turn it on in Aurelia on the main device."
          : error.code === "https_required"
            ? "Open this page with the server’s https:// address to sign in."
            : error.message;
      field.value = "";
      field.focus();
    } finally {
      busy = false;
      submit.disabled = logic.pairingDigits(field.value).length !== 8;
    }
  } },
    h("img", { class: "brand-mark", src: "/web/icon.svg", alt: "" }),
    h("h1", {}, "Sign In to Aurelia"),
    h("p", {}, "Your Mac or Linux computer shows a code; you type it here."),
    h("ol", { class: "pairing-steps" },
      h("li", {}, "On the computer that runs Aurelia, open Settings › Profiles and Devices."),
      h("li", {}, "Click Create Code. On a Linux server without screen, run aurelia pair."),
      h("li", {}, "Type the 8 digits below. A code works once and for five minutes.")),
    field, message, h("div", { class: "button-row" }, submit),
    h("p", { class: "muted small" }, `Server: ${state.server?.name ?? "Aurelia"}`));
  clear(root);
  root.append(screenFrame(form));
  field.focus();
}

/**
 * Setting up a new server in this browser: the one-time code the server computer shows, then the
 * owner's name and Server Password. This browser becomes the first device; the viewing PIN and
 * the media folders come next.
 */
function showServerSetup() {
  const token = ++state.renderToken;
  const field = (label, control, note) => h("label", { class: "setup-field" }, h("span", {}, label), control, note ? h("span", { class: "muted small" }, note) : null);
  const code = h("input", { class: "text-field setup-code", autocomplete: "off", spellcheck: "false", placeholder: "ABCDE-FGHJK", "aria-label": "Setup code" });
  const owner = h("input", { class: "text-field", autocomplete: "username", maxlength: "64", "aria-label": "Owner name" });
  const password = h("input", { class: "text-field", type: "password", autocomplete: "new-password", "aria-label": "Server Password" });
  const repeat = h("input", { class: "text-field", type: "password", autocomplete: "new-password", "aria-label": "Repeat Server Password" });
  const message = h("p", { class: "error-text", role: "alert" });
  const submit = h("button", { class: "primary-button large", type: "submit", disabled: true }, "Set Up Aurelia");
  const values = () => ({ code: code.value, ownerName: owner.value, password: password.value, repeat: repeat.value });
  const check = () => { submit.disabled = Boolean(logic.setupProblem(values())); };
  code.addEventListener("input", () => { code.value = logic.setupCode(code.value); check(); });
  for (const input of [owner, password, repeat]) input.addEventListener("input", check);
  let busy = false;
  const form = h("form", { class: "setup-card", onsubmit: async (event) => {
    event.preventDefault();
    const problem = logic.setupProblem(values());
    if (busy || problem) { message.textContent = problem ?? ""; return; }
    busy = true;
    submit.disabled = true;
    message.textContent = "";
    try {
      await api.webSetup({ code: code.value, ownerName: owner.value.trim(), password: password.value,
        deviceName: logic.deviceName(navigator.userAgent, navigator.maxTouchPoints) });
      password.value = repeat.value = "";
      try { sessionStorage.setItem("aurelia.welcome", "1"); } catch { /* The welcome page is optional. */ }
      if (token === state.renderToken) return showProfiles("Choose your profile and give it a viewing PIN.");
    } catch (error) {
      if (token !== state.renderToken) return;
      if (error instanceof ApiError && error.offline) return showServerOff();
      message.textContent = error.code === "setup_code_invalid"
        ? "That code is not right. On the server computer, run: sudo aurelia setup --browser"
        : error.code === "server_already_setup" ? "This server already has an owner. Ask them for a code to sign in." : error.message;
      if (error.code === "server_already_setup") return setTimeout(() => showPairing(), 2500);
    } finally {
      busy = false;
      check();
    }
  } },
    h("img", { class: "brand-mark", src: "/web/icon.svg", alt: "" }),
    h("h1", {}, "Set Up Your Aurelia Server"),
    h("p", {}, `“${state.server?.name ?? "Aurelia"}” has no owner yet. The server computer shows a one-time code; with it, this browser creates the owner.`),
    h("ol", { class: "pairing-steps" },
      h("li", {}, "On the server computer, run: sudo aurelia setup --browser"),
      h("li", {}, "In Docker: docker compose exec aurelia aurelia setup-code"),
      h("li", {}, "Type the code below and choose the owner’s name and Server Password.")),
    field("Setup Code", code),
    field("Owner Name", owner, "The owner manages the server. You choose a viewing PIN next."),
    field("Server Password", password, "At least 12 characters. It protects server changes like removing titles or restoring backups."),
    field("Repeat Server Password", repeat),
    message, h("div", { class: "button-row" }, h("button", { type: "button", class: "secondary-button", onclick: () => setupMove.choose() }, "Back"), submit));
  clear(root);
  root.append(screenFrame(form));
  code.focus();
}

// Moving from another Aurelia server, as the other way to set up a server nobody owns yet.
const setupMove = createSetupMove({
  api,
  show: (element) => {
    catalog.close();
    const token = ++state.renderToken;
    clear(root);
    root.append(screenFrame(element));
    return token;
  },
  current: (token) => token === state.renderToken,
  showPairing: (note) => showPairing(note),
  showServerOff: () => showServerOff(),
  newServerSetup: () => showServerSetup(),
  serverName: () => state.server?.name ?? "Aurelia",
});

/** Every page gives way to the notice of a server that moved (409 server_moved or its info). */
function showServerMoved(destination) {
  if (!destination || (state.movedToken && state.movedToken === state.renderToken)) return;
  catalog.close();
  settings.closeEditors();
  stopSync();
  closeMiniRemote();
  closePlayer();
  state.profile = null;
  document.title = "Aurelia";
  const token = ++state.renderToken;
  state.movedToken = token;
  clear(root);
  root.append(screenFrame(movedNotice({ api, destination, onUndone: () => {
    state.movedToken = null;
    toast("The move is undone. This server is back.");
    start();
  } })));
}

// MARK: Profiles

async function showProfiles(note) {
  catalog.close();
  settings.closeEditors();
  stopSync();
  closePlayer();
  state.profile = null;
  markTabProfile(false);
  document.title = "Aurelia";
  const token = ++state.renderToken;
  let picker;
  try {
    picker = await api.profiles();
  } catch (error) {
    if (token !== state.renderToken) return;
    if (error instanceof ApiError && error.offline) return showServerOff();
    return showPairing();
  }
  if (token !== state.renderToken) return;
  const firstPin = picker.managementSetupRequired;
  const list = h("div", { class: "profile-grid" }, picker.profiles.map((profile) => {
    // Screen time closes a children's profile until its wake time ("Good night · back at 07:00").
    const asleep = closedLabel(profile);
    return h("button", { class: `profile-entry${asleep ? " asleep" : ""}`,
      onclick: () => asleep ? showProfiles(`${profile.name} is asleep. Aurelia opens again at ${clockTime(profile.closedUntil)}.`)
        : firstPin && profile.role === "owner" ? showFirstPin(profile) : chooseProfile(profile) },
      profilePicture(profile, "large"),
      h("span", { class: "profile-name" }, profile.name, asleep ? icon("moonFill", { size: 14, label: "Good night" })
        : profile.pinProtectionEnabled ? icon("lock", { size: 14, label: "PIN protected" }) : null),
      asleep ? h("span", { class: "profile-asleep muted small" }, asleep) : null);
  }));
  const message = h("p", { class: "error-text", role: "alert" }, note ?? "");
  if (firstPin && !note) message.textContent = picker.profiles.some((profile) => profile.role === "owner")
    ? "Choose the owner’s profile to give it a viewing PIN."
    : "Finish setting up profiles in Aurelia on your Mac first.";
  clear(root);
  root.append(screenFrame(h("div", { class: "center-stack wide" },
    h("h1", { class: "picker-title" }, "Who’s watching?"),
    list, message,
    h("button", { class: "link-button", onclick: () => confirmSignOut() }, "Sign Out of This Browser"))));
  list.querySelector("button")?.focus();
}

const photoUrls = new Map();

/** A picture as a data: address; the page's security policy allows data: images, not blob: ones. */
function pictureAddress(blob) {
  return new Promise((resolve) => {
    const reader = new FileReader();
    reader.onload = () => resolve(typeof reader.result === "string" ? reader.result : null);
    reader.onerror = () => resolve(null);
    reader.readAsDataURL(blob);
  });
}

/**
 * A round profile picture: the profile's photo, a built-in picture (a symbol on a palette), or its
 * initial on the gradient every client gives that profile. `person` is a user or picker profile.
 */
function profilePicture(person, size = "small") {
  const id = person?.id;
  const name = logic.shownName(person);
  const builtin = logic.parsePicture(person?.pictureKey);
  const palette = builtin ? builtin.paletteIndex : logic.profileColorIndex(id);
  const picture = h("span", { class: `profile-picture ${size} palette-${palette}`, "aria-hidden": "true" });
  if (builtin) {
    const svg = document.createElementNS(SVG, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("class", "profile-symbol");
    const shape = document.createElementNS(SVG, "path");
    shape.setAttribute("d", PROFILE_SYMBOL_PATHS[builtin.symbol]);
    shape.setAttribute("fill-rule", "evenodd");
    svg.append(shape);
    picture.append(svg);
    return picture;
  }
  picture.append(logic.initial(name));
  if (person?.pictureKey === logic.PHOTO_PICTURE && id) {
    const key = `${id}-${person.pictureRevision ?? 0}`;
    const show = (url) => {
      picture.textContent = "";
      picture.append(h("img", { class: "profile-photo", src: url, alt: "" }));
    };
    if (photoUrls.has(key)) {
      photoUrls.get(key).then((url) => url && show(url));
    } else {
      const loading = api.profilePhoto(id, person.pictureRevision ?? 0).then((blob) => pictureAddress(blob)).catch(() => null);
      photoUrls.set(key, loading);
      loading.then((url) => url && show(url));
    }
  }
  return picture;
}

/** Keeps a just-uploaded photo so it shows at once. */
function rememberPhoto(person, file) {
  photoUrls.set(`${person.id}-${person.pictureRevision ?? 0}`, pictureAddress(file));
}

/** The profile changed its name or picture in Settings. */
function updateProfile(user) {
  if (!state.profile || state.profile.id !== user.id) return;
  state.profile = { ...state.profile, ...user };
  renderRoute({ quiet: true });
}

async function chooseProfile(profile) {
  if (profile.needsPinSetup) return showProfiles(`${profile.name} needs a PIN first. Set it up in Aurelia on the Mac.`);
  if (!profile.pinProtectionEnabled) return unlock(profile, null).catch((error) => showProfiles(error.message));
  showPin(profile);
}

async function unlock(profile, pin) {
  try {
    const session = await api.unlockProfile(profile.id, pin);
    return enterProfile(session.user);
  } catch (error) {
    if (error instanceof ApiError && error.offline) return showServerOff();
    if (error instanceof ApiError && error.status === 401 && error.code !== "invalid_profile_pin") return showPairing();
    throw error;
  }
}

function showPin(profile) {
  state.renderToken += 1;
  let busy = false;
  // A real field: a computer's keyboard types into it, and a phone or tablet shows its own
  // number keyboard. Its dots show only what was typed, never how long the PIN is.
  const field = h("input", {
    class: "pin-input",
    type: "password",
    inputmode: "numeric",
    pattern: "[0-9]*",
    maxlength: "8",
    autocomplete: "off",
    placeholder: "PIN",
    "aria-label": "PIN",
  });
  const message = h("p", { class: "error-text", role: "alert" });
  const confirm = h("button", { class: "pin-submit", type: "submit", "aria-label": "Unlock", disabled: true }, icon("arrow", { size: 18 }));
  const shake = () => {
    field.classList.remove("shake");
    void field.offsetWidth;
    field.classList.add("shake");
  };
  const failed = (text) => {
    field.value = "";
    message.textContent = text;
    shake();
    field.focus();
  };
  const submit = async () => {
    if (busy) return;
    const pin = field.value;
    if (!logic.isPin(pin)) return failed(pin.length > 0 ? logic.PIN_INCORRECT : "");
    message.textContent = "";
    busy = true;
    confirm.disabled = true;
    field.readOnly = true;
    try {
      await unlock(profile, pin);
    } catch (error) {
      busy = false;
      field.readOnly = false;
      failed(error instanceof ApiError && error.code === "invalid_profile_pin"
        ? logic.PIN_INCORRECT
        : error instanceof ApiError && error.status === 429 ? "Too many tries. Wait a minute, then try again." : error.message);
    }
  };
  field.addEventListener("input", () => {
    const digits = field.value.replace(/[^0-9]/g, "").slice(0, 8);
    if (digits !== field.value) field.value = digits;
    confirm.disabled = digits.length < 4;
    message.textContent = "";
  });
  field.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    event.preventDefault();
    showProfiles();
  });
  // As on the Mac: the profile, "Enter your PIN" and one round field with its arrow inside.
  const form = h("form", { class: "pin-form", onsubmit: (event) => {
    event.preventDefault();
    submit();
  } }, field, confirm);
  clear(root);
  root.append(screenFrame(h("div", { class: "center-stack pin-layout" },
    h("button", { class: "profile-back", type: "button", onclick: () => showProfiles(), "aria-label": `${profile.name}, back to profiles` },
      profilePicture(profile, "large"), h("span", { class: "profile-name pin-name" }, profile.name)),
    h("p", { class: "muted pin-prompt" }, "Enter your PIN"),
    form,
    message,
    h("button", { class: "link-button", type: "button", onclick: () => openSheet({
      symbol: "lock", title: "Forgot PIN?", subtitle: logic.forgotPinMessage(profile.role), primary: "OK", cancel: null,
    }) }, "Forgot PIN?"))));
  field.focus();
}

/**
 * The owner's first viewing PIN, right after setting up the server in this browser, as the Mac's
 * setup assistant asks for it: the Server Password confirms it is the owner, then the PIN twice.
 */
function showFirstPin(profile) {
  const token = ++state.renderToken;
  const field = (label, control) => h("label", { class: "setup-field" }, h("span", {}, label), control);
  const password = h("input", { class: "text-field", type: "password", autocomplete: "current-password", "aria-label": "Server Password" });
  const digits = (label) => h("input", { class: "text-field", type: "password", inputmode: "numeric", pattern: "[0-9]*", maxlength: "8", autocomplete: "off", "aria-label": label });
  const pin = digits("Viewing PIN");
  const repeat = digits("Repeat Viewing PIN");
  const message = h("p", { class: "error-text", role: "alert" });
  const submit = h("button", { class: "primary-button large", type: "submit", disabled: true }, "Save PIN");
  const check = () => { submit.disabled = !password.value || !logic.isPin(pin.value) || pin.value !== repeat.value; };
  password.addEventListener("input", check);
  for (const input of [pin, repeat]) input.addEventListener("input", () => { input.value = input.value.replace(/[^0-9]/g, "").slice(0, 8); check(); });
  let busy = false;
  const form = h("form", { class: "setup-card", onsubmit: async (event) => {
    event.preventDefault();
    if (busy || submit.disabled) return;
    busy = true;
    submit.disabled = true;
    message.textContent = "";
    try {
      await api.initializeProfiles(password.value, pin.value);
      const chosen = pin.value;
      const secret = password.value;
      password.value = pin.value = repeat.value = "";
      if (token !== state.renderToken) return;
      // The Server Password was just typed, so the welcome steps (adding folders) need no
      // second unlock.
      const session = await api.unlockProfile(profile.id, chosen);
      await api.unlockManagement(secret).catch(() => {});
      await enterProfile(session.user);
    } catch (error) {
      if (token !== state.renderToken) return;
      if (error instanceof ApiError && error.offline) return showServerOff();
      message.textContent = error instanceof ApiError && (error.code === "invalid_credentials" || error.status === 401)
        ? "That Server Password is not right." : error.message;
    } finally {
      busy = false;
      check();
    }
  } },
    profilePicture(profile, "large"),
    h("h1", {}, "Choose a Viewing PIN"),
    h("p", {}, `${profile.name} opens with this PIN on every device. Enter the Server Password you just chose to confirm it is you.`),
    field("Server Password", password),
    field("Viewing PIN (4–8 digits)", pin),
    field("Repeat Viewing PIN", repeat),
    message,
    h("div", { class: "button-row" },
      h("button", { class: "secondary-button", type: "button", onclick: () => showProfiles() }, "Back"), submit));
  clear(root);
  root.append(screenFrame(form));
  password.focus();
}

async function enterProfile(user) {
  reads.clear();
  prefetches.forget();
  try {
    if (sessionStorage.getItem("aurelia.welcome") === "1" && logic.managementPermissions(user).owner) {
      sessionStorage.removeItem("aurelia.welcome");
      history.replaceState(null, "", "/welcome");
      state.route = { name: "welcome" };
    }
  } catch { /* Without storage there is no welcome page; Settings has everything. */ }
  state.profile = user;
  markTabProfile(true);
  state.watchlistIds = new Set();
  state.wishSummary = null;
  wishes.reset();
  api.watchlist().then((response) => {
    if (state.profile?.id === user.id) state.watchlistIds = new Set(response?.mediaIds ?? []);
  }).catch(() => {});
  void refreshWishSummary();
  startSync();
  renderRoute();
}

function confirmSignOut() {
  const dialog = h("dialog", { class: "sheet" },
    h("h2", {}, "Sign out of this browser?"),
    h("p", {}, "To use Aurelia here again, you need a new code from the Mac or Linux computer that runs Aurelia."),
    h("div", { class: "button-row end" },
      h("button", { class: "secondary-button", onclick: () => dialog.close() }, "Cancel"),
      h("button", { class: "danger-button", onclick: async () => {
        dialog.close();
        await signOut();
      } }, "Sign Out")));
  dialog.addEventListener("close", () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
}

function showShortcutsDialog() {
  document.querySelector(".shortcuts-sheet")?.remove();
  const dialog = h("dialog", { class: "sheet shortcuts-sheet", "aria-labelledby": "shortcuts-title" },
    h("div", { class: "shortcuts-header" },
      h("h2", { id: "shortcuts-title" }, "Keyboard Shortcuts"),
      h("button", { class: "icon-button close-button", "aria-label": "Close", onclick: () => dialog.close() }, icon("close", { size: 18 }))),
    h("div", { class: "shortcuts-body" },
      logic.KEYBOARD_SHORTCUTS.map((section) =>
        h("section", { class: "shortcuts-group" },
          h("h3", {}, section.group),
          h("ul", { class: "shortcuts-list" },
            section.items.map((item) =>
              h("li", { class: "shortcut-row" },
                h("span", { class: "shortcut-action" }, item.action),
                h("span", { class: "shortcut-keys" },
                  item.keys.map((key) => h("kbd", { class: "shortcut-key" }, key))))))))));
  dialog.addEventListener("close", () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
}

async function signOut() {
  scrollMemory.clear();
  settings.closeEditors();
  stopSync();
  closeMiniRemote();
  closePlayer();
  await movieNight.leave();
  try {
    await api.signOut();
  } catch {
    // The cookies are cleared by the server's answer; without one, the next start asks again.
  }
  state.profile = null;
  showPairing();
}

async function switchProfile() {
  scrollMemory.clear();
  settings.closeEditors();
  stopSync();
  closeMiniRemote();
  closePlayer();
  state.wishSummary = null;
  wishes.reset();
  await movieNight.leave();
  try {
    await api.endProfile();
  } catch {
    // Ending is best effort: the profile session also ends after twelve hours or on restart.
  }
  showProfiles();
}

/** A profile request was refused: the profile session ended, or the whole browser was signed out. */
async function sessionEnded() {
  scrollMemory.clear();
  catalog.close();
  settings.closeEditors();
  stopSync();
  closeMiniRemote();
  closePlayer();
  state.wishSummary = null;
  wishes.reset();
  state.profile = null;
  try {
    await api.profiles();
    showProfiles("Your profile session ended. Choose your profile again.");
  } catch (error) {
    if (error instanceof ApiError && error.offline) return showServerOff();
    showPairing("This browser was signed out. Ask the owner for a new code.");
  }
}

function handleError(error) {
  if (error instanceof ApiError && logic.sessionRefused(error.status, error.code)) {
    sessionEnded();
    return true;
  }
  if (error instanceof ApiError && error.offline) {
    showServerOff();
    return true;
  }
  return false;
}

// MARK: Navigation

function navigate(route, { replace = false, quiet = false } = {}) {
  settings.closeEditors();
  endTour();
  state.settingsDirty = false;
  // Settings is a layer over the page it was opened from; Done goes back there.
  if (route.name === "settings" && state.route.name !== "settings") state.beforeSettings = logic.routePath(state.route) || "/";
  if (route.name !== "settings" && state.route.name === "settings") settings.endSearch();
  const currentPath = logic.routePath(state.route) || (location.pathname + location.search);
  const path = logic.routePath(route);
  // The page that is already open, chosen again: it only scrolls back to the top, as in the Mac app.
  if (!replace && path === currentPath && route.name === state.route.name) {
    window.scrollTo({ top: 0, behavior: motionAllowed() ? "smooth" : "auto" });
    return;
  }
  if (!replace) scrollMemory.remember(currentPath, window.scrollY);
  const inPlace = !replace && route.name === "settings" && state.route.name === "settings";
  if (replace) history.replaceState(null, "", path);
  else if (path !== location.pathname + location.search) history.pushState(null, "", path);
  state.route = route;
  renderRoute({ quiet, resetScroll: !replace, inPlace });
}

window.addEventListener("popstate", () => {
  // Back closes whatever sheet is open; it never stays over the page returned to (audit S19).
  document.querySelectorAll("dialog[open]").forEach((dialog) => dialog.close());
  settings.closeEditors();
  if (!state.profile) return;
  closePlayer();
  state.route = logic.parseRoute(location.pathname, location.search);
  renderRoute({ restoreScroll: true });
});

// Links inside the app change the screen without reloading the page.
document.addEventListener("click", (event) => {
  const link = event.target.closest?.("a[data-route]");
  if (!link || event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return;
  event.preventDefault();
  navigate(logic.parseRoute(link.getAttribute("href").split("?")[0], link.getAttribute("href").split("?")[1] ?? ""));
});

// Pointing at a title loads its page already, so the click opens it at once.
let prefetchTimer = 0;
document.addEventListener("pointerover", (event) => {
  const link = event.target.closest?.("a[href^='/title/']");
  clearTimeout(prefetchTimer);
  if (!link || !state.profile || state.player) return;
  const id = link.getAttribute("href").slice("/title/".length).split(/[?#/]/)[0];
  if (!id || reads.has(`detail:${id}`)) return;
  prefetchTimer = setTimeout(() => {
    prefetches.start(id, () => Promise.all([cached.detail(id).then((detail) => { warmBackdrop(detail); return detail; }), cached.playbackPlan(id).catch(() => null)]));
  }, event.pointerType === "touch" ? 0 : 90);
}, { passive: true });

/** Starts loading a title's big picture, so its page can open with it. */
function warmBackdrop(detail) {
  const item = detail?.item;
  const url = logic.artworkUrl(item?.backdrop ?? detail?.metadata?.backdrop ?? item?.poster, heroWidth());
  if (!url || shownArtwork.has(url)) return;
  const image = new Image();
  image.decoding = "async";
  image.src = url;
}


// The sidebar's look in this browser: hidden or shown, and how wide (210–300, as on the Mac).
const SIDEBAR_KEY = "aurelia.sidebar";
function sidebarLayout() {
  try {
    const saved = JSON.parse(localStorage.getItem(SIDEBAR_KEY) ?? "{}");
    return { hidden: saved.hidden === true, width: Math.min(300, Math.max(210, Number(saved.width) || 236)) };
  } catch { return { hidden: false, width: 236 }; }
}
function saveSidebarLayout(layout) {
  try { localStorage.setItem(SIDEBAR_KEY, JSON.stringify(layout)); } catch { /* Kept for this visit only. */ }
}
document.documentElement.style.setProperty("--sidebar", `${sidebarLayout().width}px`);

const SIDEBAR_SYMBOLS = { home: "home", search: "search", library: "library", watchlist: "bookmark", recent: "clock", shows: "tv", movies: "film",
  collections: "collections", people: "people", wishes: "gift", history: "history", statistics: "chart", "movie-night": "cards" };

/**
 * The Mac app's sidebar (audit D1): Search and Home, the library's sections in the order chosen in
 * Settings › General, Wishes, then History, Statistics and Movie Night; the profile and Settings at
 * its foot. Below 760 px it is a drawer that the round button at the top left opens.
 */
function shell(content) {
  const labels = Object.fromEntries(logic.TOP_BAR_SECTIONS);
  const general = loadGeneral();
  const places = [["search", "Search", "/search"], ["home", "Home", "/"], ...general.sectionOrder.map((name) => [name, labels[name], `/${name}`])]
    .filter(([name]) => sidebarShows(name, general));
  // People ("people-v1"): everyone in the library's credits, with search.
  if (supportsPeople(state.server)) places.push(["people", "People", "/people"]);
  const hasWishes = supportsWishes(state.server);
  if (hasWishes) places.push(["wishes", "Wishes", "/wishes"]);
  const yours = [["history", "History", "/history"], ["statistics", "Statistics", "/statistics"], ["movie-night", "Movie Night", "/movie-night"]];
  const badgeCount = hasWishes ? wishBadgeCount(state.wishSummary, state.profile) : 0;
  const wishBadge = () => h("span", { class: "nav-badge", "data-wish-badge": true, hidden: badgeCount <= 0 }, badgeCount > 0 ? String(badgeCount) : "");
  const current = state.route.name === "person" || state.route.name === "title" || state.route.name === "collection" ? null : state.route.name;
  const layout = sidebarLayout();
  const frame = h("div", { class: `app-shell${layout.hidden ? " sidebar-hidden" : ""}` });
  const closeDrawer = () => frame.classList.remove("drawer-open");
  const item = ([name, label, href]) => h("a", { class: `sidebar-item${current === name ? " selected" : ""}`, href, "data-route": true,
    "aria-current": current === name ? "page" : null, onclick: closeDrawer },
    icon(SIDEBAR_SYMBOLS[name] ?? "library", { size: 17 }), h("span", {}, label), name === "wishes" ? wishBadge() : null);

  const menu = h("div", { class: "profile-menu", role: "menu", hidden: true, "aria-label": "Profile" },
    h("div", { class: "menu-header" }, profilePicture(state.profile), h("span", {}, logic.shownName(state.profile))),
    h("button", { class: "menu-item", role: "menuitem", onclick: () => { closeMenu(); showShortcutsDialog(); } }, "Keyboard Shortcuts"),
    h("button", { class: "menu-item", role: "menuitem", onclick: () => { closeMenu(); switchProfile(); } }, "Switch Profile"),
    h("button", { class: "menu-item danger", role: "menuitem", onclick: () => { closeMenu(); confirmSignOut(); } }, "Sign Out of This Browser"));
  const profileButton = h("button", { class: "sidebar-profile", "aria-haspopup": "menu", "aria-expanded": "false",
    "aria-label": `${logic.shownName(state.profile)}, profile menu` }, profilePicture(state.profile), h("span", {}, logic.shownName(state.profile)));
  // Esc and any click outside close the menu; focus returns to its button (audit L10, W9).
  const outside = (event) => { if (!menu.contains(event.target) && event.target !== profileButton) closeMenu(); };
  const keys = (event) => {
    if (event.key === "Escape") { event.preventDefault(); closeMenu(); profileButton.focus(); }
    else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const entries = [...menu.querySelectorAll(".menu-item")];
      const at = entries.indexOf(document.activeElement);
      entries[(at + (event.key === "ArrowDown" ? 1 : entries.length - 1)) % entries.length]?.focus();
    }
  };
  function closeMenu() {
    if (menu.hidden) return;
    menu.hidden = true;
    profileButton.setAttribute("aria-expanded", "false");
    document.removeEventListener("click", outside, true);
    document.removeEventListener("keydown", keys, true);
  }
  profileButton.addEventListener("click", () => {
    if (!menu.hidden) return closeMenu();
    menu.hidden = false;
    profileButton.setAttribute("aria-expanded", "true");
    menu.querySelector(".menu-item")?.focus();
    document.addEventListener("click", outside, true);
    document.addEventListener("keydown", keys, true);
  });

  const setHidden = (hidden) => {
    frame.classList.toggle("sidebar-hidden", hidden);
    saveSidebarLayout({ ...sidebarLayout(), hidden });
  };
  const narrow = () => window.matchMedia?.("(max-width: 760px)")?.matches;
  const hide = h("button", { class: "sidebar-toggle", "aria-label": "Hide Sidebar", title: "Hide Sidebar", onclick: () => setHidden(true) }, icon("sidebar", { size: 16 }));
  const show = h("button", { class: "sidebar-toggle sidebar-show", "aria-label": "Show Sidebar", title: "Show Sidebar",
    onclick: () => narrow() ? frame.classList.add("drawer-open") : setHidden(false) }, icon("sidebar", { size: 16 }));
  // Dragging the sidebar's edge sets its width, as on the Mac.
  const handle = h("div", { class: "sidebar-resize", role: "separator", "aria-orientation": "vertical", "aria-label": "Sidebar Width" });
  handle.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    handle.setPointerCapture(event.pointerId);
    const move = (moved) => document.documentElement.style.setProperty("--sidebar", `${Math.min(300, Math.max(210, Math.round(moved.clientX)))}px`);
    const end = () => {
      handle.removeEventListener("pointermove", move);
      saveSidebarLayout({ ...sidebarLayout(), width: parseInt(getComputedStyle(document.documentElement).getPropertyValue("--sidebar"), 10) || 236 });
    };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", end, { once: true });
    handle.addEventListener("pointercancel", end, { once: true });
  });
  const sidebar = h("aside", { class: "sidebar", "aria-label": "Library" },
    h("div", { class: "sidebar-head" }, hide),
    h("nav", { class: "sidebar-list", "aria-label": "Library" },
      places.map(item),
      h("div", { class: "sidebar-heading" }, "Yours"),
      yours.map(item)),
    h("div", { class: "sidebar-foot" },
      h("div", { class: "menu-anchor", style: { flex: "1", minWidth: "0", display: "flex" } }, profileButton, menu),
      h("a", { class: `sidebar-gear${state.route.name === "settings" ? " selected" : ""}`, href: "/settings", "data-route": true, "aria-label": "Settings", title: "Settings", onclick: closeDrawer }, icon("gear", { size: 17 }))),
    handle);
  frame.append(sidebar, h("div", { class: "sidebar-backdrop", onclick: closeDrawer }), show, h("main", { class: "page", id: "page" }, content));
  return frame;
}

/** Waits a very short moment for the page's big picture, so it usually arrives with its page. */
function heroReady(content) {
  const art = content?.querySelector?.(".detail-hero img.hero-art, .hero img.hero-art");
  if (!art || art.classList.contains("loaded") || typeof art.decode !== "function") return Promise.resolve();
  return Promise.race([art.decode().catch(() => {}), new Promise((resolve) => setTimeout(resolve, 150))]);
}

/** Whether pages may move: the system's and this browser's Reduce Motion both keep them still. */
function motionAllowed() {
  return !window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches && document.body.dataset.heroMotion !== "reduced";
}

/** The horizontal rails' positions, so a page built again in place keeps them (audit L4). */
function railPositions() {
  return [...root.querySelectorAll(".rail-track, .hrail-track")].map((track) => track.scrollLeft);
}
function restoreRails(positions) {
  const tracks = root.querySelectorAll(".rail-track, .hrail-track");
  positions.forEach((left, index) => { if (tracks[index] && left) tracks[index].scrollLeft = left; });
}

/**
 * Whether a page may be built again in place now. Not while someone types or has changed
 * something not yet saved (Settings), not in a hidden tab (it catches up when shown), and not on
 * pages whose lists grow as you scroll (they show the change when opened next) (audit L4, S3).
 */
function mayRefreshInPlace() {
  if (document.hidden) return false;
  const active = document.activeElement;
  if (active && (active.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(active.tagName) && active.type !== "range" && active.type !== "checkbox")) return false;
  if (state.route.name === "settings" && state.settingsDirty) return false;
  if (["library", "recent", "movies", "shows", "search", "collections"].includes(state.route.name) && window.scrollY > 200) return false;
  return true;
}

/** Puts the page in place: the library pages in the sidebar's shell, Settings as its own layer. */
function placePage(route, content) {
  // Sheets that belong to the page that leaves close with it (audit S19).
  dispatchEvent(new Event("aurelia:page"));
  clear(root);
  if (route.name === "settings") {
    const layer = h("div", { class: "settings-layer", id: "page" }, content);
    // Something typed or chosen and not saved yet keeps the page from being built again.
    layer.addEventListener("input", (event) => { if (!event.target.closest?.(".settings-search-input")) state.settingsDirty = true; });
    root.append(layer);
    return;
  }
  root.append(shell(content));
}

/**
 * Builds the route's page and puts it in place. A page that answers within 200 ms replaces the old
 * one directly; a slower one shows a small turning ring first (audit D9). There is no page
 * animation beyond a short fade (audit P1). A quiet refresh (the server reported a change, the tab
 * came back) builds the same page again where it was: scroll position, rails and the chosen
 * season stay.
 */
async function renderRoute({ quiet = false, restoreScroll = false, resetScroll = false, inPlace = false } = {}) {
  catalog.close();
  if (!state.profile) return;
  isRenderingRoute = true;
  const route = state.route;
  const token = ++state.renderToken;
  const path = logic.routePath(route) || (location.pathname + location.search);
  const targetScroll = restoreScroll ? scrollMemory.recall(path) : null;
  const scroll = quiet ? window.scrollY : (targetScroll ?? 0);
  const rails = quiet ? railPositions() : [];
  if (route.name !== "settings") state.settingsDirty = false;
  // A series opened anew shows the season of what plays next; built again or returned to, the
  // season chosen there.
  if (route.name === "title" && !quiet && !restoreScroll && !inPlace) seasonChoice.delete(route.id);
  if (quiet) state.quietRefresh = true;
  // Some screens are built at once, others load first; both count the same here.
  const loading = Promise.resolve().then(() => screenFor(route, token)).then((content) => ({ content }), (error) => ({ error }));
  let outcome = quiet || inPlace ? await loading : await Promise.race([loading, new Promise((resolve) => setTimeout(resolve, 200))]);
  if (quiet) state.quietRefresh = false;
  if (!outcome) {
    if (token !== state.renderToken) return;
    placePage(route, h("div", { class: "page-loading", role: "status", "aria-label": "Loading" }, h("div", { class: "spinner visible" })));
    if (resetScroll || restoreScroll) window.scrollTo(0, 0);
    outcome = await loading;
  }
  let content = outcome.content;
  if (outcome.error) {
    if (token !== state.renderToken) return;
    isRenderingRoute = false;
    if (handleError(outcome.error)) return;
    // A quiet refresh that fails keeps the page as it was.
    if (quiet && root.querySelector("#page")) return;
    content = emptyState("warning", "Couldn’t Load This Page", outcome.error.message, h("button", { class: "secondary-button", onclick: () => renderRoute() }, "Try Again"));
  }
  if (token !== state.renderToken || !content) {
    isRenderingRoute = false;
    return;
  }
  if (!quiet && !inPlace) {
    await heroReady(content);
    if (token !== state.renderToken) {
      isRenderingRoute = false;
      return;
    }
  }
  placePage(route, content);
  if (quiet || inPlace) root.querySelector(".app-shell")?.classList.add("still");
  if (quiet || restoreScroll) {
    window.scrollTo(0, scroll);
    restoreRails(rails);
    if (typeof requestAnimationFrame === "function") requestAnimationFrame(() => { window.scrollTo(0, scroll); restoreRails(rails); });
  } else if (resetScroll) {
    window.scrollTo(0, 0);
  }
  // Another settings page fades in where the last one was; the list stays still.
  if (inPlace) root.querySelector(".settings-content")?.classList.add("swap-in");
  isRenderingRoute = false;
  if (route.name === "home" && !quiet && logic.tourPending(safeStorage())) setTimeout(() => startTour(), 600);
  // The tab's title is set only for the page that is really shown (audit L13).
  const label = { home: "Home", library: "Library", watchlist: "Watchlist", recent: "Recently Added", movies: "Movies", shows: "TV Shows", search: "Search", collections: "Collections", history: "Watch History", statistics: "Statistics", settings: "Settings", "movie-night": "Movie Night", wishes: "Wishes", people: "People" }[route.name];
  const named = content.dataset?.pageTitle ?? label;
  if (named) document.title = `${named} · Aurelia`;
}

// MARK: Tour

let tour = null;

function safeStorage() {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

/**
 * The short tour on the first sign-in in this browser: the page dims around one place and a note
 * explains it. Next or Enter moves on; Skip Tour, Esc or opening another page ends it.
 */
function startTour() {
  if (tour || !state.profile) return;
  logic.markTourSeen(safeStorage());
  let index = 0;
  const ring = h("div", { class: "tour-ring", "aria-hidden": "true" });
  const title = h("h2", { class: "tour-title", id: "tour-title" });
  const text = h("p", { class: "tour-text" });
  const counter = h("span", { class: "muted small" });
  const next = h("button", { class: "primary-button", onclick: () => advance() }, "Next");
  const bubble = h("div", { class: "tour-bubble", role: "dialog", "aria-modal": "false", "aria-labelledby": "tour-title" },
    title, text,
    h("div", { class: "tour-actions" }, counter,
      h("button", { class: "link-button", onclick: () => endTour() }, "Skip Tour"), next));
  const layer = h("div", { class: "tour-layer" }, ring, bubble);
  // Measures the target after the page has scrolled to it; the fixed ring follows scrolling.
  let target = null;
  const measure = () => {
    const viewport = { width: window.innerWidth, height: window.innerHeight };
    const hole = target ? logic.tourHole(target.getBoundingClientRect(), viewport) : null;
    ring.hidden = !hole;
    layer.classList.toggle("dimmed", !hole);
    if (hole) Object.assign(ring.style, { left: `${hole.left}px`, top: `${hole.top}px`, width: `${hole.right - hole.left}px`, height: `${hole.bottom - hole.top}px` });
    const position = logic.tourBubblePosition(hole, viewport, { width: Math.min(320, viewport.width - 32), height: bubble.offsetHeight || 170 });
    Object.assign(bubble.style, { left: `${position.x}px`, top: `${position.y}px` });
  };
  const place = () => {
    const stop = logic.TOUR_STOPS[index];
    const candidates = [...document.querySelectorAll(stop.target)];
    const topInset = 0;
    const viewport = { width: window.innerWidth, height: window.innerHeight };
    target = candidates[logic.visibleTourTarget(candidates.map((element) => element.getBoundingClientRect()), viewport, topInset)] ?? null;
    if (target) {
      const rect = target.getBoundingClientRect();
      if (rect.top < topInset || rect.bottom > viewport.height) target.scrollIntoView?.({ block: "center", inline: "nearest", behavior: "instant" });
    }
    requestAnimationFrame(measure);
  };
  let pending = 0;
  const follow = () => {
    if (pending) return;
    pending = requestAnimationFrame(() => { pending = 0; measure(); });
  };
  const show = () => {
    const stop = logic.TOUR_STOPS[index];
    title.textContent = stop.title;
    text.textContent = stop.text;
    counter.textContent = `${index + 1} of ${logic.TOUR_STOPS.length}`;
    next.textContent = index === logic.TOUR_STOPS.length - 1 ? "Done" : "Next";
    place();
    next.focus();
  };
  const advance = () => {
    index += 1;
    if (index >= logic.TOUR_STOPS.length) endTour();
    else show();
  };
  const keys = (event) => {
    if (event.key === "Escape") endTour();
    else if (event.key === "Enter" && document.activeElement !== next) advance();
    else return;
    event.preventDefault();
  };
  document.addEventListener("keydown", keys);
  window.addEventListener("resize", place);
  window.addEventListener("scroll", follow, { passive: true, capture: true });
  tour = { layer, close: () => {
    document.removeEventListener("keydown", keys);
    window.removeEventListener("resize", place);
    window.removeEventListener("scroll", follow, { capture: true });
    if (pending) cancelAnimationFrame(pending);
    layer.remove();
  } };
  document.body.append(layer);
  show();
}

function endTour() {
  tour?.close();
  tour = null;
}

function screenFor(route, token) {
  switch (route.name) {
    case "library":
    case "recent":
    case "movies":
    case "shows":
      return catalog.browse(route);
    case "watchlist":
      return watchlistScreen();
    case "person":
      return personScreen(route);
    case "people":
      return peopleScreen(route);
    case "settings":
      return settingsScreen(route);
    case "search":
      return catalog.search(route);
    case "title":
      return titleScreen(route.id);
    case "collections":
      return catalog.collections();
    case "collection":
      return catalog.collection(route);
    case "history":
      return historyScreen();
    case "statistics":
      return statisticsScreen();
    case "movie-night":
      return movieNight.screen();
    case "wishes":
      return supportsWishes(state.server) ? wishes.screen() : homeScreen();
    case "welcome":
      return settings.welcomeScreen();
    default:
      return homeScreen();
  }
}

// MARK: Home

async function homeScreen() {
  const home = await cached.home();
  const general = loadGeneral();
  const continuing = visibleTitles(home.continueWatching, general, { keepWatched: true });
  const favorites = visibleTitles(home.favorites, general);
  const recent = visibleTitles(home.recentlyAdded, general);
  const hero = home.recommendation ?? continuing[0] ?? recent[0];
  const sections = [];
  if (continuing.length) sections.push(rail("Continue Watching", continuing.map((item) => continueCard(item)), "landscape"));
  // "Because You Watched …": the server's suggestions after the latest watched titles (2.11.0).
  for (const suggestionRail of home.becauseYouWatched ?? []) {
    const items = visibleTitles(suggestionRail.suggestions.map((suggestion) => suggestion.item), general);
    if (items.length) sections.push(rail(`Because You Watched ${suggestionRail.sourceTitle}`, items.map((item) => posterCard(item))));
  }
  if (favorites.length) sections.push(rail("Favorites", favorites.map((item) => posterCard(item))));
  if (recent.length) sections.push(rail("Recently Added", recent.map((item) => posterCard(item))));
  if (home.collections?.length) sections.push(rail("Collections", home.collections.map((collection) => collectionCard(collection)), "poster", "/collections"));
  if (!hero && sections.length === 0)
    return emptyState("search", "Nothing Here Yet", "Your library is empty or this profile has no titles. Add a library folder in Aurelia on your Mac.");
  return h("div", { class: "home" }, hero ? heroBanner(hero) : null, h("div", { class: "sections" }, monthIsNew() ? monthlyWrappedLaunch({ compact: true }) : null, movieNight.homeStrip(), sections));
}

function heroBanner(item) {
  const target = item.kind === "episode" && item.parentId ? item.parentId : item.id;
  const started = logic.progressFraction(item.progress) > 0;
  return h("section", { class: "hero" },
    artwork(item.backdrop ?? item.poster, 1920, "hero-art", ""),
    h("div", { class: "hero-shade" }),
    h("div", { class: "hero-content" },
      h("div", { class: "eyebrow" }, logic.eyebrow(item)),
      h("h1", { class: "hero-title" }, item.kind === "episode" ? item.parentTitle ?? item.title : item.title),
      item.genres?.length ? h("div", { class: "hero-meta" }, item.genres.slice(0, 3).join(" · ")) : null,
      item.overview ? h("p", { class: "hero-overview" }, item.overview) : null,
      h("div", { class: "button-row" },
        h("button", { class: "primary-button", onclick: () => playTitle(item, undefined, { intent: started ? "resume" : "play" }) }, icon("play", { size: 16 }), started ? "Resume" : "Play"),
        h("a", { class: "secondary-button", href: `/title/${target}`, "data-route": true }, "Details"))));
}

function rail(title, cards, kind = "poster", allHref) {
  const track = h("div", { class: `rail-track ${kind}` }, cards);
  const scrollBehavior = () => window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches ? "auto" : "smooth";
  const scroll = (direction) => track.scrollBy({ left: direction * track.clientWidth * 0.85, behavior: scrollBehavior() });
  return (h("section", { class: "rail" },
    h("div", { class: "section-header" }, h("h2", {}, title), h("span", { class: "count" }, String(cards.length)),
      allHref ? h("a", { class: "text-button", href: allHref, "data-route": true }, "See All") : null,
      h("div", { class: "rail-arrows" },
        h("button", { class: "icon-button", "aria-label": `Scroll ${title} back`, onclick: () => scroll(-1) }, icon("back")),
        h("button", { class: "icon-button", "aria-label": `Scroll ${title} forward`, onclick: () => scroll(1) }, icon("forward")))),
    track));
}

const shownArtwork = new Set();

/** The width a full-window picture needs on this screen: a phone gets less than a 5K display (audit P5). */
function heroWidth() {
  return Math.min(1920, Math.round((window.innerWidth || 1440) * Math.min(2, window.devicePixelRatio || 1)));
}

function artwork(image, width, className, alt) {
  // A page's big picture loads first; posters further down load when they come near.
  const hero = /\bhero-art\b/.test(className);
  const url = logic.artworkUrl(image, hero ? heroWidth() : width);
  if (!url) return h("div", { class: `${className} artwork-missing` });
  // Posters and thumbnails come twice as large for sharp 2× screens (audit P5).
  const sharp = !hero && width <= 640 ? logic.artworkUrl(image, width * 2) : "";
  const element = h("img", { class: `${className} img-fade`, src: url, srcset: sharp && sharp !== url ? `${url} 1x, ${sharp} 2x` : null, alt,
    loading: hero ? "eager" : "lazy", decoding: "async", fetchpriority: hero ? "high" : null });
  // A picture already shown on this visit shows at once; a new one fades in when it's ready.
  if (shownArtwork.has(url) || (element.complete && element.naturalWidth)) element.classList.add("loaded");
  element.addEventListener("load", () => { shownArtwork.add(url); element.classList.add("loaded"); }, { once: true });
  element.addEventListener("error", () => element.classList.add("artwork-missing"), { once: true });
  return element;
}

function titleHref(item) {
  return `/title/${item.kind === "episode" && item.parentId ? item.parentId : item.id}`;
}

function badges(item) {
  return h("div", { class: "badges" },
    item.isFavorite ? h("span", { class: "badge" }, icon("heartFill", { size: 14, label: "Favorite" })) : null,
    item.watchState === "completed" ? h("span", { class: "badge" }, icon("check", { size: 14, label: "Watched" })) : null,
    item.availability !== "available" ? h("span", { class: "badge warning" }, "Offline") : null);
}

function progressBar(progress) {
  const fraction = logic.progressFraction(progress);
  if (fraction <= 0) return null;
  return h("div", { class: "progress", role: "progressbar", "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": String(Math.round(fraction * 100)) },
    h("div", { class: "progress-fill", style: { width: `${fraction * 100}%` } }));
}

function withMediaContextMenu(element, item, seasons, seasonNumber) {
  element.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    event.stopPropagation();
    openMenu(element, catalog.mediaMenu(item, { seasons, seasonNumber }));
  });
  return element;
}

function posterCard(item, index = 0) {
  return withMediaContextMenu(h("a", { class: "poster-card", href: titleHref(item), "data-route": true, style: { "--stagger": Math.min(index, 24) } },
    h("div", { class: "poster-frame" },
      artwork(item.poster, 320, "poster-art", ""),
      item.poster ? null : h("div", { class: "poster-fallback" }, item.title),
      badges(item), progressBar(item.progress)),
    h("div", { class: "card-title" }, item.kind === "episode" ? item.parentTitle ?? item.title : item.title),
    h("div", { class: "card-subtitle" }, item.kind === "episode" ? logic.eyebrow(item) : item.year ?? "")), item);
}

function continueCard(item) {
  const play = h("button", { class: "landscape-card", onclick: () => playTitle(item, undefined, { intent: "resume" }), "aria-label": `Resume ${item.parentTitle ?? item.title}` },
    h("div", { class: "landscape-frame" },
      artwork(item.backdrop ?? item.poster, 640, "landscape-art", ""),
      h("div", { class: "landscape-shade" }),
      h("div", { class: "landscape-text" },
        h("div", { class: "card-title" }, item.kind === "episode" ? item.parentTitle ?? item.title : item.title),
        h("div", { class: "card-subtitle" }, item.kind === "episode" ? `${logic.eyebrow({ ...item, parentTitle: null })} · ${item.title}` : logic.remaining(item.progress))),
      h("div", { class: "play-glyph" }, icon("play", { size: 18 })),
      progressBar(item.progress)));
  const more = h("button", { class: "icon-button continue-actions", "aria-label": `More Actions for ${item.parentTitle ?? item.title}`, "aria-haspopup": "menu", onclick: (event) => {
    event.stopPropagation();
    openMenu(more, catalog.mediaMenu(item));
  } }, icon("more"));
  return withMediaContextMenu(h("div", { class: "continue-card" }, play, more), item);
}

function collectionCard(collection, offset = 0) {
  const count = collection.itemCount ?? collection.totalCount ?? collection.items?.length ?? 0;
  const badgeText = collection.isSmart ? "Smart" : collection.provider === "tmdb" ? "TMDB" : collection.provider === "universe" ? "Universe" : null;
  const progress = (collection.itemCount ?? 0) > 0 && (collection.watchedCount ?? 0) > 0
    ? { positionMilliseconds: collection.watchedCount, durationMilliseconds: collection.itemCount }
    : null;
  return h("a", { class: "poster-card box-card", href: logic.routePath({ name: "collection", id: collection.id, ...(offset ? { offset } : {}) }), "data-route": true },
    h("div", { class: "box-stack" },
      h("div", { class: "poster-frame" },
        artwork(collection.poster ?? collection.items?.[0]?.poster, 320, "poster-art", ""),
        collection.poster ?? collection.items?.[0]?.poster ? null : h("div", { class: "poster-fallback" }, collection.name),
        badgeText ? h("span", { class: "badge", style: { top: "8px", left: "8px" } }, badgeText) : null,
        h("span", { class: "badge count-badge" }, String(count)),
        progressBar(progress))),
    h("div", { class: "card-title" }, collection.name),
    h("div", { class: "card-subtitle" }, logic.collectionSubtitle(collection)));
}

function emptyState(symbol, title, text, action) {
  return h("div", { class: "empty-state" }, h("div", { class: "status-icon" }, icon(symbol, { size: 30 })), h("h2", {}, title), h("p", { class: "muted" }, text), action ?? null);
}

// MARK: Library, Recently Added, Movies and TV Shows (the Mac app's sections and filters)

function menuOption(label, selected, action, disabled = false) {
  return h("button", { class: "menu-item check-item", role: "menuitemradio", "aria-checked": String(selected), disabled, onclick: action },
    h("span", { class: "check-mark" }, selected ? icon("check", { size: 15 }) : null), label);
}

/** A small menu under its button; it closes on any click or Escape. */
function openMenu(anchor, items) {
  document.querySelector(".popup-menu")?.remove();
  const menu = h("div", { class: "popup-menu profile-menu", role: "menu" }, items);
  const box = anchor.getBoundingClientRect();
  menu.style.top = `${box.bottom + window.scrollY + 8}px`;
  menu.style.left = `${Math.max(12, Math.min(box.left + window.scrollX, window.scrollX + document.documentElement.clientWidth - 260))}px`;
  document.body.append(menu);
  const close = () => {
    menu.remove();
    document.removeEventListener("click", close);
    document.removeEventListener("keydown", escape, true);
  };
  // Esc closes only this menu, also over the player (audit X9): it is heard first and taken.
  const escape = (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      close();
      anchor.focus();
    }
  };
  setTimeout(() => {
    document.addEventListener("click", close);
    document.addEventListener("keydown", escape, true);
  }, 0);
  menu.querySelector("[aria-checked=true], button:not(:disabled)")?.focus();
}

// MARK: Title details (the Mac app's detail page)

async function titleScreen(id) {
  // Parties are asked for together with the title, not after it (audit L5).
  const [detail, plan, watchlistSnapshot, parties] = await Promise.all([
    cached.detail(id),
    cached.playbackPlan(id).catch(() => null),
    cached.watchlist().catch(() => null),
    watchPartiesNow(),
  ]);
  if (watchlistSnapshot?.mediaIds) state.watchlistIds = new Set(watchlistSnapshot.mediaIds);
  const item = detail.item;
  const metadata = detail.metadata ?? {};
  const seasons = detail.seasons ?? [];
  const target = plan?.target ?? (item.kind === "series" ? null : item);

  const playButton = target && target.availability === "available"
    ? h("button", { class: "primary-button large", onclick: () => playTitle(target, seasons, { intent: plan?.action === "resume" ? "resume" : "play" }) }, icon("play", { size: 17 }), logic.detailPlayLabel(item, plan))
    : h("button", { class: "primary-button large", disabled: true }, icon("play", { size: 17 }), target ? "Unavailable" : "No Episodes");

  const playOnButton = target && target.availability === "available"
    ? h("button", { class: "secondary-button large play-on-btn", "aria-label": "Play on another device", "aria-haspopup": "menu" }, icon("airplay", { size: 17 }), "Play on…")
    : null;
  if (playOnButton) {
    playOnButton.addEventListener("click", async (event) => {
      event.stopPropagation();
      playOnButton.disabled = true;
      try {
        const devices = await api.activePlayers();
        if (!devices || devices.length === 0) {
          toast("No active Aurelia devices found.");
          return;
        }
        const items = devices.map((device) => {
          return h("button", { class: "menu-item", onclick: () => {
            document.querySelector(".popup-menu")?.remove();
            startRemotePlayback(device, target, plan);
          }}, icon("airplay", { size: 16 }), device.deviceName);
        });
        openMenu(playOnButton, items);
      } catch (error) {
        if (!handleError(error)) toast(error.message);
      } finally {
        playOnButton.disabled = false;
      }
    });
  }

  // Parties others started for this title or one of its episodes, to join with one click.
  const partyIds = new Set([item.id, ...seasons.flatMap((season) => (season.episodes ?? []).map((episode) => episode.item.id))]);
  const joinButtons = parties.filter((party) => partyIds.has(party.mediaId) && party.id !== state.watchParty?.state?.id).map((party) =>
    h("button", { class: "secondary-button large", title: `Watch ${party.title} together with ${party.hostName}`, onclick: () => joinWatchTogether(party) },
      icon("people", { size: 17 }), `Join ${party.hostName}`));

  let isFavorite = item.isFavorite;
  const favoriteButton = h("button", { class: "secondary-button large favorite-button" });
  const showFavorite = () => favoriteButton.replaceChildren(icon(isFavorite ? "starFill" : "star", { size: 17 }), isFavorite ? "Remove from Favorites" : "Add to Favorites");
  showFavorite();
  favoriteButton.addEventListener("click", async () => {
    favoriteButton.disabled = true;
    try {
      await api.setFavorite(item.id, !isFavorite);
      isFavorite = !isFavorite;
      showFavorite();
      favoriteButton.classList.add("bounce");
      setTimeout(() => favoriteButton.classList.remove("bounce"), 400);
    } catch (error) {
      if (!handleError(error)) toast(error.message);
    } finally {
      favoriteButton.disabled = false;
    }
  });

  let isWatchlisted = state.watchlistIds.has(item.id);
  const watchlistButton = h("button", { class: "secondary-button large watchlist-button" });
  const showWatchlist = () => watchlistButton.replaceChildren(icon(isWatchlisted ? "bookmarkFill" : "bookmark", { size: 17 }), isWatchlisted ? "Remove from Watchlist" : "Add to Watchlist");
  showWatchlist();
  watchlistButton.addEventListener("click", async () => {
    watchlistButton.disabled = true;
    try {
      await api.setWatchlist(item.id, !isWatchlisted);
      isWatchlisted = !isWatchlisted;
      if (isWatchlisted) state.watchlistIds.add(item.id);
      else state.watchlistIds.delete(item.id);
      showWatchlist();
      watchlistButton.classList.add("bounce");
      setTimeout(() => watchlistButton.classList.remove("bounce"), 400);
    } catch (error) {
      if (!handleError(error)) toast(error.message);
    } finally {
      watchlistButton.disabled = false;
    }
  });

  const moreButton = h("button", { class: "player-round glass detail-more", "aria-label": "More Actions", "aria-haspopup": "menu" }, icon("more", { size: 20 }));
  moreButton.addEventListener("click", (event) => {
    event.stopPropagation();
    // The season chosen on the page, not always the first (audit L11).
    const actions = catalog.mediaMenu(item, { seasons, seasonNumber: seasonChoice.get(item.id) ?? seasons[0]?.number });
    openMenu(moreButton, actions);
  });

  const stars = logic.starring(metadata.credits);
  const hero = h("section", { class: "detail-hero" },
    artwork(item.backdrop ?? metadata.backdrop ?? item.poster, 1920, "hero-art settle", ""),
    h("div", { class: "detail-shade-side" }),
    h("div", { class: "detail-shade-bottom" }),
    h("div", { class: "detail-top" },
      h("button", { class: "player-round glass", "aria-label": "Back", onclick: () => history.length > 1 ? history.back() : navigate({ name: "home" }) }, icon("back", { size: 20 })),
      moreButton),
    h("div", { class: "detail-hero-content" },
      h("div", { class: "eyebrow rise", style: { "--rise": 0 } }, logic.detailMetadataLine(item, metadata)),
      h("h1", { class: "hero-title rise", style: { "--rise": 1 } }, metadata.title ?? item.title),
      (metadata.genres ?? item.genres ?? []).length ? h("div", { class: "hero-genres rise", style: { "--rise": 2 } }, (metadata.genres ?? item.genres).slice(0, 3).join("  ·  ")) : null,
      metadata.overview ?? item.overview ? h("p", { class: "hero-overview rise", style: { "--rise": 3 } }, metadata.overview ?? item.overview) : null,
      h("div", { class: "button-row rise", style: { "--rise": 4 } }, playButton, ...joinButtons, playOnButton, favoriteButton, watchlistButton,
        logic.isTitleOffline(item, target) ? h("span", { class: "detail-offline-notice" }, icon("warning", { size: 14 }), logic.OFFLINE_FILE_NOTICE) : null,
        item.watchState === "completed" ? h("span", { class: "watched-label" }, icon("checkCircle", { size: 15 }), "Watched") : null),
      target ? progressLine(target) : null),
    stars.length ? h("div", { class: "starring rise", style: { "--rise": 5 } }, h("span", { class: "muted" }, "Starring "), stars.join(", ")) : null);

  const body = h("div", { class: "detail-sections" },
    seasons.length ? seasonsSection(item, seasons, target) : null,
    detail.franchise ? franchiseRail(detail.franchise) : null,
    supplementRails(detail.supplements, item.kind === "series" ? "Series " : "", item.title),
    castRail(metadata.credits),
    aboutSection(detail));
  return h("div", { class: "detail page-enter", dataset: { pageTitle: metadata.title ?? item.title } }, hero, body);
}

// Parties are asked for at most every 15 seconds while titles are opened one after another.
let partiesRead = null;
function watchPartiesNow() {
  if (partiesRead && Date.now() - partiesRead.at < 15_000) return partiesRead.answer;
  const answer = api.watchParties().then((list) => list ?? [], () => []);
  partiesRead = { at: Date.now(), answer };
  return answer;
}

/** The season each series' page shows, so a page built again keeps it (audit L4). */
const seasonChoice = new Map();

function franchiseRail(franchise) {
  const cards = (franchise.items ?? []).map((film) => posterCard(film));
  // Owners and administrators can keep the franchise as a collection (audit L3), once per click.
  const saveButton = logic.managementPermissions(state.profile).administrator
    ? h("button", {
        class: "text-button",
        onclick: async (event) => {
          const button = event.currentTarget;
          if (button.disabled) return;
          button.disabled = true;
          try {
            await api.createCollectionFromFranchise(franchise.id);
            toast(`Created the collection “${franchise.name}”.`);
            button.remove();
          } catch (error) {
            button.disabled = false;
            if (!handleError(error)) toast(error.message);
          }
        }
      }, "Save as Collection")
    : null;
  return h("section", { class: "rail" },
    h("div", { class: "section-header" },
      h("h2", {}, `Part of the ${franchise.name}`),
      h("span", { class: "count" }, String(cards.length)),
      saveButton),
    h("div", { class: "rail-track poster" }, cards));
}

function watchMenu(item, scope, seasonNumber) {
  return catalog.watchMenu(item, scope, seasonNumber);
}

function progressLine(item) {
  const left = logic.remaining(item.progress);
  if (!left) return null;
  return h("div", { class: "progress-line rise", style: { "--rise": 5 } }, h("div", { class: "progress inline" }, h("div", { class: "progress-fill", style: { width: `${logic.progressFraction(item.progress) * 100}%` } })), h("span", {}, left));
}

/** A horizontal row of cards with arrows at its ends, like the Mac's rails. */
function hrail(cards, { label, className = "" } = {}) {
  const track = h("div", { class: `hrail-track ${className}`, role: "list", "aria-label": label }, cards);
  const back = h("button", { class: "rail-arrow back", "aria-label": `Scroll ${label} back`, hidden: true }, icon("back", { size: 18 }));
  const forward = h("button", { class: "rail-arrow forward", "aria-label": `Scroll ${label} forward`, hidden: true }, icon("forward", { size: 18 }));
  const scrollBehavior = () => window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches ? "auto" : "smooth";
  const update = () => {
    back.hidden = track.scrollLeft <= 4;
    forward.hidden = track.scrollLeft + track.clientWidth >= track.scrollWidth - 4;
  };
  back.addEventListener("click", () => track.scrollBy({ left: -track.clientWidth * 0.85, behavior: scrollBehavior() }));
  forward.addEventListener("click", () => track.scrollBy({ left: track.clientWidth * 0.85, behavior: scrollBehavior() }));
  track.addEventListener("scroll", update, { passive: true });
  new ResizeObserver(update).observe(track);
  return h("div", { class: "hrail" }, track, back, forward);
}

function seasonsSection(item, seasons, target) {
  let current = seasons.find((season) => season.number === seasonChoice.get(item.id))
    ?? seasons.find((season) => season.episodes.some((entry) => entry.item.id === target?.id)) ?? seasons[0];
  const titleButton = h("button", { class: "season-menu", "aria-haspopup": "menu" });
  const count = h("span", { class: "muted" });
  const watched = h("span", { class: "watched-label small" });
  const holder = h("div", { class: "season-body" });
  const show = (season, animate) => {
    current = season;
    seasonChoice.set(item.id, season.number);
    titleButton.replaceChildren(icon("chevronUpDown", { size: 15 }), h("span", {}, logic.seasonTitle(season.number)), icon("chevronDown", { size: 13 }));
    count.textContent = `${season.episodes.length} episode${season.episodes.length === 1 ? "" : "s"}`;
    const allWatched = season.episodes.length > 0 && season.episodes.every((entry) => entry.item.watchState === "completed");
    watched.replaceChildren(...(allWatched ? [icon("checkCircle", { size: 14 }), "Watched"] : []));
    const rail = hrail(season.episodes.map((entry) => episodeCard(entry, seasons, season.number)), { label: "Episodes", className: "episodes" });
    if (animate) rail.classList.add("slide-in");
    holder.replaceChildren(...[rail, supplementRails(season.supplements, "", `${item.title} · ${logic.seasonTitle(season.number)}`)].filter(Boolean));
  };
  titleButton.addEventListener("click", (event) => {
    event.stopPropagation();
    openMenu(titleButton, [
      ...seasons.map((season) => menuOption(logic.seasonTitle(season.number), season === current, () => show(season, true))),
      h("div", { class: "menu-divider" }),
      ...watchMenu(item, "season", current.number),
      h("div", { class: "menu-divider" }),
      h("button", { class: "menu-item", onclick: () => catalog.openAddToCollectionDialog(item, current.number) }, icon("plus", { size: 16 }), "Add Season to Collection…"),
    ]);
  });
  titleButton.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    event.stopPropagation();
    openMenu(titleButton, [
      ...watchMenu(item, "season", current.number),
      h("div", { class: "menu-divider" }),
      h("button", { class: "menu-item", onclick: () => catalog.openAddToCollectionDialog(item, current.number) }, icon("plus", { size: 16 }), "Add Season to Collection…"),
    ]);
  });
  show(current, false);
  return h("section", { class: "detail-section" },
    h("div", { class: "section-header season-header" }, titleButton, h("span", { class: "spacer" }), watched, count),
    holder);
}

function episodeCard(entry, seasons, seasonNumber) {
  const item = entry.item;
  const available = item.availability === "available";
  return withMediaContextMenu(h("button", { class: "episode-card card-hover", role: "listitem", disabled: !available, onclick: () => playTitle(item, seasons) },
    artwork(item.backdrop ?? item.poster, 640, "episode-art", ""),
    h("div", { class: "episode-shade" }),
    h("div", { class: "episode-text" },
      h("div", { class: "eyebrow" }, `Episode ${entry.episodeNumber}`),
      h("div", { class: "episode-title" }, item.title),
      item.overview ? h("p", { class: "episode-overview" }, item.overview) : null,
      h("div", { class: "episode-footer" },
        h("span", {}, item.year ? String(item.year) : "Episode"),
        h("span", { class: "spacer" }),
        item.watchState === "completed" ? h("span", { class: "watched-label small" }, icon("checkCircle", { size: 13 }), "Watched") : null,
        available ? null : h("span", { class: "badge warning" }, "Offline"))),
    progressBar(item.progress)), item, seasons, seasonNumber ?? entry.seasonNumber);
}

function supplementRails(supplements, prefix, parentTitle) {
  const groups = logic.supplementGroups(supplements);
  if (!groups.length) return null;
  return h("div", { class: "supplement-rails" }, groups.map((group) => h("section", { class: "detail-section" },
    h("div", { class: "section-header" }, h("h2", {}, prefix + group.title)),
    hrail(group.items.map((entry) => supplementCard(entry, parentTitle)), { label: prefix + group.title, className: "supplements" }))));
}

function supplementCard(entry, parentTitle) {
  const item = { ...entry.item, parentTitle: entry.item.parentTitle ?? parentTitle };
  return withMediaContextMenu(h("button", { class: "supplement-card card-hover", role: "listitem", disabled: item.availability !== "available", onclick: () => playTitle(item) },
    artwork(item.backdrop ?? item.poster, 640, "episode-art", ""),
    h("div", { class: "episode-shade" }),
    h("div", { class: "supplement-play glass" }, icon("play", { size: 20 })),
    h("div", { class: "episode-text" },
      h("div", { class: "eyebrow" }, entry.category),
      h("div", { class: "episode-title" }, item.title),
      h("div", { class: "card-subtitle" }, logic.eyebrow(item) || "Extra"))), item);
}

function castRail(credits) {
  const cards = logic.people(credits);
  if (!cards.length) return null;
  return h("section", { class: "detail-section" },
    h("div", { class: "section-header" }, h("h2", {}, "Cast & Crew")),
    hrail(cards.map((person) => h("a", { class: "person card-hover", role: "listitem", href: logic.personHref(person), "data-route": true },
      h("div", { class: "person-photo" }, artwork(person.profile, 320, "person-art", ""), person.profile ? null : h("span", { class: "person-initial" }, logic.initial(person.name))),
      h("div", { class: "person-name" }, person.name),
      person.subtitle ? h("div", { class: "person-role" }, person.subtitle) : null)), { label: "Cast & Crew", className: "people" }));
}

async function watchlistScreen() {
  const response = await cached.watchlist();
  const items = response?.items ?? [];
  state.watchlistIds = new Set(response?.mediaIds ?? items.map((item) => item.id));
  if (!items.length) {
    return emptyState("bookmark", "Your Watchlist Is Empty", "Save movies and TV shows you want to watch later from their detail page or context menu.");
  }
  const shown = visibleTitles(items, loadGeneral(), { keepWatched: true });
  return h("div", { class: "library page-enter" },
    h("div", { class: "page-header" }, h("h1", {}, "Watchlist"), h("span", { class: "count" }, String(shown.length))),
    h("div", { class: "poster-grid" }, shown.map((item, index) => posterCard(item, index))));
}

function supportsPeople(server) {
  return Boolean(server?.capabilities?.includes(logic.PEOPLE_FEATURE));
}

async function personScreen(route) {
  // A person's life comes from TMDB beside the library's titles; it never holds the page up.
  const profileRead = route.personKey && supportsPeople(state.server)
    ? cached.personProfile(route.personKey).catch(() => null)
    : null;
  const detail = await cached.person({ name: route.personName, key: route.personKey });
  const items = detail?.items ?? [];
  const name = detail?.name ?? route.personName ?? "Person";
  // Kept from a moment ago or quick to answer: built in at once, so nothing moves afterwards.
  const early = profileRead ? await Promise.race([profileRead, new Promise((resolve) => setTimeout(resolve, 250))]) : null;
  const life = h("div", { class: "person-life muted" });
  const about = h("div", { class: "person-about-host" });
  const knownFor = h("div", { class: "known-for-host" });
  const fill = (profile) => {
    clear(life);
    clear(about);
    clear(knownFor);
    const line = logic.personLife(profile?.about);
    life.append(line);
    life.hidden = !line;
    const section = personAbout(profile?.about);
    if (section) about.append(section);
    const hits = profile?.knownFor ?? [];
    if (hits.length) {
      knownFor.append(h("section", { class: "detail-section known-for" },
        h("div", { class: "section-header" }, h("h2", {}, "Known For"), h("span", { class: "count" }, String(hits.length))),
        hrail(hits.map((hit) => knownForCard(hit)), { label: "Known For", className: "known-for-track" })));
    }
  };
  fill(early ?? null);
  if (profileRead && early === undefined) {
    void profileRead.then((profile) => { if (life.isConnected && profile) fill(profile); });
  }
  const titles = h("div", { class: "muted" }, `${items.length} ${items.length === 1 ? "title" : "titles"} in your library`);
  return h("div", { class: "library person-page page-enter", dataset: { pageTitle: name } },
    h("div", { class: "person-header" },
      h("button", { class: "player-round glass", "aria-label": "Back", onclick: () => history.length > 1 ? history.back() : navigate({ name: "home" }) }, icon("back", { size: 20 })),
      h("div", { class: "person-photo large" },
        artwork(detail?.profile, 320, "person-art", ""),
        detail?.profile ? null : h("span", { class: "person-initial" }, logic.initial(name))),
      h("div", { class: "person-heading" },
        h("div", { class: "eyebrow" }, detail?.subtitle ?? "Cast & Crew"),
        h("h1", {}, name),
        life,
        titles)),
    about,
    h("section", { class: "person-titles" },
      profileRead ? h("div", { class: "section-header" }, h("h2", {}, "In Your Library")) : null,
      items.length
        ? h("div", { class: "poster-grid" }, items.map((item, index) => posterCard(item, index)))
        : emptyState("search", "No Titles Found", "No accessible movies or TV shows in this library match this person.")),
    knownFor);
}

/** The biography, four lines first with More for the rest. */
function personAbout(about) {
  const biography = about?.biography?.trim();
  if (!biography) return null;
  const text = h("p", { class: "person-bio" }, biography);
  const long = biography.length > 360;
  const more = long ? h("button", { class: "text-button", "aria-expanded": "false" }, "More") : null;
  more?.addEventListener("click", () => {
    const open = text.classList.toggle("open");
    more.textContent = open ? "Less" : "More";
    more.setAttribute("aria-expanded", String(open));
  });
  return h("section", { class: "person-about" }, h("h2", {}, "Biography"), text, more,
    h("p", { class: "person-source muted small" }, "From TMDB"));
}

/** A title TMDB knows this person for that the library doesn't have, with Wish or Me Too. */
function knownForCard(hit) {
  const poster = wishPosterUrl(hit.posterPath, 342);
  const action = h("div", { class: "known-action" });
  const draw = () => {
    clear(action);
    if (!supportsWishes(state.server)) return;
    if (hit.alreadyWished && hit.supportedByCaller) {
      action.append(h("span", { class: "badge wished" }, icon("check", { size: 13 }), "Wished"));
    } else if (hit.alreadyWished && hit.existingWishId) {
      action.append(h("button", { class: "secondary-button small", onclick: () => void wish(() => api.setWishSupport(hit.existingWishId, true)) }, "Me Too"));
    } else {
      action.append(h("button", { class: "secondary-button small", onclick: () => void wish(async () => {
        const created = await api.createWish({ kind: hit.kind, title: hit.title, year: hit.year ?? null, provider: hit.provider,
          providerMediaId: hit.providerMediaId, overview: hit.overview ?? null, posterPath: hit.posterPath ?? null, note: null });
        hit = { ...hit, existingWishId: created?.wish?.id ?? hit.existingWishId };
      }) }, icon("gift", { size: 14 }), "Wish"));
    }
  };
  const wish = async (work) => {
    for (const button of action.querySelectorAll?.("button") ?? []) button.disabled = true;
    try {
      await work();
      hit = { ...hit, alreadyWished: true, supportedByCaller: true };
      toast(`Wished for “${hit.title}”.`);
      refreshWishSummary();
    } catch (error) {
      if (!handleError(error)) toast(describeWishError(error).message);
    }
    draw();
  };
  draw();
  return h("div", { class: "poster-card known-card", role: "listitem" },
    h("div", { class: "poster-frame" },
      poster ? h("img", { class: "poster-art img-fade", src: poster, alt: "", loading: "lazy", decoding: "async",
        onload: (event) => event.target.classList.add("loaded"), onerror: (event) => event.target.classList.add("artwork-missing") }) : null,
      poster ? null : h("div", { class: "poster-fallback" }, hit.title)),
    h("div", { class: "card-title" }, hit.title),
    h("div", { class: "card-subtitle" }, [hit.year, hit.kind === "series" ? "TV Show" : "Movie"].filter(Boolean).join(" · ")),
    action);
}

// MARK: People

const PEOPLE_PAGE = 60;

/** Everyone in the library's credits, those in the most titles first, with search ("people-v1"). */
async function peopleScreen(route) {
  let query = route.query?.trim() ?? "";
  const input = h("input", { class: "search-field", type: "search", value: route.query ?? "", placeholder: "Find a Person", "aria-label": "Find a Person", maxlength: "128", autocomplete: "off", enterkeyhint: "search" });
  const grid = h("div", { class: "people-grid", role: "list", "aria-label": "People" });
  const count = h("span", { class: "count" });
  const message = h("p", { class: "muted", role: "status", "aria-live": "polite" });
  const more = h("button", { class: "secondary-button", hidden: true }, "Load More");
  let offset = 0;
  let generation = 0;
  let request = null;
  let debounce;
  const show = (page, restart) => {
    const items = Array.isArray(page?.items) ? page.items : [];
    const total = Number.isSafeInteger(page?.total) ? page.total : items.length;
    if (restart) clear(grid);
    grid.append(...items.map(personCard));
    offset = (restart ? 0 : offset) + items.length;
    count.textContent = String(total);
    more.hidden = !items.length || offset >= total;
    message.textContent = offset ? "" : query
      ? `No one in your library matches “${query}”.`
      : "People appear here once TMDB has identified the titles in your library.";
  };
  async function load(restart) {
    const mine = ++generation;
    request?.abort();
    request = new AbortController();
    more.disabled = true;
    try {
      const page = await api.people({ query, offset: restart ? 0 : offset, limit: PEOPLE_PAGE }, { signal: request.signal });
      if (mine !== generation || !grid.isConnected) return;
      show(page, restart);
    } catch (error) {
      if (mine !== generation || error?.name === "AbortError" || handleError(error)) return;
      message.textContent = error?.message || "People couldn’t be loaded.";
    } finally {
      if (mine === generation) more.disabled = false;
    }
  }
  more.addEventListener("click", () => void load(false));
  input.addEventListener("input", () => {
    clearTimeout(debounce);
    debounce = setTimeout(() => {
      if (!input.isConnected) return;
      query = input.value.trim();
      state.route = { name: "people", ...(query ? { query } : {}) };
      history.replaceState(null, "", logic.routePath(state.route));
      void load(true);
    }, 250);
  });
  // The first page comes with the screen, so it never shows empty; a failure shows the usual error page.
  show(await api.people({ query, offset: 0, limit: PEOPLE_PAGE }), true);
  return h("div", { class: "library people-page page-enter", dataset: { pageTitle: "People" } },
    h("div", { class: "page-header" }, h("h1", {}, "People"), count),
    h("div", { class: "search-bar" }, icon("search"), input),
    grid,
    h("div", { class: "catalog-footer" }, message, more));
}

function personCard(person) {
  const role = logic.personRole(person);
  return h("a", { class: "person card-hover", role: "listitem", href: logic.personHref({ name: person.name, id: person.personKey }), "data-route": true },
    h("div", { class: "person-photo" }, artwork(person.profile, 320, "person-art", ""), person.profile ? null : h("span", { class: "person-initial" }, logic.initial(person.name))),
    h("div", { class: "person-name" }, person.name),
    h("div", { class: "person-role" }, role));
}

// MARK: Watch History

async function historyScreen() {
  const limit = 50;
  let items = [];
  let total = 0;

  const container = h("div", { class: "history-page library page-enter" });
  const listContainer = h("div", { class: "history-list" });
  const failed = (error) => { if (!handleError(error)) toast(error.message); };

  // Clearing everything, or one entry, asks first (audit L7).
  const clearButton = h("button", {
    class: "secondary-button danger",
    onclick: () => confirmSheet({
      symbol: "trash", title: "Clear Watch History?", confirm: "Clear History",
      message: "Every title leaves your history. Progress and favorites stay. This can't be undone.",
      work: () => api.clearHistory(),
    }).then((done) => {
      if (!done) return;
      toast("Watch history cleared.");
      items = [];
      total = 0;
      renderList();
    }, failed),
  }, "Clear History…");

  const header = h("div", { class: "page-header" },
    h("h1", {}, "Watch History"),
    h("span", { class: "spacer" }),
    clearButton);

  function renderList() {
    clear(listContainer);
    if (items.length === 0) {
      clearButton.hidden = true;
      listContainer.append(emptyState("clock", "No Watch History Yet", "Titles you watch will appear here."));
      return;
    }
    clearButton.hidden = false;
    for (const item of items) {
      const row = h("div", { class: "history-item-row" },
        h("a", { class: "history-item-poster", href: `/title/${item.mediaId}`, "data-route": true },
          artwork(item.poster, 160, "poster-art", "")),
        h("div", { class: "history-item-info" },
          h("a", { class: "history-item-title", href: `/title/${item.mediaId}`, "data-route": true }, item.title),
          h("div", { class: "history-item-meta muted small" },
            [item.eyebrow, new Date(item.watchedAt).toLocaleString(undefined, { month: "short", day: "numeric", year: "numeric", hour: "2-digit", minute: "2-digit" }),
              `Watched ${logic.watchTime(item.secondsWatched)}`]
              .filter(Boolean).join(" · ")),
          progressBar(item)),
        h("button", {
          class: "icon-button danger",
          "aria-label": `Remove ${item.title} from history`,
          title: "Remove from History",
          onclick: () => confirmSheet({
            symbol: "trash", title: `Remove “${item.title}” from History?`, confirm: "Remove",
            message: "Only this entry leaves your history; progress and favorites stay.",
            work: () => api.deleteHistoryItem(item.id),
          }).then((done) => {
            if (!done) return;
            items = items.filter((entry) => entry.id !== item.id);
            total = Math.max(0, total - 1);
            renderList();
          }, failed),
        }, icon("trash", { size: 16 })));
      listContainer.append(row);
    }
    if (items.length < total) {
      const loadMoreBtn = h("button", {
        class: "secondary-button load-more",
        onclick: async () => {
          loadMoreBtn.disabled = true;
          try {
            // The next page starts after what is shown, also after entries were removed (audit L7).
            const res = await api.history({ offset: items.length, limit });
            const known = new Set(items.map((entry) => entry.id));
            items.push(...(res.items ?? []).filter((entry) => !known.has(entry.id)));
            total = res.total ?? total;
            renderList();
          } catch (error) {
            loadMoreBtn.disabled = false;
            failed(error);
          }
        }
      }, "Load More");
      listContainer.append(loadMoreBtn);
    }
  }

  try {
    const res = await api.history({ offset: 0, limit });
    items = res.items ?? [];
    total = res.total ?? 0;
  } catch (error) {
    if (handleError(error)) return null;
    return emptyState("warning", "Couldn’t Load History", error.message, h("button", { class: "secondary-button", onclick: () => renderRoute() }, "Try Again"));
  }

  renderList();
  container.append(header, listContainer);
  return container;
}

// MARK: Statistics

async function statisticsScreen() {
  const container = h("div", { class: "statistics-page library page-enter" });
  container.append(h("div", { class: "page-header" }, h("h1", {}, "Statistics")));
  let stats;
  try {
    stats = await api.statistics();
  } catch (error) {
    if (handleError(error)) return null;
    return emptyState("warning", "Couldn’t Load Statistics", error.message, h("button", { class: "secondary-button", onclick: () => renderRoute() }, "Try Again"));
  }
  if (!(stats.totalHoursWatched > 0)) {
    return emptyState("star", "No Viewing Activity Yet",
      "Watch a movie or an episode, and your watch time, streaks and favorites appear here.");
  }

  const statCard = (title, value, detail) => h("div", { class: "stat-card" },
    h("div", { class: "stat-card-title muted small" }, title),
    h("div", { class: "stat-card-value" }, value),
    detail ? h("div", { class: "stat-card-subtitle muted small" }, detail) : null);
  const days = (count) => (count === 1 ? "1 day" : `${count ?? 0} days`);
  const timeOfDay = (text) => {
    const word = String(text ?? "").split(" ")[0].toLowerCase();
    return word ? (word === "night" ? "at night" : `in the ${word}`) : "";
  };

  const summary = h("div", { class: "stat-summary" },
    h("div", {},
      h("div", { class: "muted small" }, "Total Watch Time"),
      h("div", { class: "stat-total" }, logic.watchHours(stats.totalHoursWatched))),
    h("div", { class: "stat-recent" },
      h("div", {}, h("div", { class: "muted small" }, "Past 7 Days"), h("strong", {}, logic.watchHours(stats.hoursPast7Days))),
      h("div", {}, h("div", { class: "muted small" }, "Past 30 Days"), h("strong", {}, logic.watchHours(stats.hoursPast30Days)))));

  const highlights = h("div", { class: "stat-cards-grid" },
    statCard("Current Streak", days(stats.currentStreakDays)),
    statCard("Longest Streak", days(stats.longestStreakDays)),
    statCard("Finished", `${Math.round(stats.completionRate ?? 0)} %`),
    statCard("Watches Most", stats.busiestWeekday ?? "—", timeOfDay(stats.busiestTimeOfDay)));

  const weekTitle = (period) => logic.weekStart(period)?.toLocaleDateString(undefined, { day: "numeric", month: "short" }) ?? period;
  const weeks = stats.hoursByWeek?.length ? logic.lastWeeks(stats.hoursByWeek) : [];
  const longestWeek = Math.max(0.0001, ...weeks.map((week) => week.hours));
  const weeklySection = weeks.length ? h("section", { class: "stat-section" },
    h("h2", {}, "Last 12 Weeks"),
    h("div", { class: "weekly-chart" }, weeks.map((week) => {
      const label = `Week of ${weekTitle(week.period)}: ${logic.watchHours(week.hours)}`;
      return h("div", { class: "chart-bar-col", title: label, "aria-label": label, role: "img" },
        h("div", { class: "chart-bar", style: { height: `${Math.max(3, Math.round((week.hours / longestWeek) * 100))}%` } }),
        h("div", { class: "chart-label muted small" }, weekTitle(week.period)));
    }))) : null;

  const ranking = (title, note, items) => {
    const shown = (items ?? []).slice(0, 5);
    if (!shown.length) return null;
    const longest = Math.max(0.0001, ...shown.map((item) => item.hours ?? 0));
    return h("section", { class: "stat-section" },
      h("h2", {}, title),
      h("p", { class: "muted small" }, note),
      h("ol", { class: "stat-ranking" }, shown.map((item) => h("li", {},
        h("div", { class: "stat-ranking-line" },
          h("span", {}, item.name),
          h("span", { class: "muted" }, item.hours != null ? logic.watchHours(item.hours) : `${item.count}×`)),
        h("div", { class: "stat-ranking-bar", style: { width: `${Math.max(1, Math.round(((item.hours ?? 0) / longest) * 100))}%` } })))));
  };

  const years = stats.yearsAvailable ?? [];
  const yearContainer = h("div", { class: "year-in-review-content" });
  const yearSelect = h("select", { class: "select-input", "aria-label": "Year in Review" },
    years.map((year) => h("option", { value: String(year) }, String(year))));
  // Switching years quickly shows the year last chosen, never a late answer (audit L14).
  let yearTurn = 0;
  async function loadYear(year) {
    const turn = ++yearTurn;
    clear(yearContainer);
    try {
      const review = await api.yearInReview(year);
      if (turn !== yearTurn) return;
      const busiest = review.busiestDay
        ? new Date(`${review.busiestDay}T12:00:00`).toLocaleDateString(undefined, { day: "numeric", month: "long", year: "numeric" })
        : null;
      yearContainer.append(
        h("button", { class: "wrapped-launch", onclick: () => openWrapped({ api, year, artworkUrl: logic.artworkUrl }) },
          h("span", { class: "wrapped-launch-year" }, String(year)),
          h("span", {}, h("strong", {}, `Play your ${year} Wrapped`), h("span", { class: "small" }, "Your year in slides, with commentary nobody asked for.")),
          icon("play", { size: 18 })),
        h("div", { class: "stat-cards-grid" },
          statCard("Watch Time", logic.watchHours(review.totalHoursWatched)),
          statCard("Titles", String(review.titlesWatched ?? 0)),
          statCard("Movies", String(review.moviesWatched ?? 0)),
          statCard("Episodes", String(review.episodesWatched ?? 0))),
        h("dl", { class: "stat-facts" },
          review.topGenre ? [h("dt", {}, "Favorite Genre"), h("dd", {}, review.topGenre)] : null,
          review.topTitle ? [h("dt", {}, "Most Watched"), h("dd", {}, review.topTitle)] : null,
          busiest ? [h("dt", {}, "Busiest Day"), h("dd", {}, [busiest, review.busiestDayHours != null ? logic.watchHours(review.busiestDayHours) : null].filter(Boolean).join(" · "))] : null));
    } catch (error) {
      if (turn !== yearTurn || handleError(error)) return;
      yearContainer.append(error instanceof ApiError && error.status === 404
        ? h("p", { class: "muted" }, "No activity recorded for this year.")
        : h("div", { class: "error-banner" }, icon("warning", { size: 16 }), h("span", {}, error.message),
          h("button", { class: "secondary-button small", onclick: () => loadYear(year) }, "Try Again")));
    }
  }
  yearSelect.addEventListener("change", () => loadYear(Number(yearSelect.value)));
  const yearSection = years.length ? h("section", { class: "stat-section" },
    h("div", { class: "section-header" }, h("h2", {}, "Year in Review"), yearSelect),
    yearContainer) : null;
  if (years.length) loadYear(years[0]);

  container.append(
    summary,
    monthlyWrappedLaunch(),
    monthlyWrappedArchive(years),
    highlights,
    weeklySection ?? "",
    ranking("Most Watched", "Series count with all their episodes.", stats.topTitles) ?? "",
    ranking("Favorite Genres", "By the time you spent with them.", stats.topGenres) ?? "",
    yearSection ?? "");
  return container;
}

/** Every month's Wrapped, not only the newest: a year to choose and its ready months to play. */
function monthlyWrappedArchive(activityYears) {
  const years = wrappedYears(activityYears);
  const grid = h("div", { class: "wrapped-months" });
  const select = h("select", { class: "select-input", "aria-label": "Monthly Wrapped Year" },
    years.map((year) => h("option", { value: String(year) }, String(year))));
  const show = (year) => grid.replaceChildren(...readyMonths(year).reverse().map((month) =>
    h("button", { class: "wrapped-month", "aria-label": `Play ${MONTHS[month - 1]} ${year} Wrapped`,
      onclick: () => openWrapped({ api, year, month, artworkUrl: logic.artworkUrl }) },
    h("strong", {}, MONTHS[month - 1].slice(0, 3)), h("span", {}, MONTHS[month - 1]))));
  select.addEventListener("change", () => show(Number(select.value)));
  show(years[0]);
  return h("section", { class: "stat-section" },
    h("div", { class: "section-header" }, h("h2", {}, "Monthly Wrapped"), select),
    h("p", { class: "muted small" }, "Play any month again. A month is ready from the 2nd of the next month."),
    grid);
}

/** "Play your October Wrapped": the newest ready month, in Statistics and in its first week on Home. */
function monthlyWrappedLaunch({ compact = false } = {}) {
  const ready = readyMonth();
  return h("button", { class: `wrapped-launch month${compact ? " home" : ""}`, onclick: () => openWrapped({ api, year: ready.year, month: ready.month, artworkUrl: logic.artworkUrl }) },
    h("span", { class: "wrapped-launch-year" }, ready.name.slice(0, 3)),
    h("span", {}, h("strong", {}, `Your ${ready.name} Wrapped is here`), h("span", { class: "small" }, "Last month in slides. It's worse than you think.")),
    icon("play", { size: 18 }));
}

function aboutSection(detail) {
  const metadata = detail.metadata ?? {};
  const overview = metadata.overview ?? detail.item.overview;
  // Only what is known is listed; unknown fields are left out.
  const fields = logic.informationFields(detail).filter((field) => field.value);
  return h("section", { class: "detail-section about" },
    overview ? h("div", { class: "about-text" }, h("h2", {}, `About ${metadata.title ?? detail.item.title}`), h("p", {}, overview)) : null,
    fields.length ? h("h2", {}, "Information") : null,
    fields.length ? h("div", { class: `info-grid ${detail.item.kind === "series" ? "series" : ""}` }, fields.map((field) =>
      h("div", { class: "info-value" }, h("div", { class: "info-title" }, field.title), h("div", {}, field.value)))) : null);
}

let activeMiniRemote = null;

/** The mini remote ends with the session it belongs to: sign-out, another profile, a refused session or a sleeping server (audit C-L2). */
function closeMiniRemote() {
  activeMiniRemote?.close(false);
}

async function startRemotePlayback(device, target, plan) {
  try {
    const position = plan?.action === "resume" ? (target?.progress?.positionMilliseconds ?? 0) / 1000 : 0;
    await api.sendPlayerCommand(device.deviceId, {
      action: "play",
      mediaId: target.id,
      positionSeconds: position,
    });
    showMiniRemote(device, target);
  } catch (error) {
    if (!handleError(error)) toast(error.message || "Failed to start playback on remote device.");
  }
}

function showMiniRemote(device, target) {
  if (activeMiniRemote) activeMiniRemote.close();

  let isPlaying = true;
  let currentPosition = 0;
  let duration = (target.progress?.durationMilliseconds ? target.progress.durationMilliseconds / 1000 : 0) || 1;
  let pollTimer = null;

  const titleEl = h("div", { class: "mini-remote-title" }, target.title);
  const deviceEl = h("div", { class: "mini-remote-device" }, icon("airplay", { size: 14 }), `Playing on ${device.deviceName}`);
  const playBtn = h("button", { class: "icon-button mini-remote-btn", "aria-label": "Pause" }, icon("pause", { size: 18 }));
  const skipBackBtn = h("button", { class: "icon-button mini-remote-btn", "aria-label": "Back 10 Seconds" }, icon("previous", { size: 16 }));
  const skipForwardBtn = h("button", { class: "icon-button mini-remote-btn", "aria-label": "Forward 10 Seconds" }, icon("next", { size: 16 }));
  const closeBtn = h("button", { class: "icon-button mini-remote-btn", "aria-label": "Stop Remote Playback" }, icon("delete", { size: 16 }));

  const progressSlider = h("input", {
    class: "timeline mini-remote-slider",
    type: "range",
    min: "0",
    max: "1000",
    value: "0",
    "aria-label": "Remote Playback Position",
  });

  playBtn.addEventListener("click", async () => {
    try {
      const action = isPlaying ? "pause" : "resume";
      await api.sendPlayerCommand(device.deviceId, { action });
      isPlaying = !isPlaying;
      playBtn.replaceChildren(icon(isPlaying ? "pause" : "play", { size: 18 }));
      playBtn.setAttribute("aria-label", isPlaying ? "Pause" : "Play");
    } catch (e) {
      if (!handleError(e)) toast(e.message);
    }
  });

  skipBackBtn.addEventListener("click", async () => {
    try {
      await api.sendPlayerCommand(device.deviceId, { action: "skip", skipSeconds: -10 });
    } catch (e) {
      if (!handleError(e)) toast(e.message);
    }
  });

  skipForwardBtn.addEventListener("click", async () => {
    try {
      await api.sendPlayerCommand(device.deviceId, { action: "skip", skipSeconds: 10 });
    } catch (e) {
      if (!handleError(e)) toast(e.message);
    }
  });

  progressSlider.addEventListener("change", async () => {
    try {
      const fraction = Number(progressSlider.value) / 1000;
      const seekPos = fraction * duration;
      await api.sendPlayerCommand(device.deviceId, { action: "seek", positionSeconds: seekPos });
    } catch (e) {
      if (!handleError(e)) toast(e.message);
    }
  });

  const remoteWidget = h("div", { class: "mini-remote glass slide-up", role: "region", "aria-label": `Remote Control for ${device.deviceName}` },
    h("div", { class: "mini-remote-meta" }, deviceEl, titleEl),
    h("div", { class: "mini-remote-controls" }, skipBackBtn, playBtn, skipForwardBtn),
    h("div", { class: "mini-remote-scrub" }, progressSlider),
    closeBtn);

  const close = async (sendStop = false) => {
    clearInterval(pollTimer);
    remoteWidget.remove();
    activeMiniRemote = null;
    if (sendStop) {
      try {
        await api.sendPlayerCommand(device.deviceId, { action: "stop" });
      } catch {}
    }
  };

  closeBtn.addEventListener("click", () => close(true));

  // It asks every 2.5 s while this tab is visible, as the page's own background read, and ends
  // when the other device stopped playing, went away, or doesn't answer (audit L6).
  let stoppedPolls = 0;
  let failedPolls = 0;
  pollTimer = setInterval(async () => {
    if (document.hidden) return;
    try {
      const status = await api.background(() => api.playerStatus(device.deviceId));
      failedPolls = 0;
      if (status) {
        isPlaying = status.isPlaying && !status.isPaused;
        playBtn.replaceChildren(icon(isPlaying ? "pause" : "play", { size: 18 }));
        playBtn.setAttribute("aria-label", isPlaying ? "Pause" : "Play");
        stoppedPolls = status.isPlaying || status.isPaused ? 0 : stoppedPolls + 1;
        if (stoppedPolls >= 3) {
          toast(`${device.deviceName} stopped playing.`);
          close(false);
          return;
        }
        if (status.durationSeconds && status.durationSeconds > 0) {
          duration = status.durationSeconds;
          if (status.positionSeconds !== undefined && status.positionSeconds !== null) {
            currentPosition = status.positionSeconds;
            const fraction = Math.min(1, Math.max(0, currentPosition / duration));
            progressSlider.value = String(Math.round(fraction * 1000));
          }
        }
      }
    } catch (error) {
      if (error?.status === 404 || error?.code === "target_offline") {
        toast(`${device.deviceName} went offline.`);
        close(false);
      } else if (error?.status === 409 || error?.code === "target_profile_mismatch") {
        toast(`Profile changed on ${device.deviceName}.`);
        close(false);
      } else if (error?.status === 401 || error?.status === 403) {
        // A refused session never answers again; asking every few seconds only adds load.
        close(false);
      } else if (++failedPolls >= 5) {
        toast(`${device.deviceName} isn’t answering.`);
        close(false);
      }
    }
  }, 2500);

  activeMiniRemote = { close };
  document.body.append(remoteWidget);
}

// MARK: Playing

async function playTitle(item, seasons, { intent = "play", skipCinema = false, onFinished, playlist } = {}) {
  let target = item;
  try {
    // A show starts where its plan says: the next or the started episode.
    if (item.kind === "series") {
      const plan = await api.playbackPlan(item.id);
      if (!plan?.target) return toast("This show has no episode to play.");
      target = plan.target;
      if (intent === "resume" && plan.action !== "resume") intent = "play";
    }
    if (target.kind === "episode" && !seasons && target.parentId) seasons = (await api.detail(target.parentId)).seasons;
  } catch (error) {
    if (!handleError(error)) toast(error.message);
    return;
  }
  // The next title of a party (N, Up Next, the end of an episode) keeps the party: the party lets
  // go of the old player before it closes, and follows the new one, which tells the others
  // (audit X1). Only closing the player leaves it.
  if (state.player && state.watchParty?.isFollowing(state.player.partyPlayer)) state.watchParty.detach();
  closePlayer();
  if (!skipCinema && !onFinished && cinemaWanted({ item: target, intent, preferences: loadPreferences(),
    capabilities: state.server?.capabilities ?? [], watchingTogether: Boolean(state.watchParty) })) {
    if (await runCinema(target, seasons, intent)) return;
  }
  const player = new Player({
    api,
    item: target, intent, onFinished,
    preferenceScope: `${state.server?.serverId ?? location.origin}:${state.profile?.id ?? ""}`,
    next: async () => (playlist?.length ? logic.adjacentItem(playlist, target.id, 1) : target.kind === "episode" ? logic.nextEpisode(seasons, target.id) : null),
    previous: async () => (playlist?.length ? logic.adjacentItem(playlist, target.id, -1) : target.kind === "episode" ? logic.previousEpisode(seasons, target.id) : null),
    // After a movie or a series' last episode, the server suggests what follows.
    suggestions: !onFinished && state.server?.capabilities?.includes("suggestions-v1") ? () => api.suggestions(target.id, 3) : undefined,
    onPlaySuggestion: (next) => playTitle(next),
    onPlayNext: (next, options) => playTitle(next, seasons, { ...options, playlist }),
    onShowShortcuts: () => showShortcutsDialog(),
    onClose: () => {
      if (state.player === player) state.player = null;
      // Progress and Continue Watching changed; show them without jumping to the top. The next
      // episode opening right away waits with it until the last player closes.
      if (state.profile) refreshSoon();
    },
    onSessionEnded: () => sessionEnded(),
    profileName: logic.shownName(state.profile),
    // A whole-profile lock ends the profile after the good-night screen.
    onGoodNight: (status) => { if (status?.lockScope === "wholeProfile") switchProfile(); },
    onMediaMenu: (anchor, item) => openMenu(anchor, catalog.mediaMenu(item, {
      seasons, onGoToSeries: (id) => { closePlayer(); navigate({ name: "title", id }); },
    })),
    canConvert: Boolean(state.server?.capabilities?.includes(LIVE_FEATURE)),
    canStreamAdaptive: Boolean(state.server?.capabilities?.includes(ADAPTIVE_FEATURE)),
    canScrubPreview: Boolean(state.server?.capabilities?.includes("scrub-previews-v1") || state.server?.capabilities?.includes(LIVE_FEATURE)),
    together: { session: () => state.watchParty, start: (current) => startWatchTogether(current), leave: () => leaveWatchTogether() },
  });
  const close = player.onClose;
  player.onClose = () => {
    const party = state.watchParty;
    if (party?.isFollowing(player.partyPlayer)) {
      // Closing the player leaves the party; opening its next title does not.
      if (party.isChangingTitle) party.detach();
      else leaveWatchTogether();
    }
    close();
  };
  state.player = player;
  player.open(document.body);
  // A party this browser is in follows into the new player.
  state.watchParty?.attach(player.partyPlayer);
}

// MARK: Cinema mode

let cinema = null;

/**
 * The pre-show before a film: an ad, trailers, then the curtain over the starting film. Returns
 * false when there is nothing to show, so the film simply starts. Skip (→ during the ad) moves on,
 * Start Film (Return) goes straight to the film, Esc ends everything.
 */
async function runCinema(film, seasons, intent) {
  const preferences = loadPreferences();
  let trailers = [];
  if (preferences.cinemaTrailers > 0) {
    try { trailers = (await api.cinemaTrailers(film.id, preferences.cinemaTrailers))?.trailers ?? []; }
    catch { trailers = []; }
  }
  let ad = null;
  if (preferences.cinemaAds) {
    try { ad = nextAd(localStorage.getItem(LAST_AD_KEY)); localStorage.setItem(LAST_AD_KEY, ad); }
    catch { ad = nextAd(null); }
  }
  const acts = cinemaActs({ ad, trailers, film });
  if (!acts.length) return false;

  cinema?.end();
  const stage = h("div", { class: "cinema-stage" });
  const skip = h("button", { class: "secondary-button", onclick: () => current.skip?.() }, "Skip");
  const start = h("button", { class: "primary-button", onclick: () => current.startFilm() }, "Start Film");
  const close = h("button", { class: "icon-button cinema-close", "aria-label": "Close", onclick: () => current.end() }, icon("close", { size: 18 }));
  const bar = h("div", { class: "cinema-bar" }, skip, start);
  const layer = h("div", { class: "cinema-layer", role: "dialog", "aria-label": "Cinema" }, stage, close, bar);
  let ended = false;
  let trailerPlayer = null;
  let wake = () => {};
  const waitFor = (seconds) => new Promise((resolve) => {
    const timer = setTimeout(resolve, seconds * 1000);
    wake = () => { clearTimeout(timer); resolve(); };
  });
  const current = {
    skip: () => wake(),
    startFilm: () => { current.jump = true; trailerPlayer?.close(); wake(); },
    end: () => {
      ended = true;
      trailerPlayer?.close();
      layer.remove();
      document.removeEventListener("keydown", keys, true);
      wake();
      if (cinema === current) cinema = null;
    },
  };
  const keys = (event) => {
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); current.end(); }
    else if (event.key === "Enter") { event.preventDefault(); event.stopPropagation(); current.startFilm(); }
    else if (event.key === "ArrowRight" && !trailerPlayer) { event.preventDefault(); current.skip(); }
  };
  cinema = current;
  document.addEventListener("keydown", keys, true);
  document.body.append(layer);

  for (const act of acts) {
    if (ended) return true;
    if (current.jump && act.kind !== "feature") continue;
    if (act.kind === "ad") {
      stage.replaceChildren(adScene(act.ad));
      await waitFor(AD_SECONDS);
    } else if (act.kind === "trailer") {
      stage.replaceChildren(comingUp());
      await waitFor(1.6);
      if (ended || current.jump) continue;
      stage.replaceChildren();
      layer.classList.add("watching");
      // A trailer that never starts, or runs very long, gives way to the next part.
      await new Promise((resolve) => {
        let finished = false;
        const done = () => { if (!finished) { finished = true; clearInterval(check); resolve(); } };
        wake = () => { trailerPlayer?.close(); done(); };
        const opened = Date.now();
        const check = setInterval(() => {
          const time = trailerPlayer?.video?.currentTime ?? 0;
          if ((time === 0 && Date.now() - opened > TRAILER_START_SECONDS * 1000) || time > TRAILER_LONGEST_SECONDS) wake();
        }, 1000);
        playTitle(act.trailer, null, { intent: "play", skipCinema: true, onFinished: done }).then(() => {
          trailerPlayer = state.player;
          const closeTrailer = trailerPlayer?.onClose;
          if (trailerPlayer) trailerPlayer.onClose = () => { closeTrailer?.(); done(); };
        });
      });
      trailerPlayer = null;
      layer.classList.remove("watching");
    } else {
      // The film starts behind the closed curtain, which opens once its picture moves.
      const drape = curtain(act.title);
      stage.replaceChildren(drape);
      skip.hidden = true;
      start.hidden = true;
      const began = Date.now();
      await playTitle(film, seasons, { intent, skipCinema: true });
      if (ended) return true;
      const video = state.player?.video;
      await new Promise((resolve) => {
        const check = setInterval(() => {
          const waited = (Date.now() - began) / 1000;
          if (ended || (waited >= CURTAIN_EARLIEST && (video?.currentTime ?? 0) > 0.2) || waited >= CURTAIN_LONGEST_WAIT) { clearInterval(check); resolve(); }
        }, 200);
      });
      drape.classList.add("open");
      layer.classList.add("opening");
      await waitFor(CURTAIN_OPENING);
      current.end();
    }
  }
  return true;
}

// MARK: Watch Together

function newWatchParty() {
  return createWatchTogether({
    api,
    deviceName: logic.deviceName(navigator.userAgent, navigator.maxTouchPoints),
    onChange: (session) => {
      if (state.watchParty === session) state.player?.showPartyNotice(session);
    },
    openTitle: async (mediaId) => {
      try {
        const detail = await api.detail(mediaId);
        playTitle(detail.item, detail.seasons?.length ? detail.seasons : undefined);
      } catch (error) {
        if (!handleError(error)) toast(error.message);
      }
    },
  });
}

async function startWatchTogether(player) {
  await leaveWatchTogether();
  const session = newWatchParty();
  state.watchParty = session;
  const video = player.video;
  if (await session.start(player.item.id, Math.round(video.currentTime * 1000), !video.paused)) session.attach(player.partyPlayer);
  else toast(session.error ?? "Watch Together isn’t available right now.");
}

async function joinWatchTogether(party) {
  await leaveWatchTogether();
  const session = newWatchParty();
  state.watchParty = session;
  if (!(await session.join(party.id)) || !session.state) return toast(session.error ?? "Watch Together isn’t available right now.");
  try {
    const detail = await api.detail(session.state.mediaId);
    playTitle(detail.item, detail.seasons?.length ? detail.seasons : undefined);
  } catch (error) {
    if (!handleError(error)) toast(error.message);
  }
}

async function leaveWatchTogether() {
  const session = state.watchParty;
  if (!session) return;
  state.watchParty = null;
  state.player?.showPartyNotice(null);
  await session.leave();
}

function closePlayer() {
  const player = state.player;
  state.player = null;
  player?.close();
}

function toast(text) {
  // One message at a time; a new one replaces the last instead of stacking above it (audit D8).
  document.querySelectorAll(".toast").forEach((old) => old.remove());
  const element = h("div", { class: "toast", role: "status" }, text);
  document.body.append(element);
  setTimeout(() => element.classList.add("visible"), 10);
  setTimeout(() => {
    element.classList.remove("visible");
    setTimeout(() => element.remove(), 300);
  }, 4000);
}

// MARK: Live updates

/** Long-polls the server's change feed so changes from the Mac or the Apple TV show up here. */
function startSync() {
  stopSync();
  const controller = new AbortController();
  state.sync = controller;
  // The owner hears about devices that sign in for the first time.
  if (logic.managementPermissions(state.profile).owner && supportsSecurity(state.server)) securityAlerts.start();
  (async () => {
    let after = 0;
    let generation;
    let first = true;
    let failures = 0;
    let offlineInRow = 0;
    while (!controller.signal.aborted) {
      try {
        const changes = await api.changes(after, generation, controller.signal);
        if (controller.signal.aborted) return;
        if (!first && (changes.resetRequired || changes.changedAreas?.length)) {
          refreshSoon({ forget: true });
          if (changes.resetRequired || changes.changedAreas?.some((area) => String(area).toLowerCase() === "userstate" || String(area).toLowerCase() === "catalog")) {
            void refreshWishSummary({ notify: true });
          }
        }
        after = changes.cursor;
        generation = changes.generation ?? generation;
        first = false;
        failures = 0;
        offlineInRow = 0;
      } catch (error) {
        if (controller.signal.aborted || error?.name === "AbortError") return;
        failures += 1;
        offlineInRow = error instanceof ApiError && error.offline ? offlineInRow + 1 : 0;
        // An open page notices a server that went off, not only the next click. A playing
        // title reports its own problems, so the feed keeps waiting while the player is open.
        const next = logic.syncFailure(error instanceof ApiError ? error : null, failures, offlineInRow);
        if (next.action === "sessionEnded") return sessionEnded();
        if (next.action === "offline" && !state.player) return showServerOff();
        await new Promise((resolve) => setTimeout(resolve, next.delay));
      }
    }
  })();
}

function stopSync() {
  state.sync?.abort();
  state.sync = null;
  securityAlerts.stop();
}

function refreshSoon({ forget = false } = {}) {
  if (forget) {
    reads.clear();
    prefetches.forget();
  }
  // While a title plays, the page refreshes when the player closes; an open sheet, a hidden tab or
  // someone typing waits too, and the page catches up afterwards (audit L4, S3).
  state.pendingRefresh = true;
  if (state.player || document.querySelector("dialog[open]")) return;
  clearTimeout(state.refreshTimer);
  state.refreshTimer = setTimeout(() => {
    if (!state.profile || state.player || document.querySelector("dialog[open]")) return;
    if (!mayRefreshInPlace()) return;
    state.pendingRefresh = false;
    renderRoute({ quiet: true });
  }, 400);
}

/** A refresh that had to wait happens once the page is free again. */
function catchUp() {
  if (state.pendingRefresh && state.profile && !state.player) refreshSoon();
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") catchUp();
});
// Leaving a field (or closing a sheet) lets a refresh that waited for it happen.
document.addEventListener("focusout", () => setTimeout(catchUp, 0));
document.addEventListener("close", () => setTimeout(catchUp, 0), true);

document.addEventListener("keydown", (event) => {
  // "/" anywhere starts a search, as the tour says (audit L12).
  if (event.key === "/" && !event.defaultPrevented && !event.metaKey && !event.ctrlKey && !event.altKey && state.profile && !state.player) {
    const target = event.target;
    if (target?.isContentEditable || target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target?.tagName === "SELECT") return;
    if (document.querySelector("dialog[open]")) return;
    event.preventDefault();
    if (state.route.name === "search") document.querySelector(".search .search-field")?.focus();
    else navigate({ name: "search" });
    return;
  }
  if (event.key === "?" && !event.defaultPrevented && !event.metaKey && !event.ctrlKey && !event.altKey) {
    const target = event.target;
    if (target?.isContentEditable || target?.tagName === "SELECT") return;
    if ((target instanceof HTMLInputElement && target.type !== "range") || target instanceof HTMLTextAreaElement) return;
    if (state.player) return;
    const dialog = target?.closest?.('dialog, [role="dialog"]');
    if (dialog && !dialog.classList.contains("shortcuts-sheet")) return;
    event.preventDefault();
    showShortcutsDialog();
  }
});

start();
