// The Movie Night page: a lobby, a stack of posters to swipe, and the ticket for the match.
// The session lives here, outside the page, so moving around the app keeps this browser in it.

import { h, icon, clear } from "./dom.js";
import { createMovieNight, swipeChoice, cardMeta, slowpokes, screenOf, isHost, SWIPE_DISTANCE } from "./movie-night.js";

export function createMovieNightView({ api, artwork, playTitle, navigate, deviceName }) {
  let session = null;
  let root = null;
  let dragging = false;
  let dirty = false;

  function ensureSession() {
    session ??= createMovieNight({ api, deviceName, onChange: () => refresh() });
    return session;
  }

  function refresh() {
    if (!root?.isConnected) return;
    if (dragging) {
      dirty = true;
      return;
    }
    render();
  }

  /** The page for the route. */
  function screen() {
    root = h("div", { class: "movie-night page-enter" });
    render();
    return root;
  }

  function render() {
    dirty = false;
    clear(root);
    const current = ensureSession();
    const state = current.state;
    if (current.error) {
      root.append(h("div", { class: "mn-error", role: "alert" }, h("span", {}, current.error),
        h("button", { class: "icon-button", "aria-label": "Dismiss", onclick: () => current.clearError() }, icon("close", { size: 16 }))));
    }
    const view = screenOf(state, current.remaining.length);
    root.append({
      intro, lobby, swipe, waiting, match: result, "no-match": result,
    }[view](current, state));
  }

  function heading(title, text) {
    return h("div", { class: "mn-heading" }, h("h1", {}, title), text ? h("p", { class: "muted" }, text) : null);
  }

  function intro(current) {
    const list = h("div", { class: "mn-open" });
    api.movieNights().then((nights) => {
      if (!list.isConnected || !nights?.length) return;
      list.append(h("h2", {}, "Happening now"), ...nights.map((night) => h("div", { class: "mn-open-row" },
        h("div", {}, h("strong", {}, `${night.hostName}’s night`), h("div", { class: "muted small" },
          `${night.hostDevice} · ${night.memberCount === 1 ? "1 person" : `${night.memberCount} people`}`)),
        h("button", { class: "primary-button", onclick: () => current.join(night.id) }, "Join"))));
    }, () => {});
    return h("section", { class: "mn-intro" },
      h("div", { class: "mn-intro-art", "aria-hidden": "true" },
        h("div", { class: "mn-ghost one" }), h("div", { class: "mn-ghost two" }), h("div", { class: "mn-ghost three" })),
      heading("Movie Night", "Everyone swipes through the same films on their own phone. The first one you all like wins, and nobody finds out who said no to what."),
      h("div", { class: "button-row" },
        h("button", { class: "primary-button large", onclick: () => current.start(true) }, "Start Movie Night"),
        h("button", { class: "secondary-button large", onclick: () => current.start(false) }, "Use This Screen for the Lobby")),
      list);
  }

  function people(state, deckSize = 0) {
    return h("ul", { class: "mn-people" }, state.members.map((member) => h("li", {},
      h("span", { class: "mn-initial", "aria-hidden": "true" }, (member.name.trim()[0] ?? "?").toUpperCase()),
      h("span", { class: "mn-person" },
        h("strong", {}, member.isYou ? `${member.name} (you)` : member.name),
        h("span", { class: "muted small" }, [member.deviceName, member.isHost ? "started it" : null, member.isVoting ? null : "only watches"].filter(Boolean).join(" · "))),
      deckSize && member.isVoting ? h("span", { class: "mn-count muted small" }, `${member.swiped}/${deckSize}`) : null)));
  }

  function lobby(current, state) {
    const host = state.members.find((member) => member.isHost);
    const me = state.members.find((member) => member.isYou);
    const chip = (label, selected, action) => h("button", { class: `chip ${selected ? "selected" : ""}`, "aria-pressed": selected ? "true" : "false", onclick: action }, label);
    const voters = state.members.filter((member) => member.isVoting).length;
    return h("section", { class: "mn-lobby" },
      heading("Movie Night", voters ? `${voters === 1 ? "1 person is" : `${voters} people are`} ready to swipe. Anyone else at home can join from Aurelia on their phone or Mac.`
        : "Nobody is swiping yet. Open Aurelia on a phone and join this night."),
      people(state),
      isHost(state) ? h("div", { class: "mn-options" },
        h("div", { class: "mn-option-row", role: "group", "aria-label": "What to deal" },
          chip("Movies", state.kinds !== "all", () => current.settings("movies", state.genre)),
          chip("Movies and shows", state.kinds === "all", () => current.settings("all", state.genre))),
        state.genreOptions?.length ? h("div", { class: "mn-option-row", role: "group", "aria-label": "Genre" },
          chip("Any genre", !state.genre, () => current.settings(state.kinds, null)),
          state.genreOptions.map((genre) => chip(genre, state.genre === genre, () => current.settings(state.kinds, genre)))) : null) : null,
      h("div", { class: "button-row" },
        isHost(state)
          ? h("button", { class: "primary-button large", disabled: voters === 0, onclick: () => current.deal() }, "Deal the Cards")
          : h("p", { class: "muted" }, `Waiting for ${host?.name ?? "the host"} to deal.`),
        h("button", { class: "secondary-button", onclick: () => current.setVoting(!me?.isVoting) }, me?.isVoting ? "Just Watch on This Screen" : "Swipe Here Too"),
        h("button", { class: "secondary-button", onclick: () => current.leave() }, "Leave")));
  }

  function swipe(current, state) {
    const cards = current.remaining.slice(0, 3);
    const total = current.deck.length;
    const stack = h("div", { class: "mn-stack" }, cards.slice().reverse().map((card, index, all) => cardElement(card, all.length - 1 - index)));
    const top = stack.lastElementChild;
    const fling = (choice) => flyOut(top, choice, () => current.vote(cards[0].mediaId, choice === "like"));
    attachDrag(top, fling);
    const keys = (event) => {
      if (!root?.isConnected || !top.isConnected) return document.removeEventListener("keydown", keys);
      if (event.target?.closest?.("input, select, textarea")) return;
      if (event.key === "ArrowRight") { event.preventDefault(); fling("like"); }
      else if (event.key === "ArrowLeft") { event.preventDefault(); fling("nope"); }
    };
    document.addEventListener("keydown", keys);
    const others = state.members.filter((member) => member.isVoting && !member.isYou);
    return h("section", { class: "mn-swipe" },
      stack,
      h("div", { class: "mn-actions" },
        h("button", { class: "mn-button nope", "aria-label": "Nope", onclick: () => fling("nope") }, icon("close", { size: 30 })),
        h("div", { class: "mn-progress" },
          h("strong", {}, `${total - current.remaining.length + 1} of ${total}`),
          others.length ? h("span", { class: "muted small" }, others.map((member) => `${member.name} ${member.swiped}`).join(" · ")) : null),
        h("button", { class: "mn-button like", "aria-label": "Yes", onclick: () => fling("like") }, icon("heartFill", { size: 30 }))),
      h("p", { class: "mn-hint muted small" }, "Swipe right if you’d watch it tonight, left if not. Arrow keys work too."));
  }

  function cardElement(card, depth) {
    const meta = cardMeta(card);
    return h("article", { class: `mn-card depth-${depth}`, "aria-label": card.title, ...(depth === 0 ? { tabindex: "0" } : { "aria-hidden": "true" }) },
      artwork(card.poster ?? card.backdrop, 600, "mn-card-art", ""),
      h("div", { class: "mn-card-info" },
        h("h2", {}, card.title),
        meta.length ? h("div", { class: "mn-card-meta" }, meta.join(" · ")) : null,
        card.overview ? h("p", {}, card.overview) : null),
      h("div", { class: "mn-stamp like", "aria-hidden": "true" }, "Yes!"),
      h("div", { class: "mn-stamp nope", "aria-hidden": "true" }, "Nope"));
  }

  function attachDrag(card, fling) {
    if (!card) return;
    let start = null;
    const move = (dx, dy) => {
      card.style.setProperty("transform", `translate(${dx}px, ${dy * 0.25}px) rotate(${dx / 16}deg)`);
      const strength = Math.min(1, Math.abs(dx) / SWIPE_DISTANCE);
      card.style.setProperty("--like", dx > 0 ? String(strength) : "0");
      card.style.setProperty("--nope", dx < 0 ? String(strength) : "0");
    };
    card.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      start = { x: event.clientX, y: event.clientY, time: performance.now(), lastX: event.clientX, lastTime: performance.now() };
      dragging = true;
      card.setPointerCapture?.(event.pointerId);
      card.classList.add("dragging");
    });
    card.addEventListener("pointermove", (event) => {
      if (!start) return;
      move(event.clientX - start.x, event.clientY - start.y);
      start.velocity = (event.clientX - start.lastX) / Math.max(1, performance.now() - start.lastTime);
      start.lastX = event.clientX;
      start.lastTime = performance.now();
    });
    const release = (event) => {
      if (!start) return;
      const dx = event.clientX - start.x;
      const choice = swipeChoice(dx, start.velocity ?? 0, card.getBoundingClientRect().width);
      start = null;
      card.classList.remove("dragging");
      if (choice) return fling(choice);
      dragging = false;
      move(0, 0);
      if (dirty) render();
    };
    card.addEventListener("pointerup", release);
    card.addEventListener("pointercancel", release);
  }

  function flyOut(card, choice, done) {
    if (!card || card.classList.contains("gone")) return;
    dragging = true;
    card.classList.add("gone");
    const reduce = window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches;
    card.style.setProperty(choice === "like" ? "--like" : "--nope", "1");
    card.style.setProperty("transform", `translate(${choice === "like" ? 140 : -140}vw, 8vh) rotate(${choice === "like" ? 30 : -30}deg)`);
    setTimeout(() => {
      dragging = false;
      done();
    }, reduce ? 0 : 260);
  }

  function waiting(current, state) {
    const total = current.deck.length;
    const me = state.members.find((member) => member.isYou);
    const slow = slowpokes(state, total);
    return h("section", { class: "mn-waiting" },
      heading(me?.isVoting ? "You’re done." : "Swiping in progress",
        slow.length ? (me?.isVoting ? "Now we wait for the slowpokes." : "The match shows up here the moment everyone agrees.") : "Counting the votes…"),
      people(state, total),
      h("div", { class: "button-row" },
        me?.isVoting ? null : h("button", { class: "secondary-button", onclick: () => current.setVoting(true) }, "Swipe Here Too"),
        h("button", { class: "secondary-button", onclick: () => current.deal() }, "Deal New Cards"),
        h("button", { class: "secondary-button", onclick: () => current.leave() }, "Leave")));
  }

  function result(current, state) {
    const outcome = state.result;
    const card = outcome?.card;
    const voters = state.members.filter((member) => member.isVoting).map((member) => member.name);
    const ticket = card ? h("div", { class: "mn-ticket" },
      h("div", { class: "mn-ticket-main" },
        artwork(card.poster ?? card.backdrop, 500, "mn-ticket-art", ""),
        h("div", { class: "mn-ticket-text" },
          h("p", { class: "mn-ticket-headline" }, outcome.headline),
          h("h2", {}, card.title),
          h("div", { class: "muted" }, cardMeta(card).join(" · ")),
          h("p", { class: "mn-line" }, outcome.line))),
      h("div", { class: "mn-ticket-stub" },
        h("strong", {}, outcome.isUnanimous ? `Admit ${voters.length}` : `${outcome.likes} of ${outcome.voters} said yes`),
        h("span", {}, voters.join(", ")))) : h("div", { class: "mn-ticket empty" },
      h("p", { class: "mn-ticket-headline" }, outcome?.headline ?? "No match."),
      h("p", { class: "mn-line" }, outcome?.line ?? ""));
    return h("section", { class: "mn-result" },
      ticket,
      outcome?.awards?.length ? h("ul", { class: "mn-awards" }, outcome.awards.map((award) =>
        h("li", {}, h("strong", {}, award.title), h("span", {}, award.line)))) : null,
      h("div", { class: "button-row" },
        card ? h("button", { class: "primary-button large", onclick: () => playTitle({ id: card.mediaId, kind: card.kind, title: card.title, poster: card.poster, backdrop: card.backdrop, genres: card.genres }) },
          icon("play", { size: 16 }), "Play") : null,
        card ? h("button", { class: "secondary-button", onclick: () => navigate({ name: "title", id: card.mediaId }) }, "Details") : null,
        state.phase === "match" ? h("button", { class: "secondary-button", onclick: () => current.keepSwiping() }, "Keep Swiping") : null,
        h("button", { class: "secondary-button", onclick: () => current.deal() }, "Deal New Cards"),
        h("button", { class: "secondary-button", onclick: () => current.leave() }, "Leave")));
  }

  /** A line on Home: back to this browser's night, a night to join, or a way to start one. */
  function homeStrip() {
    const strip = h("a", { class: "mn-home", href: "/movie-night", "data-route": true });
    const fill = (title, text) => {
      clear(strip);
      strip.append(h("span", { class: "mn-home-cards", "aria-hidden": "true" }, h("i", {}), h("i", {}), h("i", {})),
        h("span", { class: "mn-home-text" }, h("strong", {}, title), h("span", { class: "muted small" }, text)),
        icon("forward", { size: 18 }));
    };
    if (session?.state) {
      fill("You’re in a Movie Night", "Go back to swiping.");
      return strip;
    }
    fill("Can’t decide what to watch?", "Start a Movie Night and let everyone swipe.");
    api.movieNights().then((nights) => {
      const night = nights?.[0];
      if (night && strip.isConnected) fill(`${night.hostName}’s Movie Night is on`, "Join and start swiping.");
    }, () => {});
    return strip;
  }

  return {
    screen,
    homeStrip,
    leave: () => session?.leave(),
  };
}
