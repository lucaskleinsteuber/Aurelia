// Moving a server to another computer in the browser (docs/SERVER_MOVE.md): the new server's setup
// ("Move from another Aurelia server"), the old server's Move to a New Server… and Undo Move,
// Storage Location Moved…, and the notice a moved server shows. The setup code stays in this page's
// memory only; every sign-in stays in the server's HttpOnly cookies.

import { h, clear, saveBlob } from "./dom.js";
import { countdown, setupCode } from "./logic.js";
import {
  formatMoveCode, initialChoice, mappingPayload, matchText, moveAddress, moveCodeComplete, moveProblem, ownerMoveView,
  rankedSuggestions, relocateDecision, setupMoveView,
} from "./server-move.js";

const POLL_MS = 1000;
/** How many polls may still say "idle" right after a move was started. */
const IDLE_GRACE = 3;

// MARK: The new server's setup

/**
 * @param {object} app  api, show(element) → token (puts a card on the page), current(token),
 *   showPairing(note), showServerOff(), newServerSetup(), serverName(), schedule(work, ms)
 */
export function createSetupMove(app) {
  const { api } = app;
  const schedule = app.schedule ?? ((work, ms) => setTimeout(work, ms));
  const textField = (attributes) => h("input", { class: "text-field", autocomplete: "off", spellcheck: "false", ...attributes });
  const labeled = (label, control, note) => h("label", { class: "setup-field" }, h("span", {}, label), control, note ? h("span", { class: "muted small" }, note) : null);
  const card = (...children) => h("div", { class: "setup-card" }, h("img", { class: "brand-mark", src: "/web/icon.svg", alt: "" }), ...children);

  /** "Set up a new server" or "Move from another Aurelia server": the first step of the setup. */
  function choose() {
    app.show(card(
      h("h1", {}, "Set Up Your Aurelia Server"),
      h("p", {}, `“${app.serverName()}” has no owner yet. Start fresh, or bring everything from the Aurelia server you use now.`),
      h("div", { class: "move-choices" },
        h("button", { type: "button", class: "move-choice", onclick: () => app.newServerSetup() },
          h("strong", {}, "Set Up a New Server"), h("span", { class: "muted small" }, "An empty library: you add storage locations next.")),
        h("button", { type: "button", class: "move-choice", onclick: () => start() },
          h("strong", {}, "Move from Another Aurelia Server"), h("span", { class: "muted small" }, "Titles, progress, profiles, settings and every device’s sign-in come along. Media files stay where they are.")))));
  }

  /** The setup code, then how the data comes: over the network with a move code, or a moving file. */
  function start(note) {
    const code = textField({ class: "text-field setup-code", placeholder: "ABCDE-FGHJK", "aria-label": "Setup code" });
    const network = h("input", { type: "radio", name: "move-method", value: "network", checked: true });
    const file = h("input", { type: "radio", name: "move-method", value: "file" });
    const address = textField({ placeholder: "192.168.1.20", inputmode: "url", "aria-label": "Old server address" });
    const moveCode = textField({ class: "text-field setup-code", placeholder: "ABCD-EFGH-JKMN", "aria-label": "Move code" });
    const movingFile = h("input", { type: "file", class: "file-field", accept: ".aureliamove,.aureliabackup,application/octet-stream", "aria-label": "Moving file" });
    const passphrase = textField({ type: "password", autocomplete: "off", "aria-label": "Passphrase" });
    const message = h("p", { class: "error-text", role: "alert" }, note ?? "");
    const submit = h("button", { class: "primary-button large", type: "submit" }, "Start Move");
    const networkPart = h("div", { class: "move-part" },
      labeled("Old Server’s Address", address, "A browser can’t search the network. Type the address the old server shows in its Move to a New Server window, such as 192.168.1.20."),
      labeled("Move Code", moveCode, "The 12 characters the old server shows. A code works once and for 15 minutes."));
    const filePart = h("div", { class: "move-part", hidden: true },
      labeled("Moving File", movingFile, "The file the old server saved, for example on a USB stick."),
      labeled("Passphrase", passphrase, "The passphrase chosen when the moving file was saved."));
    const switchMethod = () => { networkPart.hidden = !network.checked; filePart.hidden = network.checked; };
    network.addEventListener("change", switchMethod);
    file.addEventListener("change", switchMethod);
    code.addEventListener("input", () => { code.value = setupCode(code.value); });
    moveCode.addEventListener("input", () => { moveCode.value = formatMoveCode(moveCode.value); });
    let busy = false;
    let token = 0;
    const form = h("form", { class: "setup-card", onsubmit: async (event) => {
      event.preventDefault();
      if (busy) return;
      const setup = setupCode(code.value);
      if (setup.replace("-", "").length !== 10) { message.textContent = "Enter the 10-character setup code from the server computer."; return; }
      const target = moveAddress(address.value);
      if (network.checked && !target) { message.textContent = "Enter the old server’s address, such as 192.168.1.20."; return; }
      if (network.checked && !moveCodeComplete(moveCode.value)) { message.textContent = "Enter the 12-character move code the old server shows."; return; }
      if (file.checked && !movingFile.files?.[0]) { message.textContent = "Choose the moving file."; return; }
      if (file.checked && !passphrase.value) { message.textContent = "Enter the moving file’s passphrase."; return; }
      busy = true;
      submit.disabled = true;
      message.textContent = "";
      try {
        // A move that is already under way (this page was reloaded) is picked up where it is.
        const current = await api.setupMove(setup);
        if (!app.current(token)) return;
        if (current?.state && current.state !== "idle" && current.state !== "failed") return follow(setup, current);
        if (network.checked) {
          message.textContent = "Contacting the old server…";
          await api.startNetworkMove(setup, target, formatMoveCode(moveCode.value));
        } else {
          message.textContent = "Uploading the moving file…";
          const upload = await api.uploadMovingFile(setup, movingFile.files[0]);
          message.textContent = "Opening the moving file…";
          await api.openMovingFile(setup, upload?.uploadId, passphrase.value);
          passphrase.value = "";
        }
        if (app.current(token)) follow(setup);
      } catch (error) {
        if (!app.current(token)) return;
        if (error?.offline) return app.showServerOff();
        message.textContent = moveProblem(error);
      } finally {
        busy = false;
        submit.disabled = false;
      }
    } },
      h("img", { class: "brand-mark", src: "/web/icon.svg", alt: "" }),
      h("h1", {}, "Move from Another Aurelia Server"),
      h("p", {}, "This server takes over the old one: its library, profiles, settings and identity. Devices switch on their own; browsers sign in once at the new address."),
      h("ol", { class: "pairing-steps" },
        h("li", {}, "On the old server: Settings › Server › Move to a New Server…"),
        h("li", {}, "On this server’s computer, run: sudo aurelia setup --browser (Docker: docker compose exec aurelia aurelia setup-code)")),
      labeled("Setup Code", code),
      h("div", { class: "move-methods", role: "radiogroup", "aria-label": "How the data comes" },
        h("label", { class: "inline-control" }, network, "Over the network"),
        h("label", { class: "inline-control" }, file, "From a moving file")),
      networkPart, filePart, message,
      h("div", { class: "button-row" }, h("button", { type: "button", class: "secondary-button", onclick: () => choose() }, "Back"), submit));
    token = app.show(form);
    code.focus();
  }

  /** Polls the staged move and shows its step until it needs the person or finished. */
  function follow(setup, first) {
    let token = 0;
    const title = h("h1", {});
    const detail = h("p", {});
    const bar = h("div", { class: "move-progress", role: "progressbar", "aria-label": "Move progress" }, h("div", { class: "move-progress-fill" }));
    const note = h("p", { class: "muted small", "aria-live": "polite" });
    const cancel = h("button", { type: "button", class: "secondary-button", onclick: () => discard(setup) }, "Cancel Move");
    token = app.show(card(title, detail, bar, note, h("div", { class: "button-row" }, cancel)));
    // Right after it was asked to start, the server may still report nothing staged for a moment.
    let idle = first ? IDLE_GRACE : 0;
    const show = (status) => {
      if (!app.current(token)) return;
      const view = setupMoveView(status);
      if (view.step === "locations") return locations(setup, view);
      if (view.step === "done") return restarting(view);
      if (view.step === "failed") return start(view.detail);
      if (view.step === "start" && ++idle > IDLE_GRACE) return start("The move stopped. Start it again.");
      if (view.step === "start") {
        title.textContent = "Moving In…";
        detail.textContent = "Contacting the old server…";
        bar.className = "move-progress indeterminate";
        schedule(poll, POLL_MS);
        return;
      }
      title.textContent = view.title;
      detail.textContent = view.detail;
      const fraction = view.progress?.fraction;
      bar.hidden = view.step !== "progress";
      bar.className = fraction == null ? "move-progress indeterminate" : "move-progress";
      bar.firstChild.style.width = fraction == null ? "" : `${Math.round(fraction * 100)}%`;
      if (fraction != null) bar.setAttribute("aria-valuenow", String(Math.round(fraction * 100)));
      note.textContent = view.progress?.text ?? "";
      cancel.hidden = view.step === "applying";
      schedule(poll, POLL_MS);
    };
    const poll = async () => {
      if (!app.current(token)) return;
      try {
        show(await api.setupMove(setup));
      } catch (error) {
        if (!app.current(token)) return;
        // A server that restarts while applying answers nothing for a moment.
        if (error?.offline) { note.textContent = "Waiting for the server…"; schedule(poll, POLL_MS * 2); return; }
        if (error?.code === "server_already_setup" || error?.status === 403) return restarting(setupMoveView({ state: "done" }));
        start(moveProblem(error));
      }
    };
    if (first) show(first);
    else poll();
  }

  /** One card per storage location: its best folder here, the others, a typed folder, or Later. */
  function locations(setup, view) {
    let token = 0;
    const choices = {};
    const message = h("p", { class: "error-text", role: "alert" });
    const list = h("div", { class: "move-locations" });
    for (const location of view.locations) {
      choices[location.id] = initialChoice(location);
      const group = `move-location-${location.id}`;
      const options = h("div", { class: "move-options", role: "radiogroup", "aria-label": `Folder for ${location.name}` });
      const radio = (value, checked) => h("input", { type: "radio", name: group, value, checked });
      const select = (choice) => { choices[location.id] = choice; };
      for (const suggestion of rankedSuggestions(location)) {
        const input = radio(suggestion.path, choices[location.id].kind === "suggestion" && choices[location.id].path === suggestion.path);
        input.addEventListener("change", () => select({ kind: "suggestion", path: suggestion.path }));
        options.append(h("label", { class: "move-option" }, input,
          h("span", {}, h("span", { class: "mono" }, suggestion.path), h("span", { class: "muted small block" }, matchText(suggestion.matched, location.sampled)))));
      }
      const custom = radio("custom", false);
      const path = h("input", { class: "text-field mono", placeholder: "/path/on/this/computer", spellcheck: "false", autocomplete: "off", "aria-label": `Other folder for ${location.name}` });
      const result = h("span", { class: "muted small block", "aria-live": "polite" });
      const preview = h("button", { type: "button", class: "secondary-button", onclick: async () => {
        const typed = path.value.trim();
        if (!typed) { result.textContent = "Type a folder first."; return; }
        custom.checked = true;
        select({ kind: "custom", path: typed });
        result.textContent = "Comparing…";
        try {
          const answer = await api.previewMoveLocation(setup, location.id, typed);
          if (app.current(token)) result.textContent = matchText(answer?.matched, answer?.sampled ?? location.sampled);
        } catch (error) {
          if (app.current(token)) result.textContent = moveProblem(error);
        }
      } }, "Preview");
      custom.addEventListener("change", () => select({ kind: "custom", path: path.value }));
      path.addEventListener("input", () => { custom.checked = true; select({ kind: "custom", path: path.value }); result.textContent = ""; });
      options.append(h("label", { class: "move-option" }, custom, h("span", {}, "Another folder")),
        h("div", { class: "move-custom" }, path, preview), result);
      const later = radio("later", choices[location.id].kind === "later");
      later.addEventListener("change", () => select({ kind: "later", path: null }));
      options.append(h("label", { class: "move-option" }, later,
        h("span", {}, "Later", h("span", { class: "muted small block" }, "The location stays offline with its titles until Storage Location Moved… points it at the new folder."))));
      list.append(h("section", { class: "move-location" },
        h("h3", {}, location.name),
        h("p", { class: "muted small" }, "Was ", h("span", { class: "mono" }, location.oldPath ?? "")),
        options));
    }
    if (!view.locations.length) list.append(h("p", { class: "muted" }, "The old server had no storage locations."));
    const finish = h("button", { type: "button", class: "primary-button large", onclick: async () => {
      let body;
      try { body = mappingPayload(view.locations, choices); } catch (error) { message.textContent = error.message; return; }
      finish.disabled = true;
      message.textContent = "";
      try {
        await api.finishMove(setup, body);
        if (app.current(token)) restarting(setupMoveView({ state: "done" }));
      } catch (error) {
        if (!app.current(token)) return;
        // The server may restart before its answer arrives.
        if (error?.offline) return restarting(setupMoveView({ state: "done" }));
        message.textContent = moveProblem(error);
        finish.disabled = false;
      }
    } }, "Finish Move");
    token = app.show(h("div", { class: "setup-card wide" },
      h("h1", {}, view.title), h("p", {}, view.detail), list, message,
      h("div", { class: "button-row" }, h("button", { type: "button", class: "secondary-button", onclick: () => discard(setup) }, "Cancel Move"), finish)));
  }

  /** "Moved": waits until the server is back with its new identity, then asks to sign in. */
  function restarting(view) {
    const note = h("p", { class: "muted small", "aria-live": "polite" }, "The server restarts…");
    const token = app.show(card(h("h1", {}, view.title), h("p", {}, `${view.detail} It restarts now.`),
      h("div", { class: "spinner visible" }), note,
      h("p", {}, "This browser’s sign-in belongs to the old address: once the server is back, sign in here with a code from one of your devices.")));
    const wait = async () => {
      if (!app.current(token)) return;
      try {
        const info = await api.serverInfo();
        if (!app.current(token)) return;
        if (info?.isSetup) return app.showPairing("The move is done. Sign in with a code from one of your devices.");
      } catch { /* Restarting: try again. */ }
      note.textContent = "Waiting for the server…";
      schedule(wait, POLL_MS * 2);
    };
    schedule(wait, POLL_MS * 2);
  }

  async function discard(setup) {
    try { await api.discardMove(setup); } catch { /* Nothing staged any more. */ }
    choose();
  }

  return { choose, start, follow, locations, restarting };
}

