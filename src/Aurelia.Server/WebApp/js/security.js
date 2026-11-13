// Security ("security-v1"): words for the security log, the owner's new-device notes and the
// "Confirm on another device" unlock. No DOM here, so node tests can check it.

export const SECURITY_CAPABILITY = "security-v1";

export function supportsSecurity(server) {
  return Boolean(server?.capabilities?.includes(SECURITY_CAPABILITY));
}

const KINDS = {
  signed_in: "Signed in",
  profile_opened: "Opened profile",
  management_unlocked: "Unlocked management",
  wrong_password: "Wrong Server Password",
  wrong_pin: "Wrong profile PIN",
  wrong_code: "Wrong device code",
  locked_out: "Paused after wrong attempts",
  blocked_device_refused: "Blocked device refused",
  passkey_failed: "Face ID or Touch ID not confirmed",
  password_refused: "Server Password refused (Face ID required)",
  library_added: "Storage location added",
  library_removed: "Storage location removed",
  library_reset: "Library reset",
  title_removed: "Title removed",
  profile_created: "Profile created",
  profile_changed: "Profile changed",
  profile_deleted: "Profile deleted",
  pin_reset: "PIN replaced",
  password_reset: "Password replaced",
  role_changed: "Role changed",
  screen_time_changed: "Screen time changed",
  devices_signed_out: "Devices signed out",
  device_signed_out: "Device signed out",
  device_code_created: "Device code created",
  device_approved: "Device allowed",
  device_blocked: "Device blocked",
  device_unblocked: "Device unblocked",
  settings_changed: "Server settings changed",
  network_changed: "Network changed",
  server_restarted: "Server restarted",
  power_changed: "Power settings changed",
  backup_restored: "Backup restored",
  backup_exported: "Encrypted backup saved",
  update_installed: "Server update installed",
  metadata_changed: "Metadata settings changed",
  passkey_added: "Face ID or Touch ID set up",
  passkey_removed: "Face ID or Touch ID removed",
  passkey_requirement_changed: "Face ID requirement changed",
  security_settings_changed: "Security settings changed",
  remote_unlock_approved: "Unlock confirmed for another device",
  remote_unlock_denied: "Unlock denied for another device",
};

/** "Storage location removed"; an unknown kind from a newer server is shown, not dropped. */
export function securityKind(kind) {
  const known = KINDS[kind];
  if (known) return known;
  return String(kind ?? "").split("_").filter(Boolean).map((word) => word[0].toUpperCase() + word.slice(1)).join(" ");
}

/** "iOS · 192.168.1.40", or "" when the server knows neither. */
export function securityDeviceLine(platform, ipAddress) {
  return [platform, ipAddress].filter((part) => part).join(" · ");
}

/** The words for one log entry: what happened, and who, where and with what. */
export function securityEventText(event) {
  return {
    title: securityKind(event?.kind) + (event?.detail ? ` · ${event.detail}` : ""),
    subtitle: [event?.userName, event?.deviceName, securityDeviceLine(event?.platform, event?.ipAddress)].filter((part) => part).join(" · "),
    failed: event?.outcome === "failed",
  };
}

export const SECURITY_LOG_FILTERS = [
  ["all", "All"],
  ["succeeded", "Sign-Ins"],
  ["failed", "Failed"],
  ["changed", "Changes"],
];

/** The log's query string for one page: a filter and the time before which to continue. */
export function securityEventsQuery({ outcome = "all", before = null, limit = 50 } = {}) {
  const query = new URLSearchParams();
  if (outcome && outcome !== "all") query.set("outcome", outcome);
  if (before) query.set("before", before);
  query.set("limit", String(limit));
  return query.toString();
}

/** The note about a device that signed in for the first time. */
export function newDeviceNote(device) {
  const line = securityDeviceLine(device?.platform, device?.ipAddress);
  return `New device signed in: ${device?.deviceName ?? "Unknown device"}${line ? ` · ${line}` : ""}`;
}

/** Only new devices the person hasn't answered here yet. */
export function unansweredDevices(devices, answered) {
  return (devices ?? []).filter((device) => !answered.has(device.id));
}

/**
 * What the browser shows while it waits for an iPhone or Mac with Face ID or Touch ID to confirm.
 * @returns {{ text: string, done: boolean, unlocked: boolean }}
 */
export function remoteUnlockState(status) {
  switch (status?.state) {
    case "approved":
      return { text: "Confirmed. Server management is unlocked for ten minutes.", done: true, unlocked: true };
    case "denied":
      return { text: "The request was denied on the other device.", done: true, unlocked: false };
    case "expired":
      return { text: "The request expired. Ask again.", done: true, unlocked: false };
    default:
      return { text: "Waiting for confirmation on an iPhone, iPad or Mac with Face ID or Touch ID…", done: false, unlocked: false };
  }
}
