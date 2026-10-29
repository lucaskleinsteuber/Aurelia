// The browser app's server calls with a fake fetch: `node --test tests/WebApp`.

import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
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

test("a connection lost while reading a response becomes an offline ApiError", async () => {
  const api = createApi(async () => ({
    status: 200,
    ok: true,
    text: async () => { throw new TypeError("Synthetic response stream disconnected"); },
  }));
  await assert.rejects(api.serverStatus(), (error) => error instanceof ApiError && error.offline && error.code === "offline");
});

test("fetch and response-body cancellation preserve the original AbortError", async () => {
  for (const duringBody of [false, true]) {
    const canceled = new DOMException("Synthetic cancellation", "AbortError");
    const api = createApi(async () => {
      if (!duringBody) throw canceled;
      return { status: 200, ok: true, text: async () => { throw canceled; } };
    });
    await assert.rejects(api.mediaEditor("invented"), (error) => error === canceled);
  }
});

test("a malformed successful answer remains distinct from transport and server failures", async () => {
  const malformed = createApi(async () => ({ status: 200, ok: true, text: async () => "<html>Unexpected response</html>" }));
  await assert.rejects(malformed.libraries(), (error) => error instanceof ApiError && error.status === 200 && error.code === "invalid_response" && !error.offline);
  const failed = createApi(async () => ({ status: 503, ok: false, text: async () => "<html>Service unavailable</html>" }));
  await assert.rejects(failed.libraries(), (error) => error instanceof ApiError && error.status === 503 && error.code === "http_503" && !error.offline);
});

test("an unlocked mutation binds one approval to its exact method, encoded path and serialized bytes", async () => {
  const path = "/api/v1/users/a%2Fb/profile?revision=7&name=A%20B";
  let serializations = 0;
  const body = { toJSON: () => ({ name: `Synthetic Ω \"profile\" ${++serializations}`, note: "line one\nline two", enabled: false }) };
  const controller = new AbortController();
  const { calls, fetch } = fakeFetch((address) => address === "/api/v1/management/approval" ? json(200, { token: "synthetic-one-time-grant" }) : json(200, { saved: true }));
  const api = createApi(fetch);
  assert.deepEqual(await api.approved(path, { method: "PUT", body, signal: controller.signal }), { saved: true });
  assert.equal(serializations, 1, "Hashing and sending must share one serialization even for a stateful toJSON.");
  assert.equal(calls.length, 2, "Unlocked management needs approval and the change, without another password request.");
  assert.equal(calls[0].path, "/api/v1/management/approval");
  assert.equal(calls[0].method, "POST");
  const approval = JSON.parse(calls[0].body);
  assert.deepEqual(approval, { action: `PUT ${path}`, payloadHash: createHash("sha256").update(calls[1].body, "utf8").digest("hex") });
  assert.equal("password" in approval, false);
  assert.equal(calls[1].path, path);
  assert.equal(calls[1].method, "PUT");
  assert.equal(calls[1].headers["X-Aurelia-Approval"], "synthetic-one-time-grant");
  assert.deepEqual(JSON.parse(calls[1].body), { name: 'Synthetic Ω "profile" 1', note: "line one\nline two", enabled: false });
  for (const call of calls) {
    assert.equal(call.signal, controller.signal);
    assert.equal(call.credentials, "same-origin");
    assert.equal(call.headers["X-Aurelia-Web"], "profile");
    assert.equal("Authorization" in call.headers, false);
  }
});

test("successive guarded changes obtain distinct one-time grants and empty changes hash an empty body", async () => {
  let grants = 0;
  const { calls, fetch } = fakeFetch((path) => path === "/api/v1/management/approval" ? json(200, { token: `synthetic-grant-${++grants}` }) : json(204));
  const api = createApi(fetch);
  await api.removeLibrary("synthetic-one");
  await api.removeLibrary("synthetic-two");
  assert.equal(grants, 2);
  assert.equal(calls.length, 4);
  assert.equal(calls[1].headers["X-Aurelia-Approval"], "synthetic-grant-1");
  assert.equal(calls[3].headers["X-Aurelia-Approval"], "synthetic-grant-2");
  for (const offset of [0, 2]) {
    const proof = JSON.parse(calls[offset].body);
    assert.equal(proof.action, `DELETE ${calls[offset + 1].path}`);
    assert.equal(proof.payloadHash, createHash("sha256").update("").digest("hex"));
    assert.equal(calls[offset + 1].body, undefined);
    assert.equal("Content-Type" in calls[offset + 1].headers, false);
    assert.equal("password" in proof, false);
  }
});

