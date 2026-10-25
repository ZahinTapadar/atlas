// ATLAS Activity Bridge — sends the *active* tab's URL and title to the local ATLAS helper
// whenever it changes. No page content, form data, history or keystrokes are read.
// Incognito tabs are flagged so ATLAS can drop them unless the user opted in.

const HOST = "com.atlas.tracker.nm";
let port = null;
let last = "";

function family() {
  const brands = (navigator.userAgentData && navigator.userAgentData.brands || []).map(b => b.brand.toLowerCase());
  if (brands.some(b => b.includes("edge"))) return "edge";
  if (brands.some(b => b.includes("brave"))) return "brave";
  if (brands.some(b => b.includes("opera"))) return "opera";
  if (brands.some(b => b.includes("vivaldi"))) return "vivaldi";
  if (navigator.userAgent.includes("Arc/")) return "arc";
  return "chrome";
}

function connect() {
  try {
    port = chrome.runtime.connectNative(HOST);
    port.onDisconnect.addListener(() => { port = null; });
  } catch (e) { port = null; }
}

function send(msg) {
  if (!port) connect();
  if (!port) return; // ATLAS helper not installed: fail quietly, never break browsing.
  try { port.postMessage(msg); } catch (e) { port = null; }
}

async function report(reason) {
  let tab;
  try {
    const [t] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    tab = t;
  } catch (e) { return; }
  const win = tab ? await chrome.windows.get(tab.windowId).catch(() => null) : null;
  const msg = {
    v: 1, type: "tab", ts: Date.now() / 1000, family: family(),
    url: tab && /^https?:/.test(tab.url || "") ? tab.url : null,
    title: tab && /^https?:/.test(tab.url || "") ? (tab.title || null) : null,
    incognito: !!(tab && tab.incognito),
    audible: !!(tab && tab.audible),
    focused: !!(win && win.focused)
  };
  const key = JSON.stringify([msg.url, msg.title, msg.audible, msg.focused, msg.incognito]);
  if (key === last && reason !== "heartbeat") return;
  last = key;
  send(msg);
}

chrome.tabs.onActivated.addListener(() => report("activated"));
chrome.tabs.onUpdated.addListener((id, info, tab) => {
  if (tab.active && (info.title || info.url || "audible" in info)) report("updated");
});
chrome.windows.onFocusChanged.addListener(() => report("focus"));
chrome.idle.onStateChanged.addListener(() => report("idle"));
chrome.runtime.onStartup.addListener(() => report("startup"));
chrome.runtime.onInstalled.addListener(() => report("installed"));
