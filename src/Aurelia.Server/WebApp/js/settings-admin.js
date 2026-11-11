// The rest of the Mac's server administration in the browser: codes for new devices, sessions,
// passwords, the metadata services, review matches, the server's folders, exclusions, restart,
// diagnostics and encrypted backups. Every form uses the editors' sheet, so an expired
// management window asks for the Server Password once and keeps the draft.

import { h, clear, saveBlob } from "./dom.js";
import { codeCountdown, folderCrumbs, shownName, subtitleLanguages, SUBTITLE_LANGUAGE_CHOICES } from "./logic.js";

export function createAdminTools({ api, app, editors }) {
  const { editor, input, field, choice, button } = editors.kit;

  // MARK: Devices

  /** An 8-digit code for a new device, with its remaining minutes; a new one replaces it. */
  function createCode() {
    const context = editor("Code for a New Device", null);
    const code = h("div", { class: "pairing-code", "aria-live": "polite" });
    const left = h("p", { class: "muted small" });
    let timer = 0;
    const show = (pairing) => {
      code.textContent = `${pairing.code.slice(0, 4)} ${pairing.code.slice(4)}`;
      clearInterval(timer);
      const tick = () => {
        if (!context.alive()) return clearInterval(timer);
        const text = codeCountdown(pairing.expiresAt, Date.now());
        left.textContent = text ?? "This code has expired. Create a new one.";
        if (!text) { code.className = "pairing-code expired"; clearInterval(timer); }
      };
      code.className = "pairing-code";
      tick();
      timer = setInterval(tick, 1000);
    };
    const create = () => context.run(async () => show(await api.createPairingCode()));
    context.dialog.addEventListener("close", () => clearInterval(timer), { once: true });
    context.body.append(
      h("p", {}, "On the new device, open Aurelia and enter this code when it asks to connect. A code works once and for five minutes."),
      code, left,
      h("div", { class: "button-row" },
        button("Copy Code", async () => {
          try { await navigator.clipboard.writeText(code.textContent.replace(/\s/g, "")); app.toast("Code copied."); }
          catch { app.toast("Copy didn’t work here. Read the code from the screen instead."); }
        }),
        button("New Code", create)));
    context.ready();
    create();
  }

  /** Approves a code an older device shows itself, after checking which device asks. */
  function enterCode() {
    const value = input("", { inputmode: "numeric", autocomplete: "one-time-code", maxlength: 9, placeholder: "12345678", "aria-label": "Code" });
    const preview = h("div", { class: "pairing-preview" });
    const context = editor("Enter Code from Device", null);
    const look = () => context.run(async () => {
      const digits = value.value.replace(/\D/g, "");
      if (digits.length !== 8) return context.message("Enter the eight digits the device shows.");
      const found = await api.lookupDevicePairing(digits, { signal: context.signal });
      if (!context.alive()) return;
      clear(preview);
      preview.append(h("div", { class: "settings-card" },
        h("div", { class: "settings-card-main" },
          h("div", { class: "settings-card-title" }, found.deviceName),
          h("div", { class: "muted small" }, `Wants to connect to ${found.serverName}`)),
        h("div", { class: "settings-card-actions" },
          button("Deny", () => context.run(async () => { await api.denyDevicePairing(found.id); app.toast(`${found.deviceName} was denied.`); context.finish(); }), "secondary-button danger"),
          button("Allow", () => context.run(async () => { await api.approveDevicePairing(found.id); app.toast(`${found.deviceName} is connected.`); context.finish(); }), "primary-button"))));
    });
    value.addEventListener("keydown", (event) => { if (event.key === "Enter") { event.preventDefault(); look(); } });
    context.body.append(h("p", {}, "Older Apple TV, iPhone, iPad and browser versions show a code themselves. Type it here to let that device in."),
      field("Code", value), h("div", { class: "button-row" }, button("Look Up", look, "primary-button")), preview);
    context.ready();
    value.focus();
  }

  /** The devices one person is signed in on, each with Sign Out, and all at once. */
  function userSessions(entry) {
    const list = h("div", { class: "settings-card-list" });
    const context = editor(`${shownName(entry.user)}’s Devices`, null);
    const load = async () => {
      const sessions = await api.userSessions(entry.user.id, { signal: context.signal });
      if (!context.alive()) return;
      clear(list);
      const active = (sessions ?? []).filter((session) => !session.revokedAt);
      if (!active.length) list.append(h("p", { class: "muted" }, "Not signed in on any device."));
      for (const session of active) list.append(h("div", { class: "settings-card" },
        h("div", { class: "settings-card-main" }, h("div", { class: "settings-card-title" }, session.deviceName),
          h("div", { class: "muted small" }, `Last used ${new Date(session.lastSeenAt).toLocaleString()}`)),
        h("div", { class: "settings-card-actions" }, button("Sign Out", () => context.run(async () => {
          await api.revokeUserSession(session.id);
          app.toast(`${session.deviceName} is signed out.`);
          await load();
        })))));
    };
    context.body.append(list, h("div", { class: "button-row" }, button("Sign Out Everywhere", () => context.run(async () => {
      await api.revokeAllUserSessions(entry.user.id);
      app.toast(`${shownName(entry.user)} is signed out on every device.`);
      await load();
    }), "secondary-button danger")));
    context.ready();
    context.run(load);
  }

  /** A new sign-in password for a person; the server asks for its own password first. */
  function resetPassword(entry) {
    const first = input("", { type: "password", autocomplete: "new-password", minlength: 12 });
    const second = input("", { type: "password", autocomplete: "new-password", minlength: 12 });
    const context = editor(`New Password for ${shownName(entry.user)}`, "Change Password", async () => {
      await api.resetUserPassword(entry.user.id, first.value);
      app.toast("Password changed. Their other devices stay signed in until you sign them out.");
    });
    const check = () => {
      const ok = first.value.length >= 12 && first.value === second.value;
      context.setValid(ok);
      context.message(second.value && first.value !== second.value ? "The passwords don’t match." : "");
    };
    first.addEventListener("input", check);
    second.addEventListener("input", check);
    context.body.append(field("New Password", first, "At least 12 characters."), field("Repeat Password", second));
    context.setValid(false);
    context.ready();
    first.focus();
  }

  // MARK: Metadata services

  function metadataService(refresh) {
    const enabled = h("input", { type: "checkbox", class: "switch", "aria-label": "Use TMDB" });
    const language = choice([["en-US", "English"], ["de-DE", "German"], ["fr-FR", "French"], ["es-ES", "Spanish"], ["it-IT", "Italian"], ["nl-NL", "Dutch"], ["ja-JP", "Japanese"]], "en-US");
    const token = input("", { type: "password", autocomplete: "off", spellcheck: false, placeholder: "Leave empty to keep the saved token" });
    const status = h("p", { class: "muted small" });
    let hasToken = false;
    const context = editor("Movie & TV Info", "Save", async () => {
      await api.saveMetadataProvider({ enabled: enabled.checked, language: language.value, token: token.value.trim() || null });
      app.toast("Saved.");
      refresh?.();
    });
    const remove = button("Remove Token", () => context.run(async () => {
      const next = await api.removeMetadataToken();
      hasToken = next.hasToken;
      status.textContent = "The token was removed. Titles keep the details they already have.";
    }), "secondary-button danger");
    context.body.append(
      h("p", {}, "Aurelia gets titles, artwork and episode details from The Movie Database (TMDB). Create a free account there, then copy the “API Read Access Token” from its API settings."),
      h("label", { class: "inline-control" }, enabled, "Look up movie and TV info"),
      field("Language", language),
      field("API Read Access Token", token), status,
      h("div", { class: "button-row" }, remove));
    context.run(async () => {
      const current = await api.metadataProvider({ signal: context.signal });
      enabled.checked = current.enabled;
      language.value = [...language.options].some((option) => option.value === current.language) ? current.language : "en-US";
      hasToken = current.hasToken;
      status.textContent = hasToken ? "A token is saved. Enter a new one only to replace it." : "No token is saved yet.";
      remove.hidden = !hasToken;
      context.clean();
      context.ready();
    });
  }

  function subtitleService(refresh) {
    const enabled = h("input", { type: "checkbox", class: "switch", "aria-label": "Use OpenSubtitles" });
    const automatic = h("input", { type: "checkbox", class: "switch", "aria-label": "Download automatically" });
    const languages = input("", { placeholder: "en, de", spellcheck: false });
    const key = input("", { type: "password", autocomplete: "off", placeholder: "Leave empty to keep the saved key" });
    const account = input("", { autocomplete: "username", placeholder: "Optional" });
    const password = input("", { type: "password", autocomplete: "current-password", placeholder: "Optional" });
    const status = h("p", { class: "muted small" });
    const context = editor("Subtitles from OpenSubtitles", "Save", async () => {
      const chosen = subtitleLanguages(languages.value);
      if (!chosen.length) throw new Error("Enter at least one language code, such as en or de.");
      await api.saveSubtitleProvider({ enabled: enabled.checked, languages: chosen, automatic: automatic.checked,
        apiKey: key.value.trim() || null, accountName: account.value.trim() || null, accountPassword: password.value || null });
      app.toast("Saved.");
      refresh?.();
    });
    const removeKey = button("Remove Key", () => context.run(async () => { await api.removeSubtitleKey(); status.textContent = "The key was removed."; }), "secondary-button danger");
    const removeAccount = button("Remove Account", () => context.run(async () => { await api.removeSubtitleAccount(); status.textContent = "The account was removed."; }), "secondary-button danger");
    context.body.append(
      h("p", {}, "Finds subtitles for titles that have none. An API key from opensubtitles.com is free; an account allows more downloads a day."),
      h("label", { class: "inline-control" }, enabled, "Search OpenSubtitles"),
      h("label", { class: "inline-control" }, automatic, "Download subtitles for new titles automatically"),
      field("Languages", languages, `Two-letter codes, separated by commas: ${SUBTITLE_LANGUAGE_CHOICES.slice(0, 6).join(", ")} …`),
      field("API Key", key), field("Account Name", account), field("Account Password", password), status,
      h("div", { class: "button-row" }, removeKey, removeAccount));
    context.run(async () => {
      const current = await api.subtitleProvider({ signal: context.signal });
      enabled.checked = current.enabled;
      automatic.checked = current.automatic;
      languages.value = (current.languages ?? []).join(", ");
      account.placeholder = current.accountName ?? "Optional";
      removeKey.hidden = !current.hasApiKey;
      removeAccount.hidden = !current.hasAccount;
      status.textContent = [current.hasApiKey ? "An API key is saved." : "No API key is saved yet.", current.hasAccount ? `Signed in as ${current.accountName}.` : null].filter(Boolean).join(" ");
      context.clean();
      context.ready();
    });
  }

  /** Titles whose match the server wasn't sure about, each with its best candidates. */
  function reviewMatches(refresh) {
    const list = h("div", { class: "review-list" });
    const context = editor("Review Matches", null);
    const load = async () => {
      const reviews = await api.metadataReviews({ signal: context.signal });
      if (!context.alive()) return;
      clear(list);
      const open = (reviews ?? []).filter((review) => review.state === "needsReview");
      if (!open.length) list.append(h("p", { class: "muted" }, "Nothing to review. Every title has a match it’s sure about."));
      for (const review of open) {
        list.append(h("section", { class: "review-item" },
          h("h3", {}, review.title), h("p", { class: "muted small" }, review.reason),
          h("div", { class: "review-candidates" }, (review.candidates ?? []).slice(0, 4).map((candidate) => h("div", { class: "settings-card" },
            h("div", { class: "settings-card-main" },
              h("div", { class: "settings-card-title" }, candidate.title, candidate.year ? h("span", { class: "muted" }, ` (${candidate.year})`) : null),
              h("div", { class: "muted small" }, [candidate.mediaType === "tv" ? "TV show" : "Movie", `${Math.round((candidate.confidence ?? 0) * 100)}% sure`].join(" · ")),
              candidate.overview ? h("p", { class: "muted small review-overview" }, candidate.overview) : null),
            h("div", { class: "settings-card-actions" }, button("Use This", () => context.run(async () => {
              await api.selectMetadataMatch(review.mediaId, { providerMediaId: candidate.providerMediaId, mediaType: candidate.mediaType });
              app.toast(`“${review.title}” is matched.`);
              await load();
              refresh?.();
            }), "primary-button")))))));
      }
    };
    context.body.append(list);
    context.ready();
    context.run(load);
  }

  // MARK: Library

  /**
   * Lets a person walk the server's folders and pick one, instead of typing a path they can't
   * see from this computer. `onPick(path)` receives the chosen absolute path.
   */
  function chooseServerFolder(onPick, startPath) {
    const crumbs = h("nav", { class: "folder-crumbs", "aria-label": "Folder" });
    const list = h("ul", { class: "folder-list" });
    let current = null;
    // Choosing hands the path back and closes only this sheet; the form that asked stays open.
    const context = editor("Choose a Folder on the Server", null);
    const pick = button("Choose This Folder", () => {
      if (!current) return;
      onPick(current);
      context.dialog.close();
    }, "primary-button");
    pick.disabled = true;
    // The sheet re-enables its controls after each step, so the choice is set once a folder opened.
    const open = (path) => context.run(async () => {
      const listing = await api.serverFolders(path, { signal: context.signal });
      if (!context.alive()) return;
      current = listing.path ?? null;
      clear(crumbs);
      crumbs.append(button("Places", () => open(null), "link-button"),
        ...folderCrumbs(current).map((crumb) => button(crumb.name, () => open(crumb.path), "link-button")));
      clear(list);
      if (listing.parent) list.append(h("li", {}, h("button", { type: "button", class: "folder-entry up", onclick: () => open(listing.parent) }, "↑ Up one folder")));
      for (const folder of listing.folders ?? []) list.append(h("li", {},
        h("button", { type: "button", class: "folder-entry", onclick: () => open(folder.path) }, h("span", { class: "folder-icon", "aria-hidden": "true" }), folder.name)));
      if (!listing.folders?.length) list.append(h("li", { class: "muted small" }, "No folders inside."));
    }).then(() => { pick.disabled = !current; });
    context.body.append(h("p", { class: "muted small" }, "Aurelia only reads the folder you choose; it never changes your media."), crumbs, list,
      h("div", { class: "button-row end" }, pick));
    context.ready();
    open(startPath ?? null);
  }

  /** Files and folders a scan leaves out because a title was removed; each can come back. */
  function exclusions(library, refresh) {
    const list = h("div", { class: "settings-card-list" });
    const context = editor(`Left Out of ${library.name}`, null);
    const load = async () => {
      const entries = await api.libraryExclusions(library.id, { signal: context.signal });
      if (!context.alive()) return;
      clear(list);
      if (!entries?.length) list.append(h("p", { class: "muted" }, "Nothing is left out. Removed titles appear here and can come back."));
      for (const entry of entries ?? []) list.append(h("div", { class: "settings-card" },
        h("div", { class: "settings-card-main" }, h("div", { class: "settings-card-title mono" }, entry.relativePath),
          h("div", { class: "muted small" }, entry.isDirectory ? "Folder" : "File")),
        h("div", { class: "settings-card-actions" }, button("Bring Back", () => context.run(async () => {
          await api.restoreExclusion(library.id, entry.id);
          app.toast("It comes back with the next scan.");
          await load();
          refresh?.();
        })))));
    };
    context.body.append(h("p", { class: "muted small" }, "When you remove a title, its file is skipped by later scans. Media files are never deleted."), list);
    context.ready();
    context.run(load);
  }

  // MARK: Server

  function restart(refresh) {
    const context = editor("Restart the Server", "Restart", async () => {
      await api.restartServer();
      app.toast("The server is restarting. This page reconnects by itself.");
      refresh?.();
    });
    context.body.append(h("p", {}, "Playback stops for everyone for a few seconds. Your library, accounts and settings stay as they are."));
    context.ready();
  }

  async function downloadDiagnostics() {
    try {
      const blob = await api.diagnosticsReport();
      saveBlob(blob, `Aurelia-Diagnostics-${new Date().toISOString().slice(0, 10)}.json`);
    } catch (error) {
      if (!app.handleError(error)) app.toast(error.message);
    }
  }

  function verifyBackup(backup) {
    const context = editor("Check Backup", null);
    const result = h("p", { role: "status" }, "Checking…");
    context.body.append(h("p", { class: "muted small" }, new Date(backup.createdAt).toLocaleString()), result);
    context.ready();
    context.run(async () => {
      const verdict = await api.verifyBackup(backup.name);
      result.textContent = verdict?.isValid ? "This backup is complete and readable." : `This backup is damaged: ${verdict?.message ?? "it can’t be read."}`;
    });
  }

  /** The whole server (accounts, library, settings) as one file protected by a passphrase. */
  function exportBackup() {
    const first = input("", { type: "password", autocomplete: "new-password", minlength: 12 });
    const second = input("", { type: "password", autocomplete: "new-password", minlength: 12 });
    const context = editor("Save an Encrypted Backup", "Create and Download", async () => {
      context.message("Packing the server… this can take a minute.");
      const transfer = await api.exportBackup(first.value);
      try {
        const blob = await api.backupTransfer(transfer.id);
        saveBlob(blob, `Aurelia-Server-${new Date().toISOString().slice(0, 10)}.aureliabackup`);
        app.toast("Backup saved. Keep the passphrase: without it the file can’t be opened.");
      } finally {
        await api.discardBackupTransfer(transfer.id).catch(() => {});
      }
    });
    const check = () => context.setValid(first.value.length >= 12 && first.value === second.value);
    first.addEventListener("input", check);
    second.addEventListener("input", check);
    context.body.append(h("p", {}, "The file holds accounts, library details, progress and settings, encrypted with your passphrase. Media files are not included."),
      field("Passphrase", first, "At least 12 characters. Aurelia can’t recover it."), field("Repeat Passphrase", second));
    context.setValid(false);
    context.ready();
  }

  /** Puts an encrypted backup back: the Mac app swaps the data, a Linux package server at its restart. */
  function restoreBackup() {
    const file = h("input", { type: "file", accept: ".aureliabackup,application/octet-stream", class: "file-field" });
    const passphrase = input("", { type: "password", autocomplete: "off" });
    const signOut = h("input", { type: "checkbox", class: "switch", checked: true, "aria-label": "Sign out every device" });
    const context = editor("Restore from Backup", "Check and Restore", async ({ message }) => {
      const chosen = file.files?.[0];
      if (!chosen) throw new Error("Choose the backup file first.");
      const uploadId = crypto.randomUUID();
      message("Uploading the backup…");
      await api.uploadBackup(uploadId, chosen);
      message("Checking the backup…");
      const prepared = await api.prepareRestore({ uploadId, passphrase: passphrase.value, revokeAllSessions: signOut.checked, acceptDifferentServerIdentity: false });
      message("Restoring… the server restarts.");
      await api.applyRestore(prepared.id);
      app.toast("The server restores the backup and restarts. This page reconnects by itself.");
    });
    context.body.append(h("p", {}, "Replaces this server’s accounts, library details and settings with the backup’s. Media files stay where they are."),
      field("Backup File", file), field("Passphrase", passphrase), h("label", { class: "inline-control" }, signOut, "Sign out every device afterwards"));
    context.ready();
  }

  /** The Mac app's background hosting, from a browser: keep serving, start at login, stay awake. */
  function hosting(current, refresh) {
    const background = h("input", { type: "checkbox", class: "switch", checked: current.backgroundEnabled, "aria-label": "Keep serving in the background" });
    const login = h("input", { type: "checkbox", class: "switch", checked: current.startAtLogin, "aria-label": "Start at login" });
    const awake = h("input", { type: "checkbox", class: "switch", checked: current.preventIdleSleep, "aria-label": "Keep the Mac awake" });
    const context = editor("Hosting on the Mac", "Apply", async ({ message }) => {
      const operation = await api.changeHosting({ backgroundEnabled: background.checked, startAtLogin: login.checked, preventIdleSleep: awake.checked });
      if (operation?.state === "awaitingConfirmation") {
        message("Confirming the change…");
        await api.confirmOperation(operation.id);
      }
      app.toast("Hosting changed.");
      refresh?.();
    });
    context.body.append(
      h("label", { class: "inline-control" }, background, "Keep serving when the Aurelia window is closed"),
      h("label", { class: "inline-control" }, login, "Start serving when the Mac starts"),
      h("label", { class: "inline-control" }, awake, "Keep the Mac awake while serving"));
    context.ready();
  }

  return { createCode, enterCode, userSessions, resetPassword, metadataService, subtitleService, reviewMatches,
    chooseServerFolder, exclusions, restart, downloadDiagnostics, verifyBackup, exportBackup, restoreBackup, hosting };
}
