// Tarven was called Aurelia until server 3.0.0. This browser keeps what it remembered under the
// old names (sidebar, playback, quality and the like): each "aurelia.…" entry moves to
// "tarven.…" once, unless the new name already has a value. Imported first by app.js, so every
// other module reads the new names already.
export function adoptLegacyStorage(storage) {
  if (!storage) return 0;
  let moved = 0;
  const keys = [];
  for (let index = 0; index < storage.length; index += 1) keys.push(storage.key(index));
  for (const key of keys) {
    if (typeof key !== "string" || !key.startsWith("aurelia.")) continue;
    const renamed = `tarven.${key.slice("aurelia.".length)}`;
    try {
      if (storage.getItem(renamed) === null) {
        storage.setItem(renamed, storage.getItem(key));
        moved += 1;
      }
      storage.removeItem(key);
    } catch { /* Full or blocked storage: the setting starts fresh. */ }
  }
  return moved;
}

for (const name of ["localStorage", "sessionStorage"]) {
  try { adoptLegacyStorage(globalThis[name]); } catch { /* Storage unavailable in this browser. */ }
}
