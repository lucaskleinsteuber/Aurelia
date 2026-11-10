import { test } from "node:test";
import assert from "node:assert/strict";
import { cardMeta, createMovieNight, remainingCards, runtimeLabel, screenOf, slowpokes, swipeChoice } from "../../src/Aurelia.Server/WebApp/js/movie-night.js";
import { parseRoute, routePath } from "../../src/Aurelia.Server/WebApp/js/logic.js";

// Movie Night in the browser with an invented night and server; nothing is played.
const ids = ["00000000-0000-4000-8000-0000000000a1", "00000000-0000-4000-8000-0000000000a2", "00000000-0000-4000-8000-0000000000a3"];
const deck = ids.map((mediaId, index) => ({ mediaId, kind: "movie", title: `Invented Film ${index + 1}`, year: 2020 + index, runtimeMinutes: 95 + index * 30, genres: ["Comedy", "Crime", "Drama"] }));

function night({ phase = "voting", revision = 2, round = 1, deckVersion = 1, withDeck = true, yourVotes = [], voting = true, result = null } = {}) {
  return {
    id: "00000000-0000-4000-8000-0000000000b1", phase, revision, round, deckVersion, kinds: "movies", genre: null, genreOptions: ["Comedy"],
    members: [{ id: "m1", name: "Browser", deviceName: "Chrome", isVoting: voting, isHost: true, isYou: true, swiped: yourVotes.length },
      { id: "m2", name: "Mia", deviceName: "Phone", isVoting: true, isHost: false, isYou: false, swiped: 1 }],
    deck: withDeck ? deck : null, yourVotes, result, lastAction: "swiped", lastActionBy: "Mia",
  };
}

function fakeApi(answers) {
  const sent = [];
  const next = (name, body) => { sent.push([name, body]); return Promise.resolve(answers.shift()); };
  return { sent,
    createMovieNight: (body) => next("create", body), joinMovieNight: (_, body) => next("join", body),
    movieNightVote: (_, body) => next("vote", body), dealMovieNight: () => next("deal"), keepSwiping: () => next("keep"),
    movieNightSettings: (_, body) => next("settings", body), movieNightRole: (_, body) => next("role", body), leaveMovieNight: async () => null,
    movieNight: (_, __, ___, ____, { signal }) => new Promise((_, reject) => signal.addEventListener("abort", () => reject(Object.assign(new Error("aborted"), { name: "AbortError" })))) };
}

test("a card counts as a vote once it travels far enough or is flicked", () => {
  assert.equal(swipeChoice(120), "like");
  assert.equal(swipeChoice(-120), "nope");
  assert.equal(swipeChoice(40), null);
  assert.equal(swipeChoice(40, 0.9), "like");
  assert.equal(swipeChoice(-40, -0.9), "nope");
  assert.equal(swipeChoice(-20, -2), null);
  // On a narrow phone a shorter swipe is enough.
  assert.equal(swipeChoice(80, 0, 260), "like");
});

test("the deck shows what is left, slowest swipers first, and readable details", () => {
  assert.deepEqual(remainingCards(deck, [{ mediaId: ids[0], like: true }], new Map([[ids[2], false]])).map((card) => card.mediaId), [ids[1]]);
  assert.equal(runtimeLabel(95), "1h 35m");
  assert.equal(runtimeLabel(120), "2h");
  assert.equal(runtimeLabel(48), "48m");
  assert.equal(runtimeLabel(null), null);
  assert.deepEqual(cardMeta(deck[0]), ["2020", "1h 35m", "Comedy", "Crime"]);
  const state = night();
  state.members[0].swiped = 3;
  assert.deepEqual(slowpokes(state, 3).map((member) => member.name), ["Mia"]);
});

test("the page follows the night's phase", () => {
  assert.equal(screenOf(null, 0), "intro");
  assert.equal(screenOf(night({ phase: "lobby" }), 3), "lobby");
  assert.equal(screenOf(night(), 3), "swipe");
  assert.equal(screenOf(night(), 0), "waiting");
  assert.equal(screenOf(night({ voting: false }), 3), "waiting");
  assert.equal(screenOf(night({ phase: "match" }), 2), "match");
  assert.equal(screenOf(night({ phase: "no-match" }), 0), "no-match");
  assert.deepEqual(parseRoute("/movie-night"), { name: "movie-night" });
  assert.equal(routePath({ name: "movie-night" }), "/movie-night");
});

test("a swipe counts at once, the deck is kept between polls and a new round starts over", async () => {
  const api = fakeApi([night({ revision: 2 }), night({ revision: 3, withDeck: false, yourVotes: [{ mediaId: ids[0], like: true }] })]);
  let changes = 0;
  const session = createMovieNight({ api, deviceName: "Invented Browser", onChange: () => changes++ });
  assert.equal(await session.start(), true);
  assert.deepEqual(api.sent[0], ["create", { deviceName: "Invented Browser", isVoting: true }]);
  assert.equal(session.remaining.length, 3);

  session.vote(ids[0], true);
  assert.equal(session.remaining.length, 2);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(api.sent[1], ["vote", { mediaId: ids[0], like: true }]);
  assert.equal(session.deck.length, 3);
  assert.equal(session.remaining[0].mediaId, ids[1]);

  // An older answer never undoes a newer one.
  session.receive(night({ revision: 1, withDeck: false }));
  assert.equal(session.state.revision, 3);
  session.receive(night({ revision: 4, round: 2, deckVersion: 2, yourVotes: [] }));
  assert.equal(session.remaining.length, 3);
  assert.ok(changes >= 4);
  await session.leave();
  assert.equal(session.state, null);
});

test("a swipe the server refused can be swiped again", async () => {
  const api = fakeApi([night()]);
  api.movieNightVote = () => Promise.reject(new Error("That title is not in tonight’s deck."));
  const session = createMovieNight({ api, deviceName: "Invented Browser" });
  await session.join("00000000-0000-4000-8000-0000000000b1");
  session.vote(ids[1], false);
  assert.equal(session.remaining.length, 2);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(session.remaining.length, 3);
  assert.equal(session.error, "That title is not in tonight’s deck.");
  await session.leave();
});