// MARK: The old server, in Settings › Server

/** @param {object} options  api, app (toast, handleError), kit (editor, input, field, button), chooseServerFolder */
export function createMoveTools({ api, app, kit, chooseServerFolder }) {
  const { editor, input, field, button } = kit;

  /** The Server section's part: the move's state and the actions that fit it. */
  function moveSection(refresh) {
    const summary = h("p", { class: "muted small" }, "Checking…");
    const actions = h("div", { class: "button-row" });
    const element = h("div", { class: "move-section" }, summary, actions);
    api.serverMove().then((status) => {
      const view = ownerMoveView(status);
      summary.textContent = view.summary;
      clear(actions);
      for (const action of view.actions) {
        if (action === "start") actions.append(button(view.state === "none" ? "Move to a New Server…" : "New Move Code…", () => moveServer(refresh), view.state === "none" ? "secondary-button" : "primary-button"));
        if (action === "cancel") actions.append(button("Cancel Move", () => cancelMove(refresh)));
        if (action === "markMoved") actions.append(button("Mark as Moved…", () => markMoved(refresh)));
        if (action === "undo") actions.append(button("Undo Move…", () => undoMove(refresh), "secondary-button danger"));
      }
    }, (error) => {
      summary.textContent = error?.status === 404 ? "This server’s version can’t move to another computer yet." : moveProblem(error);
    });
    return element;
  }

  /** Over the network (a code) or with a moving file (a passphrase). */
  function moveServer(refresh) {
    const context = editor("Move to a New Server", null);
    let timer = 0;
    let poll = 0;
    const stop = () => { clearInterval(timer); clearTimeout(poll); };
    context.dialog.addEventListener("close", () => { stop(); refresh?.(); }, { once: true });
    const choices = h("div", { class: "move-choices" },
      h("button", { type: "button", class: "move-choice", onclick: () => network() },
        h("strong", {}, "Over the Network"), h("span", { class: "muted small" }, "Both servers are on. This server shows a code that you type on the new one.")),
      h("button", { type: "button", class: "move-choice", onclick: () => file() },
        h("strong", {}, "With a Moving File"), h("span", { class: "muted small" }, "An encrypted file for a USB stick or a network share, protected by a passphrase.")));
    context.body.append(h("p", {}, "Everything but the media files moves: titles, progress, favorites, collections, profiles, settings, the server’s identity and every device’s sign-in. On the new computer, choose Move from another Aurelia server while setting it up."), choices);
    context.ready();

    function network() {
      clear(context.body);
      const code = h("div", { class: "pairing-code move-code", "aria-live": "polite" }, "…");
      const left = h("p", { class: "muted small" });
      const state = h("p", { role: "status" });
      const where = h("p", { class: "muted small" }, `On the new server, type this server’s address (${location.host}) and the code.`);
      context.body.append(where, code, left, state, h("div", { class: "button-row" },
        button("Copy Code", async () => {
          try { await navigator.clipboard.writeText(code.textContent); app.toast("Code copied."); } catch { app.toast("Copy didn’t work here. Read the code from the screen instead."); }
        }),
        button("New Code", () => begin())));
      const watch = async () => {
        if (!context.alive()) return;
        try {
          const status = await api.serverMove({ signal: context.signal });
          if (!context.alive()) return;
          if (status?.state === "transferring") state.textContent = "The new server is receiving the data…";
          if (status?.state === "moved") {
            stop();
            code.classList.add("expired");
            left.textContent = "";
            state.textContent = ownerMoveView(status).summary;
            return;
          }
          if (status?.state === "none") { stop(); state.textContent = "The move was cancelled."; return; }
        } catch (error) {
          if (!context.alive() || error?.name === "AbortError") return;
        }
        poll = setTimeout(watch, 2000);
      };
      const begin = () => context.run(async () => {
        stop();
        const started = await api.startServerMove({ method: "network" });
        if (!context.alive()) return;
        code.textContent = formatMoveCode(started.code);
        code.className = "pairing-code move-code";
        state.textContent = "Waiting for the new server…";
        const tick = () => {
          const text = countdown(started.expiresAt, Date.now());
          left.textContent = text ? `The code works once, for ${text}.` : "This code has expired. Choose New Code.";
          if (!text) { code.classList.add("expired"); clearInterval(timer); }
        };
        tick();
        timer = setInterval(tick, 1000);
        poll = setTimeout(watch, 2000);
      });
      begin();
    }

    function file() {
      clear(context.body);
      const first = input("", { type: "password", autocomplete: "new-password", minlength: 12, "aria-label": "Passphrase" });
      const second = input("", { type: "password", autocomplete: "new-password", minlength: 12, "aria-label": "Repeat Passphrase" });
      const save = button("Create and Download", () => context.run(async () => {
        if (first.value.length < 12 || first.value !== second.value) throw new Error("Enter the same passphrase twice, with at least 12 characters.");
        context.message("Packing the server… this can take a minute.");
        const started = await api.startServerMove({ method: "file", passphrase: first.value });
        first.value = second.value = "";
        try {
          const blob = await api.backupTransfer(started.transferId);
          saveBlob(blob, `Aurelia-Move-${new Date().toISOString().slice(0, 10)}.aureliamove`);
        } finally {
          await api.discardBackupTransfer(started.transferId).catch(() => {});
        }
        context.message("");
        clear(context.body);
        context.body.append(h("p", {}, "Moving file saved. Set up the new server, choose Move from another Aurelia server and open this file with its passphrase."),
          h("p", { class: "muted small" }, "When the new server can reach this one, this server learns about the move by itself. Otherwise choose Mark as Moved here afterwards."));
      }), "primary-button");
      context.body.append(h("p", {}, "The moving file holds the whole server, encrypted with your passphrase. Media files are not included."),
        field("Passphrase", first, "At least 12 characters. Aurelia can’t recover it."), field("Repeat Passphrase", second),
        h("div", { class: "button-row end" }, save));
      first.focus();
    }
  }

  function cancelMove(refresh) {
    const context = editor("Cancel the Move", "Cancel Move", async () => {
      await api.endServerMove();
      app.toast("The move is cancelled.");
      refresh?.();
    });
    context.body.append(h("p", {}, "The move code or moving file stops working. This server stays as it is."));
    context.ready();
  }

  function markMoved(refresh) {
    const context = editor("Mark as Moved", "Mark as Moved", async () => {
      await api.markServerMoved();
      app.toast("This server now tells devices that it moved.");
      refresh?.();
    });
    context.body.append(h("p", {}, "Use this when the new server runs with the moving file but couldn’t reach this one. This server then stops offering itself on the network and sends devices to the new one."));
    context.ready();
  }

  function undoMove(refresh) {
    const off = h("input", { type: "checkbox", class: "switch", "aria-label": "The new server is turned off" });
    const context = editor("Undo the Move", "Undo Move", async () => {
      if (!off.checked) throw new Error("Turn the new server off first, then confirm it here.");
      await api.endServerMove();
      app.toast("This server is back. Devices that already switched come back when the new server is off.");
      refresh?.();
    });
    context.body.append(h("p", {}, "This server takes back its library and identity. Two copies of the same server must never run at once: turn the new server off first. Changes made on the new server since the move are not brought back."),
      h("label", { class: "inline-control" }, off, "The new server is turned off"));
    context.ready();
  }

  /** Storage Location Moved: point a location at the folder that holds its files now. */
  function relocate(library, refresh) {
    const list = h("div", { class: "move-options", role: "radiogroup", "aria-label": "Suggested folders" });
    const path = input("", { spellcheck: false, autocomplete: "off", placeholder: "/path/on/the/server", class: "text-field mono", "aria-label": "New folder" });
    const result = h("p", { class: "muted small", "aria-live": "polite" });
    const empty = h("input", { type: "checkbox", class: "switch", "aria-label": "Point it there anyway" });
    const emptyRow = h("label", { class: "inline-control", hidden: true }, empty, "No sample file is there. Point the location at this folder anyway.");
    let preview = null;
    let previewed = "";
    const context = editor(`${library.name} Moved`, "Move Location", async () => {
      const decision = relocateDecision(preview, { confirmedEmpty: empty.checked });
      if (!decision.canConfirm || previewed !== path.value.trim()) throw new Error("Preview the folder first.");
      await api.relocateLibrary(library.id, previewed, decision.force);
      app.toast(`“${library.name}” now reads from ${previewed}. A scan finds its titles there.`);
      refresh?.();
    });
    const update = () => {
      const decision = relocateDecision(previewed === path.value.trim() ? preview : null, { confirmedEmpty: empty.checked });
      result.textContent = decision.text;
      emptyRow.hidden = !decision.needsSecondConfirmation;
      context.setValid(decision.canConfirm);
    };
    const check = () => context.run(async () => {
      const typed = path.value.trim();
      if (!typed) throw new Error("Choose or type a folder first.");
      preview = await api.previewRelocation(library.id, typed, { signal: context.signal });
      previewed = typed;
      empty.checked = false;
      update();
    });
    path.addEventListener("input", () => { empty.checked = false; update(); });
    empty.addEventListener("change", update);
    const browse = chooseServerFolder ? button("Browse…", () => chooseServerFolder((chosen) => { path.value = chosen; check(); }, path.value.trim() || null)) : null;
    context.body.append(
      h("p", {}, "When the files of this location are now in another folder (a new disk or computer), point it there. Titles, progress and artwork stay; a scan then finds the files by their path. Media files are only read."),
      h("p", { class: "muted small mono" }, `Now: ${library.path}`),
      list,
      h("div", { class: "editor-path-row" }, field("New Folder", path), browse, button("Preview", check)),
      result, emptyRow);
    context.setValid(false);
    context.ready();
    context.run(async () => {
      const answer = await api.relocateSuggestions(library.id, { signal: context.signal });
      if (!context.alive()) return;
      const suggestions = rankedSuggestions(answer);
      if (!suggestions.length) list.append(h("p", { class: "muted small" }, "No folder with these files was found. Choose one yourself."));
      for (const suggestion of suggestions) {
        const radio = h("input", { type: "radio", name: "relocate-suggestion", value: suggestion.path });
        radio.addEventListener("change", () => {
          path.value = suggestion.path;
          preview = { sampled: answer.sampled, matched: suggestion.matched };
          previewed = suggestion.path;
          empty.checked = false;
          update();
        });
        list.append(h("label", { class: "move-option" }, radio,
          h("span", {}, h("span", { class: "mono" }, suggestion.path), h("span", { class: "muted small block" }, matchText(suggestion.matched, answer.sampled)))));
      }
    });
  }

  return { moveSection, moveServer, cancelMove, markMoved, undoMove, relocate };
}

