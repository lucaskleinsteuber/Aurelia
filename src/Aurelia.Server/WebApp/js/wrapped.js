// Wrapped: a profile's year as full-screen slides, like a story. The server chooses the slides
// and their lines; this only shows them. Each slide runs for SLIDE_MS, a tap on the right or
// left moves on or back, holding pauses, and Escape closes.

import { h, icon, clear } from "./dom.js";

export const SLIDE_MS = 6000;

/** The Wrapped colors: a field and the ink that reads on it. */
export const ACCENTS = {
  night: { field: "#171a3a", ink: "#f2f0ff", sticker: "#5b7cff" },
  ember: { field: "#ff5a36", ink: "#1c0600", sticker: "#1c0600" },
  violet: { field: "#6a4cff", ink: "#ffffff", sticker: "#ffd84d" },
  gold: { field: "#f6b92b", ink: "#1e1400", sticker: "#1e1400" },
  rose: { field: "#ff4d88", ink: "#22000f", sticker: "#22000f" },
  mint: { field: "#33d39a", ink: "#00180e", sticker: "#00180e" },
  ocean: { field: "#1d8bff", ink: "#ffffff", sticker: "#0b1a3a" },
  lime: { field: "#c4ee34", ink: "#131a00", sticker: "#131a00" },
};

export function accentFor(name) {
  return ACCENTS[name] ?? ACCENTS.night;
}

/** The number to count up to, when the big text is a plain number ("143", not "02:47"). */
export function countTarget(text) {
  return /^\d{1,6}$/.test(String(text ?? "")) ? Number(text) : null;
}

/** The number shown `fraction` (0…1) into the count, easing out so it lands softly. */
export function countValue(target, fraction) {
  const t = Math.min(1, Math.max(0, fraction));
  return Math.round(target * (1 - Math.pow(1 - t, 3)));
}

/** The slide after a tap: right half forward, left third back. Null past the last one. */
export function stepFrom(index, count, forward) {
  if (forward) return index + 1 < count ? index + 1 : null;
  return Math.max(0, index - 1);
}

export const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August",
  "September", "October", "November", "December"];

/** The newest month whose Wrapped is ready: last month from the 2nd on, else the one before. */
export function readyMonth(today = new Date()) {
  const first = new Date(today.getFullYear(), today.getMonth() - (today.getDate() >= 2 ? 1 : 2), 1);
  return { year: first.getFullYear(), month: first.getMonth() + 1, name: MONTHS[first.getMonth()] };
}

/** Home shows the new month in its first week, from the 2nd to the 8th. */
export function monthIsNew(today = new Date()) {
  return today.getDate() >= 2 && today.getDate() <= 8;
}

/**
 * Opens a year, or with `month` one month, over the whole window. `artworkUrl(image, width)`
 * makes picture addresses.
 */
