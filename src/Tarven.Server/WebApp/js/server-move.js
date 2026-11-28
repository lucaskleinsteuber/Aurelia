// Moving a whole server to another computer (docs/SERVER_MOVE.md): the rules the browser app needs
// without a page, so they run the same in a browser and in `node --test tests/WebApp`.

import { countdown } from "./logic.js";

/** The port every Tarven server answers on when an address names none. */
export const DEFAULT_PORT = 43111;

/** "abcd efgh-jkmn" becomes "ABCD-EFGH-JKMN": twelve letters and digits in groups of four. */
export function formatMoveCode(text) {
  const characters = String(text ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 12);
  return characters.match(/.{1,4}/g)?.join("-") ?? "";
}

/** Whether a typed move code has all twelve characters. */
export function moveCodeComplete(text) {
  return formatMoveCode(text).replace(/-/g, "").length === 12;
}

/**
 * The old server's address as the new server should call it: "192.168.1.20" becomes
 * "https://192.168.1.20:43111". Only https, a host and an optional port; null for anything else.
 */
export function moveAddress(text) {
  const typed = String(text ?? "").trim();
  if (!typed || typed.length > 255) return null;
  const withScheme = typed.includes("://") ? typed : `https://${typed}`;
  let url;
  try { url = new URL(withScheme); } catch { return null; }
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password || url.search || url.hash) return null;
  if (url.pathname !== "/" && url.pathname !== "") return null;
  const authority = withScheme.slice(withScheme.indexOf("://") + 3).split(/[/?#]/)[0];
  const explicitPort = authority.startsWith("[") ? authority.includes("]:") : authority.includes(":");
  // URL drops the default https port 443, so a typed ":443" stays as it was typed.
  const port = explicitPort ? (url.port || "443") : String(DEFAULT_PORT);
  return `https://${url.hostname}:${port}`;
}

/** "412 of 415 sample files found", for a storage location and a folder on the new computer. */
export function matchText(matched, sampled) {
  const found = Number(matched) || 0;
  const total = Number(sampled) || 0;
  if (total <= 0) return "This location had no files to compare.";
  if (found <= 0) return `None of ${total} sample file${total === 1 ? "" : "s"} found`;
  if (found >= total) return `All ${total} sample file${total === 1 ? "" : "s"} found`;
  return `${found} of ${total} sample files found`;
}

function bytes(value) {
  const number = Number(value) || 0;
  if (number < 1024) return `${number} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let size = number / 1024;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) { size /= 1024; unit += 1; }
  return `${size.toFixed(size < 10 ? 1 : 0)} ${units[unit]}`;
}

/** "12 MB of 80 MB" and a fraction for the progress bar, or the received size alone. */
export function transferProgress(progress) {
  const received = Math.max(0, Number(progress?.received) || 0);
  const expected = Math.max(0, Number(progress?.expected) || 0);
  if (!expected) return { fraction: null, text: received ? `${bytes(received)} received` : "Waiting for the old server…" };
  const fraction = Math.min(1, received / expected);
  return { fraction, text: `${bytes(received)} of ${bytes(expected)}` };
}

/** A location's suggestions, the best (most matches) first; ties keep the server's order. */
export function rankedSuggestions(location) {
  return (location?.suggestions ?? [])
    .filter((suggestion) => typeof suggestion?.path === "string" && suggestion.path)
    .map((suggestion, index) => ({ ...suggestion, index }))
    .sort((left, right) => (Number(right.matched) || 0) - (Number(left.matched) || 0) || left.index - right.index)
    .map(({ index, ...suggestion }) => suggestion);
}

/** What each location starts with: its best suggestion when it found files, else Later. */
export function initialChoice(location) {
  const best = rankedSuggestions(location)[0];
  return best && (Number(best.matched) || 0) > 0 ? { kind: "suggestion", path: best.path } : { kind: "later", path: null };
}

/**
 * The body of POST /api/v1/setup/move/finish: one mapping per location, the chosen folder or null
 * for Later (the location keeps its old path and stays offline). A typed folder must be absolute.
 */
export function mappingPayload(locations, choices) {
  const mappings = [];
  for (const location of locations ?? []) {
    const choice = choices?.[location.id] ?? initialChoice(location);
    if (choice.kind === "later") { mappings.push({ id: location.id, path: null }); continue; }
    const path = String(choice.path ?? "").trim();
    if (!path) throw new Error(`Choose a folder for “${location.name}”, or choose Later.`);
    if (!path.startsWith("/") && !/^[A-Za-z]:[\\/]/.test(path)) throw new Error(`Enter the whole path of the folder for “${location.name}”, starting with /.`);
    mappings.push({ id: location.id, path });
  }
  return { mappings };
}

/**
 * The new server's setup move as a screen: which step to show and what it says.
 * Steps: "start" (nothing staged), "progress", "locations", "applying", "done", "failed".
 */
export function setupMoveView(status) {
  const source = status?.source?.name ? `“${status.source.name}”` : "the old server";
  switch (status?.state) {
    case "fetching":
      return { step: "progress", title: "Moving In…", detail: `Receiving the data from ${source}. Keep both servers on.`, progress: transferProgress(status.progress) };
    case "received":
      return { step: "locations", title: "Where Are Your Media Files Now?", detail: `The data from ${source} arrived. For each storage location, choose the folder on this computer that holds the same files.`, locations: status.locations ?? [] };
    case "applying":
      return { step: "applying", title: "Moving In…", detail: "Tarven applies the moved data. The server restarts in a moment." };
    case "done":
      return { step: "done", title: "Moved", detail: `This server now runs with ${source}’s library and identity.` };
    case "failed":
      return { step: "failed", title: "The Move Didn’t Work", detail: status.error || "The data couldn’t be received. Nothing changed on either server." };
    default:
      return { step: "start", title: "Move from Another Tarven Server", detail: null };
  }
}

/** The old server's move as Settings › Server shows it, with the actions that fit. */
export function ownerMoveView(status, now = Date.now()) {
  const state = status?.state ?? "none";
  if (state === "waiting") {
    const left = status.method === "network" ? countdown(status.expiresAt, now) : "";
    return {
      state,
      summary: status.method === "network"
        ? (left ? `Waiting for the new server · the code works for ${left}` : "The move code has expired. Start again for a new one.")
        : "Waiting for the new server to open the moving file.",
      actions: status.method === "file" ? ["markMoved", "cancel"] : ["start", "cancel"],
    };
  }
  if (state === "transferring") return { state, summary: "The new server is receiving the data…", actions: ["cancel"] };
  if (state === "moved") {
    const name = status.movedTo?.name ? `“${status.movedTo.name}”` : "a new server";
    const when = status.movedAt ? ` on ${new Date(status.movedAt).toLocaleString()}` : "";
    return { state, summary: `This server moved to ${name}${when}. Devices switch there on their own.`, actions: ["undo"] };
  }
  return { state: "none", summary: "Move this server, with its library, profiles and sign-ins, to another computer. Media files stay where they are.", actions: ["start"] };
}

/** Only http(s) addresses without credentials, for links the moved notice shows. */
export function safeAddresses(addresses) {
  const shown = [];
  for (const address of addresses ?? []) {
    let url;
    try { url = new URL(String(address)); } catch { continue; }
    if ((url.protocol !== "https:" && url.protocol !== "http:") || url.username || url.password) continue;
    const text = `${url.protocol}//${url.host}`;
    if (!shown.includes(text)) shown.push(text);
  }
  return shown;
}

