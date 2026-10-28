// This is injected only into the fresh capture context. The real HTMLVideoElement never gets
// a media src, load or play call. Production player controls see paused, synthetic metadata;
// the only picture is the same generated episode backdrop used by the Mac showcase.
export function installCaptureMedia({ now, poster, duration }) {
  const OriginalDate = Date;
  globalThis.Date = class extends OriginalDate {
    constructor(...args) { super(...(args.length ? args : [now])); }
    static now() { return now; }
  };
  globalThis.__aureliaCaptureMedia = { simulatedPlayCalls: 0, simulatedLoadCalls: 0 };
  const state = new WeakMap();
  const own = (element) => { if (!state.has(element)) state.set(element, { source: "", currentTime: 0 }); return state.get(element); };
  const metadata = (element) => {
    element.poster = poster;
    queueMicrotask(() => { if (own(element).source) { element.dispatchEvent(new Event("loadedmetadata")); element.dispatchEvent(new Event("canplay")); } });
  };
  const media = HTMLMediaElement.prototype;
  for (const [name, get] of Object.entries({ paused: () => true, ended: () => false, duration: () => duration, readyState: () => 4, networkState: () => 1,
    buffered: () => ({ length: 0 }), seekable: () => ({ length: 1, start: () => 0, end: () => duration }) })) Object.defineProperty(media, name, { configurable: true, get });
  Object.defineProperty(media, "currentTime", { configurable: true, get() { return own(this).currentTime; }, set(value) { own(this).currentTime = Number(value) || 0; queueMicrotask(() => this.dispatchEvent(new Event("timeupdate"))); } });
  Object.defineProperty(media, "src", { configurable: true, get() { return own(this).source; }, set(value) { own(this).source = String(value); metadata(this); } });
  const set = media.setAttribute, remove = media.removeAttribute;
  media.setAttribute = function(name, value) { if (String(name).toLowerCase() === "src") { this.src = value; return; } return set.call(this, name, value); };
  media.removeAttribute = function(name) { if (String(name).toLowerCase() === "src") { own(this).source = ""; return; } return remove.call(this, name); };
  media.load = function() { globalThis.__aureliaCaptureMedia.simulatedLoadCalls++; if (own(this).source) metadata(this); };
  media.play = async function() { globalThis.__aureliaCaptureMedia.simulatedPlayCalls++; metadata(this); this.dispatchEvent(new Event("playing")); this.dispatchEvent(new Event("pause")); };
  media.pause = function() { this.dispatchEvent(new Event("pause")); };
  for (const [name, value] of Object.entries({ videoWidth: 1920, videoHeight: 1080 })) Object.defineProperty(HTMLVideoElement.prototype, name, { configurable: true, get: () => value });
  Object.defineProperty(globalThis, "MediaSource", { configurable: true, value: undefined });
  Object.defineProperty(globalThis, "ManagedMediaSource", { configurable: true, value: undefined });
  const nativeFetch = globalThis.fetch;
  globalThis.fetch = (input, init) => {
    // Keep the production change reader pending without a network request, polling or timers.
    // A fresh capture never has any real server changes to receive.
    const address = typeof input === "string" ? input : input.url;
    if (new URL(address, location.href).pathname === "/api/v1/sync/changes") return new Promise((_resolve, reject) => {
      const signal = init?.signal;
      const abort = () => reject(new DOMException("Capture closed", "AbortError"));
      if (signal?.aborted) abort(); else signal?.addEventListener("abort", abort, { once: true });
    });
    return nativeFetch(input, init);
  };
}
