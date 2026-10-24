// Aurelia in a web browser: sign-in with a code approved on the Mac, profiles, the library
// and the player. The server serves this page, so every address here is its own.

import { h, icon, clear } from "./dom.js";
import { createApi, ApiError, loadAllPages } from "./api.js";
import * as logic from "./logic.js";
import { Player } from "./player.js";
import { LIVE_FEATURE } from "./live-logic.js";

const api = createApi();
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
};

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
  stopSync();
  const name = state.server?.name ?? "The server";
  render(screenFrame(h("div", { class: "center-stack narrow" },
    h("div", { class: "status-icon" }, icon("power", { size: 34 })),
    h("h1", {}, "The Server Is Off"),
    h("p", {}, `“${name}” isn’t answering. Turn on the computer the server runs on, or open Aurelia on your Mac to wake it.`),
    h("p", { class: "muted" }, "This page connects by itself as soon as the server is on."),
    h("div", { class: "button-row" }, h("button", { class: "primary-button", onclick: () => start() }, "Try Again")))));
  state.retryTimer = setTimeout(() => start(), 20_000);
}

function screenFrame(...children) {
  return h("div", { class: "screen ambient" }, h("div", { class: "glow one" }), h("div", { class: "glow two" }), h("main", { class: "screen-content" }, children));
}

function render(element) {
  state.renderToken += 1;
  document.title = "Aurelia";
  clear(root);
  root.append(element);
}

// MARK: Pairing

async function showPairing(note) {
  stopSync();
  document.title = "Aurelia";
  const token = ++state.renderToken;
  const code = h("div", { class: "pairing-code", "aria-live": "polite" }, "…");
  const expiry = h("p", { class: "muted pairing-expiry" });
  const message = h("p", { class: "error-text", role: "alert" }, note ?? "");
  const renew = h("button", { class: "secondary-button", hidden: true, onclick: () => showPairing() }, "Create a New Code");
  clear(root);
  root.append(screenFrame(h("div", { class: "center-stack narrow" },
    h("img", { class: "brand-mark", src: "/web/icon.svg", alt: "" }),
    h("h1", {}, "Sign In to Aurelia"),
    h("p", {}, "In Aurelia on your Mac, open Settings › Server › Devices, choose “Enter Code from Apple TV or Browser…” and type this code."),
    code, expiry, message, h("div", { class: "button-row" }, renew),
    h("p", { class: "muted small" }, `Server: ${state.server?.name ?? "Aurelia"}`))));

  let pairing;
  try {
    pairing = await api.startPairing(logic.deviceName(navigator.userAgent, navigator.maxTouchPoints));
  } catch (error) {
    if (token !== state.renderToken) return;
    if (error instanceof ApiError && error.offline) return showServerOff();
    code.textContent = "— — — —";
    message.textContent = error.code === "pairing_disabled"
      ? "Signing in new devices is turned off on this server. Turn it on in Aurelia on your Mac."
      : error.code === "https_required"
        ? "Open this page with the server’s https:// address to sign in."
        : error.message;
    renew.hidden = false;
    renew.textContent = "Try Again";
    return;
  }
  if (token !== state.renderToken) return;
  code.textContent = logic.formatCode(pairing.code);
  code.setAttribute("aria-label", `Code ${pairing.code.split("").join(" ")}`);

  const tick = () => {
    const left = logic.countdown(pairing.expiresAt);
    expiry.textContent = left ? `Valid for ${left}` : "This code has expired.";
    if (!left) {
      code.classList.add("expired");
      renew.hidden = false;
    }
    return Boolean(left);
  };
  tick();
  const ticker = setInterval(() => {
    if (token !== state.renderToken || !tick()) clearInterval(ticker);
  }, 1000);

  const interval = Math.max(5, pairing.pollIntervalSeconds ?? 5) * 1000 + 500;
  const poll = async () => {
    if (token !== state.renderToken || !logic.countdown(pairing.expiresAt)) return;
    try {
      const status = await api.pairingStatus();
      if (token !== state.renderToken) return;
      if (status.state === "approved") return showProfiles();
      if (status.state === "denied") {
        message.textContent = "The code was declined on the Mac.";
        code.classList.add("expired");
        renew.hidden = false;
        return;
      }
      if (status.state !== "pending") {
        code.classList.add("expired");
        renew.hidden = false;
        return;
      }
    } catch (error) {
      if (token !== state.renderToken) return;
      if (error instanceof ApiError && error.status === 404) {
        code.classList.add("expired");
        renew.hidden = false;
        return;
      }
      // Offline for a moment or polled too soon: keep waiting.
    }
    setTimeout(poll, interval);
  };
  setTimeout(poll, interval);
}

