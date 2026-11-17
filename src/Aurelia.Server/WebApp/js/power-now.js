// Sleep, Turn Off or Stop Now for the owner, in Settings › Power ("power-now-v1"). Servers from
// 2.16.0 to 2.22 offered the same under "automation-v1" (Smart Home, since removed).

export const POWER_NOW_CAPABILITIES = Object.freeze(["power-now-v1", "automation-v1"]);

/** Whether this server can be told to sleep, turn off or stop now. */
export function supportsPowerNow(capabilities) {
  return Array.isArray(capabilities) && POWER_NOW_CAPABILITIES.some((name) => capabilities.includes(name));
}

/** The address that lists what the server can do now; older servers list it in their Smart Home overview. */
export function powerNowOptionsPath(capabilities) {
  return Array.isArray(capabilities) && capabilities.includes("power-now-v1")
    ? "/api/v1/server/power/now"
    : "/api/v1/server/automation";
}

/** The actions a server answered with, in its order, without ones the browser has no words for. */
export function powerNowActions(answer) {
  const listed = answer?.actions ?? answer?.powerActions ?? [];
  return listed.filter((action) => Object.hasOwn(POWER_ACTIONS, action));
}

export const POWER_ACTIONS = Object.freeze({
  sleep: { title: "Sleep Now", detail: "The computer sleeps; Wake-on-LAN wakes it in about 10 to 20 seconds." },
  shutdown: { title: "Turn Off Now", detail: "The computer turns off; Wake-on-LAN starts it in about 30 to 60 seconds." },
  stop: { title: "Stop Aurelia Now", detail: "Only Aurelia Server stops." },
});