export async function openWrapped({ api, year, month = null, artworkUrl }) {
  const reduce = Boolean(window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches);
  const opener = document.activeElement;
  const frame = h("div", { class: "wrapped-frame" }, h("div", { class: "spinner visible" }));
  const overlay = h("div", { class: "wrapped", role: "dialog", "aria-modal": "true", "aria-label": month ? `Your ${MONTHS[month - 1]} Wrapped` : `Your ${year} Wrapped` }, frame);
  document.body.append(overlay);
  document.body.classList.add("playing");

  let slides = [];
  let index = 0;
  let held = false;
  let holdTimer = null;
  let counting = 0;

  function close() {
    cancelAnimationFrame(counting);
    document.removeEventListener("keydown", keys);
    overlay.remove();
    document.body.classList.remove("playing");
    opener?.focus?.();
  }

  function keys(event) {
    if (event.key === "Escape") close();
    else if (event.key === "ArrowRight") go(true);
    else if (event.key === "ArrowLeft") go(false);
    else if (event.key === " ") {
      event.preventDefault();
      held = !held;
      overlay.classList.toggle("held", held);
    } else return;
    event.preventDefault?.();
  }
  document.addEventListener("keydown", keys);
  overlay.addEventListener("click", (event) => { if (event.target === overlay) close(); });

  try {
    slides = (await api.wrapped(year, month))?.slides ?? [];
  } catch (error) {
    clear(frame);
    frame.append(h("div", { class: "wrapped-slide" },
      h("h2", { class: "wrapped-headline" }, "Wrapped didn’t load."),
      h("p", { class: "wrapped-detail" }, error?.message ?? "Try again in a moment."),
      h("button", { class: "primary-button", onclick: close }, "Close")));
    return;
  }
  if (!slides.length) return close();

  function go(forward) {
    const next = stepFrom(index, slides.length, forward);
    if (next === null) return close();
    index = next;
    show();
  }

  function show() {
    cancelAnimationFrame(counting);
    const slide = slides[index];
    const accent = accentFor(slide.accent);
    clear(frame);
    frame.style.setProperty("--field", accent.field);
    frame.style.setProperty("--ink", accent.ink);
    frame.style.setProperty("--sticker", accent.sticker);
    frame.dataset.kind = slide.kind;
    const picture = slide.poster ? artworkUrl(slide.poster, 600) : null;
    const bars = h("div", { class: "wrapped-bars", "aria-hidden": "true" }, slides.map((_, at) =>
      h("span", { class: at < index ? "done" : at === index ? "now" : "" }, h("i", { style: { "animation-duration": `${SLIDE_MS}ms` } }))));
    const big = slide.bigNumber ? h("div", { class: "wrapped-big" }, h("span", { class: "wrapped-number" }, slide.bigNumber),
      slide.unit ? h("span", { class: "wrapped-unit" }, slide.unit) : null) : null;
    const content = h("div", { class: "wrapped-slide", "aria-live": "polite" },
      h("p", { class: "wrapped-eyebrow" }, slide.eyebrow),
      slide.kind === "summary" ? summary(slide) : [
        picture ? h("img", { class: "wrapped-poster", src: picture, alt: "" }) : null,
        h("h2", { class: "wrapped-headline" }, slide.headline),
        big,
        slide.detail ? h("p", { class: "wrapped-detail" }, slide.detail) : null,
      ],
      h("p", { class: "wrapped-sticker" }, slide.quip));
    if (picture) frame.append(h("div", { class: "wrapped-backdrop", style: { "background-image": `url("${picture}")` } }));
    frame.append(
      bars,
      h("button", { class: "wrapped-close", "aria-label": "Close Wrapped", onclick: close }, icon("close", { size: 20 })),
      content,
      h("div", { class: "wrapped-nav" },
        h("button", { class: "wrapped-tap back", "aria-label": "Previous slide", onclick: () => go(false) }),
        h("button", { class: "wrapped-tap forward", "aria-label": index + 1 < slides.length ? "Next slide" : "Close Wrapped", onclick: () => go(true) })));

    // The bar running out moves on, so holding (which pauses it) also holds the slide.
    const running = bars.querySelector(".now i");
    if (!reduce && running) running.addEventListener("animationend", () => go(true), { once: true });
    const number = frame.querySelector(".wrapped-number");
    const target = countTarget(slide.bigNumber);
    if (!reduce && number && target !== null && target > 1) {
      const started = performance.now();
      const tick = (time) => {
        number.textContent = String(countValue(target, (time - started) / 1100));
        if (time - started < 1100) counting = requestAnimationFrame(tick);
      };
      counting = requestAnimationFrame(tick);
    }
  }

  function summary(slide) {
    return [
      h("h2", { class: "wrapped-headline" }, slide.headline),
      slide.posters?.length ? h("div", { class: `wrapped-posters count-${Math.min(4, slide.posters.length)}` },
        slide.posters.slice(0, 4).map((poster) => h("img", { src: artworkUrl(poster, 300), alt: "" }))) : null,
      slide.facts?.length ? h("dl", { class: "wrapped-facts" }, slide.facts.map((fact) => [h("dt", {}, fact.label), h("dd", {}, fact.value)])) : null,
    ];
  }

  // Holding anywhere pauses, like a story; a short tap still moves.
  frame.addEventListener("pointerdown", () => {
    holdTimer = setTimeout(() => overlay.classList.add("held"), 220);
  });
  const release = () => {
    clearTimeout(holdTimer);
    if (overlay.classList.contains("held") && !held) {
      // Swallow the click that ends a hold, so letting go does not also move on.
      overlay.addEventListener("click", (event) => event.stopPropagation(), { capture: true, once: true });
      setTimeout(() => overlay.classList.remove("held"), 0);
    }
  };
  frame.addEventListener("pointerup", release);
  frame.addEventListener("pointercancel", release);

  show();
  // Focus stays on the story itself; arrow keys and Escape work from here.
  frame.setAttribute("tabindex", "-1");
  frame.focus();
}