// MARK: Profiles

async function showProfiles(note) {
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
      profilePicture(profile.id, profile.name, "large"),
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

function profilePicture(id, name, size = "small") {
  return h("span", { class: `profile-picture ${size} palette-${logic.profileColorIndex(id)}`, "aria-hidden": "true" }, logic.initial(name));
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
      profilePicture(profile.id, profile.name, "large"), h("span", { class: "profile-name pin-name" }, profile.name)),
    h("p", { class: "muted pin-prompt" }, "Enter your PIN"),
    form,
    message)));
  field.focus();
}

async function enterProfile(user) {
  state.profile = user;
  startSync();
  renderRoute();
}

function confirmSignOut() {
  const dialog = h("dialog", { class: "sheet" },
    h("h2", {}, "Sign out of this browser?"),
    h("p", {}, "To use Aurelia here again, the owner has to approve a new code on the Mac."),
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

async function signOut() {
  stopSync();
  closePlayer();
  try {
    await api.signOut();
  } catch {
    // The cookies are cleared by the server's answer; without one, the next start asks again.
  }
  state.profile = null;
  showPairing();
}

async function switchProfile() {
  stopSync();
  closePlayer();
  try {
    await api.endProfile();
  } catch {
    // Ending is best effort: the profile session also ends after twelve hours or on restart.
  }
  showProfiles();
}

/** A profile request was refused: the profile session ended, or the whole browser was signed out. */
async function sessionEnded() {
  stopSync();
  closePlayer();
  state.profile = null;
  try {
    await api.profiles();
    showProfiles("Your profile session ended. Choose your profile again.");
  } catch (error) {
    if (error instanceof ApiError && error.offline) return showServerOff();
    showPairing("This browser was signed out. Ask the owner to approve a new code.");
  }
}

function handleError(error) {
  if (error instanceof ApiError && (error.status === 401 || (error.status === 403 && /session|profile|device/.test(error.code)))) {
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
  const path = logic.routePath(route);
  if (replace) history.replaceState(null, "", path);
  else if (path !== location.pathname + location.search) history.pushState(null, "", path);
  state.route = route;
  renderRoute();
  if (!replace) window.scrollTo(0, 0);
}

window.addEventListener("popstate", () => {
  if (!state.profile) return;
  closePlayer();
  state.route = logic.parseRoute(location.pathname, location.search);
  renderRoute();
});

// Links inside the app change the screen without reloading the page.
document.addEventListener("click", (event) => {
  const link = event.target.closest?.("a[data-route]");
  if (!link || event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return;
  event.preventDefault();
  navigate(logic.parseRoute(link.getAttribute("href").split("?")[0], link.getAttribute("href").split("?")[1] ?? ""));
});

function shell(content) {
  const tabs = [
    ["home", "Home", "/"],
    ["movies", "Movies", "/movies"],
    ["shows", "TV Shows", "/shows"],
  ];
  const current = state.route.name;
  const menu = h("div", { class: "profile-menu", hidden: true },
    h("div", { class: "menu-header" }, profilePicture(state.profile.id, state.profile.username), h("span", {}, state.profile.username)),
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
        h("button", { class: "avatar-button", "aria-label": `${state.profile.username}, profile menu`, "aria-haspopup": "menu", onclick: toggleMenu },
          profilePicture(state.profile.id, state.profile.username)), menu)));
  return h("div", { class: "app-shell" }, header, h("main", { class: "page", id: "page" }, content));
}

async function renderRoute({ quiet = false } = {}) {
  if (!state.profile) return;
  const route = state.route;
  const token = ++state.renderToken;
  const scroll = window.scrollY;
  const page = h("div", { class: "page-loading" }, h("div", { class: "spinner visible" }));
  if (!quiet) {
    clear(root);
    root.append(shell(page));
  }
  let content;
  try {
    content = await screenFor(route, token);
  } catch (error) {
    if (token !== state.renderToken) return;
    if (handleError(error)) return;
    content = emptyState("warning", "Couldn’t Load This Page", error.message, h("button", { class: "secondary-button", onclick: () => renderRoute() }, "Try Again"));
  }
  if (token !== state.renderToken || !content) return;
  clear(root);
  root.append(shell(content));
  if (quiet) window.scrollTo(0, scroll);
  const label = { home: "Home", movies: "Movies", shows: "TV Shows", search: "Search" }[route.name];
  if (label) document.title = `${label} · Aurelia`;
}

function screenFor(route, token) {
  switch (route.name) {
    case "movies":
      return libraryScreen("movie", route);
    case "shows":
      return libraryScreen("series", route);
    case "search":
      return searchScreen(route, token);
    case "title":
      return titleScreen(route.id);
    case "collection":
      return collectionScreen(route.id);
    default:
      return homeScreen();
  }
}

// MARK: Home

async function homeScreen() {
  const home = await api.home();
  const continuing = home.continueWatching ?? [];
  const hero = home.recommendation ?? continuing[0] ?? home.recentlyAdded?.[0];
  const sections = [];
  if (continuing.length) sections.push(rail("Continue Watching", continuing.map((item) => continueCard(item)), "landscape"));
  if (home.favorites?.length) sections.push(rail("Favorites", home.favorites.map((item) => posterCard(item))));
  if (home.recentlyAdded?.length) sections.push(rail("Recently Added", home.recentlyAdded.map((item) => posterCard(item))));
  if (home.collections?.length) sections.push(rail("Collections", home.collections.map((collection) => collectionCard(collection))));
  if (!hero && sections.length === 0)
    return emptyState("search", "Nothing Here Yet", "Your library is empty or this profile has no titles. Add a library folder in Aurelia on your Mac.");
  return h("div", { class: "home" }, hero ? heroBanner(hero) : null, h("div", { class: "sections" }, sections));
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
        h("button", { class: "primary-button", onclick: () => playTitle(item) }, icon("play", { size: 16 }), started ? "Resume" : "Play"),
        h("a", { class: "secondary-button", href: `/title/${target}`, "data-route": true }, "Details"))));
}

