// Settings › Server › Speech Recognition for the owner: whisper.cpp on the server, the model to
// download once or remove (kept in the server's data folder with its size), and running jobs.

import { h, clear } from "./dom.js";
import { speechJobText } from "./logic.js";

function bytes(value) {
  if (!(value > 0)) return "0 MB";
  return value >= 1e9 ? `${(value / 1e9).toFixed(1)} GB` : `${Math.round(value / 1e6)} MB`;
}

export function serverSpeechSection({ api, section }) {
  const body = h("div", { class: "settings-rows" }, h("p", { class: "muted small" }, "Loading…"));
  const message = h("p", { class: "muted small", role: "status", "aria-live": "polite" });
  const element = section("Speech Recognition", "captions",
    "The server writes subtitles from what is said and moves existing subtitles onto the speech, with whisper.cpp. Sound stays in memory; only the finished subtitles are kept.",
    body, message);
  let choice = "small";
  const act = async (action) => {
    try { render(await action()); message.textContent = ""; }
    catch (error) { message.textContent = error.message; }
  };
  function render(settings) {
    clear(body);
    if (!settings.available) {
      body.append(h("p", { class: "muted small" }, "whisper.cpp isn’t installed on this server. On Debian or Ubuntu: sudo apt install whisper.cpp. Aurelia for Mac still writes subtitles itself."));
    } else if (settings.downloading) {
      const download = settings.downloading;
      body.append(h("progress", { class: "segments-progress", max: String(Math.max(1, download.totalBytes)), value: String(download.receivedBytes) }),
        h("p", { class: "muted small" }, `Downloading the ${download.name} model… ${bytes(download.receivedBytes)} of ${bytes(download.totalBytes)}`),
        h("button", { type: "button", class: "secondary-button", title: "Stops the download and removes what was downloaded.", onclick: () => act(() => api.removeSpeechModel()) }, "Stop Download"));
    } else if (settings.model) {
      const label = settings.models.find((entry) => entry.name === settings.model)?.label ?? settings.model;
      body.append(h("p", {}, `Model: ${label} · ${bytes(settings.modelBytes)}`),
        h("button", { type: "button", class: "secondary-button danger", title: "Deletes the model from the server’s data folder. Subtitles already written stay.",
          onclick: () => { if (confirm("Remove the speech model? Subtitles from speech then stay off until a model is downloaded again.")) act(() => api.removeSpeechModel()); } }, "Remove Model"));
    } else {
      const options = h("div", { class: "settings-choice-list", role: "radiogroup", "aria-label": "Model" });
      for (const entry of settings.models) {
        const radio = h("input", { type: "radio", name: "speech-model", value: entry.name, checked: entry.name === choice });
        radio.addEventListener("change", () => { choice = entry.name; });
        options.append(h("label", { class: "inline-control" }, radio, h("span", {}, `${entry.label} · ${entry.description}`)));
      }
      body.append(options, h("button", { type: "button", class: "primary-button", title: "Downloads the chosen model once from whisper.cpp’s model page into the server’s data folder.",
        onclick: () => act(() => api.downloadSpeechModel(choice)) }, "Download Model"));
    }
    if (settings.downloadError) body.append(h("p", { class: "error-text small" }, settings.downloadError));
    for (const job of (settings.jobs ?? []).filter((entry) => ["waiting", "listening", "saving"].includes(entry.state))) {
      body.append(h("div", { class: "settings-card small" },
        h("div", { class: "settings-card-main" }, h("div", { class: "settings-card-title" }, `${job.kind === "sync" ? "Syncing" : "Listening to"} ${job.title}`),
          h("div", { class: "muted small" }, speechJobText(job))),
        h("div", { class: "settings-card-actions" }, h("button", { type: "button", class: "secondary-button", title: "Stops listening; nothing is saved.",
          onclick: () => act(async () => { await api.cancelSpeech(job.mediaId); return api.serverSpeech(); }) }, "Cancel"))));
    }
    return settings;
  }
  let last = null;
  const tick = async () => {
    if (!element.isConnected && last) return;
    try { last = render(await api.serverSpeech()); } catch (error) { message.textContent = error.message; }
    const busy = last?.downloading || (last?.jobs ?? []).some((job) => ["waiting", "listening", "saving"].includes(job.state));
    if (element.isConnected || !last) setTimeout(tick, busy ? 2000 : 10000);
  };
  tick();
  return element;
}
