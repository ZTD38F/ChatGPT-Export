const $ = (id) => document.getElementById(id);
const admin = $("admin");
admin.value = localStorage.getItem("chatgptExportAdminToken") || "";

function token() {
  return localStorage.getItem("chatgptExportAdminToken") || admin.value.trim() || "";
}
function headers() { return {"X-Admin-Token": token()}; }
function setText(id, value) { $(id).textContent = value == null ? "—" : String(value); }
function setPill(el, text, kind="neutral") { el.textContent = text; el.className = `pill ${kind}`; }

async function api(path, options={}) {
  const res = await fetch(path, {...options, headers: {...headers(), ...(options.headers||{})}});
  const data = await res.json().catch(() => ({detail:`HTTP ${res.status}`}));
  if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
  return data;
}

function renderStatus(data) {
  $("status").textContent = JSON.stringify(data, null, 2);
  setPill($("admin-state"), "Admin connected", "good");
  const job = data.latest;
  if (!job) {
    setText("job-state", data.connected ? "Ready to export" : "No export yet");
    setText("phase", data.session_error || (data.connected ? "Session stored." : "Connect a ChatGPT session to begin."));
    $("progress-bar").style.width = "0%";
    return;
  }
  const p = job.progress || {};
  const expected = Number(p.conversations_expected || 0);
  const verified = Number(p.conversations_verified || 0);
  const assetExpected = Number(p.assets_expected || 0);
  const assetVerified = Number(p.assets_verified || 0);
  const pct = expected > 0 ? Math.min(100, Math.round((verified / expected) * 100)) : (job.status === "COMPLETE" ? 100 : 0);
  $("progress-bar").style.width = `${pct}%`;
  setText("job-state", job.status || "UNKNOWN");
  setText("phase", String(p.phase || "waiting").replaceAll("_", " "));
  setText("m-chats", `${verified} / ${expected || "?"}`);
  setText("m-projects", p.projects ?? 0);
  setText("m-assets", `${assetVerified} / ${assetExpected || 0}`);
  setText("m-workspaces", p.workspaces ?? 0);
  setText("m-errors", p.errors ?? 0);
  const notice = $("notice");
  if (job.status === "COMPLETE") {
    notice.textContent = "Verified complete for every currently supported web-accessible scope.";
    notice.className = "notice good-text";
  } else if (job.status === "AUTH_REQUIRED") {
    notice.textContent = "ChatGPT authentication expired. Paste a fresh /api/auth/session JSON; the next run resumes durable progress.";
    notice.className = "notice warning";
  } else if (["PARTIAL", "FAILED", "INTERRUPTED"].includes(job.status)) {
    notice.textContent = "The run is not verified complete. Open Technical details before treating this backup as finished.";
    notice.className = "notice warning";
  } else {
    notice.textContent = data.active ? "Export is running in the background. You may close this tab." : "";
    notice.className = "notice";
  }
  if (data.session_error) {
    notice.textContent = data.session_error;
    notice.className = "notice warning";
  }
}

$("save-admin").onclick = async () => {
  localStorage.setItem("chatgptExportAdminToken", admin.value.trim());
  await loadStatus();
};

$("connect").onclick = async () => {
  try {
    const raw = $("session").value.trim();
    if (!raw) throw new Error("Paste the complete /api/auth/session JSON first.");
    const parsed = JSON.parse(raw);
    setText("notice", "Verifying ChatGPT session…");
    const data = await api("/api/session", {method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(parsed)});
    $("session").value = "";
    $("notice").textContent = `${data.message} Workspaces: ${data.workspaces}.`;
    await loadStatus();
  } catch (e) { $("notice").textContent = `ERROR: ${e.message}`; $("notice").className = "notice warning"; }
};

$("resume").onclick = async () => {
  try { await api("/api/export", {method:"POST"}); await loadStatus(); }
  catch (e) { $("notice").textContent = `ERROR: ${e.message}`; $("notice").className = "notice warning"; }
};

$("disconnect").onclick = async () => {
  try { await api("/api/session", {method:"DELETE"}); $("session").value = ""; await loadStatus(); }
  catch (e) { $("notice").textContent = `ERROR: ${e.message}`; $("notice").className = "notice warning"; }
};

$("refresh").onclick = loadStatus;

async function loadStatus() {
  if (!token()) { setPill($("admin-state"), "Not connected", "neutral"); return; }
  try { renderStatus(await api("/api/status")); }
  catch (e) {
    setPill($("admin-state"), "Access failed", "bad");
    $("status").textContent = `STATUS ERROR: ${e.message}`;
    $("notice").textContent = "Check the admin token.";
    $("notice").className = "notice warning";
  }
}

async function health() {
  try {
    const res = await fetch("/healthz"); const data = await res.json();
    setPill($("health"), data.ok ? "Service healthy" : "Service problem", data.ok ? "good" : "bad");
  } catch { setPill($("health"), "Offline", "bad"); }
}

health();
if (admin.value) loadStatus();
setInterval(() => { if (token()) loadStatus(); }, 5000);
