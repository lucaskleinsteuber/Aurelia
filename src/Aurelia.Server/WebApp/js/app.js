// Aurelia in a web browser: sign-in with a code approved on the Mac, profiles, the library
// and the player. The server serves this page, so every address here is its own.

import { h, icon, clear } from "./dom.js";
import { createApi, ApiError } from "./api.js";
import { createCatalogView } from "./catalog-view.js";
import * as logic from "./logic.js";
import { PROFILE_SYMBOL_PATHS } from "./profile-symbols.js";
import { createWatchTogether } from "./watch-together.js";
import { createMovieNightView } from "./movie-night-view.js";
import { openWrapped, readyMonth, monthIsNew } from "./wrapped.js";
import { Player } from "./player.js";
import { LIVE_FEATURE } from "./live-logic.js";
import { ADAPTIVE_FEATURE } from "./hls-logic.js";
import { createSettings } from "./settings.js";
import { adScene, cinemaActs, cinemaWanted, comingUp, curtain, nextAd, AD_SECONDS, CURTAIN_EARLIEST, CURTAIN_LONGEST_WAIT, CURTAIN_OPENING, LAST_AD_KEY, TRAILER_LONGEST_SECONDS, TRAILER_START_SECONDS } from "./cinema.js";
import { loadPreferences } from "./player.js";
import { applyAppearance, loadGeneral, sidebarShows, startPath, visibleTitles } from "./preferences.js";

// Pages seen before show at once from what the server said last time; anything this browser
// changes on the server, and every change the server reports, forgets them.
const reads = logic.createReadCache();
const prefetches = logic.createPrefetcher();
const api = createApi(undefined, { onChange: (path) => {
  if (path.endsWith("/player/heartbeat")) return;
  reads.clear();
  prefetches.forget();
} });
const remembered = (name, key, load) => reads.read(`${name}:${key}`, load, () => refreshSoon());
const cached = {
  home: () => remembered("home", "", () => api.home()),
  detail: (id) => remembered("detail", id, () => api.detail(id)),
  playbackPlan: (id) => remembered("plan", id, () => api.playbackPlan(id)),
  watchlist: () => remembered("watchlist", "", () => api.watchlist()),
  person: (who) => remembered("person", JSON.stringify(who), () => api.person(who)),
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
  watchlistIds: new Set(),
};

// Settings › General: open on the chosen page when the app starts at Home.
if (location.pathname === "/" && startPath() !== "/") {
  history.replaceState(null, "", startPath());
  state.route = logic.parseRoute(location.pathname, location.search);
}
applyAppearance();

const scrollMemory = new logic.ScrollMemory();
let isRenderingRoute = false;

window.addEventListener("scroll", () => {
  if (isRenderingRoute || !state.profile) return;
  const currentPath = logic.routePath(state.route) || (location.pathname + location.search);
  scrollMemory.remember(currentPath, window.scrollY);
}, { passive: true });

// MARK: Start and connection

async function start() {
  clearTimeout(state.retryTimer);
  showConnecting();
  try {
    state.server = await api.serverInfo();
    document.title = state.server?.name && state.server.name !== "Aurelia" ? `Aurelia · ${state.server.name}` : "Aurelia";
  } catch (error) {
    return showServerOff(error);
  }
  // A page reload keeps a profile that is still open in this browser session.
  try {
    const user = await api.request("/api/v1/auth/me");
    if (user?.id) return enterProfile(user);
  } catch (error) {
    if (error instanceof ApiError && error.offline) return showServerOff(error);
  }
  await showProfiles();
}

function showConnecting() {
  render(screenFrame(h("div", { class: "center-stack" }, h("div", { class: "spinner visible" }), h("p", { class: "muted" }, "Connecting…"))));
}

