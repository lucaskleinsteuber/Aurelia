// The browser app's server calls with a fake fetch: `node --test tests/WebApp`.

import test from "node:test";
import assert from "node:assert/strict";
import { ApiError, createApi, loadAllPages } from "../../src/Aurelia.Server/WebApp/js/api.js";

function fakeFetch(answer) {
  const calls = [];
  const fetch = async (path, options) => {
    calls.push({ path, ...options });
    return answer(path, options);
  };
  return { calls, fetch };
}

const json = (status, value) => ({ status, ok: status >= 200 && status < 300, text: async () => (value === undefined ? "" : JSON.stringify(value)) });

test("every call names its credential and sends no token", async () => {
  const { calls, fetch } = fakeFetch(() => json(200, { profiles: [] }));
  const api = createApi(fetch);
  await api.profiles();
  await api.home();
  assert.equal(calls[0].headers["X-Aurelia-Web"], "device");
  assert.equal(calls[1].headers["X-Aurelia-Web"], "profile");
  assert.equal(calls[0].credentials, "same-origin");
  for (const call of calls) assert.equal("Authorization" in call.headers, false);
});

test("problems carry the server's code and message, and no answer means offline", async () => {
  const api = createApi(async () => json(401, { code: "invalid_profile_pin", message: "The PIN is incorrect or this profile still needs PIN setup." }));
  await assert.rejects(api.unlockProfile("id", "1234"), (error) => error instanceof ApiError && error.status === 401 && error.code === "invalid_profile_pin");
  const offline = createApi(async () => {
    throw new TypeError("Failed to fetch");
  });
  await assert.rejects(offline.home(), (error) => error instanceof ApiError && error.offline);
});

test("an empty answer is fine and a PIN-free profile sends no PIN", async () => {
  const { calls, fetch } = fakeFetch(() => json(204));
  const api = createApi(fetch);
  assert.equal(await api.signOut(), null);
  await api.unlockProfile("abc", null);
  assert.equal(calls[1].body, "{}");
  assert.equal(calls[1].path, "/api/v1/web/profiles/abc/unlock");
});

test("catalog lists load every page against one revision", async () => {
  const pages = [
    { items: [{ id: "a" }, { id: "b" }], total: 3, revision: "r1" },
    { items: [{ id: "c" }], total: 3, revision: "r1" },
  ];
  const requests = [];
  const items = await loadAllPages(async (parameters) => {
    requests.push(parameters);
    return pages.shift();
  }, { kind: "movie" }, { limit: 2 });
  assert.deepEqual(items.map((item) => item.id), ["a", "b", "c"]);
  assert.equal(requests[0].revision, undefined);
  assert.equal(requests[1].revision, "r1");
  assert.equal(requests[1].offset, 2);
});

test("a library change during loading starts the list again", async () => {
  let call = 0;
  const items = await loadAllPages(async (parameters) => {
    call += 1;
    if (call === 1) return { items: [{ id: "a" }], total: 2, revision: "old" };
    if (call === 2) throw new ApiError(409, "catalog_changed", "changed");
    return parameters.offset === 0 ? { items: [{ id: "x" }], total: 2, revision: "new" } : { items: [{ id: "y" }], total: 2, revision: "new" };
  }, {}, { limit: 1 });
  assert.deepEqual(items.map((item) => item.id), ["x", "y"]);
});
