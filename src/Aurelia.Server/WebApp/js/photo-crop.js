// Crop for an own profile photo: the chosen picture in a square frame that can be moved and
// zoomed, then drawn into a square JPEG in the browser. Nothing leaves the device before Save.

import { h } from "./dom.js";
import { cropFrame, cropPixels } from "./logic.js";

/** The edge of the square photo that is uploaded; the server keeps its own small copy. */
export const PHOTO_EDGE = 1024;

/** Resolves with a square JPEG `File` of the chosen part, or null when cancelled or unreadable. */
export function cropPhoto(file) {
  return new Promise((resolve) => {
    const address = URL.createObjectURL(file);
    const image = h("img", { class: "crop-image", src: address, alt: "", draggable: "false" });
    const frame = h("div", { class: "crop-frame round", "aria-hidden": "true" });
    const stage = h("div", { class: "crop-stage" }, image, frame);
    const zoom = h("input", { type: "range", min: "1", max: "4", step: "0.01", value: "1", "aria-label": "Zoom" });
    let crop = null;
    let state = { zoom: 1, centerX: 0.5, centerY: 0.5 };
    let confirmed = false;
    const place = () => {
      if (!image.naturalWidth) return;
      crop = cropFrame({ imageWidth: image.naturalWidth, imageHeight: image.naturalHeight, aspect: 1, ...state });
      state.centerX = crop.x + crop.width / 2;
      state.centerY = crop.y + crop.height / 2;
      Object.assign(frame.style, { left: `${crop.x * 100}%`, top: `${crop.y * 100}%`, width: `${crop.width * 100}%`, height: `${crop.height * 100}%` });
    };
    image.addEventListener("load", place, { once: true });
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
    const sheet = h("dialog", { class: "sheet crop-sheet", "aria-label": "Crop Photo" },
      h("h2", {}, "Crop Photo"),
      h("p", { class: "muted small" }, "Drag the circle and zoom until it shows the part you want."),
      stage,
      h("label", { class: "field" }, h("span", {}, "Zoom"), zoom),
      h("div", { class: "button-row end" },
        h("button", { class: "secondary-button", type: "button", onclick: () => sheet.close() }, "Cancel"),
        h("button", { class: "primary-button", type: "button", onclick: () => { confirmed = true; sheet.close(); } }, "Use Photo")));
    sheet.addEventListener("close", async () => {
      sheet.remove();
      const result = confirmed && crop ? await squarePhoto(image, crop).catch(() => null) : null;
      URL.revokeObjectURL(address);
      resolve(result);
    }, { once: true });
    document.body.append(sheet);
    sheet.showModal();
    if (image.complete && image.naturalWidth) place();
  });
}

/** The cropped part as a `PHOTO_EDGE` square JPEG. */
async function squarePhoto(image, crop) {
  const source = cropPixels(crop, image.naturalWidth, image.naturalHeight);
  const edge = Math.min(PHOTO_EDGE, source.width);
  const canvas = h("canvas", { width: edge, height: edge });
  canvas.getContext("2d").drawImage(image, source.x, source.y, source.width, source.height, 0, 0, edge, edge);
  const blob = await new Promise((done) => canvas.toBlob(done, "image/jpeg", 0.88));
  return blob ? new File([blob], "photo.jpg", { type: "image/jpeg" }) : null;
}
