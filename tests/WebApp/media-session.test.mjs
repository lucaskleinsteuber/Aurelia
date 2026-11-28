// The browser player in the system's media controls, with an invented title and a stand-in for
// navigator.mediaSession. No browser, network or files.
import test from "node:test";
import assert from "node:assert/strict";
import { attachMediaSession, mediaMetadataFor, positionStateFor, supportsMediaSession } from "../../src/Tarven.Server/WebApp/js/media-session.js";

class FakeMetadata { constructor(values) { Object.assign(this, values); } }

function fakeNavigator({ refuse = [] } = {}) {
  const handlers = new Map();
  const positions = [];
  return {
    handlers, positions,
    mediaSession: {
      metadata: undefined,
      playbackState: "none",
      setActionHandler(action, handler) {
        if (refuse.includes(action)) throw new TypeError(`${action} is not supported`);
        if (handler) handlers.set(action, handler); else handlers.delete(action);
      },
      setPositionState(state) { positions.push(state); },
    },
  };
}

const episode = { id: "e1", kind: "episode", title: "Low Tide", parentTitle: "Harbor Lights", seasonNumber: 2, episodeNumber: 1,
  poster: { path: "/api/v1/artwork/invented", revision: 3 } };

test("an episode shows its show and number, a movie its year, with the poster", () => {
  const url = (image, width) => image ? `${image.path}?width=${width}` : "";
  const shown = mediaMetadataFor(episode, url);
  assert.deepEqual({ title: shown.title, artist: shown.artist, album: shown.album },
    { title: "Low Tide", artist: "Harbor Lights · S2 E1", album: "Tarven" });
  assert.deepEqual(shown.artwork.map((entry) => entry.sizes), ["320x480", "640x960"]);
  assert.equal(mediaMetadataFor({ kind: "movie", title: "Amber Fields", year: 2019 }, url).artist, "2019");
  assert.deepEqual(mediaMetadataFor({ kind: "movie", title: "No Poster" }, url).artwork, []);
  assert.equal(mediaMetadataFor(null), null);
});

test("the position is shown only once it is known, and never past the end", () => {
  assert.equal(positionStateFor({ duration: NaN, currentTime: 0 }), null);
  assert.equal(positionStateFor({ duration: 0, currentTime: 0 }), null);
  assert.deepEqual(positionStateFor({ duration: 100, currentTime: 120, playbackRate: 1.5 }), { duration: 100, position: 100, playbackRate: 1.5 });
  assert.deepEqual(positionStateFor({ duration: 100, currentTime: 12, playbackRate: 0 }), { duration: 100, position: 12, playbackRate: 1 });
});

test("the system's buttons reach the player, and closing clears them", () => {
  const nav = fakeNavigator({ refuse: ["stop"] });
  assert.equal(supportsMediaSession(nav, FakeMetadata), true);
  const calls = [];
  const session = attachMediaSession({
    nav, Metadata: FakeMetadata, seekSeconds: 15, metadata: mediaMetadataFor(episode),
    handlers: {
      play: () => calls.push("play"), pause: () => calls.push("pause"),
      seekBy: (seconds) => calls.push(`by ${seconds}`), seekTo: (seconds) => calls.push(`to ${seconds}`),
      previous: () => calls.push("previous"), next: () => calls.push("next"),
    },
  });
  assert.equal(nav.mediaSession.metadata.title, "Low Tide");
  nav.handlers.get("play")();
  nav.handlers.get("pause")();
  nav.handlers.get("seekforward")({});
  nav.handlers.get("seekbackward")({ seekOffset: 5 });
  nav.handlers.get("seekto")({ seekTime: 42 });
  nav.handlers.get("seekto")({});
  assert.deepEqual(calls, ["play", "pause", "by 15", "by -5", "to 42"]);
  // An action the browser doesn't know is skipped; the others still work.
  assert.equal(nav.handlers.has("stop"), false);

  assert.equal(nav.handlers.has("nexttrack"), false);
  session.setEpisodes(false, true);
  assert.equal(nav.handlers.has("previoustrack"), false);
  nav.handlers.get("nexttrack")();
  assert.deepEqual(calls.at(-1), "next");

  session.update({ duration: 60, currentTime: 30, playbackRate: 1 }, true);
  assert.equal(nav.mediaSession.playbackState, "playing");
  assert.deepEqual(nav.positions.at(-1), { duration: 60, position: 30, playbackRate: 1 });

  session.detach();
  assert.equal(nav.handlers.size, 0);
  assert.equal(nav.mediaSession.metadata, null);
  assert.equal(nav.mediaSession.playbackState, "none");
  session.update({ duration: 60, currentTime: 31 }, true);
  assert.equal(nav.mediaSession.playbackState, "none");
});

test("without the API nothing happens", () => {
  const session = attachMediaSession({ nav: {}, Metadata: undefined, metadata: mediaMetadataFor(episode), handlers: {} });
  assert.doesNotThrow(() => { session.update({ duration: 1, currentTime: 0 }, true); session.setEpisodes(true, true); session.detach(); });
});