// MARK: A server that moved

/**
 * The full-page notice of a server that moved: where it went, with links to its addresses. When
 * this browser still has the owner's profile open, Undo Move is offered too.
 * @param {object} options  api, destination ({ name, addresses }), onUndone()
 */
export function movedNotice({ api, destination, onUndone }) {
  const links = destination.addresses.length
    ? h("ul", { class: "move-addresses" }, destination.addresses.map((address) => h("li", {}, h("a", { href: `${address}/`, rel: "noopener" }, address))))
    : h("p", { class: "muted" }, "Open Aurelia at the new server’s address.");
  const owner = h("div", { class: "move-owner", hidden: true });
  const element = h("div", { class: "center-stack narrow move-notice" },
    h("img", { class: "brand-mark", src: "/web/icon.svg", alt: "" }),
    h("h1", {}, `This Server Moved to “${destination.name}”`),
    h("p", {}, "Aurelia now runs on another computer. Open it at its new address and sign in there once: a browser’s sign-in belongs to the address. Apps switch on their own."),
    links, owner);
  // Only the owner's open profile can read the move; for everyone else this stays hidden. A moved
  // server still lets its owner unlock Server Management and approve the undo.
  api.serverMove().then((status) => {
    if (status?.state !== "moved") return;
    const off = h("input", { type: "checkbox", class: "switch", "aria-label": "The new server is turned off" });
    const message = h("p", { class: "error-text", role: "alert" });
    const password = h("input", { class: "text-field", type: "password", autocomplete: "current-password", "aria-label": "Server Password" });
    const unlock = h("label", { class: "setup-field", hidden: true }, h("span", {}, "Server Password"), password);
    const undo = h("button", { type: "button", class: "secondary-button danger", onclick: async () => {
      if (!off.checked) { message.textContent = "Turn the new server off first, then confirm it here."; return; }
      undo.disabled = true;
      message.textContent = "";
      try {
        if (!unlock.hidden) {
          if (!password.value) { message.textContent = "Enter the Server Password."; return; }
          await api.unlockManagement(password.value);
          password.value = "";
          unlock.hidden = true;
        }
        await api.endServerMove();
        onUndone?.();
      } catch (error) {
        password.value = "";
        if (error?.code === "management_locked") {
          unlock.hidden = false;
          message.textContent = "Enter the Server Password to undo the move.";
          password.focus();
        } else if (error?.code === "invalid_credentials" || error?.code === "invalid_password") {
          message.textContent = "The Server Password is incorrect.";
        } else if (error?.code === "passkey_required") {
          message.textContent = "This server needs Face ID or Touch ID for this. Run sudo aurelia move undo on this server’s computer, or use Aurelia on your Mac.";
        } else {
          message.textContent = error?.message ?? "Something went wrong.";
        }
      } finally {
        undo.disabled = false;
      }
    } }, "Undo Move");
    owner.append(h("h2", {}, "Undo the Move"),
      h("p", { class: "muted small" }, "This server takes back its library and identity. Two copies of the same server must never run at once: turn the new server off first."),
      h("label", { class: "inline-control" }, off, "The new server is turned off"), unlock, message, h("div", { class: "button-row" }, undo));
    owner.hidden = false;
  }, () => {});
  return element;
}
