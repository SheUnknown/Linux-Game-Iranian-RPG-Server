/* Admin page: shows what the server sends, asks for actions. Rank / hierarchy / target checks are all done by the server. */
(function () {
  "use strict";
  const $ = UI.$, TABS = ["players", "bans", "announce"];
  let list = [], rank = 0, selId = 0, tab = "players", pend = null;
  const NAMES = { 1: "Moderator", 2: "Admin", 3: "Head Admin", 4: "Owner" };

  function setTab(t) {
    tab = t; const idx = TABS.indexOf(t);
    UI.$$("#tabs button").forEach((b, i) => b.classList.toggle("on", i === idx));
    const b = UI.$$("#tabs button")[idx]; $("#ink").style.width = b.offsetWidth + "px"; $("#ink").style.transform = "translateX(" + b.offsetLeft + "px)";
    $("#pPlayers").classList.toggle("u-hide", t !== "players"); $("#pBans").classList.toggle("u-hide", t !== "bans"); $("#pAnn").classList.toggle("u-hide", t !== "announce");
    if (t === "bans") { $("#blist").innerHTML = '<div class="empty">Loading…</div>'; UI.send("Lx:admin:ui:bans"); }
  }
  UI.$$("#tabs button").forEach((b, i) => b.onclick = () => setTab(TABS[i]));
  $("#closeBtn").onclick = () => UI.send("Lx:admin:ui:close");

  function drawList() {
    const q = $("#q").value.trim().toLowerCase(), box = $("#plist"); box.textContent = "";
    list.forEach((p, i) => {
      if (q && !(p.name.toLowerCase().includes(q) || String(p.id) === q)) return;
      const d = UI.el("div", "p" + (p.id === selId ? " on" : "")); d.dataset.i = i;
      d.appendChild(UI.el("span", "id", "#" + p.id));
      const n = UI.el("span", "n", p.name);
      if (p.rank > 0) n.appendChild(UI.el("span", "tag", NAMES[p.rank].toUpperCase()));
      if (p.muted) n.appendChild(UI.el("span", "tag m", "MUTED"));
      d.appendChild(n); d.appendChild(UI.el("span", "ping", p.ping + " ms"));
      d.onclick = () => { selId = p.id; pend = null; $("#confirm").classList.add("u-hide"); drawList(); drawSel(); };
      box.appendChild(d);
    });
  }
  function drawSel() {
    const p = list.find(x => x.id === selId);
    $("#none").classList.toggle("u-hide", !!p); $("#sel").classList.toggle("u-hide", !p);
    if (!p) return;
    $("#sName").textContent = p.name; $("#sMeta").textContent = "ID " + p.id + "  ·  " + p.hp + " HP  ·  " + p.ping + " ms";
    UI.$$(".grid button").forEach(b => { const a = b.dataset.a; b.disabled = (a === "ban" && rank < 2) || (p.rank >= rank && p.id !== myId()); });
  }
  const myId = () => -1;

  function send(action) {
    const p = list.find(x => x.id === selId); if (!p) return;
    const idx = list.indexOf(p);
    UI.send("Lx:admin:ui:do", action, idx, p.id, $("#reason").value.trim(), parseInt($("#mins").value, 10) || 0);
  }
  UI.$$(".grid button").forEach(b => b.onclick = () => {
    const a = b.dataset.a;
    if (a === "kick" || a === "ban") {                          // destructive actions need a second click
      pend = a; $("#cText").textContent = (a === "ban" ? "Ban " : "Kick ") + $("#sName").textContent + "?"; $("#confirm").classList.remove("u-hide");
    } else send(a);
  });
  $("#cYes").onclick = () => { if (pend) send(pend); pend = null; $("#confirm").classList.add("u-hide"); };
  $("#cNo").onclick = () => { pend = null; $("#confirm").classList.add("u-hide"); };
  $("#q").addEventListener("input", drawList);
  $("#annGo").onclick = () => { const t = $("#ann").value.trim(); if (t) { UI.send("Lx:admin:ui:do", "announce", -1, 0, t, 0); $("#ann").value = ""; } };

  window.A = {
    show(on) { document.body.classList.toggle("on", !!on); if (on) { selId = 0; setTab("players"); $("#q").value = ""; setTimeout(() => $("#q").focus(), 380); } },
    list(l, r) {
      list = Array.isArray(l) ? l : Object.values(l || {}); rank = r;
      $("#rankLbl").textContent = NAMES[r] || "Staff";
      $("#tabs button[data-t=announce]").style.display = r >= 2 ? "" : "none";
      drawList(); drawSel();
    },
    bans(l) {
      l = Array.isArray(l) ? l : Object.values(l || {}); const box = $("#blist"); box.textContent = "";
      if (!l.length) { box.innerHTML = '<div class="empty">No active bans.</div>'; return; }
      l.forEach(b => {
        const row = UI.el("div", "b"), t = UI.el("div", "t");
        t.appendChild(UI.el("b", "", "#" + b.id + "  " + b.reason));
        t.appendChild(UI.el("span", "", "by " + b.by + "  ·  " + (b.expires ? "until " + new Date(b.expires * 1000).toLocaleString() : "permanent")));
        row.appendChild(t);
        if (rank >= 3) { const u = UI.el("button", "u-btn ghost sm", "Unban"); u.onclick = () => { UI.send("Lx:admin:ui:unban", b.id); u.disabled = true; setTimeout(() => UI.send("Lx:admin:ui:bans"), 700); }; row.appendChild(u); }
        box.appendChild(row);
      });
    },
  };
})();
