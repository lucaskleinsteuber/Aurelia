// People ("people-v1"): the page's address, what a person's card and life line say, and the
// requests the browser sends. Invented people only; no browser is opened.
import test from "node:test";
import assert from "node:assert/strict";
import * as logic from "../../src/Tarven.Server/WebApp/js/logic.js";
import { createApi } from "../../src/Tarven.Server/WebApp/js/api.js";

test("People has its own address with the search in it", () => {
  assert.deepEqual(logic.parseRoute("/people", "?q=vale"), { name: "people", query: "vale" });
  assert.deepEqual(logic.parseRoute("/people", ""), { name: "people", query: "" });
  assert.equal(logic.routePath({ name: "people", query: "Morgan Vale" }), "/people?q=Morgan%20Vale");
  assert.equal(logic.routePath({ name: "people", query: "" }), "/people");
  // A person from People opens the same page as from Cast & Crew.
  assert.equal(logic.personHref({ name: "Morgan Vale", id: "tmdb:person:17" }), "/person?name=Morgan+Vale&key=tmdb%3Aperson%3A17");
});

test("the life line says birth, age and place, as on the Mac", () => {
  const today = new Date(2026, 10, 16);
  const about = (birthday, deathday = null, placeOfBirth = null) => ({ birthday, deathday, placeOfBirth });
  assert.equal(logic.personLife(about("1970-05-01", null, "Invented Town"), today), "Born May 1, 1970 (age 56) in Invented Town");
  assert.equal(logic.personLife(about("1970-12-24"), today), "Born December 24, 1970 (age 55)");
  assert.equal(logic.personLife(about("1931-02-08", "1955-09-30", "Invented Town"), today),
    "February 8, 1931 – September 30, 1955 (aged 24) · Invented Town");
  assert.equal(logic.personLife(about(null, "2001-03-04"), today), "Died March 4, 2001");
  assert.equal(logic.personLife(about(null, null, " Invented Town "), today), "Born in Invented Town");
  assert.equal(logic.personLife(about("sometime"), today), "");
  assert.equal(logic.personLife(null, today), "");
});

test("a card says the job only for people behind the camera", () => {
  assert.equal(logic.personRole({ titleCount: 3, department: "Acting" }), "3 titles");
  assert.equal(logic.personRole({ titleCount: 1, department: "Director" }), "Director · 1 title");
  assert.equal(logic.personRole({ titleCount: 2 }), "2 titles");
});

test("the browser asks for a page of people and a person's profile by key", async () => {
  const paths = [];
  const api = createApi(async (path) => {
    paths.push(path);
    return { status: 200, ok: true, text: async () => JSON.stringify({ items: [], total: 0, offset: 0, limit: 60 }) };
  });
  await api.people({ query: "vale", offset: 60, limit: 60 });
  assert.equal(paths.at(-1), "/api/v1/people?query=vale&offset=60&limit=60");
  await api.personProfile("tmdb:person:17");
  assert.equal(paths.at(-1), "/api/v1/people/profile?key=tmdb%3Aperson%3A17");
});
