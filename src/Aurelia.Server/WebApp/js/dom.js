// A tiny element builder. Text always goes in as text, never as HTML, so titles and names
// from the library cannot inject markup.

export function h(tag, attributes = {}, ...children) {
  const element = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes ?? {})) {
    if (value == null || value === false) continue;
    if (key === "class") element.className = value;
    else if (key === "dataset") Object.assign(element.dataset, value);
    else if (key.startsWith("on") && typeof value === "function") element.addEventListener(key.slice(2), value);
    // Style keys may be written as in CSS ("min-width", "--fill") or as in scripts ("minWidth");
    // setProperty knows only the first, and silently dropped the others (audit L2).
    else if (key === "style") for (const [name, styleValue] of Object.entries(value)) element.style.setProperty(cssName(name), styleValue);
    else if (value === true) element.setAttribute(key, "");
    else element.setAttribute(key, String(value));
  }
  append(element, children);
  return element;
}

/** "minWidth" → "min-width"; CSS names and custom properties stay as they are. */
export function cssName(name) {
  return name.startsWith("--") || name.includes("-") ? name : name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`);
}

function append(element, children) {
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false) continue;
    element.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
}

const SVG = "http://www.w3.org/2000/svg";

// Outline icons drawn on a 24-point grid, in the spirit of SF Symbols.
const PATHS = {
  pencil: ["M4 16.5V20h3.5L19 8.5 15.5 5zM14 6.5l3.5 3.5", "stroke"],
  eye: ["M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6", "stroke"],
  hide: ["M3 3l18 18M9.5 5.3A12 12 0 0 1 12 5c6.5 0 10 7 10 7a18 18 0 0 1-3.5 4.5M6.5 6.5A19 19 0 0 0 2 12s3.5 7 10 7a13 13 0 0 0 5.5-1.5", "stroke"],
  play: ["M8 5.5v13a1 1 0 0 0 1.5.86l10.4-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z", "fill"],
  pause: ["M7 5h3.2v14H7zM13.8 5H17v14h-3.2z", "fill"],
  back: ["M15 5l-7 7 7 7", "stroke"],
  forward: ["M9 5l7 7-7 7", "stroke"],
  arrow: ["M5 12h14M13 6l6 6-6 6", "stroke"],
  close: ["M6 6l12 12M18 6L6 18", "stroke"],
  heart: ["M12 20s-7.5-4.6-7.5-10.2A4.3 4.3 0 0 1 12 7.4a4.3 4.3 0 0 1 7.5 2.4C19.5 15.4 12 20 12 20z", "stroke"],
  heartFill: ["M12 20s-7.5-4.6-7.5-10.2A4.3 4.3 0 0 1 12 7.4a4.3 4.3 0 0 1 7.5 2.4C19.5 15.4 12 20 12 20z", "fill"],
  circle: ["M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18", "stroke"],
  check: ["M5 12.5l4.5 4.5L19 7.5", "stroke"],
  checkCircle: ["M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM8 12.3l2.8 2.8L16.2 9.6", "stroke"],
  search: ["M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM15.5 15.5L20 20", "stroke"],
  replay10: ["M12 5a7 7 0 1 1-6.6 4.7M12 5V2L8 5l4 3V5", "stroke"],
  skip10: ["M12 5a7 7 0 1 0 6.6 4.7M12 5V2l4 3-4 3V5", "stroke"],
  volume: ["M4 9.5h3.5L12 6v12l-4.5-3.5H4zM15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11", "stroke"],
  mute: ["M4 9.5h3.5L12 6v12l-4.5-3.5H4zM16 9.5l5 5M21 9.5l-5 5", "stroke"],
  fullscreen: ["M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5", "stroke"],
  exitFullscreen: ["M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5", "stroke"],
  pip: ["M3.5 5.5h17v13h-17zM12.5 12h6v4.5h-6z", "stroke"],
  audio: ["M4 10v4M8 7v10M12 4v16M16 8v8M20 10.5v3", "stroke"],
  captions: ["M3.5 5.5h17v13h-17zM10.5 10.2a2.4 2.4 0 1 0 0 3.6M17 10.2a2.4 2.4 0 1 0 0 3.6", "stroke"],
  delete: ["M9 6h11v12H9l-6-6zM12 9.5l5 5M17 9.5l-5 5", "stroke"],
  lock: ["M7 11V8a5 5 0 0 1 10 0v3M5.5 11h13v9h-13z", "stroke"],
  more: ["M6 12h.01M12 12h.01M18 12h.01", "dots"],
  warning: ["M12 4l9 16H3zM12 10v4.5M12 17.5h.01", "stroke"],
  power: ["M12 3v8M7 6.5a7 7 0 1 0 10 0", "stroke"],
  moon: ["M19 14.5A7.5 7.5 0 1 1 9.5 5a6 6 0 0 0 9.5 9.5zM16 3.5h3l-3 3h3", "stroke"],
  moonFill: ["M19 14.5A7.5 7.5 0 1 1 9.5 5a6 6 0 0 0 9.5 9.5z", "fill"],
  bookmark: ["M7 4h10v16l-5-3.6L7 20z", "stroke"],
  bookmarkFill: ["M7 4h10v16l-5-3.6L7 20z", "fill"],
  captionsFill: ["M3.5 5.5h17v13h-17zM10.5 10.2a2.4 2.4 0 1 0 0 3.6M17 10.2a2.4 2.4 0 1 0 0 3.6", "fill"],
  previous: ["M5 5h2v14H5zM18 5v14l-10-7z", "fill"],
  next: ["M17 5h2v14h-2zM6 5l10 7-10 7z", "fill"],
  plus: ["M12 5v14M5 12h14", "stroke"],
  chapters: ["M4 6h16M4 12h16M4 18h10", "stroke"],
  library: ["M4 5h4v14H4zM10 5h4v14h-4zM16.5 5.5l3.6.9-3.3 13.2-3.6-.9z", "stroke"],
  gear: ["M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM19.4 13a7.6 7.6 0 0 0 0-2l2-1.5-2-3.4-2.3 1a7.4 7.4 0 0 0-1.7-1L15 3.6h-4l-.4 2.5a7.4 7.4 0 0 0-1.7 1l-2.3-1-2 3.4 2 1.5a7.6 7.6 0 0 0 0 2l-2 1.5 2 3.4 2.3-1a7.4 7.4 0 0 0 1.7 1l.4 2.5h4l.4-2.5a7.4 7.4 0 0 0 1.7-1l2.3 1 2-3.4z", "stroke"],
  chevronDown: ["M7 10l5 5 5-5", "stroke"],
  chevronUpDown: ["M8 9l4-4 4 4M8 15l4 4 4-4", "stroke"],
  starSlash: ["M3 3l18 18M8 8l-3.4.6 4 3.7L7.5 18l4.5-2.6 4.5 2.6-.9-4.4M11 6l1-2 2.4 5 5.4.6-2.8 2.6", "stroke"],
  tv: ["M3 7h18v13H3zM8 3l4 4 4-4", "stroke"],
  star: ["M12 4l2.4 5 5.4.6-4 3.7 1.1 5.4L12 16l-4.9 2.7 1.1-5.4-4-3.7 5.4-.6z", "stroke"],
  starFill: ["M12 4l2.4 5 5.4.6-4 3.7 1.1 5.4L12 16l-4.9 2.7 1.1-5.4-4-3.7 5.4-.6z", "fill"],
  people: ["M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20c.4-3.6 3.1-5.8 6.5-5.8s6.1 2.2 6.5 5.8M16.5 11a3 3 0 1 0 0-6M17.5 14.4c2.3.4 3.8 2.3 4 5.6", "stroke"],
  airplay: ["M5 17H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-1M12 15l5 6H7l5-6z", "stroke"],
  arrowUp: ["M12 19V5M6 11l6-6 6 6", "stroke"],
  arrowDown: ["M12 5v14M6 13l6 6 6-6", "stroke"],
  collections: ["M5 7h14v13H5zM7 4h10M9 20V7", "stroke"],
  home: ["M4 11.5L12 4.5l8 7M6.5 9.5V20h11V9.5M10 20v-5.5h4V20", "stroke"],
  film: ["M4 5h16v14H4zM8 5v14M16 5v14M4 9.5h4M4 14.5h4M16 9.5h4M16 14.5h4", "stroke"],
  clock: ["M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7.5V12l3 2", "stroke"],
  history: ["M4.5 12a7.5 7.5 0 1 0 2.2-5.3M4.5 4.5v3.7h3.7M12 8v4l3 2", "stroke"],
  chart: ["M5 20v-8M11 20V5M17 20v-6M3 20h18", "stroke"],
  gift: ["M4.5 10.5h15V20h-15zM3.5 7h17v3.5h-17zM12 7v13M12 7c-1.2-3-5.5-3.4-5 0M12 7c1.2-3 5.5-3.4 5 0", "stroke"],
  sidebar: ["M3.5 5h17v14h-17zM9.5 5v14M5.5 8.5h2M5.5 11.5h2", "stroke"],
  trash: ["M5 7h14M10 7V4.5h4V7M7 7l.9 13h8.2L17 7M10.3 11v5.5M13.7 11v5.5", "stroke"],
  folder: ["M3.5 6.5h6l2 2h9v10.5h-17z", "stroke"],
  minus: ["M5 12h14", "stroke"],
  info: ["M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v5.5M12 7.8h.01", "stroke"],
  refresh: ["M19.5 12a7.5 7.5 0 1 1-2.2-5.3M19.5 4.5v3.7h-3.7", "stroke"],
  cards: ["M4 7.8l8.5-2.3 3 11.1-8.5 2.3zM14.2 5.6l5.5 1.5-2.6 9.6", "stroke"],
};

export function icon(name, { size = 20, label } = {}) {
  const [path, style] = PATHS[name] ?? PATHS.more;
  // A document without SVG (the logic tests' small DOM) gets an empty placeholder.
  if (typeof document.createElementNS !== "function") return h("span", { class: "icon", "aria-hidden": label ? null : "true", "aria-label": label ?? null });
  const svg = document.createElementNS(SVG, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", String(size));
  svg.setAttribute("height", String(size));
  svg.setAttribute("class", "icon");
  if (label) {
    svg.setAttribute("role", "img");
    svg.setAttribute("aria-label", label);
  } else {
    svg.setAttribute("aria-hidden", "true");
  }
  const shape = document.createElementNS(SVG, "path");
  shape.setAttribute("d", path);
  if (style === "fill") {
    shape.setAttribute("fill", "currentColor");
  } else {
    shape.setAttribute("fill", "none");
    shape.setAttribute("stroke", "currentColor");
    shape.setAttribute("stroke-width", style === "dots" ? "3" : "2");
    shape.setAttribute("stroke-linecap", "round");
    shape.setAttribute("stroke-linejoin", "round");
  }
  svg.append(shape);
  return svg;
}

export function clear(element) {
  while (element.firstChild) element.firstChild.remove();
}

let activePopupMenuClose = null;

/** Closes the currently open popup menu and removes its document listeners. */
export function closePopupMenu() {
  activePopupMenuClose?.();
}

/**
 * Opens a positioned popup menu anchored to `anchor`. Replaces any previous popup menu cleanly,
 * supports ArrowDown/ArrowUp/Home/End navigation and Escape (returning focus to `anchor`), and
 * closes on outside/item click or page navigation.
 */
export function openPopupMenu(anchor, items) {
  closePopupMenu();
  const menu = h("div", { class: "popup-menu profile-menu", role: "menu" }, items);
  for (const entry of menu.querySelectorAll("button")) {
    if (!entry.getAttribute("role")) entry.setAttribute("role", "menuitem");
  }
  const box = anchor.getBoundingClientRect?.() ?? { left: 0, bottom: 0 };
  const scrollX = globalThis.window?.scrollX ?? 0;
  const scrollY = globalThis.window?.scrollY ?? 0;
  const clientWidth = document.documentElement?.clientWidth ?? 1024;
  menu.style.setProperty("top", `${box.bottom + scrollY + 8}px`);
  menu.style.setProperty("left", `${Math.max(12, Math.min(box.left + scrollX, scrollX + clientWidth - 260))}px`);
  document.body.append(menu);

  let closed = false;
  let attachTimer = null;
  const enabledItems = () => [...menu.querySelectorAll("button")].filter((entry) => !entry.disabled);

  const close = () => {
    if (closed) return;
    closed = true;
    if (attachTimer !== null) {
      clearTimeout(attachTimer);
      attachTimer = null;
    }
    if (activePopupMenuClose === close) activePopupMenuClose = null;
    menu.remove();
    document.removeEventListener?.("click", close);
    document.removeEventListener?.("keydown", onKey, true);
    globalThis.removeEventListener?.("aurelia:page", close);
  };

  // Esc and menu navigation keys are handled before player or page shortcuts (audit X9).
  const onKey = (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      close();
      anchor.focus?.();
      return;
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp" || event.key === "Home" || event.key === "End") {
      const entries = enabledItems();
      if (!entries.length) return;
      event.preventDefault();
      event.stopPropagation();
      if (event.key === "Home") {
        entries[0].focus?.();
        return;
      }
      if (event.key === "End") {
        entries[entries.length - 1].focus?.();
        return;
      }
      const at = entries.indexOf(document.activeElement);
      const next = at === -1
        ? (event.key === "ArrowDown" ? 0 : entries.length - 1)
        : (at + (event.key === "ArrowDown" ? 1 : entries.length - 1)) % entries.length;
      entries[next]?.focus?.();
    }
  };

  activePopupMenuClose = close;
  document.addEventListener?.("keydown", onKey, true);
  globalThis.addEventListener?.("aurelia:page", close);
  attachTimer = setTimeout(() => {
    attachTimer = null;
    if (!closed) document.addEventListener?.("click", close);
  }, 0);

  const initial = enabledItems().find((entry) => entry.getAttribute("aria-checked") === "true") ?? enabledItems()[0];
  initial?.focus?.();
  return { menu, close };
}

/** Keyboard- and pointer-operable vertical resize separator for the sidebar (210–300 px). */
export function createSidebarResizeHandle({ width = 236, min = 210, max = 300, step = 10, onPreview, onCommit } = {}) {
  const clamp = (value) => Math.min(max, Math.max(min, Math.round(Number(value) || width)));
  let current = clamp(width);
  const handle = h("div", {
    class: "sidebar-resize",
    role: "separator",
    tabindex: "0",
    "aria-orientation": "vertical",
    "aria-label": "Sidebar Width",
    "aria-valuemin": String(min),
    "aria-valuemax": String(max),
    "aria-valuenow": String(current),
  });

  const apply = (next, commit) => {
    current = clamp(next);
    handle.setAttribute("aria-valuenow", String(current));
    onPreview?.(current);
    if (commit) onCommit?.(current);
  };

  handle.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    handle.setPointerCapture?.(event.pointerId);
    const move = (moved) => apply(moved.clientX, false);
    const end = () => {
      handle.removeEventListener("pointermove", move);
      handle.removeEventListener("pointerup", end);
      handle.removeEventListener("pointercancel", end);
      apply(current, true);
    };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", end);
    handle.addEventListener("pointercancel", end);
  });

  handle.addEventListener("keydown", (event) => {
    const delta = event.shiftKey ? step * 2 : step;
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      apply(current - delta, true);
    } else if (event.key === "ArrowRight") {
      event.preventDefault();
      apply(current + delta, true);
    } else if (event.key === "Home") {
      event.preventDefault();
      apply(min, true);
    } else if (event.key === "End") {
      event.preventDefault();
      apply(max, true);
    }
  });

  return handle;
}

/** Hands a file the server made (a backup, a report) to the browser's download. */
export function saveBlob(blob, name) {
  const address = URL.createObjectURL(blob);
  const link = h("a", { href: address, download: name, hidden: true });
  document.body.append(link);
  link.click();
  link.remove();
  // Kept for ten minutes, so a large backup still saves when its save dialog stays open a while
  // (audit C-X20); leaving the page frees it at once.
  const revoke = () => URL.revokeObjectURL(address);
  // Under Node (the logic tests) the pending timer must not keep the process running.
  setTimeout(revoke, 600_000)?.unref?.();
  addEventListener("pagehide", revoke, { once: true });
}