function rail(title, cards, kind = "poster") {
  const track = h("div", { class: `rail-track ${kind}` }, cards);
  const scroll = (direction) => track.scrollBy({ left: direction * track.clientWidth * 0.85, behavior: "smooth" });
  return h("section", { class: "rail" },
    h("div", { class: "section-header" }, h("h2", {}, title), h("span", { class: "count" }, String(cards.length)),
      h("div", { class: "rail-arrows" },
        h("button", { class: "icon-button", "aria-label": `Scroll ${title} back`, onclick: () => scroll(-1) }, icon("back")),
        h("button", { class: "icon-button", "aria-label": `Scroll ${title} forward`, onclick: () => scroll(1) }, icon("forward")))),
    track);
}

function artwork(image, width, className, alt) {
  const url = logic.artworkUrl(image, width);
  if (!url) return h("div", { class: `${className} artwork-missing` });
  const element = h("img", { class: className, src: url, alt, loading: "lazy", decoding: "async" });
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

function posterCard(item) {
  return h("a", { class: "poster-card", href: titleHref(item), "data-route": true },
    h("div", { class: "poster-frame" },
      artwork(item.poster, 320, "poster-art", ""),
      item.poster ? null : h("div", { class: "poster-fallback" }, item.title),
      badges(item), progressBar(item.progress)),
    h("div", { class: "card-title" }, item.kind === "episode" ? item.parentTitle ?? item.title : item.title),
    h("div", { class: "card-subtitle" }, item.kind === "episode" ? logic.eyebrow(item) : item.year ?? ""));
}

function continueCard(item) {
  return h("button", { class: "landscape-card", onclick: () => playTitle(item), "aria-label": `Resume ${item.parentTitle ?? item.title}` },
    h("div", { class: "landscape-frame" },
      artwork(item.backdrop ?? item.poster, 640, "landscape-art", ""),
      h("div", { class: "landscape-shade" }),
      h("div", { class: "landscape-text" },
        h("div", { class: "card-title" }, item.kind === "episode" ? item.parentTitle ?? item.title : item.title),
        h("div", { class: "card-subtitle" }, item.kind === "episode" ? `${logic.eyebrow({ ...item, parentTitle: null })} · ${item.title}` : logic.remaining(item.progress))),
      h("div", { class: "play-glyph" }, icon("play", { size: 18 })),
      progressBar(item.progress)));
}

function collectionCard(collection) {
  return h("a", { class: "poster-card", href: `/collection/${collection.id}`, "data-route": true },
    h("div", { class: "poster-frame" },
      artwork(collection.poster ?? collection.items?.[0]?.poster, 320, "poster-art", ""),
      h("span", { class: "badge count-badge" }, String(collection.items?.length ?? 0))),
    h("div", { class: "card-title" }, collection.name),
    h("div", { class: "card-subtitle" }, "Collection"));
}

function emptyState(symbol, title, text, action) {
  return h("div", { class: "empty-state" }, h("div", { class: "status-icon" }, icon(symbol, { size: 30 })), h("h2", {}, title), h("p", { class: "muted" }, text), action ?? null);
}

// MARK: Movies and TV shows

const SORTS = [
  ["title", "Title"],
  ["dateAdded", "Date Added"],
  ["releaseYear", "Release Year"],
  ["lastPlayed", "Last Played"],
];

async function libraryScreen(kind, route) {
  const sort = SORTS.some(([value]) => value === route.sort) ? route.sort : "title";
  const items = await loadAllPages(api.catalogPage, { kind, sort, direction: sort === "title" ? "ascending" : "descending" });
  const select = h("select", { class: "select", "aria-label": "Sort by", onchange: () => navigate({ ...route, sort: select.value }, { replace: true }) },
    SORTS.map(([value, label]) => h("option", { value, selected: value === sort }, label)));
  const title = kind === "movie" ? "Movies" : "TV Shows";
  return h("div", { class: "library" },
    h("div", { class: "page-header" }, h("h1", {}, title), h("span", { class: "count" }, String(items.length)), h("div", { class: "spacer" }), select),
    items.length ? h("div", { class: "poster-grid" }, items.map((item) => posterCard(item)))
      : emptyState("search", `No ${title}`, `This profile has no ${title.toLowerCase()} yet.`));
}

// MARK: Search

async function searchScreen(route) {
  const results = h("div", { class: "search-results" });
  const input = h("input", { class: "search-field", type: "search", placeholder: "Movies, shows and episodes", value: route.query, "aria-label": "Search", autocomplete: "off", enterkeyhint: "search" });
  let timer;
  let generation = 0;
  const run = async (query) => {
    const mine = ++generation;
    clear(results);
    if (!query.trim()) {
      results.append(emptyState("search", "Search Your Library", "Find a title by its name."));
      return;
    }
    results.append(h("div", { class: "page-loading" }, h("div", { class: "spinner visible" })));
    try {
      const page = await api.search({ query: query.trim(), limit: 100 });
      if (mine !== generation) return;
      clear(results);
      const items = page.items ?? [];
      results.append(items.length
        ? h("div", { class: "poster-grid" }, items.map((item) => posterCard(item)))
        : emptyState("search", "No Results", `Nothing matches “${query.trim()}”.`));
    } catch (error) {
      if (mine !== generation || handleError(error)) return;
      clear(results);
      results.append(emptyState("warning", "Search Failed", error.message));
    }
  };
  input.addEventListener("input", () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      state.route = { name: "search", query: input.value };
      history.replaceState(null, "", logic.routePath(state.route));
      run(input.value);
    }, 250);
  });
  run(route.query);
  setTimeout(() => input.focus(), 0);
  return h("div", { class: "search" }, h("div", { class: "page-header" }, h("h1", {}, "Search")), h("div", { class: "search-bar" }, icon("search"), input), results);
}