function showServerOff() {
  catalog.close();
  settings.closeEditors();
  stopSync();
  const name = state.server?.name ?? "The server";
  render(screenFrame(h("div", { class: "center-stack narrow" },
    h("div", { class: "status-icon" }, icon("power", { size: 34 })),
    h("h1", {}, "The Server Is Asleep or Offline"),
    h("p", {}, `“${name}” isn’t answering. The computer may be asleep or turned off. You can wake it with Aurelia on your Mac if Wake-on-LAN is set up, or check that the computer is turned on.`),
    h("p", { class: "muted" }, "This page connects by itself as soon as the server is on."),
    h("div", { class: "button-row" }, h("button", { class: "primary-button", onclick: () => start() }, "Try Again")))));
  // Several requests can fail at once; only one retry may be waiting.
  clearTimeout(state.retryTimer);
  state.retryTimer = setTimeout(() => start(), 20_000);
}

// Settings needs these app functions; they are declarations, so they exist already.
const settings = createSettings({ api, state, navigate, toast, handleError, profilePicture, switchProfile, confirmSignOut,
  rememberPhoto, updateProfile, pictureAddress, startTour: () => { navigate({ name: "home" }); setTimeout(() => startTour(), 400); } });

const catalog = createCatalogView({ api, navigate, posterCard, collectionCard, emptyState, openMenu, menuOption, handleError, toast,
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

function settingsScreen(route) {
  return settings.settingsScreen(route);
}

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
  let busy = false;
  // Every Aurelia app pairs the same way: the main device shows the code, this browser types it.
  const field = h("input", {
    class: "pairing-code pairing-input",
    type: "text",
    inputmode: "numeric",
    pattern: "[0-9]*",
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

// MARK: Profiles

async function showProfiles(note) {
  catalog.close();
  settings.closeEditors();
  stopSync();
  closePlayer();
  state.profile = null;
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
  const list = h("div", { class: "profile-grid" }, picker.profiles.map((profile) =>
    h("button", { class: "profile-entry", onclick: () => chooseProfile(profile) },
      profilePicture(profile, "large"),
      h("span", { class: "profile-name" }, profile.name, profile.pinProtectionEnabled ? icon("lock", { size: 14, label: "PIN protected" }) : null))));
  const message = h("p", { class: "error-text", role: "alert" }, note ?? "");
  if (picker.managementSetupRequired) message.textContent = "Finish setting up profiles in Aurelia on your Mac first.";
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
    message)));
  field.focus();
}

async function enterProfile(user) {
  reads.clear();
  prefetches.forget();
  state.profile = user;
  state.watchlistIds = new Set();
  api.watchlist().then((response) => {
    if (state.profile?.id === user.id) state.watchlistIds = new Set(response?.mediaIds ?? []);
  }).catch(() => {});
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
  closePlayer();
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
  closePlayer();
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

function navigate(route, { replace = false } = {}) {
  settings.closeEditors();
  endTour();
  const currentPath = logic.routePath(state.route) || (location.pathname + location.search);
  if (!replace) scrollMemory.remember(currentPath, window.scrollY);
  const path = logic.routePath(route);
  if (replace) history.replaceState(null, "", path);
  else if (path !== location.pathname + location.search) history.pushState(null, "", path);
  state.route = route;
  renderRoute({ resetScroll: !replace });
}

window.addEventListener("popstate", () => {
  settings.closeEditors();
  if (!state.profile) return;
  closePlayer();
  state.route = logic.parseRoute(location.pathname, location.search);
  renderRoute({ restoreScroll: true, direction: "back" });
});

// Links inside the app change the screen without reloading the page.
document.addEventListener("click", (event) => {
  const link = event.target.closest?.("a[data-route]");
  if (!link || event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return;
  event.preventDefault();
  // The clicked poster grows into the title's picture on the next page.
  const art = link.matches(".poster-card, .continue-card") ? link.querySelector("img.loaded") : null;
  const titleId = link.getAttribute("href").startsWith("/title/") ? link.getAttribute("href").slice(7).split(/[?#/]/)[0] : null;
  if (art && titleId) {
    art.style.viewTransitionName = "title-art";
    art.dataset.morph = "1";
    state.morphFrom = titleId;
  }
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
    prefetches.start(id, () => Promise.all([cached.detail(id), cached.playbackPlan(id).catch(() => null)]));
  }, event.pointerType === "touch" ? 0 : 90);
}, { passive: true });

/** Rails rise in once as they come into view; a quiet refresh shows them as they were. */
let revealObserver = null;
let revealInstantly = false;
function revealWhenSeen(element) {
  if (revealInstantly || typeof IntersectionObserver !== "function" || !motionAllowed()) {
    element.classList.add("revealed");
    return element;
  }
  revealObserver ??= new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add("revealed");
      revealObserver.unobserve(entry.target);
    }
  }, { rootMargin: "0px 0px -6% 0px" });
  revealObserver.observe(element);
  return element;
}

