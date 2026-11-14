// Settings › Smart Home for the owner: webhooks for Home Assistant and other receivers, keys
// for Home Assistant and shortcuts, and turning the server on and off. See docs/AUTOMATION.md.

import { h, clear } from "./dom.js";
import { remoteUnlockPanel } from "./security-view.js";
import {
  AUTOMATION_PRESETS, INTEGRATION_SCOPES, POWER_ACTIONS, homeAssistantExample, homeAssistantUrl,
  splitHomeAssistantUrl, webhookFormProblem, webhookHost, webhookRequest, webhookStatus,
} from "./automation.js";

function when(text) {
  return text ? new Date(text).toLocaleString() : "never";
}

function sheet(title, ...children) {
  const dialog = h("dialog", { class: "sheet settings-editor automation-sheet", "aria-label": title }, h("h2", {}, title), ...children);
  dialog.addEventListener("close", () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
  return dialog;
}

function copyButton(label, text, toast) {
  return h("button", { type: "button", class: "secondary-button", onclick: async () => {
    try { await navigator.clipboard.writeText(text); toast("Copied."); } catch { toast("Select the text and copy it."); }
  } }, label);
}

function confirm(title, message, action, danger = true) {
  return new Promise((resolve) => {
    const dialog = h("dialog", { class: "sheet" }, h("h2", {}, title), h("p", {}, message),
      h("div", { class: "button-row end" },
        h("button", { class: "secondary-button", onclick: () => { dialog.close(); resolve(false); } }, "Cancel"),
        h("button", { class: danger ? "danger-button" : "primary-button", onclick: () => { dialog.close(); resolve(true); } }, action)));
    dialog.addEventListener("cancel", () => resolve(false));
    dialog.addEventListener("close", () => dialog.remove());
    document.body.append(dialog);
    dialog.showModal();
  });
}

/**
 * Runs a change; when server management is locked, asks for the Server Password (or another
 * device's Face ID when that is required) and runs it again. Resolves to undefined if cancelled.
 */
async function unlocked(api, work) {
  try {
    return await work();
  } catch (error) {
    if (error?.code !== "management_locked") throw error;
  }
  const ok = await new Promise((resolve) => {
    const password = h("input", { type: "password", class: "text-field", autocomplete: "current-password", "aria-label": "Server Password" });
    const message = h("p", { class: "error-text", role: "alert" });
    const body = h("div", {});
    const submit = h("button", { type: "button", class: "primary-button" }, "Unlock");
    let settled = false;
    const finish = (value) => { if (!settled) { settled = true; resolve(value); } dialog.close(); };
    const dialog = h("dialog", { class: "sheet" },
      h("h2", {}, "Unlock Server Management"),
      h("p", { class: "muted small" }, "Enter the Server Password to make this change. Management stays unlocked for ten minutes."),
      body, password, message,
      h("div", { class: "button-row end" }, h("button", { type: "button", class: "secondary-button", onclick: () => finish(false) }, "Cancel"), submit));
    submit.addEventListener("click", async () => {
      if (!password.value) return;
      submit.disabled = true;
      try {
        await api.unlockManagement(password.value);
        finish(true);
      } catch (error) {
        submit.disabled = false;
        if (error?.code === "passkey_required") {
          password.hidden = true;
          submit.hidden = true;
          body.append(remoteUnlockPanel({ api, onUnlocked: () => finish(true) }));
          return;
        }
        message.textContent = error?.code === "invalid_credentials" ? "The Server Password is incorrect." : error?.message ?? "";
      } finally {
        password.value = "";
      }
    });
    password.addEventListener("keydown", (event) => { if (event.key === "Enter") { event.preventDefault(); submit.click(); } });
    dialog.addEventListener("cancel", () => finish(false));
    dialog.addEventListener("close", () => { if (!settled) { settled = true; resolve(false); } dialog.remove(); });
    document.body.append(dialog);
    dialog.showModal();
    password.focus();
  });
  return ok ? work() : undefined;
}

function checkboxList(items, chosen, name) {
  const selected = new Set(chosen);
  const element = h("div", { class: "checkbox-list", role: "group", "aria-label": name },
    ...items.map((item) => {
      const box = h("input", { type: "checkbox", checked: selected.has(item.id) });
      box.addEventListener("change", () => { if (box.checked) selected.add(item.id); else selected.delete(item.id); });
      return h("label", { class: "checkbox-row" }, box,
        h("span", {}, h("span", {}, item.title), item.detail ? h("span", { class: "muted small" }, item.detail) : null));
    }));
  return { element, values: () => [...selected] };
}

/** Shows a new secret once, with the example automation for Home Assistant. */
function showSecret(secret, webhook, toast) {
  const { webhookId } = splitHomeAssistantUrl(webhook.url);
  const dialog = sheet("Webhook Saved",
    h("p", {}, "Every event carries a signature made with this secret (header X-Aurelia-Signature). Keep it if your receiver checks signatures; it is shown only now."),
    h("code", { class: "code-block" }, secret),
    h("div", { class: "button-row" }, copyButton("Copy Secret", secret, toast)),
    webhook.preset === "homeAssistant" ? [
      h("h3", { class: "settings-subheading" }, "Example Automation"),
      h("p", { class: "muted small" }, "In Home Assistant: Settings › Automations › Create Automation › ⋮ › Edit in YAML, paste this and change the lights to yours."),
      h("pre", { class: "code-block" }, homeAssistantExample(webhookId)),
      h("div", { class: "button-row" }, copyButton("Copy Example", homeAssistantExample(webhookId), toast)),
    ] : null,
    h("div", { class: "button-row end" }, h("button", { class: "primary-button", onclick: () => dialog.close() }, "Done")));
}

/** Adds or edits a webhook. */
export function openWebhookEditor({ api, overview, webhook, onSaved, toast }) {
  const editing = Boolean(webhook);
  const draft = webhook ? { ...webhook } : {
    name: "Home Assistant", preset: "homeAssistant", url: "", enabled: true, includeTitles: true, excludeChildren: false,
    events: ["playback.started", "playback.paused", "playback.resumed", "playback.stopped", "playback.finished"],
    deviceIds: [], profileIds: [],
  };
  const parts = splitHomeAssistantUrl(draft.url);
  const name = h("input", { class: "text-field", value: draft.name, maxlength: 64, "aria-label": "Name" });
  const preset = h("select", { class: "select", "aria-label": "Receiver" },
    AUTOMATION_PRESETS.map((choice) => h("option", { value: choice.id, selected: choice.id === draft.preset }, choice.title)));
  const presetNote = h("p", { class: "muted small" });
  const base = h("input", { class: "text-field", value: parts.base || "", placeholder: "homeassistant.local:8123", "aria-label": "Home Assistant Address" });
  const hookId = h("input", { class: "text-field", value: parts.webhookId || "", placeholder: "aurelia_movie_lights", "aria-label": "Webhook ID" });
  const url = h("input", { class: "text-field", value: draft.url, placeholder: "https://…", "aria-label": "Address" });
  const homeFields = h("div", { class: "settings-rows" },
    h("label", { class: "field" }, h("span", {}, "Home Assistant Address"), base,
      h("span", { class: "muted small" }, "As you open Home Assistant in a browser, for example homeassistant.local:8123.")),
    h("label", { class: "field" }, h("span", {}, "Webhook ID"), hookId,
      h("span", { class: "muted small" }, "The ID of the automation's Webhook trigger. Letters, digits, - and _.")));
  const genericFields = h("label", { class: "field" }, h("span", {}, "Address"), url,
    h("span", { class: "muted small" }, "Receives a signed JSON POST for each event. Use https:// outside your home network."));
  const events = checkboxList(overview.events.map((event) => ({ id: event.kind, title: event.title, detail: event.detail })), draft.events, "Events");
  const devices = checkboxList(overview.devices.map((device) => ({ id: device.id, title: device.name, detail: device.detail })), draft.deviceIds, "Devices");
  const profiles = checkboxList(overview.profiles.map((profile) => ({ id: profile.id, title: profile.name, detail: profile.detail })), draft.profileIds, "Profiles");
  const toggle = (checked, label, detail) => {
    const input = h("input", { type: "checkbox", checked, "aria-label": label });
    return { input, row: h("label", { class: "checkbox-row" }, input, h("span", {}, h("span", {}, label), h("span", { class: "muted small" }, detail))) };
  };
  const titles = toggle(draft.includeTitles !== false, "Send Titles and Profile Names", "Off sends only which device played, not what or who.");
  const children = toggle(Boolean(draft.excludeChildren), "Leave Out Children's Profiles", "Nothing is sent while a children's profile watches.");
  const enabled = toggle(draft.enabled !== false, "On", "Off keeps the webhook but sends nothing.");
  const problem = h("p", { class: "error-text", role: "alert" });
  const save = h("button", { type: "button", class: "primary-button" }, editing ? "Save" : "Add Webhook");
  const updatePreset = () => {
    const home = preset.value === "homeAssistant";
    homeFields.hidden = !home;
    genericFields.hidden = home;
    presetNote.textContent = AUTOMATION_PRESETS.find((choice) => choice.id === preset.value)?.detail ?? "";
  };
  preset.addEventListener("change", updatePreset);
  updatePreset();
  const form = () => ({
    name: name.value, preset: preset.value,
    url: preset.value === "homeAssistant" ? (homeAssistantUrl(base.value, hookId.value) ?? "") : url.value,
    events: events.values(), deviceIds: devices.values(), profileIds: profiles.values(),
    includeTitles: titles.input.checked, excludeChildren: children.input.checked, enabled: enabled.input.checked,
  });
  const dialog = sheet(editing ? `Edit “${draft.name}”` : "Add a Webhook",
    h("p", { class: "muted small" }, "Aurelia sends an event the moment it happens, such as a movie starting on the living room TV, so lights or scenes can follow."),
    h("label", { class: "field" }, h("span", {}, "Name"), name),
    h("label", { class: "field" }, h("span", {}, "Receiver"), preset, presetNote),
    homeFields, genericFields,
    h("h3", { class: "settings-subheading" }, "Events"), events.element,
    h("details", { class: "automation-filters" },
      h("summary", {}, "Only Some Devices or Profiles"),
      h("p", { class: "muted small" }, "With none chosen, events come from every device and profile."),
      h("h4", {}, "Devices"), devices.element,
      h("h4", {}, "Profiles"), profiles.element),
    h("h3", { class: "settings-subheading" }, "Privacy"), titles.row, children.row, enabled.row,
    problem,
    h("div", { class: "button-row end" }, h("button", { type: "button", class: "secondary-button", onclick: () => dialog.close() }, "Cancel"), save));
  save.addEventListener("click", async () => {
    const values = form();
    const text = preset.value === "homeAssistant" && !values.url ? "Enter Home Assistant's address and the webhook ID." : webhookFormProblem(values);
    problem.textContent = text ?? "";
    if (text) return;
    save.disabled = true;
    try {
      if (editing) {
        if (await unlocked(api, () => api.saveWebhook(webhook.id, webhookRequest(values))) === undefined) return;
        toast("Saved.");
      } else {
        const created = await unlocked(api, () => api.createWebhook(webhookRequest(values)));
        if (!created) return;
        showSecret(created.secret, created.webhook, toast);
      }
      dialog.close();
      onSaved();
    } catch (error) {
      problem.textContent = error.message;
    } finally {
      save.disabled = false;
    }
  });
}

function openDeliveries({ api, webhook, toast }) {
  const list = h("div", { class: "settings-card-list" }, h("p", { class: "muted small" }, "Loading…"));
  const dialog = sheet(`Deliveries of “${webhook.name}”`,
    h("p", { class: "muted small" }, "The last 100 deliveries of the past seven days, with how long the receiver took. The events themselves are not kept."),
    list, h("div", { class: "button-row end" }, h("button", { class: "primary-button", onclick: () => dialog.close() }, "Done")));
  api.webhookDeliveries(webhook.id).then((deliveries) => {
    clear(list);
    for (const delivery of deliveries) {
      const ok = delivery.state === "succeeded";
      list.append(h("div", { class: `settings-card small${ok ? "" : " security-failed"}` },
        h("div", { class: "settings-card-main" },
          h("div", { class: "settings-card-title" }, delivery.event),
          h("div", { class: "muted small" }, [
            ok ? "Delivered" : delivery.state === "pending" ? "Trying again" : "Failed",
            delivery.statusCode ? `HTTP ${delivery.statusCode}` : null,
            delivery.durationMilliseconds != null ? `${delivery.durationMilliseconds} ms` : null,
            delivery.attempt > 1 ? `attempt ${delivery.attempt}` : null,
            delivery.error,
          ].filter(Boolean).join(" · "))),
        h("div", { class: "muted small" }, when(delivery.at))));
    }
    if (!list.children.length) list.append(h("p", { class: "muted small" }, "Nothing sent yet."));
  }).catch((error) => toast(error.message));
}

function openTokenEditor({ api, onSaved, toast }) {
  const name = h("input", { class: "text-field", value: "Home Assistant", maxlength: 64, "aria-label": "Name" });
  const scopes = checkboxList(INTEGRATION_SCOPES, ["status"], "What the Key May Do");
  const problem = h("p", { class: "error-text", role: "alert" });
  const create = h("button", { type: "button", class: "primary-button" }, "Create Key");
  const dialog = sheet("Create a Key",
    h("p", { class: "muted small" }, "A key lets Home Assistant or a shortcut talk to Aurelia without a profile. It can do only what you allow here, and you can remove it any time."),
    h("label", { class: "field" }, h("span", {}, "Name"), name),
    h("h3", { class: "settings-subheading" }, "What the Key May Do"), scopes.element,
    problem,
    h("div", { class: "button-row end" }, h("button", { type: "button", class: "secondary-button", onclick: () => dialog.close() }, "Cancel"), create));
  create.addEventListener("click", async () => {
    if (!name.value.trim()) { problem.textContent = "Give the key a name."; return; }
    if (!scopes.values().length) { problem.textContent = "Choose what the key may do."; return; }
    create.disabled = true;
    try {
      const created = await unlocked(api, () => api.createIntegrationToken({ name: name.value.trim(), scopes: scopes.values() }));
      if (!created) return;
      dialog.close();
      onSaved();
      const shown = sheet("Key Created",
        h("p", {}, "Copy the key now: it is shown only once. Aurelia keeps only a fingerprint of it."),
        h("code", { class: "code-block" }, created.value),
        h("div", { class: "button-row" }, copyButton("Copy Key", created.value, toast)),
        h("p", { class: "muted small" }, "Send it as “Authorization: Bearer <key>”. docs/AUTOMATION.md shows sensors and buttons for Home Assistant."),
        h("div", { class: "button-row end" }, h("button", { class: "primary-button", onclick: () => shown.close() }, "Done")));
    } catch (error) {
      problem.textContent = error.message;
    } finally {
      create.disabled = false;
    }
  });
}

/**
 * The Smart Home page: what it is for, webhooks, keys, and turning the server on and off.
 * @param {object} kit  the settings page's section, row and value builders
 */
export function smartHomeSections({ api, app, kit, refresh }) {
  const { section, row, value } = kit;
  const hooks = h("div", { class: "settings-card-list" }, h("p", { class: "muted small" }, "Loading…"));
  const tokens = h("div", { class: "settings-card-list" });
  const power = h("div", { class: "settings-rows" });
  let overview = null;
  const run = async (work, done) => {
    try {
      const result = await unlocked(api, work);
      if (result === undefined && done) { refresh(); return; }
      if (done) app.toast(typeof done === "function" ? done(result) : done);
      refresh();
    } catch (error) {
      if (error?.code === "management_locked") app.toast("Unlock Server Management first, in Settings › Server.");
      else if (!app.handleError(error)) app.toast(error.message);
    }
  };
  const addHook = h("button", { type: "button", class: "primary-button", disabled: true,
    onclick: () => openWebhookEditor({ api, overview, onSaved: refresh, toast: app.toast }) }, "Add Webhook…");
  const addToken = h("button", { type: "button", class: "secondary-button", disabled: true,
    onclick: () => openTokenEditor({ api, onSaved: refresh, toast: app.toast }) }, "Create Key…");

  const sections = [
    section("Smart Home", "tv",
      "Aurelia tells Home Assistant and other automations the moment a movie starts, pauses or ends, or a new title arrives, so lights and scenes can follow. Home Assistant can also wake the server and turn it off.",
      h("h3", { class: "settings-subheading" }, "Webhooks"),
      h("p", { class: "muted small" }, "Each webhook gets the events you choose, signed so the receiver can check they came from your server."),
      hooks, h("div", { class: "button-row" }, addHook)),
    section("Keys for Home Assistant and Shortcuts", "lock",
      "For the other direction: Home Assistant reads what plays, or turns the server off, with a key you create here.",
      tokens, h("div", { class: "button-row" }, addToken)),
    section("Turning the Server On and Off", "power",
      "Home Assistant and every Aurelia app start the server with Wake-on-LAN, using the network card's address below.",
      power),
  ];

  (async () => {
    try {
      overview = await api.automationOverview();
    } catch (error) {
      clear(hooks);
      hooks.append(h("p", { class: "error-text" }, error.message));
      return;
    }
    addHook.disabled = false;
    addToken.disabled = false;
    clear(hooks);
    for (const hook of overview.webhooks) {
      const status = webhookStatus(hook);
      const eventTitles = hook.events.map((kind) => overview.events.find((event) => event.kind === kind)?.title ?? kind);
      hooks.append(h("div", { class: "settings-card automation-card" },
        h("div", { class: "settings-card-main" },
          h("div", { class: "settings-card-title" }, hook.name, h("span", { class: `tag tag-${status.tone}` }, status.text)),
          h("div", { class: "muted small" }, `${webhookHost(hook.url)} · ${eventTitles.join(", ")}`),
          hook.pausedReason ? h("div", { class: "error-text small" }, hook.pausedReason) : null),
        h("div", { class: "settings-card-actions" },
          h("button", { type: "button", class: "secondary-button", onclick: () => run(() => api.testWebhook(hook.id),
            (delivery) => delivery.state === "succeeded" ? `Delivered in ${delivery.durationMilliseconds} ms.` : `Not delivered: ${delivery.error ?? "no answer"}.`) }, "Send Test"),
          h("button", { type: "button", class: "secondary-button", onclick: () => openDeliveries({ api, webhook: hook, toast: app.toast }) }, "Deliveries…"),
          h("button", { type: "button", class: "secondary-button", onclick: () => openWebhookEditor({ api, overview, webhook: hook, onSaved: refresh, toast: app.toast }) }, "Edit…"),
          h("button", { type: "button", class: "secondary-button", onclick: () => run(async () => {
            const result = await api.rotateWebhookSecret(hook.id);
            showSecret(result.secret, hook, app.toast);
          }) }, "New Secret…"),
          h("button", { type: "button", class: "secondary-button danger", onclick: async () => {
            if (await confirm(`Remove “${hook.name}”?`, "It stops getting events at once. Your automation in Home Assistant stays.", "Remove"))
              run(() => api.deleteWebhook(hook.id), "Removed.");
          } }, "Remove…"))));
    }
    if (!overview.webhooks.length) {
      hooks.append(h("p", { class: "muted small" }, "No webhooks yet. Add one for Home Assistant: in Home Assistant create an automation with a Webhook trigger, then enter its ID here."));
    }
    clear(tokens);
    for (const token of overview.tokens) {
      tokens.append(h("div", { class: "settings-card" },
        h("div", { class: "settings-card-main" },
          h("div", { class: "settings-card-title" }, token.name),
          h("div", { class: "muted small" }, [
            token.scopes.map((scope) => INTEGRATION_SCOPES.find((item) => item.id === scope)?.title ?? scope).join(", "),
            `last used ${when(token.lastUsedAt)}`,
          ].join(" · "))),
        h("div", { class: "settings-card-actions" },
          h("button", { type: "button", class: "secondary-button danger", onclick: async () => {
            if (await confirm(`Remove the key “${token.name}”?`, "Whatever uses it stops working at once.", "Remove"))
              run(() => api.revokeIntegrationToken(token.id), "Removed.");
          } }, "Remove…"))));
    }
    if (!overview.tokens.length) tokens.append(h("p", { class: "muted small" }, "No keys yet."));
    clear(power);
    power.append(row("Network Card", value(overview.wakeOnLanAddresses.length ? overview.wakeOnLanAddresses.join(", ") : "Not reported"),
      overview.wakeOnLanAddresses.length
        ? "For Home Assistant's Wake on LAN integration (wake_on_lan.send_magic_packet) use this MAC address."
        : "This server doesn't report a network card that can be woken, for example when it runs in an app or a container."));
    for (const action of overview.powerActions) {
      const words = POWER_ACTIONS[action];
      power.append(row(words.title, h("button", { type: "button", class: action === "stop" ? "secondary-button" : "secondary-button danger", onclick: async () => {
        if (!await confirm(`${words.title}?`, words.detail, words.title)) return;
        try {
          const result = await unlocked(api, () => api.powerNow(action));
          if (result) app.toast(result.message);
        } catch (error) {
          if (error?.code === "playback_active" && await confirm("Someone is watching", "Turn it off anyway? Their playback stops.", words.title)) {
            run(() => api.powerNow(action, true), (result) => result.message);
          } else if (!app.handleError(error)) app.toast(error.message);
        }
      } }, words.title), words.detail));
    }
    if (!overview.powerActions.length) {
      power.append(h("p", { class: "muted small" }, "This server can't turn itself off; it runs as a service that something else starts and stops."));
    }
  })();
  return sections;
}
