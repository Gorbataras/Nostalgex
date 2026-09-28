// Shared snapshot status bar. Inject by adding <div id="snapshot-bar"></div>
// at the top of the .shell and including this script.

(async function () {
  const el = document.getElementById("snapshot-bar");
  if (!el) return;

  function ago(ts) {
    if (!ts) return "";
    const diff = Math.floor(Date.now() / 1000 - ts);
    if (diff < 60) return `${diff}s ago`;
    if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
    if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
    return `${Math.floor(diff / 86400)}d ago`;
  }

  async function render() {
    try {
      const r = await fetch("/api/snapshot");
      const data = await r.json();
      const snap = data.snapshot;
      if (snap) {
        el.className = "snapshot-bar has-snap";
        el.innerHTML = `
          <div>
            <span class="label">SNAPSHOT MODE</span>
            <span class="meta" style="margin-left:14px">${escapeHtml(snap.deviceName || "?")}</span>
            <span class="age">· ${snap.totalChannels} channels · ${snap.totalItems.toLocaleString()} items · captured ${ago(snap.generatedAt)} · received ${ago(snap.savedAt)}${snap.appVersion ? ` · v${escapeHtml(snap.appVersion)}` : ""}</span>
          </div>
          <div class="actions">
            <button type="button" id="snap-refresh">REFRESH</button>
            <button type="button" id="snap-clear">CLEAR · USE LIVE</button>
          </div>`;
        document.getElementById("snap-refresh").addEventListener("click", render);
        document.getElementById("snap-clear").addEventListener("click", async () => {
          if (!confirm("Delete the stored snapshot? This overwrites scripts/devtools/snapshot.json and cannot be undone. Rebuilding it needs PLEX_URL and PLEX_TOKEN (npm run snapshot). Continue?")) return;
          await fetch("/api/snapshot/clear", { method: "POST" });
          location.reload();
        });
      } else {
        el.className = "snapshot-bar no-snap";
        el.innerHTML = `
          <div>
            <span class="label">LIVE MODE</span>
            <span class="age">· no snapshot uploaded yet · data comes from live Plex queries (may drift from app)</span>
          </div>
          <div class="actions">
            <span class="age">Build one: <span class="code">npm run snapshot</span> (needs PLEX_URL + PLEX_TOKEN in .env)</span>
          </div>`;
      }
    } catch (e) {
      el.style.display = "none";
    }
  }

  function escapeHtml(s) { return String(s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"})[c]); }
  render();
})();
