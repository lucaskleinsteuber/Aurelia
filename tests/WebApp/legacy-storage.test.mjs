import test from "node:test";
import assert from "node:assert/strict";
import { adoptLegacyStorage } from "../../src/Tarven.Server/WebApp/js/legacy-storage.js";

function memoryStorage(entries) {
  const map = new Map(Object.entries(entries));
  return {
    get length() { return map.size; },
    key: (index) => [...map.keys()][index] ?? null,
    getItem: (key) => (map.has(key) ? map.get(key) : null),
    setItem: (key, value) => map.set(key, String(value)),
    removeItem: (key) => map.delete(key),
    entries: () => Object.fromEntries(map),
  };
}

test("settings remembered under Aurelia's names move to Tarven's once", () => {
  const storage = memoryStorage({
    "aurelia.sidebar": "{\"width\":260}",
    "aurelia.streamingQuality": "720p",
    "tarven.streamingQuality": "1080p",
    "unrelated": "kept",
  });
  assert.equal(adoptLegacyStorage(storage), 1);
  assert.deepEqual(storage.entries(), {
    "tarven.streamingQuality": "1080p",
    "unrelated": "kept",
    "tarven.sidebar": "{\"width\":260}",
  });
  assert.equal(adoptLegacyStorage(storage), 0);
  assert.equal(adoptLegacyStorage(null), 0);
});