// MARK: Title details

async function titleScreen(id) {
  const [detail, plan] = await Promise.all([api.detail(id), api.playbackPlan(id).catch(() => null)]);
  const item = detail.item;
  const metadata = detail.metadata ?? {};
  document.title = `${item.title} · Aurelia`;
  const credits = (metadata.credits ?? []).filter((credit) => credit.department === "Acting").slice(0, 5).map((credit) => credit.name);
  const directors = (metadata.credits ?? []).filter((credit) => credit.job === "Director").map((credit) => credit.name);
  const facts = [metadata.year ?? item.year, logic.runtime(metadata.runtimeMinutes), metadata.contentRating,
    metadata.rating ? `★ ${metadata.rating.toFixed(1)}` : null].filter(Boolean);

  const favorite = h("button", { class: `round-button ${item.isFavorite ? "active" : ""}`, "aria-pressed": String(item.isFavorite), "aria-label": "Favorite" },
    icon(item.isFavorite ? "heartFill" : "heart"));
  favorite.addEventListener("click", async () => {
    const next = favorite.getAttribute("aria-pressed") !== "true";
    favorite.disabled = true;
    try {
      await api.setFavorite(item.id, next);
      favorite.setAttribute("aria-pressed", String(next));
      favorite.classList.toggle("active", next);
      favorite.replaceChildren(icon(next ? "heartFill" : "heart"));
    } catch (error) {
      if (!handleError(error)) toast(error.message);
    } finally {
      favorite.disabled = false;
    }
  });

  const watched = h("button", { class: `round-button ${item.watchState === "completed" ? "active" : ""}`, "aria-label": "Watched", "aria-pressed": String(item.watchState === "completed") },
    icon("checkCircle"));
  watched.addEventListener("click", async () => {
    watched.disabled = true;
    try {
      const current = await api.watchState(item.id, item.kind === "series" ? "series" : "title");
      const next = current.watchState !== "completed";
      const result = await api.setWatchState(item.id, {
        isWatched: next, scope: current.scope, seasonNumber: current.seasonNumber, stateToken: current.stateToken, clientMutationId: crypto.randomUUID(),
      });
      const done = result.watchState === "completed";
      watched.setAttribute("aria-pressed", String(done));
      watched.classList.toggle("active", done);
      renderRoute({ quiet: true });
    } catch (error) {
      if (!handleError(error)) toast(error.message);
    } finally {
      watched.disabled = false;
    }
  });

  const target = plan?.target ?? (item.kind === "series" ? null : item);
  const playLabel = !plan ? "Play" : plan.action === "resume" ? "Resume" : plan.action === "playAgain" ? "Play Again" : "Play";
  const playDetail = target && target.kind === "episode" ? ` S${target.seasonNumber ?? "?"} · E${target.episodeNumber ?? "?"}` : "";
  const play = target && target.availability === "available"
    ? h("button", { class: "primary-button", onclick: () => playTitle(target, detail.seasons) }, icon("play", { size: 16 }), playLabel + playDetail)
    : h("button", { class: "primary-button", disabled: true }, target ? "Unavailable" : "No Episodes");

  return h("div", { class: "detail" },
    h("section", { class: "hero detail-hero" },
      artwork(item.backdrop ?? metadata.backdrop ?? item.poster, 1920, "hero-art", ""),
      h("div", { class: "hero-shade" }),
      h("div", { class: "hero-content" },
        h("div", { class: "eyebrow" }, logic.eyebrow(item)),
        h("h1", { class: "hero-title" }, item.title),
        facts.length ? h("div", { class: "hero-meta" }, facts.join(" · ")) : null,
        item.genres?.length ? h("div", { class: "hero-meta" }, item.genres.join(" · ")) : null,
        h("div", { class: "button-row" }, play, favorite, watched),
        target ? progressLine(target) : null)),
    h("div", { class: "detail-body" },
      metadata.overview ?? item.overview ? h("p", { class: "overview" }, metadata.overview ?? item.overview) : null,
      credits.length ? h("p", { class: "credits" }, h("span", { class: "muted" }, "Starring "), credits.join(", ")) : null,
      directors.length ? h("p", { class: "credits" }, h("span", { class: "muted" }, directors.length > 1 ? "Directors " : "Director "), directors.join(", ")) : null),
    detail.seasons?.length ? seasonsSection(detail.seasons, target) : null,
    detail.supplements?.length ? rail("Extras", detail.supplements.map((supplement) => extraCard(supplement.item)), "landscape") : null);
}