/** Where a server that moved went, from a 409 server_moved or the public server info, or null. */
export function movedDestination(value) {
  const movedTo = value?.movedTo ?? value?.moved;
  if (!movedTo || typeof movedTo !== "object") return null;
  return { serverId: movedTo.serverId ?? null, name: String(movedTo.name || "the new server"), addresses: safeAddresses(movedTo.addresses) };
}

/** Whether an error says this server moved away. */
export function isServerMoved(error) {
  return error?.status === 409 && error?.code === "server_moved";
}

/**
 * Storage Location Moved: whether a previewed folder can be confirmed. A folder with no matching
 * sample files needs an explicit second confirmation and is then sent with force.
 */
export function relocateDecision(preview, { confirmedEmpty = false } = {}) {
  if (!preview) return { canConfirm: false, force: false, text: "Choose a folder and preview it first." };
  const matched = Number(preview.matched) || 0;
  const sampled = Number(preview.sampled) || 0;
  if (matched > 0) return { canConfirm: true, force: false, text: matchText(matched, sampled) };
  return {
    canConfirm: confirmedEmpty,
    force: confirmedEmpty,
    needsSecondConfirmation: true,
    text: sampled > 0 ? `${matchText(0, sampled)}. This may be the wrong folder.` : matchText(0, 0),
  };
}

/** A friendly sentence for the move problems the server reports (docs/SERVER_MOVE.md). */
export function moveProblem(error) {
  switch (error?.code) {
    case "move_not_waiting": return "The old server isn’t waiting for a move. On the old server, choose Move to a New Server… and use the code it shows.";
    case "move_code_invalid":
    case "invalid_move_code": return "That move code is not right or has expired. Check the code the old server shows.";
    case "move_address_invalid": return "Enter the old server’s address, such as 192.168.1.20.";
    case "move_source_unreachable":
    case "move_source_failed": return "The old server couldn’t be reached at that address. Check that it is on and shows its move code.";
    case "move_in_progress": return "A move is already under way on this server.";
    case "setup_code_invalid": return "That setup code is not right. On the server computer, run: sudo tarven setup --browser";
    case "backup_invalid":
    case "invalid_passphrase":
    case "backup_passphrase_invalid": return "The passphrase doesn’t open this moving file.";
    case "move_file_invalid": return "This file is not a moving file. On the old server, choose Move to a New Server… › With a Moving File.";
    case "move_not_received": return "The old server’s data hasn’t arrived yet. Start the move again.";
    case "folder_invalid": return "Choose an existing folder on this computer, with its whole path.";
    case "locations_overlap": return "Two storage locations can’t use the same folder. Choose another folder, or Later.";
    case "server_already_setup": return "This server already has an owner, so it can’t receive a move.";
    case "passphrase_invalid": return "Use a passphrase with at least 12 characters.";
    case "network_access_required": return "A move over the network needs this server’s network access. Turn it on in Settings › Server, or use a moving file.";
    case "relocate_no_matches": return "None of the sample files are in that folder. Confirm it explicitly to use it anyway.";
    case "library_scan_active": return "This storage location is being scanned. Try again when the scan finished.";
    case "http_404": return "This server’s version can’t move yet. Update Tarven first.";
    default: return error?.message || "Something went wrong.";
  }
}
