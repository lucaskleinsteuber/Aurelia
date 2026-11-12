// Native browser forms for the same server operations as the Mac settings. Credentials stay
// in HttpOnly cookies; an expired management window asks once, without discarding the draft.
import { h, clear } from "./dom.js";
import { loadAllPages } from "./api.js";
import { libraryPayload, managementPermissions, metadataPayload, profilePayload, waitForLibraryOperation, artworkUrl } from "./logic.js";
import { createMetadataExtras } from "./metadata-extras.js";
import { segmentsSection, SEGMENTS_FEATURE } from "./segments-view.js";

const input = (value = "", attributes = {}) => h("input", { class: "text-field", value: String(value ?? ""), ...attributes });
const field = (title, control, note) => h("label", { class: "editor-field" }, h("span", { class: "editor-field-title" }, title), control,
  note ? h("span", { class: "muted small" }, note) : null);
const choice = (options, current) => h("select", { class: "select" }, options.map(([value, label]) => h("option", { value, selected: value === current }, label)));
const button = (title, action, kind = "secondary-button") => h("button", { type: "button", class: kind, onclick: action }, title);

export function createManagementEditors(app) {
  const { api, state } = app;
  const dialogs = new Set();
  const metadataExtras = createMetadataExtras({ api, app, kit: { input, field, choice, button } });

  function editor(title, saveLabel, onSave) {
    const profileID = state.profile?.id;
    const controller = new AbortController();
    const body = h("div", { class: "editor-body" });
    const message = h("p", { class: "error-text editor-message", role: "alert" });
    const unlock = h("div", { class: "editor-unlock" });
    const discard = h("div", { class: "button-row", hidden: true });
    const cancel = button(saveLabel ? "Cancel" : "Close", requestClose);
    const save = h("button", { type: "submit", class: "primary-button", disabled: true }, saveLabel);
    const form = h("form", { class: "editor-form" }, body, message, unlock, discard,
      h("div", { class: "button-row end editor-actions" }, cancel, saveLabel ? save : null));
    const dialog = h("dialog", { class: "sheet settings-editor", "aria-label": title }, h("h2", {}, title), form);
    let busy = false;
    let canCancel = true;
    let dirty = false;
    let ready = false;
    let valid = true;
    const alive = () => !controller.signal.aborted && profileID === state.profile?.id && dialog.isConnected;
    const finish = () => { dialog.close(); app.onSaved?.(); };
    const setBusy = (value, cancellable = true) => {
      busy = value;
      canCancel = !value || cancellable;
      save.disabled = value || !ready || !valid;
      cancel.disabled = value && !cancellable;
      form.setAttribute("aria-busy", String(value));
      for (const control of body.querySelectorAll("input, select, textarea, button")) {
        if (value) control.dataset.wasDisabled = String(control.disabled);
        if (value || control.dataset.wasDisabled !== undefined) control.disabled = value || control.dataset.wasDisabled === "true";
        if (!value) delete control.dataset.wasDisabled;
      }
    };
    function requestClose() {
      if (busy && !canCancel) return;
      if (!dirty) return dialog.close();
      message.textContent = "Discard unsaved changes?";
      clear(discard);
      discard.hidden = false;
      discard.append(button("Keep Editing", () => { discard.hidden = true; message.textContent = ""; }),
        button("Discard", () => dialog.close(), "danger-button"));
    }
    function showUnlock(retry) {
      clear(unlock);
      const password = input("", { type: "password", autocomplete: "current-password", "aria-label": "Server Password" });
      const submit = button("Unlock", async () => {
        if (!password.value || !alive()) return;
        submit.disabled = true;
        try {
          await api.unlockManagement(password.value);
          password.value = "";
          if (!alive()) return;
          clear(unlock);
          message.textContent = "";
          await retry();
        } catch (error) {
          password.value = "";
          if (!alive()) return;
          submit.disabled = false;
          message.textContent = error.code === "invalid_credentials" ? "The Server Password is incorrect." : error.message;
          password.focus();
        }
      }, "primary-button");
      password.addEventListener("keydown", (event) => { if (event.key === "Enter") { event.preventDefault(); submit.click(); } });
      unlock.append(h("p", { class: "muted small" }, "Unlock Server Management to continue. Your draft stays open."),
        field("Server Password", password), submit);
      password.focus();
    }
    async function run(work, { complete = false, cancellable = !complete } = {}) {
      if (!alive() || busy) return;
      setBusy(true, cancellable);
      message.textContent = "";
      try {
        await work();
        if (alive() && complete) finish();
      } catch (error) {
        if (!alive() || error?.name === "AbortError") return;
        if (error.code === "management_locked") showUnlock(() => run(work, { complete, cancellable }));
        else if (error.offline || !app.handleError(error)) message.textContent = error.message;
      } finally {
        if (alive()) setBusy(false);
      }
    }
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      if (ready && valid && saveLabel) run(() => onSave(context), { complete: true });
    });
    form.addEventListener("input", () => { dirty = true; discard.hidden = true; });
    form.addEventListener("change", () => { dirty = true; discard.hidden = true; });
    dialog.addEventListener("cancel", (event) => { event.preventDefault(); requestClose(); });
    dialog.addEventListener("close", () => {
      controller.abort();
      for (const secret of form.querySelectorAll("input[type=password]")) secret.value = "";
      dialogs.delete(dialog);
      dialog.remove();
    }, { once: true });
    dialogs.add(dialog);
    document.body.append(dialog);
    dialog.showModal();
    const context = {
      body, dialog, signal: controller.signal, alive, run, finish,
      message: (text) => { if (alive()) message.textContent = text; },
      ready: () => { ready = true; save.disabled = busy || !valid; },
      setValid: (value) => { valid = value; save.disabled = busy || !ready || !valid; },
      clean: () => { dirty = false; },
      markChanged: () => { dirty = true; },
    };
    return context;
  }

  function addStorage() {
    if (!managementPermissions(state.profile).owner) return;
    const name = input("", { maxlength: 128, placeholder: "Optional name" });
    const path = input("", { required: true, spellcheck: false, placeholder: "/path/on/the/server", autocomplete: "off" });
    const kind = choice([["automatic", "Automatic"], ["movies", "Movies"], ["tvShows", "TV Shows"]], "automatic");
    const review = h("input", { type: "checkbox", class: "switch", "aria-label": "Review Before Importing" });
    const context = editor("Add Storage Location", "Add Storage Location", async ({ signal }) => {
      const library = await api.addLibrary(libraryPayload({ name: name.value, path: path.value, kind: kind.value, review: review.checked }), { signal });
      if (review.checked && library?.id && app.reviewImport) {
        // The sheet closes first; the preview opens over the settings.
        setTimeout(() => app.reviewImport(library), 0);
        return;
      }
      app.toast("Storage location added. Choose Scan Now to read its media.");
    });
    const browse = app.chooseServerFolder ? button("Browse…", () => app.chooseServerFolder((chosen) => {
      path.value = chosen;
      path.dispatchEvent(new Event("input", { bubbles: true }));
      if (!name.value.trim()) name.value = chosen.split(/[\\/]/).filter(Boolean).pop() ?? "";
    }, path.value.trim() || null)) : null;
    context.body.append(field("Name", name),
      h("div", { class: "editor-path-row" }, field("Server Folder Path", path, "A folder on the server computer. Browse shows the server’s folders; Aurelia only reads your media."), browse),
      field("Content", kind),
      app.reviewImport ? h("label", { class: "inline-control editor-toggle" }, review,
        h("span", {}, "Review Before Importing", h("span", { class: "muted small block" }, "See what each folder and file becomes and correct it before anything is imported."))) : null);
    context.ready();
    path.focus();
  }

  function removeStorage(library) {
    if (!managementPermissions(state.profile).owner) return;
    const context = editor("Remove Storage Location", "Remove", async ({ signal, message }) => {
      const operation = await api.removeLibrary(library.id, { signal });
      await waitForLibraryOperation(api, operation, { signal, onProgress: () => message("Removing the storage location…") });
      app.toast("Storage location removed.");
    });
    context.body.append(h("p", {}, `Remove “${library.name}” from Aurelia? Its titles, artwork and library state will be removed. Accounts, server settings and media files stay in place.`),
      h("div", { class: "muted small mono" }, library.path));
    context.ready();
  }

  async function profileTitles(signal) {
    const items = await loadAllPages((parameters) => api.request(`/api/v1/catalog/items?${new URLSearchParams(parameters)}`, { signal }), {});
    return items.filter((item) => item.kind === "movie" || item.kind === "series").sort((a, b) => a.title.localeCompare(b.title));
  }

  function editProfile(existing = null) {
    if (!managementPermissions(state.profile).owner) return;
    let snapshot = null;
    let ageSnapshot = null;
    let collect;
    let collectAge = () => null;
    const agesOffered = Boolean(state.server?.capabilities?.includes("age-limits-v1"));
    // A children's profile is set apart from the rest, as on the Mac: it ends before a role
    // change, and starts once the profile exists.
    const saveAge = async (userId, wanted, signal) => {
      const current = await api.profileAgeLimit(userId, { signal });
      if ((current?.ageLimit ?? null) === wanted) return;
      await api.setProfileAgeLimit(userId, { ageLimit: wanted, allowedTitleIds: wanted == null ? [] : current?.allowedTitleIds ?? [],
        hiddenTitleIds: wanted == null ? [] : current?.hiddenTitleIds ?? [], revision: current?.revision ?? 0 }, { signal });
    };
    const context = editor(existing ? "Edit Profile" : "Create Profile", existing ? "Save" : "Create Profile", async ({ signal }) => {
      const body = profilePayload(snapshot, collect());
      const age = agesOffered ? collectAge() : undefined;
      if (existing) {
        if (age === null && ageSnapshot?.ageLimit != null) await saveAge(existing.user.id, null, signal);
        await api.updateProfile(existing.user.id, body, { signal });
        if (age != null) await saveAge(existing.user.id, age, signal);
      } else {
        const created = await api.createProfile(body, { signal });
        const createdId = created?.user?.id ?? created?.id;
        if (age != null && createdId) await saveAge(createdId, age, signal);
      }
      app.toast(existing ? "Profile saved." : "Profile created.");
    });
    const load = async () => {
      const [loaded, titles, age] = await Promise.all([existing ? api.profileEditor(existing.user.id, { signal: context.signal }) : null, profileTitles(context.signal),
        existing && agesOffered ? api.profileAgeLimit(existing.user.id, { signal: context.signal }).catch(() => null) : null]);
      if (!context.alive()) return;
      snapshot = loaded;
      ageSnapshot = age;
      clear(context.body);
      const user = snapshot?.user;
      const name = input(user?.username ?? "", { minlength: 3, maxlength: 64, required: true, disabled: Boolean(existing) });
      const role = choice([["user", "User"], ["admin", "Administrator"], ["owner", "Owner"]], user?.role ?? "user");
      const enabled = input("", { type: "checkbox", checked: snapshot?.isEnabled ?? true });
      const protection = input("", { type: "checkbox", checked: user?.pinProtectionEnabled ?? false });
      const pin = input("", { type: "password", inputmode: "numeric", pattern: "[0-9]{4,8}", maxlength: 8, autocomplete: "new-password" });
      const confirm = input("", { type: "password", inputmode: "numeric", pattern: "[0-9]{4,8}", maxlength: 8, autocomplete: "new-password" });
      const access = choice([
        ...(snapshot?.access.mode === "legacyLibraries" ? [["legacyLibraries", "Existing Storage Grants"]] : []),
        ["entireLibrary", "Entire Library"], ["selectedTitles", "Selected Titles"],
      ], snapshot?.access.mode ?? "selectedTitles");
      const selected = new Set(snapshot?.access.titleIds ?? []);
      const query = input("", { type: "search", placeholder: "Search films and series" });
      const count = h("span", { class: "muted small" });
      const list = h("div", { class: "editor-title-list" });
      const picker = h("div", { class: "editor-title-picker" }, field("Films and Series", query), count, list,
        h("p", { class: "muted small" }, "A series includes all current and future seasons, episodes, extras and trailers."));
      const protectionFields = h("div", { class: "editor-grid" }, field(user?.pinProtectionEnabled && !user.needsPinSetup ? "New PIN (optional)" : "PIN (4–8 digits)", pin), field("Confirm PIN", confirm));
      const accessNote = h("p", { class: "muted small" });
      const child = input("", { type: "checkbox", checked: ageSnapshot?.ageLimit != null });
      const ageChoice = choice([[0, "Under 6 · FSK 0"], [6, "6 to 11 · up to FSK 6"], [12, "12 to 15 · up to FSK 12"], [16, "16 or 17 · up to FSK 16"]],
        ageSnapshot?.ageLimit ?? 6);
      const ageField = field("Age", ageChoice, "Only titles up to this FSK rating show. Titles without a rating stay hidden until you allow them on the Mac.");
      const childSection = agesOffered ? h("div", {}, h("h3", {}, "Children's Profile"),
        field("Children's Profile", child, "A profile for a child: it sees only titles for its age."), ageField) : null;
      const redraw = () => {
        clear(list);
        const matches = titles.filter((item) => item.title.toLocaleLowerCase().includes(query.value.toLocaleLowerCase()));
        count.textContent = `${selected.size} selected${matches.length > 100 ? " · Showing the first 100 matches; refine the search to see more." : ""}`;
        list.append(...matches.slice(0, 100).map((item) => {
          const checked = input("", { type: "checkbox", checked: selected.has(item.id) });
          checked.addEventListener("change", () => { if (checked.checked) selected.add(item.id); else selected.delete(item.id); count.textContent = `${selected.size} selected`; });
          return h("label", { class: "editor-title-option" }, checked, h("span", {}, item.title), item.year ? h("span", { class: "muted small" }, item.year) : null);
        }));
        if (!matches.length) list.append(h("p", { class: "muted small" }, "No matching films or series."));
      };
      const update = () => {
        const privileged = role.value !== "user";
        if (privileged) protection.checked = true;
        protection.disabled = privileged;
        protectionFields.hidden = !protection.checked;
        if (!protection.checked) { pin.value = ""; confirm.value = ""; }
        if (childSection) {
          childSection.hidden = role.value !== "user";
          ageField.hidden = !child.checked;
        }
        access.disabled = role.value === "owner";
        if (role.value === "owner") access.value = "entireLibrary";
        picker.hidden = access.value !== "selectedTitles";
        accessNote.textContent = access.value === "legacyLibraries" ? "Existing storage grants stay unchanged unless you select another access mode."
          : access.value === "entireLibrary" ? "Includes all existing titles and titles added later." : "Choose the films and series this profile can watch.";
      };
      query.addEventListener("input", redraw);
      for (const control of [role, protection, access, child]) control.addEventListener("change", update);
      collectAge = () => role.value === "user" && child.checked ? Number(ageChoice.value) : null;
      context.body.append(field("Name", name), field("Role", role, "Administrators manage their allowed content. Owners manage the whole server."),
        field("Profile enabled", enabled), h("h3", {}, "PIN Protection"), field("Require a Profile PIN", protection, "Owner and administrator profiles always require a PIN."),
        protectionFields, h("p", { class: "muted small" }, user?.pinProtectionEnabled && !user.needsPinSetup
          ? "Leave both PIN fields empty to keep the current PIN. Changing it locks active sessions."
          : "Use 4–8 digits and enter the same PIN in both fields when protection is enabled."),
        childSection, h("h3", {}, "Content Access"), field("Can watch", access), accessNote, picker);
      collect = () => ({ username: name.value, role: role.value, isEnabled: enabled.checked, pinProtectionEnabled: protection.checked,
        pin: pin.value, pinConfirmation: confirm.value, accessMode: access.value, titleIds: [...selected] });
      redraw(); update(); context.clean(); context.ready();
    };
    context.body.append(h("p", { class: "muted" }, "Loading profile…"));
    context.run(load);
  }

  function metadataPicker() {
    if (!managementPermissions(state.profile).administrator) return;
    const context = editor("Edit Metadata", null);
    const query = input("", { type: "search", placeholder: "Search your library", "aria-label": "Search your library" });
    const results = h("div", { class: "editor-title-list" });
    let generation = 0;
    let searchController;
    const search = async () => {
      const mine = ++generation;
      searchController?.abort();
      clear(results);
      context.message("");
      if (!query.value.trim()) return;
      searchController = new AbortController();
      const current = searchController;
      const stop = () => current.abort();
      context.signal.addEventListener("abort", stop, { once: true });
      try {
        const page = await api.request(`/api/v1/catalog/search?${new URLSearchParams({ query: query.value.trim(), limit: 100 })}`, { signal: current.signal });
        if (!context.alive() || mine !== generation) return;
        for (const item of page.items ?? []) results.append(button(`${item.title}${item.year ? ` (${item.year})` : ""}`, () => { context.dialog.close(); editMetadata(item); }));
        if (!page.items?.length) results.append(h("p", { class: "muted" }, "No matching titles."));
      } catch (error) { if (context.alive() && mine === generation && error.name !== "AbortError") context.message(error.message); }
      finally { context.signal.removeEventListener("abort", stop); }
    };
    query.addEventListener("keydown", (event) => { if (event.key === "Enter") { event.preventDefault(); search(); } });
    context.body.append(field("Title", query), button("Search", search), results);
    query.focus();
  }

  function editMetadata(item) {
    if (!managementPermissions(state.profile).administrator) return;
    let document;
    const changes = {};
    const automatic = new Set();
    const controls = new Map();
    const extras = {};
    const context = editor("Edit Metadata", "Save", async ({ signal }) => {
      const payload = metadataPayload(document, changes, [...automatic]);
      if (extras.relativeSourcePath) payload.relativeSourcePath = extras.relativeSourcePath;
      await api.saveMediaEditor(item.id, payload, { signal });
      app.toast("Metadata saved.");
    });
    context.dialog.setAttribute("class", "sheet settings-editor metadata-editor");
    const posterPath = artworkUrl(item.poster, 320);
    const name = h("p", { class: "metadata-editor-title" }, item.title);
    context.dialog.querySelector("h2").replaceWith(h("header", { class: "metadata-editor-header" },
      posterPath ? h("img", { class: "metadata-editor-poster", src: posterPath, alt: "", decoding: "async" })
        : h("div", { class: "metadata-editor-poster artwork-missing", "aria-hidden": "true" }),
      h("div", {}, h("h2", {}, "Edit Metadata"), name,
        h("p", { class: "muted small" }, "Changes apply to this title. Your video files stay in place."))));
    const section = (title, ...content) => h("section", { class: "editor-section settings-section metadata-section" }, h("h3", {}, title), ...content);
    const validate = () => {
      for (const [key, entry] of controls) {
        entry.error.textContent = "";
        entry.control.setAttribute("aria-invalid", "false");
        if (!Object.hasOwn(changes, key)) continue;
        try { metadataPayload(document, { [key]: changes[key] }, []); }
        catch (error) { entry.error.textContent = error.message; entry.control.setAttribute("aria-invalid", "true"); }
      }
      try { metadataPayload(document, changes, [...automatic]); context.setValid(true); context.message(""); }
      catch (error) { context.setValid(false); context.message(error.message); }
    };
    const load = async () => {
      const loaded = await api.mediaEditor(item.id, { signal: context.signal });
      if (!context.alive()) return;
      document = loaded;
      for (const key of Object.keys(changes)) delete changes[key];
      automatic.clear(); controls.clear(); clear(context.body);
      const makeField = (label, key, property, attributes = {}) => {
        const value = document.values[property];
        const list = key === "genres" || key === "studios";
        const control = key === "overview" || list ? h("textarea", { class: `text-field ${list ? "editor-lines" : "editor-description"}`, maxlength: 8192,
          ...attributes }, Array.isArray(value) ? value.join("\n") : value ?? "")
          : key === "fsk" ? choice([["", "Not specified"], ...[0, 6, 12, 16, 18].map((age) => [String(age), `FSK ${age}`])], value == null ? "" : String(value))
            : input(Array.isArray(value) ? value.join(", ") : value ?? "", attributes);
        const error = h("p", { class: "error-text metadata-field-error", role: "status", "aria-live": "polite" });
        controls.set(key, { control, property, error });
        const changed = () => {
          changes[key] = list ? control.value.split("\n") : control.value;
          automatic.delete(key);
          if (key === "title") name.textContent = control.value || item.title;
          validate();
        };
        control.addEventListener("input", changed);
        control.addEventListener("change", changed);
        const reset = button("Reset to Automatic", () => {
          automatic.add(key); delete changes[key];
          const resetValue = document.automaticValues[property];
          control.value = Array.isArray(resetValue) ? resetValue.join("\n") : resetValue ?? "";
          control.dispatchEvent(new Event("change", { bubbles: true }));
          delete changes[key]; automatic.add(key); validate();
        });
        return h("div", { class: "editor-metadata-field" }, field(label, control), error, reset);
      };
      const titleAndYear = section("Title and Year", makeField("Title", "title", "title", { required: true, maxlength: 512 }),
        h("div", { class: "editor-grid" }, makeField("Release Year", "releaseYear", "releaseYear", { inputmode: "numeric", placeholder: "Not specified" }), makeField("FSK", "fsk", "fskAge")),
        document.kind === "movie" ? makeField("Runtime in Minutes", "runtimeMinutes", "runtimeMinutes", { inputmode: "numeric", placeholder: "Not specified" }) : null);
      const overview = section("Overview", makeField("Overview", "overview", "overview"));
      const genres = section("Genres", makeField("Genres", "genres", "genres", { placeholder: "One genre per line" }));
      const production = section("Production and Release", makeField("Studios", "studios", "studios", { placeholder: "One studio per line" }),
        makeField("Country of Origin", "country", "country", { maxlength: 128 }), h("p", { class: "muted small" }, "Choose one country. Foreign content ratings are not automatically converted to FSK."));
      delete extras.relativeSourcePath;
      const { artwork, credits, source, subtitles, removal } = metadataExtras.sections({ item, document, context, changes, automatic, extras, changed: () => { validate(); } });
      const capabilities = state.server?.capabilities ?? [];
      const segments = capabilities.includes(SEGMENTS_FEATURE) && (document.kind === "episode" || document.kind === "series" || document.kind === "movie")
        ? segmentsSection({ api, item, kind: document.kind, canPreview: capabilities.includes("scrub-previews-v1") || capabilities.includes("live-conversion-v1") })
        : null;
      const reload = button("Reload", () => {
        // Reload is explicit: keep a conflict draft until the user chooses to discard it.
        const confirm = button("Discard Draft and Reload", () => context.run(load), "danger-button");
        reload.replaceWith(confirm);
      });
      context.body.append(h("p", { class: "muted small" }, "Manual changes survive scans and provider refreshes. Your video files are never changed."),
        ...[titleAndYear, overview, genres, production, artwork, credits, segments, matchingSection(item, context, load), source, subtitles, reload, removal].filter(Boolean));
      name.textContent = document.values.title;
      validate();
      context.clean(); context.ready();
    };
    context.body.append(h("p", { class: "muted" }, "Loading editor…"));
    context.run(load);
  }

  function matchingSection(item, context, reload) {
    const query = input(item.title, { type: "search", "aria-label": "Find Movie Info" });
    const results = h("div", { class: "editor-match-list" });
    const search = () => context.run(async () => {
      const candidates = await api.metadataSearch(item.id, query.value.trim(), { signal: context.signal });
      if (!context.alive()) return;
      clear(results);
      for (const candidate of candidates ?? []) results.append(h("div", { class: "settings-card" },
        h("div", { class: "settings-card-main" }, h("strong", {}, candidate.title), h("span", { class: "muted small" }, [candidate.year, candidate.mediaType].filter(Boolean).join(" · "))),
        button("Use Match", () => {
          clear(results);
          results.append(h("p", {}, "Use this match? Unsaved edits in this form will be discarded. Saved manual overrides stay in place."), button("Use Match and Reload", () => context.run(async () => {
            await api.selectMetadataMatch(item.id, { providerMediaId: candidate.providerMediaId, mediaType: candidate.mediaType }, { signal: context.signal });
            await reload();
          }, { cancellable: false })));
        })));
      if (!candidates?.length) results.append(h("p", { class: "muted small" }, "No matching movie info."));
    });
    query.addEventListener("keydown", (event) => { if (event.key === "Enter") { event.preventDefault(); search(); } });
    const remove = button("Clear Match", () => {
      clear(results);
      results.append(h("p", {}, "Clear the provider match? Unsaved edits in this form will be discarded. Saved manual overrides stay in place."), button("Clear Match and Reload", () => context.run(async () => {
        await api.clearMetadataMatch(item.id, { signal: context.signal });
        await reload();
      }, { cancellable: false }), "danger-button"));
    });
    return h("section", { class: "editor-section settings-section metadata-section" }, h("h3", {}, "Match with TMDB"), field("Title", query), h("div", { class: "button-row" }, button("Search", search), remove), results);
  }

  return { addStorage, removeStorage, editProfile, editMetadata, metadataPicker, kit: { editor, input, field, choice, button },
    close: () => { for (const dialog of [...dialogs]) dialog.close(); } };
}