test("refused or missing approval cannot send the guarded mutation", async () => {
  for (const [status, answer, expected] of [
    [403, { code: "management_locked", message: "Unlock management first." }, "management_locked"],
    [401, { code: "profile_session_expired", message: "Sign in again." }, "profile_session_expired"],
    [200, {}, "invalid_response"],
    [200, { token: "" }, "invalid_response"],
    [204, undefined, "invalid_response"],
  ]) {
    const { calls, fetch } = fakeFetch(() => json(status, answer));
    await assert.rejects(createApi(fetch).createProfile({ name: "Synthetic viewer" }), (error) => error instanceof ApiError && error.code === expected);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].path, "/api/v1/management/approval");
  }
});

test("management mutation failures retain authentication codes without replay or a password prompt", async () => {
  for (const [status, code] of [[401, "profile_session_expired"], [403, "management_locked"], [403, "approval_required"]]) {
    const { calls, fetch } = fakeFetch((path) => path === "/api/v1/management/approval" ? json(200, { token: "synthetic-grant" }) : json(status, { code, message: "Synthetic authorization refusal." }));
    await assert.rejects(createApi(fetch).updateProfile("synthetic", { name: "Updated" }), (error) => error instanceof ApiError && error.status === status && error.code === code && error.message === "Synthetic authorization refusal.");
    assert.equal(calls.length, 2);
    assert.equal(calls[1].path, "/api/v1/users/synthetic/profile");
  }
});

test("new storage, profile and metadata calls use their encoded routes, methods, bodies and cancellation signal", async () => {
  const item = "synthetic/a ?#&";
  const encoded = "synthetic%2Fa%20%3F%23%26";
  const payload = { name: "Invented", path: "/Synthetic Media/A & B", revision: 7 };
  const query = "A & B / Ω";
  const cases = [
    [(api, signal) => api.addLibrary(payload, { signal }), "/api/v1/libraries", "POST", payload, true],
    [(api, signal) => api.removeLibrary(item, { signal }), `/api/v1/libraries/${encoded}`, "DELETE", undefined, true],
    [(api, signal) => api.libraryOperation(item, { signal }), `/api/v1/library-operations/${encoded}`, "GET"],
    [(api, signal) => api.profileEditor(item, { signal }), `/api/v1/users/${encoded}/profile`, "GET"],
    [(api, signal) => api.createProfile(payload, { signal }), "/api/v1/users", "POST", payload, true],
    [(api, signal) => api.updateProfile(item, payload, { signal }), `/api/v1/users/${encoded}/profile`, "PUT", payload, true],
    [(api, signal) => api.mediaEditor(item, { signal }), `/api/v1/media/${encoded}/editor`, "GET"],
    [(api, signal) => api.saveMediaEditor(item, payload, { signal }), `/api/v1/media/${encoded}/editor`, "PUT", payload],
    [(api, signal) => api.metadataSearch(item, query, { signal }), `/api/v1/media/${encoded}/metadata/search?query=A+%26+B+%2F+%CE%A9`, "GET"],
    [(api, signal) => api.selectMetadataMatch(item, payload, { signal }), `/api/v1/media/${encoded}/metadata/match`, "PUT", payload],
    [(api, signal) => api.clearMetadataMatch(item, { signal }), `/api/v1/media/${encoded}/metadata/match`, "DELETE"],
  ];
  for (const [invoke, path, method, body, guarded = false] of cases) {
    const controller = new AbortController();
    const { calls, fetch } = fakeFetch((address) => address === "/api/v1/management/approval" ? json(200, { token: "synthetic-route-grant" }) : json(204));
    await invoke(createApi(fetch), controller.signal);
    assert.equal(calls.length, guarded ? 2 : 1, `${method} ${path}`);
    const call = calls.at(-1);
    assert.equal(call.path, path);
    assert.equal(call.method, method);
    assert.equal(call.body, body === undefined ? undefined : JSON.stringify(body));
    assert.equal(call.signal, controller.signal);
    if (guarded) {
      assert.equal(calls[0].signal, controller.signal);
      assert.equal(JSON.parse(calls[0].body).action, `${method} ${path}`);
      assert.equal(call.headers["X-Aurelia-Approval"], "synthetic-route-grant");
    } else assert.equal("X-Aurelia-Approval" in call.headers, false);
  }
});

