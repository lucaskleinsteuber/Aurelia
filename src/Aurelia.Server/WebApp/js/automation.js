// Smart Home ("automation-v1"): what the player reports, and the words and rules of
// Settings › Smart Home. Pure functions, tested with node --test.

export const AUTOMATION_CAPABILITY = "automation-v1";

export function supportsAutomation(capabilities) {
  return Array.isArray(capabilities) && capabilities.includes(AUTOMATION_CAPABILITY);
}

/** The state a video element event means, or null for events that change nothing. */
export function playerStateFor(event) {
  switch (event) {
    case "playing": return "playing";
    case "pause": return "paused";
    case "waiting": return "buffering";
    case "ended": return "finished";
    default: return null;
  }
}

/**
 * Whether a new state is worth sending: equal states in a row are not, a pause right after the
 * end is not (the video pauses itself when it ends), and nothing follows "finished" but playing.
 */
export function shouldReport(last, next) {
  if (!next || next === last) return false;
  if (last === "finished" && next !== "playing") return false;
  return true;
}

export const AUTOMATION_PRESETS = Object.freeze([
  { id: "homeAssistant", title: "Home Assistant", detail: "Sends to a Home Assistant automation with a Webhook trigger." },
  { id: "generic", title: "Other Receiver", detail: "Any address that accepts a signed JSON POST, such as Node-RED or a script." },
]);

export const INTEGRATION_SCOPES = Object.freeze([
  { id: "status", title: "Read What Plays", detail: "What is playing where, and whether the server can turn off." },
  { id: "power", title: "Turn the Server Off", detail: "Sleep, turn off or stop the server, for example from a Home Assistant button." },
  { id: "playback", title: "Control Players", detail: "Play, pause or stop on your own devices that have Aurelia open." },
]);

export const POWER_ACTIONS = Object.freeze({
  sleep: { title: "Sleep Now", detail: "The computer sleeps; Wake-on-LAN wakes it in about 10 to 20 seconds." },
  shutdown: { title: "Turn Off Now", detail: "The computer turns off; Wake-on-LAN starts it in about 30 to 60 seconds." },
  stop: { title: "Stop Aurelia Now", detail: "Only Aurelia Server stops." },
});

/** The address Home Assistant's Webhook trigger listens on, from its address and webhook ID. */
export function homeAssistantUrl(base, webhookId) {
  const trimmed = String(base || "").trim().replace(/\/+$/, "");
  const hookId = String(webhookId || "").trim();
  if (!trimmed || !hookId || /[^A-Za-z0-9_-]/.test(hookId)) return null;
  const withScheme = /^https?:\/\//i.test(trimmed) ? trimmed : `http://${trimmed}`;
  try {
    const url = new URL(withScheme);
    // Home Assistant listens on 8123; an address typed without a port means that one.
    if (!url.port && url.protocol === "http:" && !/:80$/.test(withScheme.split("/")[2])) url.port = "8123";
    return `${url.origin}/api/webhook/${hookId}`;
  } catch {
    return null;
  }
}

/** Home Assistant's address and webhook ID back from a stored webhook address. */
export function splitHomeAssistantUrl(url) {
  const match = /^(https?:\/\/[^/]+)\/api\/webhook\/([A-Za-z0-9_-]+)$/.exec(String(url || ""));
  return match ? { base: match[1], webhookId: match[2] } : { base: "", webhookId: "" };
}

/**
 * The same rule the server applies: HTTPS goes anywhere, plain HTTP only to this computer or the
 * home network. Returns a sentence to show, or null when the address is fine.
 */
export function webhookUrlProblem(url) {
  const text = String(url || "").trim();
  if (!text) return "Enter the address the events go to.";
  let parsed;
  try { parsed = new URL(text); } catch { return "The address must start with http:// or https://."; }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return "The address must start with http:// or https://.";
  if (parsed.username || parsed.password) return "Put no user name or password in the address.";
  const host = parsed.hostname.replace(/^\[|\]$/g, "");
  if (/^169\.254\./.test(host) || /^fe80:/i.test(host)) return "This address can't receive events.";
  if (parsed.protocol === "http:" && !isHomeHost(host)) return "Use https:// for addresses outside your home network.";
  return null;
}

function isHomeHost(host) {
  if (/\.(local|lan|home\.arpa|fritz\.box)$/i.test(host) || host === "localhost" || !host.includes(".")) return true;
  const parts = host.split(".").map(Number);
  if (parts.length === 4 && parts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255)) {
    const [a, b] = parts;
    return a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
  }
  return /^(fc|fd)/i.test(host) || host === "::1";
}

/** One line for a webhook in the list: where it goes and how the last delivery went. */
export function webhookStatus(webhook) {
  if (!webhook.enabled) return { tone: "off", text: "Off" };
  if (webhook.pausedReason) return { tone: "warning", text: "Paused after failed deliveries" };
  const last = webhook.lastDelivery;
  if (!last) return { tone: "idle", text: "Nothing sent yet" };
  if (last.state === "succeeded") return { tone: "ok", text: `Last delivery ${last.durationMilliseconds ?? "?"} ms` };
  if (last.state === "pending") return { tone: "warning", text: "Trying again…" };
  return { tone: "warning", text: last.error || "The last delivery failed" };
}

/** The host only, so the list never shows a webhook ID. */
export function webhookHost(url) {
  try { return new URL(url).host; } catch { return url; }
}

/** The YAML of a ready Home Assistant automation for this webhook. */
export function homeAssistantExample(webhookId, deviceName) {
  const id = webhookId || "aurelia";
  const device = deviceName ? `\n      - condition: template\n        value_template: "{{ trigger.json.device.name == '${deviceName.replace(/'/g, "")}' }}"` : "";
  return `alias: Aurelia – movie lights
triggers:
  - trigger: webhook
    webhook_id: ${id}
    allowed_methods: [POST]
    local_only: true
actions:
  - choose:
      - conditions:
          - condition: template
            value_template: "{{ trigger.json.event in ['playback.started', 'playback.resumed'] }}"${device}
        sequence:
          - action: light.turn_on
            target: { area_id: living_room }
            data: { brightness_pct: 10, transition: 2 }
      - conditions:
          - condition: template
            value_template: "{{ trigger.json.event in ['playback.paused', 'playback.stopped', 'playback.finished'] }}"
        sequence:
          - action: light.turn_on
            target: { area_id: living_room }
            data: { brightness_pct: 70, transition: 2 }
`;
}

/** The request body for saving a webhook from the form. */
export function webhookRequest(form) {
  return {
    name: String(form.name || "").trim(),
    url: String(form.url || "").trim(),
    preset: form.preset === "generic" ? "generic" : "homeAssistant",
    events: [...new Set(form.events || [])],
    deviceIds: [...new Set(form.deviceIds || [])],
    profileIds: [...new Set(form.profileIds || [])],
    includeTitles: form.includeTitles !== false,
    excludeChildren: Boolean(form.excludeChildren),
    enabled: form.enabled !== false,
  };
}

/** What is wrong with the form, or null when it can be saved. */
export function webhookFormProblem(form) {
  const request = webhookRequest(form);
  if (!request.name || request.name.length > 64) return "Give the webhook a name of up to 64 characters.";
  const urlProblem = webhookUrlProblem(request.url);
  if (urlProblem) return urlProblem;
  if (request.events.length === 0) return "Choose at least one event.";
  return null;
}