function progressLine(item) {
  const left = logic.remaining(item.progress);
  if (!left) return null;
  return h("div", { class: "progress-line" }, h("div", { class: "progress inline" }, h("div", { class: "progress-fill", style: { width: `${logic.progressFraction(item.progress) * 100}%` } })), h("span", {}, left));
}

function seasonsSection(seasons, target) {
  const initialSeason = seasons.find((season) => season.episodes.some((entry) => entry.item.id === target?.id)) ?? seasons[0];
  const list = h("div", { class: "episode-list" });
  const choose = (season) => {
    for (const button of picker.querySelectorAll("button")) button.classList.toggle("selected", button.dataset.season === String(season.number));
    clear(list);
    list.append(...season.episodes.map((entry) => episodeRow(entry.item, seasons)));
  };
  const picker = h("div", { class: "season-picker", role: "tablist" }, seasons.map((season) =>
    h("button", { class: "chip", role: "tab", dataset: { season: String(season.number) }, onclick: () => choose(season) },
      season.number === 0 ? "Specials" : `Season ${season.number}`)));
  choose(initialSeason);
  return h("section", { class: "seasons" }, h("div", { class: "section-header" }, h("h2", {}, "Episodes")), picker, list);
}

function episodeRow(item, seasons) {
  const available = item.availability === "available";
  return h("button", { class: "episode-row", disabled: !available, onclick: () => playTitle(item, seasons) },
    h("div", { class: "episode-thumb" },
      artwork(item.backdrop ?? item.poster, 640, "landscape-art", ""),
      available ? h("div", { class: "play-glyph" }, icon("play", { size: 16 })) : null,
      progressBar(item.progress)),
    h("div", { class: "episode-text" },
      h("div", { class: "episode-title" }, logic.episodeLabel(item), item.watchState === "completed" ? icon("check", { size: 14, label: "Watched" }) : null),
      h("div", { class: "card-subtitle" }, available ? logic.remaining(item.progress) : "Unavailable: the file is offline."),
      item.overview ? h("p", { class: "episode-overview" }, item.overview) : null));
}