function shell(content) {
  // The Mac app's sidebar: Home, then the library's sections.
  // Home first, then the sections in the order chosen in Settings › General.
  const labels = Object.fromEntries(logic.TOP_BAR_SECTIONS);
  const tabs = [["home", "Home", "/"], ...loadGeneral().sectionOrder.map((name) => [name, labels[name], `/${name}`])]
    .filter(([name]) => sidebarShows(name));
  const current = state.route.name;
  const menu = h("div", { class: "profile-menu", hidden: true },
    h("div", { class: "menu-header" }, profilePicture(state.profile), h("span", {}, logic.shownName(state.profile))),
    h("a", { class: "menu-item", href: "/history", "data-route": true }, "Watch History"),
    h("a", { class: "menu-item", href: "/statistics", "data-route": true }, "Statistics"),
    h("a", { class: "menu-item", href: "/movie-night", "data-route": true }, "Movie Night"),
    h("a", { class: "menu-item", href: "/settings", "data-route": true }, "Settings…"),
    h("button", { class: "menu-item", onclick: () => showShortcutsDialog() }, "Keyboard Shortcuts"),
    h("button", { class: "menu-item", onclick: () => switchProfile() }, "Switch Profile"),
    h("button", { class: "menu-item danger", onclick: () => confirmSignOut() }, "Sign Out of This Browser"));
  const toggleMenu = (event) => {
    event.stopPropagation();
    menu.hidden = !menu.hidden;
    if (!menu.hidden) {
      menu.querySelector("button")?.focus();
      document.addEventListener("click", () => (menu.hidden = true), { once: true });
    }
  };
  const header = h("header", { class: "top-bar" },
    h("a", { class: "brand", href: "/", "data-route": true, "aria-label": "Go to Home" }, h("img", { src: "/web/icon.svg", alt: "" }), h("span", {}, "Aurelia")),
    h("nav", { class: "tabs", "aria-label": "Library" }, tabs.map(([name, label, href]) =>
      h("a", { class: `tab ${current === name ? "selected" : ""}`, href, "data-route": true, "aria-current": current === name ? "page" : null }, label))),
    h("div", { class: "top-actions" },
      h("a", { class: `icon-button ${current === "search" ? "selected" : ""}`, href: "/search", "data-route": true, "aria-label": "Search" }, icon("search")),
      h("div", { class: "menu-anchor" },
        h("button", { class: "avatar-button", "aria-label": `${logic.shownName(state.profile)}, profile menu`, "aria-haspopup": "menu", onclick: toggleMenu },
          profilePicture(state.profile)), menu)));
  return h("div", { class: "app-shell" }, header, h("main", { class: "page", id: "page" }, content));
}

/** Whether pages may move: the system's and this browser's Reduce Motion both keep them still. */
function motionAllowed() {
  return !window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches && document.body.dataset.heroMotion !== "reduced";
}

/**
 * Replaces the page. With motion, the browser blends the old page into the new one (a poster
 * that was clicked grows into the title's picture); without, the page simply changes.
 */
function swapPage(update, { animate, direction }) {
  if (!animate || typeof document.startViewTransition !== "function" || !motionAllowed()) {
    update();
    return;
  }
  document.documentElement.dataset.navigation = direction;
  document.documentElement.classList.add("page-transition");
  try {
    const transition = document.startViewTransition(update);
    transition.finished.catch(() => {}).finally(() => {
      document.documentElement.classList.remove("page-transition");
      document.querySelectorAll("[data-morph]").forEach((element) => { element.style.viewTransitionName = ""; delete element.dataset.morph; });
    });
  } catch {
    update();
  }
}

