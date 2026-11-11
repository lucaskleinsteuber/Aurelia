// Movie Night in the browser: the rules that need no page (swipe distance, what is left to
// swipe, labels) and the session that keeps this browser in a night.

/** How far a card must travel, in pixels, before letting go counts as a vote. */
export const SWIPE_DISTANCE = 110;

/** "like", "nope" or null for a card let go at `dx` pixels, moving at `velocity` pixels per ms. */
export function swipeChoice(dx, velocity = 0, width = 360) {
  const limit = Math.min(SWIPE_DISTANCE, Math.max(60, width * 0.3));
  if (dx >= limit || (velocity > 0.6 && dx > 30)) return "like";
  if (dx <= -limit || (velocity < -0.6 && dx < -30)) return "nope";
  return null;
}

/** The cards this person has not swiped yet, in deck order. */
export function remainingCards(deck, yourVotes, pending = new Map()) {
  const voted = new Set((yourVotes ?? []).map((vote) => vote.mediaId));
  for (const id of pending.keys()) voted.add(id);
  return (deck ?? []).filter((card) => !voted.has(card.mediaId));
}

/** "1h 52m", "48m", or null. */
export function runtimeLabel(minutes) {
  if (!(minutes > 0)) return null;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return hours ? (rest ? `${hours}h ${rest}m` : `${hours}h`) : `${rest}m`;
}

export function cardMeta(card) {
  return [card.year, runtimeLabel(card.runtimeMinutes), ...(card.genres ?? []).slice(0, 2)].filter(Boolean).map(String);
}

/** The voters still swiping, slowest first, for the waiting screen. */
export function slowpokes(state, deckSize) {
  return (state?.members ?? [])
    .filter((member) => member.isVoting && member.swiped < deckSize)
    .sort((a, b) => a.swiped - b.swiped);
}

/** What this browser shows: "intro", "lobby", "swipe", "waiting", "match" or "no-match". */
export function screenOf(state, remaining) {
  if (!state) return "intro";
  if (state.phase === "lobby") return "lobby";
  if (state.phase === "match" || state.phase === "no-match") return state.phase;
  const me = state.members?.find((member) => member.isYou);
  return me?.isVoting && remaining > 0 ? "swipe" : "waiting";
}

/** The choices the host can make before a deal, in the order the lobby shows them. */
export const PROGRAM = Object.freeze({
  kinds: [["movies", "Movies"], ["all", "Movies and shows"]],
  era: [["any", "Any time"], ["2020s", "2020s"], ["2010s", "2010s"], ["2000s", "2000s"], ["older", "Older"]],
  length: [["any", "Any length"], ["short", "Short, up to 1h 40m"], ["standard", "Up to 2h 10m"]],
});

/** Tonight's choices with one of them changed; a server without eras and lengths keeps them out. */
export function programChoices(state, change = {}) {
  const choices = { kinds: state?.kinds ?? "movies", genre: state?.genre ?? null, era: state?.era ?? "any", length: state?.length ?? "any", ...change };
  return { kinds: choices.kinds, genre: choices.genre || null, era: choices.era, length: choices.length };
}

/** "Movies · Comedy · 2010s · Short" for what the host chose. */
export function programSummary(state) {
  const choice = programChoices(state);
  const label = (list, value) => list.find(([key]) => key === value)?.[1];
  return [
    choice.kinds === "all" ? "Movies and shows" : "Movies",
    choice.genre,
    choice.era !== "any" ? label(PROGRAM.era, choice.era) : null,
    choice.length === "short" ? "Short" : choice.length === "standard" ? "Up to 2h 10m" : null,
  ].filter(Boolean).join(" · ");
}

/** How long a card flies off: a fast flick leaves quicker than a slow push, never instantly. */
export function flingDuration(velocity = 0) {
  return Math.round(Math.min(420, Math.max(180, 420 - Math.abs(velocity) * 140)));
}

export function isHost(state) {
  return Boolean(state?.members?.find((member) => member.isYou)?.isHost);
}

/**
 * The night this browser is in. `onChange(session)` runs whenever something changed; the
 * deck is kept between polls, which only carry it again when it changed.
 */
export function createMovieNight({ api, deviceName, onChange = () => {}, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) }) {
  let state = null;
  let deck = [];
  let error = null;
  let polling = null;
  const pending = new Map();
  const changed = () => onChange(session);

  function receive(next) {
    // Answers can arrive out of order; an older state never undoes a newer one.
    if (state && state.id === next.id && next.revision < state.revision) return;
    if (next.deck) {
      deck = next.deck;
      const inDeck = new Set(deck.map((card) => card.mediaId));
      for (const id of [...pending.keys()]) if (!inDeck.has(id)) pending.delete(id);
    }
    if (state && next.round !== state.round) pending.clear();
    for (const vote of next.yourVotes ?? []) pending.delete(vote.mediaId);
    state = { ...next, deck: undefined };
    changed();
  }

  async function run(action) {
    try {
      receive(await action());
      error = null;
      startPolling();
      return true;
    } catch (failure) {
      error = failure?.message || "Movie Night isn’t available right now.";
      changed();
      return false;
    }
  }

  function startPolling() {
    if (polling) return;
    const controller = new AbortController();
    polling = controller;
    (async () => {
      let failures = 0;
      while (!controller.signal.aborted && state) {
        try {
          const next = await api.movieNight(state.id, state.revision, state.deckVersion, 20000, { signal: controller.signal });
          failures = 0;
          if (!controller.signal.aborted) receive(next);
        } catch (failure) {
          if (controller.signal.aborted || failure?.name === "AbortError") return;
          if (failure?.status === 403 || failure?.status === 404) return ended("This Movie Night has ended.");
          if (++failures >= 6) return ended("Lost the connection to Movie Night.");
          await sleep(2000);
        }
      }
    })();
  }

  function ended(message) {
    error = message;
    state = null;
    deck = [];
    pending.clear();
    polling = null;
    changed();
  }

  const session = {
    get state() { return state; },
    get deck() { return deck; },
    get error() { return error; },
    get remaining() { return state ? remainingCards(deck, state.yourVotes, pending) : []; },
    clearError() { error = null; changed(); },
    start: (isVoting = true) => run(() => api.createMovieNight({ deviceName, isVoting })),
    join: (nightId, isVoting = true) => run(() => api.joinMovieNight(nightId, { deviceName, isVoting })),
    /** Changes tonight's program: kinds, genre, era or length; the others stay as they are. */
    settings: (change) => state && run(() => api.movieNightSettings(state.id, programChoices(state, change))),
    deal: () => state && run(() => api.dealMovieNight(state.id)),
    keepSwiping: () => state && run(() => api.keepSwiping(state.id)),
    setVoting: (isVoting) => state && run(() => api.movieNightRole(state.id, { isVoting })),
    /** Counts at once here; the server's answer follows. */
    vote(mediaId, like) {
      if (!state) return;
      pending.set(mediaId, like);
      changed();
      const id = state.id;
      api.movieNightVote(id, { mediaId, like }).then(receive, (failure) => {
        pending.delete(mediaId);
        error = failure?.message || "That swipe didn’t reach the server. Try it again.";
        changed();
      });
    },
    async leave() {
      polling?.abort();
      polling = null;
      const id = state?.id;
      state = null;
      deck = [];
      pending.clear();
      changed();
      if (id) await api.leaveMovieNight(id).catch(() => {});
    },
    receive,
  };
  return session;
}
