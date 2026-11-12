// The parts of Edit Metadata beyond text: poster and background with their crop, Cast and Crew,
// the title's video file, its downloaded subtitles and removing the title. Pictures are uploaded
// to the server's editor drafts; the crop is saved with the rest of the form.

import { h, clear } from "./dom.js";
import { cropFrame, speechJobRunning, speechJobText, SPEECH_FEATURE } from "./logic.js";

const PICTURES = [
  { key: "poster", label: "Poster", aspect: 2 / 3 },
  { key: "backdrop", label: "Background", aspect: 16 / 9 },
];
const DEPARTMENTS = ["Acting", "Directing", "Writing", "Production", "Camera", "Editing", "Sound", "Art", "Crew"];
const LANGUAGES = [["en", "English"], ["de", "German"], ["fr", "French"], ["es", "Spanish"], ["it", "Italian"], ["nl", "Dutch"],
  ["pt", "Portuguese"], ["pl", "Polish"], ["sv", "Swedish"], ["da", "Danish"], ["tr", "Turkish"], ["ja", "Japanese"]];

/** Where a picture choice can be seen: a new upload or a picture the title already has. */
export function pictureAddress(mediaId, selection) {
  const id = encodeURIComponent(mediaId);
  if (selection?.uploadId) return `/api/v1/media/${id}/editor/uploads/${encodeURIComponent(selection.uploadId)}`;
  if (selection?.assetId) return `/api/v1/media/${id}/editor/artwork/${encodeURIComponent(selection.assetId)}`;
  return "";
}

/** The CSS background size and position that show exactly `crop` of a picture. */
export function cropStyle(crop) {
  if (!crop) return { "background-size": "cover", "background-position": "center" };
  const size = (part) => `${(100 / part).toFixed(3)}%`;
  const position = (start, part) => (part >= 1 ? "0%" : `${((start / (1 - part)) * 100).toFixed(3)}%`);
  return { "background-size": `${size(crop.width)} ${size(crop.height)}`, "background-position": `${position(crop.x, crop.width)} ${position(crop.y, crop.height)}` };
}

