// Import Preview, as in the Mac app: a new storage location is read without importing anything,
// the owner checks what each folder and file becomes, corrects what's wrong and then imports the
// recognized items. Video files are only read.

import { h, clear } from "./dom.js";
import {
  IMPORT_FILTERS, importAssignmentChanges, importChoicesFor, importEditorStart, importPreviewRows, loadImportPreview,
} from "./logic.js";

const KIND_LABELS = { movie: "Movie", series: "Series", episode: "Episode", extra: "Extra", trailer: "Trailer" };
const STATUS_LABELS = { recognized: "Recognized", pending: "Needs Review", ignored: "Ignored", error: "Error" };

/** @param {{ api: object, app: object, kit: object }} options  kit: the editors' sheet helpers */
export function createImportPreview({ api, app, kit }) {
  const { editor, input, field, choice, button } = kit;

  function open(library, { onDone } = {}) {
    let summary = null;
    let items = [];
    let assignments = [];
    let changed = false;
    const selected = new Set();
    const context = editor("Import Preview", null);
    context.dialog.className += " import-preview-sheet";

    const counts = h("p", { class: "import-counts muted small", role: "status" }, "Reading file names and folders…");
    const search = input("", { type: "search", placeholder: "Search titles, folders or files", "aria-label": "Search the Preview" });
    const filter = choice(IMPORT_FILTERS, "all");
    filter.setAttribute("aria-label", "Show");
    const edit = button("Edit Assignment…", () => assign([...selected].map(byPath).filter(Boolean)));
    const automatic = button("Use Automatic Detection", () => save([...selected].map(byPath).filter(Boolean)
      .map((item) => ({ relativePath: item.relativePath, isDirectory: Boolean(item.isDirectory), kind: null, useAutomaticDetection: true }))));
    const list = h("ul", { class: "import-list", "aria-label": "Files and Folders" });
    const issues = h("details", { class: "import-issues", hidden: true });
    const again = button("Analyze Again", () => {
      if (changed && !confirmDiscard()) return;
      analyze();
    });
    const confirm = button(library.importPreviewRequired ? "Import Recognized Items" : "Apply and Rescan", () => context.run(async () => {
      await api.confirmImportPreview(library.id, summary.previewId, summary.revision, { signal: context.signal });
      changed = false;
      context.clean();
      app.toast(`Importing ${library.name}…`);
      context.dialog.close();
      onDone?.();
    }), "primary-button");

    const byPath = (path) => items.find((item) => item.relativePath === path);
    const confirmDiscard = () => globalThis.confirm?.("Discard the changed assignments and analyze again? The library and the files stay unchanged.") ?? true;

    function updateButtons() {
      edit.disabled = automatic.disabled = selected.size === 0;
      confirm.disabled = !summary || summary.counts.errors !== 0;
    }

    function renderList() {
      clear(list);
      const rows = importPreviewRows(items, { search: search.value, filter: filter.value, assignments });
      if (!rows.length) list.append(h("li", { class: "muted small import-empty" }, items.length ? "Nothing matches." : "No video files found."));
      for (const { item, depth } of rows) {
        const box = h("input", { type: "checkbox", checked: selected.has(item.relativePath), "aria-label": `Select ${item.title}` });
        box.addEventListener("change", () => {
          if (box.checked) selected.add(item.relativePath); else selected.delete(item.relativePath);
          updateButtons();
        });
        const needsLook = item.status === "pending" || item.status === "error";
        list.append(h("li", { class: `import-row${item.isDirectory ? " folder" : ""}`, style: { "--depth": Math.min(depth, 8) }, title: item.reason || null },
          box,
          h("span", { class: `import-glyph ${item.isDirectory ? "folder" : item.kind ?? "unknown"}`, "aria-hidden": "true" }),
          h("span", { class: "import-name" },
            h("span", { class: "import-title" }, item.title || item.relativePath.split("/").pop() || library.name),
            h("span", { class: "muted small import-path" }, item.relativePath || "Storage root")),
          item.seasonNumber != null ? h("span", { class: "import-number" }, `S${item.seasonNumber}`) : null,
          item.episodeNumber != null ? h("span", { class: "import-number" }, `E${item.episodeNumber}`) : null,
          h("span", { class: `import-kind${needsLook ? " attention" : ""}` }, KIND_LABELS[item.kind] ?? STATUS_LABELS[item.status] ?? ""),
          button("Edit", () => assign([item]), "link-button")));
      }
      updateButtons();
    }

    function show(newSummary, loaded) {
      summary = newSummary;
      items = loaded;
      selected.clear();
      const c = summary.counts;
      counts.textContent = [`${c.files} files`, `${c.movies} movies · ${c.series} series · ${c.episodes} episodes`,
        `${c.extras} extras · ${c.trailers} trailers`, `${c.pending} need review`].join("   ");
      counts.className = `import-counts muted small${c.pending > 0 ? " attention" : ""}`;
      clear(issues);
      issues.hidden = !summary.issues?.length;
      if (summary.issues?.length) {
        issues.append(h("summary", {}, `${summary.issues.length} scan warning${summary.issues.length === 1 ? "" : "s"}`),
          h("ul", {}, summary.issues.slice(0, 50).map((issue) => h("li", { class: "muted small" }, issue.message))));
      }
      renderList();
    }

    function analyze() {
      return context.run(async () => {
        counts.textContent = "Reading file names and folders…";
        const analyzed = await api.analyzeImport(library.id, { signal: context.signal });
        const loaded = await loadImportPreview(api, library.id, analyzed, { signal: context.signal });
        assignments = (await api.importAssignments(library.id, { signal: context.signal }))?.assignments ?? [];
        if (!context.alive()) return;
        changed = false;
        show(analyzed, loaded);
      }).then(updateButtons);
    }

    function save(changes) {
      if (!changes.length || !summary) return Promise.resolve();
      return context.run(async () => {
        const updated = await api.updateImportPreview(library.id, summary.previewId, summary.revision, changes, { signal: context.signal });
        const loaded = await loadImportPreview(api, library.id, updated, { signal: context.signal });
        if (!context.alive()) return;
        for (const change of changes) {
          assignments = assignments.filter((rule) => !(rule.relativePath === change.relativePath && rule.isDirectory === change.isDirectory));
          if (!change.useAutomaticDetection) assignments.push(change);
        }
        changed = true;
        context.markChanged();
        show(updated, loaded);
      }).then(updateButtons);
    }

    function assign(chosen) {
      if (!chosen.length || !summary) return;
      const targets = summary.targets ?? [];
      const start = importEditorStart(chosen);
      const kind = choice(importChoicesFor(chosen), start.choice);
      const parent = choice([["", "Choose a movie or series"], ...targets.map((target) => [target.relativePath,
        `${target.title} · ${target.kind === "series" ? "Series" : "Movie"}`])], start.parentPath);
      const entire = h("input", { type: "checkbox", class: "switch", checked: start.entireSeries, "aria-label": "Entire Series" });
      const season = input(start.season, { inputmode: "numeric", "aria-label": "Season Number" });
      const episode = input(start.episode, { inputmode: "numeric", "aria-label": "Episode Number" });
      const category = input(start.category, { placeholder: "Optional", "aria-label": "Category" });
      const title = input(start.title, { "aria-label": "Display Title" });
      const oneFile = chosen.length === 1 && !chosen[0].isDirectory;
      const parentRow = field("Belongs To", parent);
      const entireRow = h("label", { class: "inline-control" }, entire, "Entire Series");
      const seasonRow = field("Season", season);
      const episodeRow = field("Episode", episode);
      const categoryRow = field("Category", category);
      const sheet = editor("Edit Import Assignment", "Save Assignment", async () => {
        const changes = importAssignmentChanges(chosen, { choice: kind.value, parentPath: parent.value, entireSeries: entire.checked,
          season: season.value, episode: episode.value, category: category.value, title: title.value }, targets);
        await save(changes);
      });
      const update = () => {
        const needsParent = ["episode", "extra", "trailer"].includes(kind.value);
        const series = targets.find((target) => target.relativePath === parent.value)?.kind === "series";
        parentRow.hidden = !needsParent;
        entireRow.hidden = !needsParent || !series || kind.value === "episode";
        seasonRow.hidden = !needsParent || !series || (kind.value !== "episode" && entire.checked);
        episodeRow.hidden = kind.value !== "episode";
        categoryRow.hidden = !(needsParent && (kind.value === "extra" || kind.value === "trailer"));
      };
      for (const control of [kind, parent, entire]) control.addEventListener("change", update);
      sheet.body.append(
        h("p", { class: "muted small mono" }, chosen.length === 1 ? chosen[0].relativePath || "Storage root" : `${chosen.length} selected files or folders`),
        field("Import As", kind), parentRow, entireRow, seasonRow, episodeRow, categoryRow,
        oneFile ? field("Display Title", title) : null,
        h("p", { class: "muted small" }, "Folder rules apply to everything inside. A file's own assignment wins. Unnumbered episodes are numbered only with TV Show · Force Import."));
      update();
      sheet.ready();
    }

    // Searching, filtering and selecting change nothing; only saved assignments ask before closing.
    const keepState = () => queueMicrotask(() => (changed ? context.markChanged() : context.clean()));
    context.body.addEventListener("input", keepState);
    context.body.addEventListener("change", keepState);
    search.addEventListener("input", renderList);
    filter.addEventListener("change", renderList);
    context.body.append(
      h("div", { class: "import-head" }, h("div", { class: "settings-card-title" }, library.name), h("div", { class: "muted small mono" }, library.path)),
      counts,
      h("div", { class: "import-controls" }, search, filter, edit, automatic),
      list, issues,
      h("p", { class: "muted small" }, "Nothing is imported until you confirm. Files that still need review stay out; video files are never changed."),
      h("div", { class: "button-row end" }, again, confirm));
    updateButtons();
    analyze();
  }

  return { open };
}
