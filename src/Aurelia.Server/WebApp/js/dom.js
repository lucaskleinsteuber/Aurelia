// A tiny element builder. Text always goes in as text, never as HTML, so titles and names
// from the library cannot inject markup.

export function h(tag, attributes = {}, ...children) {
  const element = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes ?? {})) {
    if (value == null || value === false) continue;
    if (key === "class") element.className = value;
    else if (key === "dataset") Object.assign(element.dataset, value);
    else if (key.startsWith("on") && typeof value === "function") element.addEventListener(key.slice(2), value);
    else if (key === "style") for (const [name, styleValue] of Object.entries(value)) element.style.setProperty(name, styleValue);
    else if (value === true) element.setAttribute(key, "");
    else element.setAttribute(key, String(value));
  }
  append(element, children);
  return element;
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
  play: ["M8 5.5v13a1 1 0 0 0 1.5.86l10.4-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z", "fill"],
  pause: ["M7 5h3.2v14H7zM13.8 5H17v14h-3.2z", "fill"],
  back: ["M15 5l-7 7 7 7", "stroke"],
  forward: ["M9 5l7 7-7 7", "stroke"],
  close: ["M6 6l12 12M18 6L6 18", "stroke"],
  heart: ["M12 20s-7.5-4.6-7.5-10.2A4.3 4.3 0 0 1 12 7.4a4.3 4.3 0 0 1 7.5 2.4C19.5 15.4 12 20 12 20z", "stroke"],
  heartFill: ["M12 20s-7.5-4.6-7.5-10.2A4.3 4.3 0 0 1 12 7.4a4.3 4.3 0 0 1 7.5 2.4C19.5 15.4 12 20 12 20z", "fill"],
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
  captions: ["M3.5 5.5h17v13h-17zM10.5 10.2a2.4 2.4 0 1 0 0 3.6M17 10.2a2.4 2.4 0 1 0 0 3.6", "stroke"],
  delete: ["M9 6h11v12H9l-6-6zM12 9.5l5 5M17 9.5l-5 5", "stroke"],
  lock: ["M7 11V8a5 5 0 0 1 10 0v3M5.5 11h13v9h-13z", "stroke"],
  more: ["M6 12h.01M12 12h.01M18 12h.01", "dots"],
  warning: ["M12 4l9 16H3zM12 10v4.5M12 17.5h.01", "stroke"],
  power: ["M12 3v8M7 6.5a7 7 0 1 0 10 0", "stroke"],
};

export function icon(name, { size = 20, label } = {}) {
  const [path, style] = PATHS[name] ?? PATHS.more;
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