export function createMetadataExtras({ api, app, kit }) {
  const { button, input, field, choice } = kit;

  /**
   * The picture, cast, file, subtitle and removal sections for one open editor. `state` holds the
   * form's `changes` and `automatic` sets; `changed()` re-validates after an edit.
   */
  function sections({ item, document, context, changes, automatic, extras, changed }) {
    return {
      artwork: artworkSection(item, document, context, changes, automatic, changed),
      credits: creditsSection(document, changes, automatic, changed),
      source: sourceSection(item, document, context, extras, changed),
      subtitles: subtitlesSection(item, context),
      removal: removeSection(item, context),
    };
  }

  function block(title, ...content) {
    return h("section", { class: "editor-section settings-section metadata-section" }, h("h3", {}, title), ...content);
  }

  // MARK: Pictures

  function artworkSection(item, document, context, changes, automatic, changed) {
    const grid = h("div", { class: "metadata-artwork-grid" });
    const draw = () => {
      clear(grid);
      for (const picture of PICTURES) {
        const selection = changes[picture.key] ?? document.values[picture.key];
        const address = pictureAddress(item.id, selection);
        const preview = h("div", { class: `artwork-crop-preview ${picture.key}`, role: "img", "aria-label": picture.label });
        if (address) {
          preview.style.setProperty("background-image", `url("${address}")`);
          for (const [property, value] of Object.entries(cropStyle(selection?.crop))) preview.style.setProperty(property, value);
        } else preview.append(h("span", { class: "muted small" }, `No ${picture.label.toLowerCase()}`));
        const file = h("input", { type: "file", accept: "image/png,image/jpeg,image/webp,image/heic", class: "visually-hidden", "aria-label": `Choose ${picture.label}` });
        file.addEventListener("change", () => {
          const chosen = file.files?.[0];
          file.value = "";
          if (!chosen) return;
          context.run(async () => {
            const upload = await api.uploadEditorImage(item.id, chosen, { signal: context.signal });
            const draft = { uploadId: upload.id };
            const crop = await cropPicture(pictureAddress(item.id, draft), picture, null);
            if (!crop) return api.discardEditorImage(item.id, upload.id).catch(() => {});
            changes[picture.key] = { ...draft, crop };
            automatic.delete(picture.key);
            changed();
            draw();
          });
        });
        grid.append(h("div", { class: "artwork-choice" },
          h("h4", {}, picture.label), preview,
          h("div", { class: "button-row" },
            button("Choose Image…", () => file.click()),
            address ? button("Crop…", async () => {
              const crop = await cropPicture(address, picture, selection?.crop ?? null);
              if (!crop) return;
              changes[picture.key] = { ...(selection.uploadId ? { uploadId: selection.uploadId } : { assetId: selection.assetId }), crop };
              automatic.delete(picture.key);
              changed();
              draw();
            }) : null,
            button("Automatic", () => {
              delete changes[picture.key];
              automatic.add(picture.key);
              document.values[picture.key] = document.automaticValues[picture.key] ?? null;
              changed();
              draw();
            })),
          file));
      }
    };
    draw();
    return block("Artwork", h("p", { class: "muted small" }, "Upload a picture from this computer or crop the current one. The original file stays untouched."), grid);
  }

  /**
   * Shows the picture with a frame in the shape of a poster or background that can be moved and
   * zoomed. Resolves with the crop in 0…1, or null when cancelled.
   */
  function cropPicture(address, picture, startCrop) {
    return new Promise((resolve) => {
      const image = h("img", { class: "crop-image", src: address, alt: "", draggable: "false" });
      const frame = h("div", { class: "crop-frame", "aria-hidden": "true" });
      const stage = h("div", { class: "crop-stage" }, image, frame);
      const zoom = h("input", { type: "range", min: "1", max: "4", step: "0.01", value: "1", "aria-label": "Zoom" });
      let result = null;
      let state = { zoom: 1, centerX: 0.5, centerY: 0.5 };
      if (startCrop) state = { zoom: 1, centerX: startCrop.x + startCrop.width / 2, centerY: startCrop.y + startCrop.height / 2 };
      const place = () => {
        if (!image.naturalWidth) return;
        const crop = cropFrame({ imageWidth: image.naturalWidth, imageHeight: image.naturalHeight, aspect: picture.aspect, ...state });
        state.centerX = crop.x + crop.width / 2;
        state.centerY = crop.y + crop.height / 2;
        Object.assign(frame.style, { left: `${crop.x * 100}%`, top: `${crop.y * 100}%`, width: `${crop.width * 100}%`, height: `${crop.height * 100}%` });
        result = crop;
      };
      image.addEventListener("load", () => {
        if (startCrop) {
          const full = cropFrame({ imageWidth: image.naturalWidth, imageHeight: image.naturalHeight, aspect: picture.aspect });
          state.zoom = Math.min(4, Math.max(1, full.width / startCrop.width));
          zoom.value = String(state.zoom);
        }
        place();
      }, { once: true });
      zoom.addEventListener("input", () => { state.zoom = Number(zoom.value); place(); });
      let drag = null;
      frame.addEventListener("pointerdown", (event) => {
        drag = { x: event.clientX, y: event.clientY, centerX: state.centerX, centerY: state.centerY };
        frame.setPointerCapture?.(event.pointerId);
      });
      frame.addEventListener("pointermove", (event) => {
        if (!drag) return;
        const box = stage.getBoundingClientRect();
        state.centerX = drag.centerX + (event.clientX - drag.x) / box.width;
        state.centerY = drag.centerY + (event.clientY - drag.y) / box.height;
        place();
      });
      const end = () => { drag = null; };
      frame.addEventListener("pointerup", end);
      frame.addEventListener("pointercancel", end);
      const sheet = h("dialog", { class: "sheet crop-sheet", "aria-label": `Crop ${picture.label}` },
        h("h2", {}, `Crop ${picture.label}`),
        h("p", { class: "muted small" }, "Drag the frame and zoom until it shows the part you want."),
        stage, field("Zoom", zoom),
        h("div", { class: "button-row end" },
          button("Cancel", () => { result = null; sheet.close(); }),
          button("Use Crop", () => sheet.close(), "primary-button")));
      sheet.addEventListener("cancel", () => { result = null; });
      sheet.addEventListener("close", () => { sheet.remove(); resolve(result); }, { once: true });
      document.body.append(sheet);
      sheet.showModal();
      if (image.complete && image.naturalWidth) image.dispatchEvent(new Event("load"));
    });
  }

  // MARK: Cast and Crew

  function creditsSection(document, changes, automatic, changed) {
    const people = h("ol", { class: "credit-editor" });
    let list = structuredClone(changes.credits ?? document.values.credits ?? []);
    const commit = () => {
      changes.credits = list;
      automatic.delete("credits");
      changed();
    };
    const draw = () => {
      clear(people);
      list.forEach((person, index) => {
        const name = input(person.name, { maxlength: 256, "aria-label": "Name" });
        const department = choice(DEPARTMENTS.includes(person.department) ? DEPARTMENTS.map((value) => [value, value]) : [[person.department, person.department], ...DEPARTMENTS.map((value) => [value, value])], person.department || "Acting");
        const role = input(person.department === "Acting" ? person.character ?? "" : person.job ?? "", { maxlength: 256, "aria-label": "Role", placeholder: person.department === "Acting" ? "Character" : "Job" });
        name.addEventListener("input", () => { person.name = name.value; commit(); });
        department.addEventListener("change", () => {
          person.department = department.value;
          role.placeholder = person.department === "Acting" ? "Character" : "Job";
          commit();
        });
        role.addEventListener("input", () => {
          if (person.department === "Acting") person.character = role.value; else person.job = role.value;
          commit();
        });
        const move = (offset) => {
          const target = index + offset;
          if (target < 0 || target >= list.length) return;
          [list[index], list[target]] = [list[target], list[index]];
          commit();
          draw();
        };
        people.append(h("li", { class: "credit-row" }, name, department, role,
          h("div", { class: "credit-actions" },
            h("button", { type: "button", class: "icon-button", "aria-label": `Move ${person.name || "person"} up`, disabled: index === 0, onclick: () => move(-1) }, "↑"),
            h("button", { type: "button", class: "icon-button", "aria-label": `Move ${person.name || "person"} down`, disabled: index === list.length - 1, onclick: () => move(1) }, "↓"),
            h("button", { type: "button", class: "icon-button danger", "aria-label": `Remove ${person.name || "person"}`, onclick: () => { list.splice(index, 1); commit(); draw(); } }, "✕"))));
      });
      if (!list.length) people.append(h("li", { class: "muted small" }, "No cast or crew listed."));
    };
    draw();
    return block("Cast and Crew",
      h("p", { class: "muted small" }, "The order here is the order on the title’s page."),
      people,
      h("div", { class: "button-row" },
        button("Add Person", () => { list.push({ id: crypto.randomUUID(), name: "", department: "Acting", job: null, character: null, profile: null }); commit(); draw(); }),
        button("Automatic", () => {
          delete changes.credits;
          automatic.add("credits");
          list = structuredClone(document.automaticValues.credits ?? []);
          changed();
          draw();
        })));
  }

  // MARK: Video file

  function sourceSection(item, document, context, extras, changed) {
    const current = h("p", { class: "metadata-source mono" }, document.relativeSourcePath || document.sourcePath || "No file");
    const movable = document.kind === "movie" || document.kind === "episode";
    return block("Video File",
      h("p", { class: "muted small" }, "The file this title plays. Choosing another file only changes which file belongs to the title; no file is moved or changed."),
      current,
      movable ? h("div", { class: "button-row" }, button("Choose Another File…", () => chooseFile(item, document.relativeSourcePath, (path) => {
        extras.relativeSourcePath = path;
        current.textContent = `${path} (after saving)`;
        changed();
      }))) : null);
  }

  function chooseFile(item, currentPath, onPick) {
    const list = h("ul", { class: "folder-list" });
    const where = h("p", { class: "muted small mono" });
    const sheet = h("dialog", { class: "sheet settings-editor", "aria-label": "Choose a Video File" },
      h("h2", {}, "Choose a Video File"), where, list,
      h("div", { class: "button-row end" }, button("Cancel", () => sheet.close())));
    const open = async (path) => {
      try {
        const listing = await api.editorFiles(item.id, path);
        clear(list);
        where.textContent = listing.relativePath || "The storage location’s top folder";
        if (listing.relativePath) {
          const parent = listing.relativePath.split(/[\\/]/).slice(0, -1).join("/");
          list.append(h("li", {}, h("button", { type: "button", class: "folder-entry up", onclick: () => open(parent) }, "↑ Up one folder")));
        }
        for (const entry of listing.entries ?? []) list.append(h("li", {}, h("button", {
          type: "button", class: "folder-entry", onclick: () => {
            if (entry.isDirectory) return open(entry.relativePath);
            onPick(entry.relativePath);
            sheet.close();
          },
        }, h("span", { class: entry.isDirectory ? "folder-icon" : "file-icon", "aria-hidden": "true" }), entry.name)));
        if (!listing.entries?.length) list.append(h("li", { class: "muted small" }, "Empty folder."));
      } catch (error) {
        if (!app.handleError(error)) where.textContent = error.message;
      }
    };
    sheet.addEventListener("close", () => sheet.remove(), { once: true });
    document.body.append(sheet);
    sheet.showModal();
    const start = (currentPath ?? "").split(/[\\/]/).slice(0, -1).join("/");
    open(start);
  }

  // MARK: Subtitles

  function subtitlesSection(item, context) {
    if (item.kind !== "movie" && item.kind !== "episode") return null;
    const saved = h("div", { class: "settings-card-list" });
    const found = h("div", { class: "settings-card-list" });
    const language = choice(LANGUAGES, (navigator.language ?? "en").slice(0, 2));
    const load = async () => {
      const subtitles = await api.downloadedSubtitles(item.id, { signal: context.signal });
      if (!context.alive()) return;
      clear(saved);
      if (!subtitles?.length) saved.append(h("p", { class: "muted small" }, "No downloaded or speech-made subtitles."));
      for (const subtitle of subtitles ?? []) saved.append(h("div", { class: "settings-card" },
        h("div", { class: "settings-card-main" }, h("div", { class: "settings-card-title" }, subtitle.title),
          h("div", { class: "muted small" }, [subtitle.provider, subtitle.hearingImpaired ? "for the hard of hearing" : null, subtitle.forced ? "forced" : null].filter(Boolean).join(" · "))),
        h("div", { class: "settings-card-actions" }, button("Remove", () => context.run(async () => {
          await api.removeSubtitle(item.id, subtitle.id);
          await load();
        }), "secondary-button danger"))));
    };
    const search = () => context.run(async () => {
      const candidates = await api.searchSubtitles(item.id, language.value, { signal: context.signal });
      if (!context.alive()) return;
      clear(found);
      if (!candidates?.length) found.append(h("p", { class: "muted small" }, "OpenSubtitles has nothing in this language for this title."));
      for (const candidate of (candidates ?? []).slice(0, 12)) found.append(h("div", { class: "settings-card" },
        h("div", { class: "settings-card-main" }, h("div", { class: "settings-card-title" }, candidate.release || "Subtitles"),
          h("div", { class: "muted small" }, [candidate.hashMatch ? "Made for this exact file" : null, candidate.hearingImpaired ? "for the hard of hearing" : null,
            candidate.foreignPartsOnly ? "foreign parts only" : null].filter(Boolean).join(" · ") || "Language match")),
        h("div", { class: "settings-card-actions" }, button("Download", () => context.run(async () => {
          await api.downloadSubtitle(item.id, { fileId: candidate.fileId, language: candidate.language, release: candidate.release ?? null,
            hearingImpaired: Boolean(candidate.hearingImpaired), foreignPartsOnly: Boolean(candidate.foreignPartsOnly) });
          app.toast("Subtitles downloaded. They appear in the subtitle menu on every device.");
          clear(found);
          await load();
        }), "primary-button"))));
    });
    context.run(load);
    const speech = app.state?.server?.capabilities?.includes(SPEECH_FEATURE) ? speechPart(item, context, load) : null;
    return block("Subtitles",
      saved,
      h("div", { class: "editor-path-row" }, field("Find on OpenSubtitles", language), button("Search", search)),
      found,
      h("p", { class: "muted small" }, speech ? "Needs an OpenSubtitles key in Settings › Metadata." : "Needs an OpenSubtitles key in Settings › Metadata. Subtitles from speech are made by Aurelia for Mac."),
      speech);
  }

  /**
   * Subtitles from Speech on the server: it listens to the title in the background with
   * whisper.cpp and saves subtitles in the spoken language, or moves existing subtitles onto the
   * speech as a synced copy. The page follows the job while it runs and can stop it.
   */
  function speechPart(item, context, reloadSubtitles) {
    const area = h("div", { class: "speech-part" }, h("p", { class: "muted small" }, "Checking the server’s speech recognition…"));
    const spoken = choice(LANGUAGES, (navigator.language ?? "en").slice(0, 2));
    const tracks = h("select", { class: "select", "aria-label": "Subtitles to sync" });
    let timer = null;
    const show = (state) => {
      clear(area);
      area.append(h("h4", {}, "Subtitles from Speech"));
      if (!state.available) {
        area.append(h("p", { class: "muted small" }, "The server needs whisper.cpp to listen (on Debian or Ubuntu: sudo apt install whisper.cpp). Aurelia for Mac can still write subtitles itself."));
        return;
      }
      if (!state.modelReady) {
        area.append(h("p", { class: "muted small" }, "Download a speech model first: Settings › Server › Speech Recognition."));
        return;
      }
      const job = state.job;
      if (speechJobRunning(job)) {
        area.append(h("progress", { class: "segments-progress", max: "1", value: String(job.progress ?? 0) }),
          h("p", { class: "muted small", role: "status" }, speechJobText(job)),
          button("Stop", () => context.run(async () => { await api.cancelSpeech(item.id); show(await api.mediaSpeech(item.id)); }), "secondary-button"));
        clearTimeout(timer);
        timer = setTimeout(async () => {
          if (!context.alive()) return;
          const next = await api.mediaSpeech(item.id).catch(() => null);
          if (!next || !context.alive()) return;
          if (!speechJobRunning(next.job)) await reloadSubtitles();
          show(next);
        }, 2000);
        return;
      }
      if (job) area.append(h("p", { class: job.state === "failed" ? "error-text small" : "muted small", role: "status" }, speechJobText(job)));
      area.append(
        h("p", { class: "muted small" }, "The server listens to the title in the background and keeps only the finished subtitles. This window can be closed meanwhile."),
        h("div", { class: "editor-path-row" }, field("Spoken Language", spoken),
          button("Create Subtitles from Speech", () => context.run(async () => show(await api.startSpeech(item.id, { kind: "create", language: spoken.value }))), "primary-button")),
        h("div", { class: "editor-path-row" }, field("Subtitles to Sync", tracks),
          button("Sync to Speech", () => context.run(async () => {
            const index = Number(tracks.value);
            const track = [...tracks.options].find((option) => Number(option.value) === index);
            show(await api.startSpeech(item.id, { kind: "sync", language: track?.dataset.language || spoken.value, subtitleIndex: index }));
          }))),
        h("p", { class: "muted small" }, "Syncing moves the chosen subtitles so they appear when the words are said, also when they were made for another frame rate or cut. The result is saved as a synced copy; the original stays."));
    };
    const loadTracks = async () => {
      const ticket = await api.createPlayback(item.id);
      try {
        const list = (await api.streamSubtitles(ticket.id)) ?? [];
        clear(tracks);
        for (const track of list.filter((entry) => entry.supported)) {
          const option = h("option", { value: String(track.index) }, [track.title || track.language || "Subtitles", track.language].filter(Boolean).join(" · "));
          option.dataset.language = (track.language ?? "").slice(0, 2);
          tracks.append(option);
        }
        if (!tracks.options.length) tracks.append(h("option", { value: "", disabled: true }, "No subtitles to sync"));
      } finally {
        api.revokePlayback(ticket.id).catch(() => {});
      }
    };
    context.run(async () => {
      const state = await api.mediaSpeech(item.id, { signal: context.signal });
      if (!context.alive()) return;
      show(state);
      if (state.available && state.modelReady) await loadTracks().catch(() => {});
    });
    return area;
  }

  // MARK: Removing

  function removeSection(item, context) {
    const area = h("div", {});
    const ask = button("Remove from Library…", () => {
      clear(area);
      area.append(h("p", {}, `Remove “${item.title}” from Aurelia? Its details, progress and artwork go away and later scans skip its file. The video file itself stays on the disk.`),
        h("div", { class: "button-row" },
          button("Keep It", () => { clear(area); area.append(ask); }),
          button("Remove from Library", () => context.run(async () => {
            await api.removeTitle(item.id);
            app.toast(`“${item.title}” was removed. Settings › Library › Left Out can bring it back.`);
            context.dialog.close();
            app.navigate({ name: "home" });
          }, { cancellable: false }), "danger-button")));
    }, "secondary-button danger");
    area.append(ask);
    return h("section", { class: "editor-section settings-section metadata-section danger-zone" }, h("h3", {}, "Remove Title"), area);
  }

  return { sections, cropPicture };
}
