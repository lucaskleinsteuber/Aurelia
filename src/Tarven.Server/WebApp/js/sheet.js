// Sheets in the Mac's TarvenSheet form (audit D7): a symbol tile, a title and a sentence, the
// content between separators, and a footer with Cancel (Esc) and the main button (Return). An
// error shows as a banner inside the sheet, not as a passing toast (audit D8).

import { h, icon } from "./dom.js";

/**
 * Opens a sheet. `onPrimary` may be async; while it runs the buttons wait, and an error it throws
 * shows in the sheet. It returns false to keep the sheet open. `confirmClose` may answer false
 * (or a promise of false) to keep a sheet with unsaved changes open on Esc or Cancel (audit S19).
 */
export function openSheet({
  symbol = "info", title, subtitle, body = [], primary = "Done", primaryKind = "primary-button", onPrimary,
  cancel = "Cancel", wide = false, danger = false, confirmClose, onClose, label,
} = {}) {
  const banner = h("div", { class: "error-banner", role: "alert", hidden: true }, icon("warning", { size: 16 }), h("span"));
  const primaryButton = primary ? h("button", { type: "submit", class: primaryKind }, primary) : null;
  const cancelButton = cancel ? h("button", { type: "button", class: "secondary-button" }, cancel) : null;
  const content = h("div", { class: "sheet-body" }, banner, body);
  const form = h("form", { method: "dialog" },
    h("div", { class: "sheet-head" },
      h("span", { class: `sheet-symbol${danger ? " danger" : ""}`, "aria-hidden": "true" }, icon(symbol, { size: 20 })),
      h("div", {}, h("h2", { id: undefined }, title), subtitle ? h("p", { class: "muted" }, subtitle) : null)),
    content,
    h("div", { class: "sheet-foot" }, cancelButton, primaryButton));
  const dialog = h("dialog", { class: `sheet app-sheet${wide ? " wide" : ""}`, "aria-label": label ?? title }, form);
  let busy = false;
  let closed = false;

  const setError = (text) => {
    banner.hidden = !text;
    banner.querySelector("span").textContent = text ?? "";
    if (text) banner.scrollIntoView?.({ block: "nearest" });
  };
  const setBusy = (value) => {
    busy = value;
    if (primaryButton) primaryButton.disabled = value;
    if (cancelButton) cancelButton.disabled = value;
  };
  const close = () => {
    if (closed) return;
    closed = true;
    globalThis.removeEventListener?.("tarven:page", close);
    if (dialog.open) dialog.close();
    dialog.remove();
    onClose?.();
  };
  const tryClose = async () => {
    if (busy) return;
    if (confirmClose && (await confirmClose()) === false) return;
    close();
  };

  const runPrimary = async () => {
    if (busy || !primaryButton) return;
    if (!onPrimary) return close();
    setError("");
    setBusy(true);
    try {
      const keep = await onPrimary({ setError, close });
      if (keep !== false) close();
    } catch (error) {
      setError(error?.message ?? "Something went wrong. Try again.");
    } finally {
      if (!closed) setBusy(false);
    }
  };
  // Return submits the form; a click runs the same, without the browser's own submission.
  form.addEventListener("submit", (event) => { event.preventDefault(); runPrimary(); });
  primaryButton?.addEventListener("click", (event) => { event.preventDefault(); runPrimary(); });
  cancelButton?.addEventListener("click", () => tryClose());
  // Esc is the dialog's cancel; it asks first when changes would be lost.
  dialog.addEventListener("cancel", (event) => {
    event.preventDefault();
    tryClose();
  });
  // Return inside a multi-line field writes a new line; elsewhere it is the main button.
  form.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && event.target instanceof HTMLTextAreaElement) event.stopPropagation();
  });
  // A page that changes underneath closes the sheet with it (audit S19).
  dialog.addEventListener("close", close, { once: true });
  globalThis.addEventListener?.("tarven:page", close, { once: true });

  document.body.append(dialog);
  dialog.showModal();
  (content.querySelector("input, select, textarea") ?? primaryButton ?? cancelButton)?.focus();
  return { dialog, close, setError, setBusy, body: content };
}

/** Asks before something that can't be undone. Resolves true when confirmed. */
export function confirmSheet({ symbol = "warning", title, message, confirm = "Continue", danger = true, work } = {}) {
  return new Promise((resolve) => {
    let answered = false;
    openSheet({
      symbol, title, subtitle: message, danger,
      primary: confirm, primaryKind: danger ? "danger-button" : "primary-button",
      onPrimary: async () => {
        if (work) await work();
        answered = true;
        resolve(true);
      },
      onClose: () => { if (!answered) resolve(false); },
    });
  });
}
