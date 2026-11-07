// Watch Together in the browser: the same party protocol and following rules as the Mac, Linux
// and Apple TV players. The player follows the shared state and sends what happens here.

export const DRIFT_TOLERANCE = 1500;
export const STILL_TOLERANCE = 500;
/** Browser video events that follow a remote step are not sent back as this player's own. */
export const REMOTE_QUIET_MS = 800;

export function shouldPlay(state) {
  return Boolean(state?.isPlaying && !state.isWaiting);
}

/** The shared position at `serverNow` (milliseconds since 1970). */
export function partyPosition(state, serverNow) {
  if (!shouldPlay(state)) return state.positionMilliseconds;
  const updated = Date.parse(state.updatedAt);
  if (!Number.isFinite(updated)) return state.positionMilliseconds;
  return state.positionMilliseconds + Math.max(0, Math.round(serverNow - updated));
}

/** The few steps that bring a player to the shared moment; small differences are left alone. */
export function followSteps(state, serverNow, localPosition, localPlaying) {
  const steps = [];
  const target = partyPosition(state, serverNow);
  const playing = shouldPlay(state);
  if (Math.abs(localPosition - target) > (playing ? DRIFT_TOLERANCE : STILL_TOLERANCE)) steps.push({ step: "seek", position: target });
  if (playing !== localPlaying) steps.push({ step: playing ? "play" : "pause" });
  return steps;
}

/** The server's clock minus this one, assuming the answer was written halfway through the request. */
export function clockOffset(serverTime, sent, received) {
  const server = Date.parse(serverTime);
  return Number.isFinite(server) ? server - (sent + (received - sent) / 2) : 0;
}

export function partyNotice(state) {
  const by = state?.lastActionBy;
  if (!by) return null;
  switch (state.lastAction) {
    case "play": return `${by} pressed play`;
    case "pause": return `${by} paused`;
    case "seek": return `${by} jumped to another moment`;
    case "joined": return `${by} joined`;
    case "left": return `${by} left`;
    case "change": return `${by} started ${state.title}`;
    default: return null;
  }
}

/**
 * The party this browser is in. `player` is an adapter: { mediaId, position(), playing(), ready(),
 * play(), pause(), seek(ms) }. `onChange` runs whenever the state or notice changes; `openTitle`
 * opens another title when the party moves on.
 */
export function createWatchTogether({ api, deviceName, now = () => Date.now(), onChange = () => {}, openTitle = () => {}, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) }) {
  let state = null;
  let notice = null;
  let error = null;
  let player = null;
  let offset = 0;
  let polling = null;
  let applyingUntil = 0;
  let reportedReady = false;
  let changingTitle = false;
  let noticeTimer = null;
  const own = new Set();

  const changed = () => onChange(session);

  function receive(next, sent, mine) {
    offset = clockOffset(next.serverTime, sent, now());
    if (mine) own.add(next.revision);
    // Answers can arrive out of order; an older state never undoes a newer one.
    if (state && state.id === next.id && next.revision < state.revision) return;
    const isNew = next.revision !== state?.revision;
    state = next;
    if (isNew && !mine && !own.has(next.revision)) {
      const text = partyNotice(next);
      if (text) show(text);
    }
    const me = next.members?.find((member) => member.isYou);
    if (me?.isBuffering && player && player.mediaId === next.mediaId && player.ready()) send({ action: "ready" });
    apply(next);
    changed();
  }

  function show(text) {
    notice = text;
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => {
      notice = null;
      changed();
    }, 4000);
  }

  function apply(next) {
    if (!player) return;
    if (next.mediaId !== player.mediaId) {
      if (changingTitle) return;
      changingTitle = true;
      openTitle(next.mediaId, next.title);
      return;
    }
    if (!player.ready()) return;
    const steps = followSteps(next, now() + offset, player.position(), player.playing());
    if (steps.length) applyingUntil = now() + REMOTE_QUIET_MS;
    for (const { step, position } of steps) {
      if (step === "seek") player.seek(position);
      else if (step === "play") player.play();
      else player.pause();
    }
  }

  async function run(action) {
    try {
      const sent = now();
      const next = await action();
      receive(next, sent, true);
      error = null;
      startPolling();
      return true;
    } catch (failure) {
      error = failure?.message || "Watch Together isn’t available right now.";
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
        const sent = now();
        try {
          const next = await api.watchParty(state.id, state.revision, 20000, { signal: controller.signal });
          failures = 0;
          if (!controller.signal.aborted) receive(next, sent, false);
        } catch (failure) {
          if (controller.signal.aborted || failure?.name === "AbortError") return;
          if (failure?.status === 403 || failure?.status === 404) return ended("The Watch Together party has ended.");
          if (++failures >= 6) return ended("Lost the Watch Together party.");
          await sleep(2000);
        }
      }
    })();
  }

  function ended(message) {
    error = message;
    state = null;
    polling = null;
    player = null;
    changed();
  }

  function send(body) {
    if (!state) return;
    const sent = now();
    const id = state.id;
    api.watchPartyCommand(id, body).then((next) => receive(next, sent, true), (failure) => {
      error = failure?.message || "Watch Together couldn’t send that.";
      changed();
    });
  }

  const session = {
    get state() { return state; },
    get notice() { return notice; },
    get error() { return error; },
    get isChangingTitle() { return changingTitle; },
    start: (mediaId, positionMilliseconds, isPlaying) =>
      run(() => api.createWatchParty({ mediaId, positionMilliseconds, isPlaying, deviceName })),
    join: (partyId) => run(() => api.joinWatchParty(partyId, { deviceName })),
    async leave() {
      polling?.abort();
      polling = null;
      const id = state?.id;
      player = null;
      state = null;
      changed();
      if (id) await api.leaveWatchParty(id).catch(() => {});
    },
    attach(next) {
      player = next;
      changingTitle = false;
      reportedReady = false;
      session.playerChanged();
    },
    detach() { player = null; },
    isFollowing: (candidate) => player === candidate,
    /** The player became ready, started loading, or moved to another title by itself. */
    playerChanged() {
      if (!player || !state) return;
      if (player.mediaId !== state.mediaId) {
        if (changingTitle) return;
        reportedReady = false;
        send({ action: "change", positionMilliseconds: 0, mediaId: player.mediaId });
        return;
      }
      changingTitle = false;
      const me = state.members?.find((member) => member.isYou);
      if (player.ready()) {
        if (me?.isBuffering || !reportedReady) {
          reportedReady = true;
          send({ action: "ready" });
        }
        apply(state);
      } else if (reportedReady && me && !me.isBuffering) {
        send({ action: "buffering" });
      }
    },
    /** Play, pause or seek someone did here; echoes of remote steps are ignored. */
    userAction(action, positionMilliseconds) {
      if (!state || now() < applyingUntil) return;
      send({ action, positionMilliseconds: Math.round(positionMilliseconds) });
    },
    receive,
  };
  return session;
}