async function renderRoute({ quiet = false, restoreScroll = false, resetScroll = false, direction = "forward" } = {}) {
  catalog.close();
  if (!state.profile) return;
  isRenderingRoute = true;
  const route = state.route;
  const token = ++state.renderToken;
  const path = logic.routePath(route) || (location.pathname + location.search);
  const targetScroll = restoreScroll ? scrollMemory.recall(path) : null;
  const scroll = quiet ? window.scrollY : (targetScroll ?? 0);
  revealInstantly = quiet;
  // Some screens are built at once, others load first; both count the same here.
  const loading = Promise.resolve().then(() => screenFor(route, token)).then((content) => ({ content }), (error) => ({ error }));
  // A page that answers quickly (remembered or near) replaces the old one directly; a slower one
  // shows its shape first.
  let outcome = quiet ? await loading : await Promise.race([loading, new Promise((resolve) => setTimeout(resolve, 140))]);
  if (!outcome) {
    if (token !== state.renderToken) return;
    swapPage(() => {
      clear(root);
      root.append(shell(skeletonFor(route)));
      if (resetScroll || restoreScroll) window.scrollTo(0, 0);
    }, { animate: true, direction });
    outcome = await loading;
  }
  let content = outcome.content;
  if (outcome.error) {
    if (token !== state.renderToken) return;
    isRenderingRoute = false;
    if (handleError(outcome.error)) return;
    content = emptyState("warning", "Couldn’t Load This Page", outcome.error.message, h("button", { class: "secondary-button", onclick: () => renderRoute() }, "Try Again"));
  }
  if (token !== state.renderToken || !content) {
    isRenderingRoute = false;
    return;
  }
  const morph = state.morphFrom;
  state.morphFrom = null;
  swapPage(() => {
    clear(root);
    root.append(shell(content));
    if (morph && route.name === "title" && route.id === morph) {
      const art = root.querySelector(".detail-hero .hero-art");
      if (art) { art.style.viewTransitionName = "title-art"; art.dataset.morph = "1"; }
    }
    if (quiet || restoreScroll) {
      window.scrollTo(0, scroll);
      if (typeof requestAnimationFrame === "function") {
        requestAnimationFrame(() => window.scrollTo(0, scroll));
      }
    } else if (resetScroll) {
      window.scrollTo(0, 0);
    }
  }, { animate: !quiet && !root.querySelector(".page-skeleton"), direction });
  revealInstantly = false;
  isRenderingRoute = false;
  if (route.name === "home" && !quiet && logic.tourPending(safeStorage())) setTimeout(() => startTour(), 600);
  const label = { home: "Home", library: "Library", watchlist: "Watchlist", recent: "Recently Added", movies: "Movies", shows: "TV Shows", search: "Search", collections: "Collections", history: "Watch History", statistics: "Statistics", settings: "Settings", "movie-night": "Movie Night" }[route.name];
  if (label) document.title = `${label} · Aurelia`;
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
    const topInset = document.querySelector(".top-bar")?.getBoundingClientRect().bottom ?? 0;
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
  return revealWhenSeen(h("section", { class: "rail reveal" },
    h("div", { class: "section-header" }, h("h2", {}, title), h("span", { class: "count" }, String(cards.length)),
      allHref ? h("a", { class: "text-button", href: allHref, "data-route": true }, "See All") : null,
      h("div", { class: "rail-arrows" },
        h("button", { class: "icon-button", "aria-label": `Scroll ${title} back`, onclick: () => scroll(-1) }, icon("back")),
        h("button", { class: "icon-button", "aria-label": `Scroll ${title} forward`, onclick: () => scroll(1) }, icon("forward")))),
    track));
}