test("settings refresh reads forward cancellation without changing credential mode", async () => {
  const controller = new AbortController();
  const { calls, fetch } = fakeFetch(() => json(200, []));
  const api = createApi(fetch);
  await api.libraries({ signal: controller.signal });
  await api.metadataJobs({ signal: controller.signal });
  await api.serverStatus({ signal: controller.signal });
  assert.deepEqual(calls.map((call) => call.path), ["/api/v1/libraries", "/api/v1/metadata/jobs", "/api/v1/server/status"]);
  for (const call of calls) {
    assert.equal(call.method, "GET");
    assert.equal(call.signal, controller.signal);
    assert.equal(call.headers["X-Aurelia-Web"], "profile");
  }
});

test("collections v2, subtitles, history, statistics and health API endpoints use correct routes and methods", async () => {
  const calls = [];
  const api = createApi(async (path, options) => {
    calls.push({ path, ...options });
    return json(200, {});
  });

  await api.createCollection({ name: "Favorites", isSmart: false });
  assert.equal(calls.at(-1).path, "/api/v1/collections");
  assert.equal(calls.at(-1).method, "POST");

  await api.updateCollection("col-1", { name: "Sci-Fi", isSmart: true });
  assert.equal(calls.at(-1).path, "/api/v1/collections/col-1");
  assert.equal(calls.at(-1).method, "PUT");

  await api.deleteCollection("col-1");
  assert.equal(calls.at(-1).path, "/api/v1/collections/col-1");
  assert.equal(calls.at(-1).method, "DELETE");

  await api.addCollectionItem("col-1", "med-1");
  assert.equal(calls.at(-1).path, "/api/v1/collections/col-1/items/med-1");
  assert.equal(calls.at(-1).method, "POST");

  await api.removeCollectionItem("col-1", "med-1");
  assert.equal(calls.at(-1).path, "/api/v1/collections/col-1/items/med-1");
  assert.equal(calls.at(-1).method, "DELETE");

  await api.franchises();
  assert.equal(calls.at(-1).path, "/api/v1/franchises");
  assert.equal(calls.at(-1).method, "GET");

  await api.createCollectionFromFranchise("fran-1");
  assert.equal(calls.at(-1).path, "/api/v1/collections/from-franchise/fran-1");
  assert.equal(calls.at(-1).method, "POST");

  await api.streamSubtitles("ticket-1");
  assert.equal(calls.at(-1).path, "/api/v1/streams/ticket-1/subtitles");

  await api.history({ offset: 10, limit: 25 });
  assert.equal(calls.at(-1).path, "/api/v1/history?offset=10&limit=25");

  await api.deleteHistoryItem("hist-1");
  assert.equal(calls.at(-1).path, "/api/v1/history/hist-1");
  assert.equal(calls.at(-1).method, "DELETE");

  await api.clearHistory();
  assert.equal(calls.at(-1).path, "/api/v1/history");
  assert.equal(calls.at(-1).method, "DELETE");

  await api.statistics();
  assert.equal(calls.at(-1).path, "/api/v1/statistics");

  await api.yearInReview(2025);
  assert.equal(calls.at(-1).path, "/api/v1/statistics/year/2025");

  await api.healthDuplicates();
  assert.equal(calls.at(-1).path, "/api/v1/library/health/duplicates?offset=0&limit=50");

  await api.healthOffline({ days: 60, offset: 0, limit: 20 });
  assert.equal(calls.at(-1).path, "/api/v1/library/health/offline?days=60&offset=0&limit=20");

  await api.healthUnmatched();
  assert.equal(calls.at(-1).path, "/api/v1/library/health/unmatched?offset=0&limit=50");

  await api.mergeHealthDuplicates("src-1", "tgt-1");
  assert.equal(calls.at(-1).path, "/api/v1/library/health/merge");
  assert.equal(calls.at(-1).method, "POST");

  await api.setPreferredHealthVersion("pref-1");
  assert.equal(calls.at(-1).path, "/api/v1/library/health/preferred");
  assert.equal(calls.at(-1).method, "PUT");

  await api.removeHealthEntry("med-1");
  assert.equal(calls.at(-1).path, "/api/v1/library/health/entries/med-1");
  assert.equal(calls.at(-1).method, "DELETE");
});
