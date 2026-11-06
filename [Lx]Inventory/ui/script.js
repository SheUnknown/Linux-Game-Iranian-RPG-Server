/* Inventory page. The server is the only source of truth: this page only renders what it is told and sends requests. */
(function () {
  "use strict";
  const $ = UI.$, SLOTS = 30;
  const ITEMS = window.ITEMS_UI = {};                       // filled by sync(): { name: {label, cat, weight, stack, desc, use} }
  const ICONS = {
    food:  '<path d="M4 12a8 6 0 0 1 16 0z"/><path d="M3 15h18"/><path d="M5 18h14"/>',
    drink: '<path d="M7 4h10l-1 16H8z"/><path d="M7.5 9h9"/>',
    med:   '<path d="M9 4h6v5h5v6h-5v5H9v-5H4V9h5z"/>',
    tool:  '<path d="M14 6a4 4 0 0 0-5 5l-6 6 3 3 6-6a4 4 0 0 0 5-5l-3 3-2-2z"/>',
    misc:  '<path d="M4 8l8-4 8 4v8l-8 4-8-4z"/><path d="M4 8l8 4 8-4"/><path d="M12 12v8"/>',
    doc:   '<path d="M7 3h8l4 4v14H7z"/><path d="M15 3v4h4"/>',
    key:   '<circle cx="8.5" cy="12" r="4"/><path d="M12.5 12H21M18 12v3"/>',
  };
  const svg = c => '<svg viewBox="0 0 24 24">' + (ICONS[c] || ICONS.misc) + '</svg>';

  let slots = [], sel = 0, qty = 1, maxW = 40, defs = null;
  const grid = $("#grid"), els = [];
  for (let i = 1; i <= SLOTS; i++) { const d = UI.el("div", "slot"); d.dataset.i = i; grid.appendChild(d); els[i] = d; }

  function paint(i) {
    const d = els[i], s = slots[i];
    d.className = "slot" + (s ? " has " + (defs[s.item] ? defs[s.item].cat : "misc") : "") + (sel === i ? " sel" : "");
    d.innerHTML = s ? '<div class="ic">' + svg(defs[s.item] ? defs[s.item].cat : "misc") + '</div>' + (s.count > 1 ? '<span class="n">' + s.count + '</span>' : "") : "";
  }
  function paintAll() { for (let i = 1; i <= SLOTS; i++) paint(i); detail(); }

  function detail() {
    const s = slots[sel];
    $("#empty").classList.toggle("u-hide", !!s); $("#info").classList.toggle("u-hide", !s);
    $("#people").classList.add("u-hide"); $("#confirm").classList.add("u-hide");
    if (!s) return;
    const d = defs[s.item] || { label: s.item, cat: "misc", weight: 0, desc: "" };
    const info = $("#info"); info.className = d.cat;
    info.style.animation = "none"; void info.offsetWidth; info.style.animation = "";
    $("#iIc").className = "ic big"; $("#iIc").innerHTML = svg(d.cat);
    $("#iName").textContent = d.label; $("#iDesc").textContent = d.desc;
    $("#iCnt").textContent = "x" + s.count; $("#iWt").textContent = (d.weight * s.count).toFixed(1) + " kg";
    $("#bUse").classList.toggle("u-hide", !d.use);
    qty = Math.min(Math.max(1, qty), s.count); $("#qVal").textContent = qty;
  }

  // ---- drag & drop with pointer events (HTML5 drag-and-drop is unreliable inside MTA's browser)
  const ghost = $("#ghost"); let drag = null;
  grid.addEventListener("mousedown", e => {
    const d = e.target.closest(".slot"); if (!d) return;
    const i = +d.dataset.i; if (e.button !== 0) return;
    drag = { i, x: e.clientX, y: e.clientY, on: false };
    if (slots[i]) { sel = i; qty = 1; paintAll(); }
  });
  window.addEventListener("mousemove", e => {
    if (!drag) return;
    if (!drag.on) {
      if (!slots[drag.i] || Math.abs(e.clientX - drag.x) + Math.abs(e.clientY - drag.y) < 6) return;
      drag.on = true; ghost.className = "slot has " + (defs[slots[drag.i].item] ? defs[slots[drag.i].item].cat : "misc");
      ghost.innerHTML = els[drag.i].innerHTML; els[drag.i].classList.add("drag");
    }
    ghost.style.transform = "translate3d(" + (e.clientX - 39) + "px," + (e.clientY - 39) + "px,0)";
    const t = document.elementFromPoint(e.clientX, e.clientY), s = t && t.closest(".slot");
    els.forEach(x => x && x.classList.remove("over")); if (s && s.dataset.i) s.classList.add("over");
  });
  window.addEventListener("mouseup", e => {
    if (!drag) return;
    const was = drag; drag = null; ghost.className = "slot u-hide"; els.forEach(x => x && x.classList.remove("over", "drag"));
    if (!was.on) return;
    const t = document.elementFromPoint(e.clientX, e.clientY), s = t && t.closest(".slot");
    const to = s && +s.dataset.i;
    if (to && to !== was.i) {
      const a = slots[was.i], b = slots[to];                       // optimistic: the server reply below corrects anything unexpected
      if (b && a.item === b.item) { const room = (defs[a.item].stack) - b.count, put = Math.min(room, a.count); b.count += put; a.count -= put; if (a.count <= 0) slots[was.i] = null; }
      else { slots[was.i] = b || null; slots[to] = a; }
      if (sel === was.i) sel = to; paintAll();
      UI.send("Lx:inv:ui:move", was.i, to);
    }
  });

  // ---- buttons
  $("#qMinus").onclick = () => { qty = Math.max(1, qty - 1); $("#qVal").textContent = qty; };
  $("#qPlus").onclick  = () => { const s = slots[sel]; if (s) { qty = Math.min(s.count, qty + 1); $("#qVal").textContent = qty; } };
  $("#qAll").onclick   = () => { const s = slots[sel]; if (s) { qty = s.count; $("#qVal").textContent = qty; } };
  $("#bUse").onclick   = () => { if (slots[sel]) UI.send("Lx:inv:ui:use", sel); };
  $("#bDrop").onclick  = () => { $("#people").classList.add("u-hide"); $("#cQty").textContent = qty + "x"; $("#confirm").classList.remove("u-hide"); };
  $("#cNo").onclick    = () => $("#confirm").classList.add("u-hide");
  $("#cYes").onclick   = () => { UI.send("Lx:inv:ui:drop", sel, qty); $("#confirm").classList.add("u-hide"); };
  $("#bGive").onclick  = () => { $("#confirm").classList.add("u-hide"); const p = $("#people"); p.textContent = "Searching…"; p.classList.remove("u-hide"); UI.send("Lx:inv:ui:nearby"); };
  $("#closeBtn").onclick = () => UI.send("Lx:inv:ui:close");
  window.addEventListener("keydown", e => { if (e.key === "Escape" || e.key.toLowerCase() === "i") UI.send("Lx:inv:ui:close"); });

  window.INV = {
    show(on) { document.body.classList.toggle("on", !!on); if (!on) { sel = 0; qty = 1; } },
    sync(list, used, max) {
      if (!defs) defs = window.ITEM_DEFS || {};
      list = Array.isArray(list) ? list : Object.values(list || {});       // MTA's toJSON turns an empty table into {}
      slots = []; list.forEach(r => slots[r.slot] = { item: r.item, count: r.count });
      if (sel && !slots[sel]) sel = 0;
      maxW = max; $("#wUsed").textContent = used.toFixed(1); $("#wMax").textContent = max;
      $("#wBar").style.transform = "scaleX(" + Math.min(1, used / max) + ")";
      paintAll();
    },
    nearby(list) {
      const p = $("#people"); p.textContent = "";
      list = Array.isArray(list) ? list : Object.values(list || {});
      if (!list.length) { p.textContent = "Nobody is close enough."; return; }
      list.forEach((x, idx) => { const b = UI.el("button", "", x.name); b.onclick = () => { UI.send("Lx:inv:ui:give", sel, qty, idx); p.classList.add("u-hide"); }; p.appendChild(b); });
    },
  };
})();