function artwork(image, width, className, alt) {
  const url = logic.artworkUrl(image, width);
  if (!url) return h("div", { class: `${className} artwork-missing` });
  const element = h("img", { class: `${className} img-fade`, src: url, alt, loading: "lazy", decoding: "async" });
  // A picture the browser already has shows at once; one still loading fades in when it's ready.
  if (element.complete && element.naturalWidth) element.classList.add("loaded");
  else element.addEventListener("load", () => element.classList.add("loaded"), { once: true });
  element.addEventListener("error", () => element.classList.add("artwork-missing"), { once: true });
  return element;
}

/** The page's shape while it loads: the hero and rails of Home, a title's header, or a poster grid. */
function skeletonFor(route) {
  const block = (name) => h("div", { class: `skeleton ${name}` });
  const rail = (count = 8) => h("div", { class: "skeleton-rail" }, block("skeleton-heading"),
    h("div", { class: "skeleton-row" }, Array.from({ length: count }, () => block("skeleton-poster"))));
  const frame = (...children) => h("div", { class: "page-skeleton", role: "status", "aria-label": "Loading" }, ...children);
  switch (route.name) {
    case "home": return frame(block("skeleton-hero"), rail(), rail());
    case "title": return frame(block("skeleton-detail"), rail(4));
    case "library": case "recent": case "movies": case "shows": case "watchlist": case "collections": case "collection": case "person":
      return frame(h("div", { class: "skeleton-page-header" }, block("skeleton-title")),
        h("div", { class: "skeleton-grid" }, Array.from({ length: 18 }, () => block("skeleton-poster"))));
    default: return h("div", { class: "page-loading" }, h("div", { class: "spinner visible" }));
  }
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
  return withMediaContextMenu(h("a", { class: "poster-card card-hover", href: titleHref(item), "data-route": true, style: { "--stagger": Math.min(index, 24) } },
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
  const count = collection.totalCount ?? collection.items?.length ?? 0;
  return h("a", { class: "poster-card", href: logic.routePath({ name: "collection", id: collection.id, ...(offset ? { offset } : {}) }), "data-route": true },
    h("div", { class: "poster-frame" },
      artwork(collection.poster ?? collection.items?.[0]?.poster, 320, "poster-art", ""),
      collection.isSmart ? h("span", { class: "badge", style: { top: "8px", left: "8px" } }, "Smart") : null,
      h("span", { class: "badge count-badge" }, String(count))),
    h("div", { class: "card-title" }, collection.name),
    h("div", { class: "card-subtitle" }, collection.isSmart ? "Smart List" : "Collection"));
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
    document.removeEventListener("keydown", escape);
  };
  const escape = (event) => {
    if (event.key === "Escape") {
      close();
      anchor.focus();
    }
  };
  setTimeout(() => {
    document.addEventListener("click", close);
    document.addEventListener("keydown", escape);
  }, 0);
  menu.querySelector("[aria-checked=true], button:not(:disabled)")?.focus();
}

// MARK: Title details (the Mac app's detail page)

async function titleScreen(id) {
  const [detail, plan, watchlistSnapshot] = await Promise.all([
    cached.detail(id),
    cached.playbackPlan(id).catch(() => null),
    cached.watchlist().catch(() => null),
  ]);
  if (watchlistSnapshot?.mediaIds) state.watchlistIds = new Set(watchlistSnapshot.mediaIds);
  const item = detail.item;
  const metadata = detail.metadata ?? {};
  document.title = `${metadata.title ?? item.title} · Aurelia`;
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
  const parties = (await api.watchParties().catch(() => [])) ?? [];
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
    const actions = catalog.mediaMenu(item, { seasons, seasonNumber: seasons[0]?.number });
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
  return h("div", { class: "detail page-enter" }, hero, body);
}

function franchiseRail(franchise) {
  const cards = (franchise.items ?? []).map((film) => posterCard(film));
  const saveButton = state.profile?.isOwner || state.profile?.isAdmin
    ? h("button", {
        class: "text-button",
        onclick: async () => {
          try {
            await api.createCollectionFromFranchise(franchise.id);
            toast(`Created collection “${franchise.name}”`);
          } catch (e) {
            toast(e.message);
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
  let current = seasons.find((season) => season.episodes.some((entry) => entry.item.id === target?.id)) ?? seasons[0];
  const titleButton = h("button", { class: "season-menu", "aria-haspopup": "menu" });
  const count = h("span", { class: "muted" });
  const watched = h("span", { class: "watched-label small" });
  const holder = h("div", { class: "season-body" });
  const show = (season, animate) => {
    const backwards = seasons.indexOf(season) < seasons.indexOf(current);
    current = season;
    titleButton.replaceChildren(icon("chevronUpDown", { size: 15 }), h("span", {}, logic.seasonTitle(season.number)), icon("chevronDown", { size: 13 }));
    count.textContent = `${season.episodes.length} episode${season.episodes.length === 1 ? "" : "s"}`;
    const allWatched = season.episodes.length > 0 && season.episodes.every((entry) => entry.item.watchState === "completed");
    watched.replaceChildren(...(allWatched ? [icon("checkCircle", { size: 14 }), "Watched"] : []));
    const rail = hrail(season.episodes.map((entry) => episodeCard(entry, seasons, season.number)), { label: "Episodes", className: "episodes" });
    if (animate) rail.classList.add("slide-in", ...(backwards ? ["back"] : []));
    holder.replaceChildren(...[rail, supplementRails(season.supplements, "", `${item.title} · ${logic.seasonTitle(season.number)}`)].filter(Boolean));
  };
  titleButton.addEventListener("click", (event) => {
    event.stopPropagation();
    openMenu(titleButton, [
      ...seasons.map((season) => menuOption(logic.seasonTitle(season.number), season === current, () => show(season, true))),
      h("div", { class: "menu-divider" }),
      ...watchMenu(item, "season", current.number),
    ]);
  });
  titleButton.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    event.stopPropagation();
    openMenu(titleButton, watchMenu(item, "season", current.number));
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
  return h("div", { class: "library page-enter" },
    h("div", { class: "page-header" }, h("h1", {}, "Watchlist"), h("span", { class: "count" }, String(items.length))),
    h("div", { class: "poster-grid" }, visibleTitles(items, loadGeneral(), { keepWatched: true }).map((item, index) => posterCard(item, index))));
}

async function personScreen(route) {
  const detail = await cached.person({ name: route.personName, key: route.personKey });
  const items = detail?.items ?? [];
  const name = detail?.name ?? route.personName ?? "Person";
  document.title = `${name} · Aurelia`;
  return h("div", { class: "library person-page page-enter" },
    h("div", { class: "person-header" },
      h("button", { class: "player-round glass", "aria-label": "Back", onclick: () => history.length > 1 ? history.back() : navigate({ name: "home" }) }, icon("back", { size: 20 })),
      h("div", { class: "person-photo large" },
        artwork(detail?.profile, 320, "person-art", ""),
        detail?.profile ? null : h("span", { class: "person-initial" }, logic.initial(name))),
      h("div", { class: "person-heading" },
        h("div", { class: "eyebrow" }, detail?.subtitle ?? "Cast & Crew"),
        h("h1", {}, name),
        h("div", { class: "muted" }, `${items.length} ${items.length === 1 ? "title" : "titles"} in your library`))),
    items.length
      ? h("div", { class: "poster-grid" }, items.map((item, index) => posterCard(item, index)))
      : emptyState("search", "No Titles Found", "No accessible movies or TV shows in this library match this person."));
}

// MARK: Watch History

async function historyScreen() {
  let offset = 0;
  const limit = 50;
  let items = [];
  let total = 0;

  const container = h("div", { class: "history-page library page-enter" });
  const listContainer = h("div", { class: "history-list" });

  const clearButton = h("button", {
    class: "secondary-button danger",
    onclick: async () => {
      if (!confirm("Clear your entire watch history? This cannot be undone.")) return;
      try {
        await api.clearHistory();
        toast("Watch history cleared.");
        items = [];
        total = 0;
        renderList();
      } catch (e) {
        toast(e.message);
      }
    }
  }, "Clear History…");

  const header = h("div", { class: "page-header" },
    h("h1", {}, "Watch History"),
    h("div", { class: "button-row" }, clearButton));

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
            [item.eyebrow, new Date(item.watchedAt).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }),
              `Watched ${logic.watchTime(item.secondsWatched)}`]
              .filter(Boolean).join(" · ")),
          progressBar(item)),
        h("button", {
          class: "icon-button danger",
          "aria-label": `Remove ${item.title} from history`,
          onclick: async () => {
            try {
              await api.deleteHistoryItem(item.id);
              items = items.filter((x) => x.id !== item.id);
              renderList();
            } catch (e) {
              toast(e.message);
            }
          }
        }, icon("trash", { size: 16 })));
      listContainer.append(row);
    }
    if (items.length < total) {
      const loadMoreBtn = h("button", {
        class: "secondary-button load-more",
        onclick: async () => {
          loadMoreBtn.disabled = true;
          try {
            offset += limit;
            const res = await api.history({ offset, limit });
            items.push(...res.items);
            total = res.total;
            renderList();
          } catch (e) {
            toast(e.message);
          }
        }
      }, "Load More");
      listContainer.append(loadMoreBtn);
    }
  }

  try {
    const res = await api.history({ offset, limit });
    items = res.items ?? [];
    total = res.total ?? 0;
  } catch (e) {
    return emptyState("warning", "Couldn’t Load History", e.message);
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
  } catch (e) {
    return emptyState("warning", "Couldn’t Load Statistics", e.message);
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
  async function loadYear(year) {
    clear(yearContainer);
    try {
      const review = await api.yearInReview(year);
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
    } catch {
      yearContainer.append(h("p", { class: "muted" }, "No activity recorded for this year."));
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
    highlights,
    weeklySection ?? "",
    ranking("Most Watched", "Series count with all their episodes.", stats.topTitles) ?? "",
    ranking("Favorite Genres", "By the time you spent with them.", stats.topGenres) ?? "",
    yearSection ?? "");
  return container;
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

  pollTimer = setInterval(async () => {
    try {
      const status = await api.playerStatus(device.deviceId);
      if (status) {
        isPlaying = status.isPlaying && !status.isPaused;
        playBtn.replaceChildren(icon(isPlaying ? "pause" : "play", { size: 18 }));
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
      }
    }
  }, 2500);

  activeMiniRemote = { close };
  document.body.append(remoteWidget);
}

// MARK: Playing

async function playTitle(item, seasons, { intent = "play", skipCinema = false, onFinished } = {}) {
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
  closePlayer();
  if (!skipCinema && !onFinished && cinemaWanted({ item: target, intent, preferences: loadPreferences(),
    capabilities: state.server?.capabilities ?? [], watchingTogether: Boolean(state.watchParty) })) {
    if (await runCinema(target, seasons, intent)) return;
  }
  const player = new Player({
    api,
    item: target, intent, onFinished,
    preferenceScope: `${state.server?.serverId ?? location.origin}:${state.profile?.id ?? ""}`,
    next: async () => (target.kind === "episode" ? logic.nextEpisode(seasons, target.id) : null),
    previous: async () => (target.kind === "episode" ? logic.previousEpisode(seasons, target.id) : null),
    onPlayNext: (next, options) => playTitle(next, seasons, options),
    onShowShortcuts: () => showShortcutsDialog(),
    onClose: () => {
      if (state.player === player) state.player = null;
      // Progress and Continue Watching changed; show them without jumping to the top.
      if (state.profile) renderRoute({ quiet: true });
    },
    onSessionEnded: () => sessionEnded(),
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
        if (!first && (changes.resetRequired || changes.changedAreas?.length)) refreshSoon({ forget: true });
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
}

function refreshSoon({ forget = false } = {}) {
  if (forget) {
    reads.clear();
    prefetches.forget();
  }
  // While a title plays, the page refreshes when the player closes.
  if (state.player || document.querySelector("dialog[open]")) return;
  clearTimeout(state.refreshTimer);
  state.refreshTimer = setTimeout(() => {
    if (state.route.name !== "search") renderRoute({ quiet: true });
  }, 400);
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && state.profile && !state.player) refreshSoon();
});

document.addEventListener("keydown", (event) => {
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