function extraCard(item) {
  return h("button", { class: "landscape-card", onclick: () => playTitle(item) },
    h("div", { class: "landscape-frame" },
      artwork(item.backdrop ?? item.poster, 640, "landscape-art", ""),
      h("div", { class: "landscape-shade" }),
      h("div", { class: "landscape-text" }, h("div", { class: "card-title" }, item.title)),
      h("div", { class: "play-glyph" }, icon("play", { size: 18 }))));
}

async function collectionScreen(id) {
  const collections = await api.collections();
  const collection = (collections ?? []).find((entry) => entry.id === id);
  if (!collection) return emptyState("search", "Collection Not Found", "It may have been removed.");
  document.title = `${collection.name} · Aurelia`;
  return h("div", { class: "library" },
    h("div", { class: "page-header" }, h("h1", {}, collection.name), h("span", { class: "count" }, String(collection.items.length))),
    h("div", { class: "poster-grid" }, collection.items.map((item) => posterCard(item))));
}

// MARK: Playing

async function playTitle(item, seasons) {
  let target = item;
  try {
    // A show starts where its plan says: the next or the started episode.
    if (item.kind === "series") {
      const plan = await api.playbackPlan(item.id);
      if (!plan?.target) return toast("This show has no episode to play.");
      target = plan.target;
    }
    if (target.kind === "episode" && !seasons && target.parentId) seasons = (await api.detail(target.parentId)).seasons;
  } catch (error) {
    if (!handleError(error)) toast(error.message);
    return;
  }
  closePlayer();
  const player = new Player({
    api,
    item: target,
    next: async () => (target.kind === "episode" ? logic.nextEpisode(seasons, target.id) : null),
    onPlayNext: (next) => playTitle(next, seasons),
    onClose: () => {
      if (state.player === player) state.player = null;
      // Progress and Continue Watching changed; show them without jumping to the top.
      if (state.profile) renderRoute({ quiet: true });
    },
    onSessionEnded: () => sessionEnded(),
    canConvert: Boolean(state.server?.capabilities?.includes(LIVE_FEATURE)),
  });
  state.player = player;
  player.open(document.body);
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
    while (!controller.signal.aborted) {
      try {
        const changes = await api.changes(after, generation, controller.signal);
        if (controller.signal.aborted) return;
        if (!first && (changes.resetRequired || changes.changedAreas?.length)) refreshSoon();
        after = changes.cursor;
        generation = changes.generation ?? generation;
        first = false;
        failures = 0;
      } catch (error) {
        if (controller.signal.aborted || error?.name === "AbortError") return;
        if (error instanceof ApiError && (error.status === 401 || error.status === 403)) return sessionEnded();
        failures += 1;
        await new Promise((resolve) => setTimeout(resolve, Math.min(30_000, 2_000 * 2 ** Math.min(failures, 4))));
      }
    }
  })();
}

function stopSync() {
  state.sync?.abort();
  state.sync = null;
}

function refreshSoon() {
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

start();
