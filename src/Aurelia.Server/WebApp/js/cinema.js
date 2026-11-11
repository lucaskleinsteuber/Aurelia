// Cinema mode in the browser, as on the Mac: before a film that starts from the beginning comes
// one of Aurelia's made-up ads (nothing is for sale), trailers of films in the library nobody has
// watched yet, and the curtain, which opens once the film's picture moves.

import { h } from "./dom.js";

export const CINEMA_ADS = Object.freeze(["iceCream", "popcorn", "phones"]);
export const LAST_AD_KEY = "aurelia.cinemaLastAd";
/** Every ad runs this long, in seconds. */
export const AD_SECONDS = 15;
/** The curtain stays closed at least this long while the film starts behind it. */
export const CURTAIN_EARLIEST = 3.3;
/** A film that hasn't started by then gets the curtain opened anyway. */
export const CURTAIN_LONGEST_WAIT = 10;
export const CURTAIN_OPENING = 4;
/** A trailer whose picture hasn't moved by then is left out; even a long one ends here. */
export const TRAILER_START_SECONDS = 15;
export const TRAILER_LONGEST_SECONDS = 300;

/** The ads take turns, so the same one never runs twice in a row. */
export function nextAd(last) {
  const index = CINEMA_ADS.indexOf(last);
  return index < 0 ? CINEMA_ADS[0] : CINEMA_ADS[(index + 1) % CINEMA_ADS.length];
}

/**
 * Whether a title gets a pre-show: a film, cinema mode on with ads or trailers, the server can
 * list trailers, nobody is watching along, and the film starts at its beginning.
 */
export function cinemaWanted({ item, intent, preferences, capabilities = [], watchingTogether = false }) {
  if (item?.kind !== "movie" || watchingTogether || !preferences?.cinemaMode) return false;
  if (!preferences.cinemaAds && !(preferences.cinemaTrailers > 0)) return false;
  if (!capabilities.includes("cinema-trailers-v1")) return false;
  const position = item.progress?.isCompleted ? 0 : item.progress?.positionMilliseconds ?? 0;
  const threshold = (preferences.resumeThresholdSeconds ?? 0) * 1000;
  return intent === "play" || position === 0 || position < threshold;
}

/** The ad, the trailers that aren't for the film itself, then the curtain; nothing without either. */
export function cinemaActs({ ad, trailers = [], film }) {
  const acts = ad ? [{ kind: "ad", ad }] : [];
  for (const entry of trailers) {
    if (entry?.title?.id === film.id || entry?.trailer?.parentId === film.id || !entry?.trailer) continue;
    acts.push({ kind: "trailer", trailer: entry.trailer, title: entry.title });
  }
  if (acts.length) acts.push({ kind: "feature", title: film.title });
  return acts;
}

/** One line of an ad: it appears at `at` and leaves at `until` seconds. */
function beat(at, until, className, ...content) {
  const element = h("div", { class: `cinema-beat ${className}` }, ...content);
  element.style.setProperty("--in", `${at}s`);
  element.style.setProperty("--out", `${until}s`);
  return element;
}

/** The ad's scene. Its lines run on CSS timings; Reduce Motion shows them without movement. */
export function adScene(ad) {
  const fine = (text) => h("p", { class: "cinema-fine" }, text);
  switch (ad) {
    case "popcorn":
      return h("div", { class: "cinema-ad popcorn", role: "img", "aria-label": "Aurelia Popcorn, a made-up ad" },
        h("div", { class: "popcorn-box", "aria-hidden": "true" }, h("span", {}, "POPCORN"),
          ...Array.from({ length: 9 }, (_, index) => h("i", { class: "kernel", style: { "--k": index } }))),
        beat(0.4, 5, "cinema-line big", "Aurelia Popcorn"),
        beat(5, 9.5, "cinema-line", "Louder than the film."),
        beat(9.5, 13, "cinema-line", "Now with extra crunch for the quiet scenes."),
        beat(13, 16, "cinema-line brand", "Crunch responsibly."),
        fine("*Rustling the bag in the dark is included at no extra cost."));
    case "phones":
      return h("div", { class: "cinema-ad phones", role: "img", "aria-label": "A made-up message from your cinema about phones" },
        beat(0.2, 4, "cinema-line small-caps", "A MESSAGE FROM YOUR CINEMA"),
        h("div", { class: "phone", "aria-hidden": "true" },
          ...["Mum: are you there", "Group chat (48)", "Battery 3%", "Mum: ???"].map((text, index) => h("span", { class: "buzz", style: { "--n": index } }, text))),
        beat(8, 11, "cinema-line big", "Thank you."),
        beat(11, 14, "cinema-line", "Phones off. Yes, yours too."),
        beat(13.2, 16, "cinema-line soft", "The group chat will survive. Probably."));
    default:
      return h("div", { class: "cinema-ad ice", role: "img", "aria-label": "Aurelia Ice, a made-up ad" },
        h("div", { class: "cone", "aria-hidden": "true" }, h("i", { class: "scoop one" }), h("i", { class: "scoop two" }), h("i", { class: "scoop three" }), h("b", {})),
        beat(0.3, 3.4, "cinema-line", "Feeling warm?"),
        beat(3.4, 6.6, "cinema-line drip", "Ninety minutes is a long t."),
        beat(6.6, 11, "cinema-line big brand", h("div", {}, "Aurelia Ice"), h("div", { class: "cinema-sub" }, "Three scoops. Zero plot holes.")),
        beat(11, 16, "cinema-line price", h("span", { class: "burst" }, h("small", {}, "ONLY"), "4.50!"), h("div", { class: "cinema-sub" }, "Now in the foyer.")),
        fine("*The foyer is your kitchen. Aurelia does not sell ice cream and never has."));
  }
}

export function comingUp() {
  return h("div", { class: "cinema-ad coming-up" }, h("p", { class: "cinema-line small-caps" }, "COMING UP"));
}

/** The closed curtain with the film's name; `.open` draws it aside. */
export function curtain(title) {
  return h("div", { class: "cinema-curtain" },
    h("div", { class: "curtain-half left", "aria-hidden": "true" }),
    h("div", { class: "curtain-half right", "aria-hidden": "true" }),
    h("div", { class: "curtain-title" }, h("p", { class: "small-caps" }, "AURELIA CINEMA PRESENTS"), h("h2", {}, title)));
}
