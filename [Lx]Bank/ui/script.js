/* Bank page. Display + requests only: every number is re-sent by the server after each action. */
(function () {
  "use strict";
  const $ = UI.$, TABS = ["deposit", "withdraw", "transfer", "history"];
  let cash = 0, bank = 0, fee = 0, maxT = 0, tab = "deposit", busy = false;
  const money = n => "$" + UI.fmt(n);

  function countTo(el, from, to) {                              // animated number: text only changes (no layout-heavy effects)
    const t0 = performance.now(), d = 550;
    (function step(t) {
      const k = Math.min(1, (t - t0) / d), e = 1 - Math.pow(1 - k, 3);
      el.textContent = money(from + (to - from) * e);
      if (k < 1) requestAnimationFrame(step);
    })(t0);
  }
  function setBal(c, b, animate) {
    if (animate) { countTo($("#cash"), cash, c); countTo($("#bank"), bank, b); }
    else { $("#cash").textContent = money(c); $("#bank").textContent = money(b); }
    cash = c; bank = b;
  }
  function setTab(t) {
    tab = t;
    UI.$$("#tabs button").forEach(b => b.classList.toggle("on", b.dataset.t === t));
    $("#ink").style.transform = "translateX(" + TABS.indexOf(t) * 100 + "%)";
    const h = t === "history";
    $("#form").classList.toggle("u-hide", h); $("#hist").classList.toggle("u-hide", !h);
    $("#targetRow").classList.toggle("u-hide", t !== "transfer");
    $("#go").textContent = t === "deposit" ? "Deposit" : t === "withdraw" ? "Withdraw" : "Send money";
    $("#note").textContent = t === "transfer" ? "Fee " + fee + "% paid by you  ·  max " + money(maxT) + " per transfer" : t === "deposit" ? "Cash in hand: " + money(cash) : t === "withdraw" ? "In the bank: " + money(bank) : "";
    flash("");
    if (h) { $("#hlist").innerHTML = '<div class="empty">Loading…</div>'; UI.send("Lx:bank:ui:history"); }
  }
  function flash(text, ok) { const m = $("#msg"); m.className = text ? (ok ? "show ok" : "show bad") : ""; m.textContent = text || ""; }
  const amountVal = () => parseInt($("#amount").value.replace(/\D/g, ""), 10) || 0;

  $("#amount").addEventListener("input", e => { const n = e.target.value.replace(/\D/g, ""); e.target.value = n ? UI.fmt(+n) : ""; });
  UI.$$(".chips button").forEach(b => b.onclick = () => {
    const v = b.dataset.v === "max" ? (tab === "deposit" ? cash : bank) : +b.dataset.v;
    $("#amount").value = v ? UI.fmt(v) : "";
  });
  UI.$$("#tabs button").forEach(b => b.onclick = () => setTab(b.dataset.t));
  $("#closeBtn").onclick = () => UI.send("Lx:bank:ui:close");
  $("#go").onclick = () => {
    if (busy) return; const a = amountVal();
    if (!a) return flash("Enter an amount.", false);
    if (tab === "transfer" && !$("#target").value.trim()) return flash("Enter the receiver's name.", false);
    busy = true; $("#go").setAttribute("disabled", ""); UI.send("Lx:bank:ui:do", tab, a, $("#target").value.trim());
    setTimeout(() => { busy = false; $("#go").removeAttribute("disabled"); }, 1500);          // safety if a reply is lost
  };
  window.addEventListener("keydown", e => { if (e.key === "Enter" && tab !== "history") $("#go").click(); });

  window.B = {
    show(on) { document.body.classList.toggle("on", !!on); if (!on) flash(""); },
    open(c, b, f, m) { fee = f; maxT = m; setBal(c, b, false); $("#amount").value = ""; setTab("deposit"); this.show(true); setTimeout(() => $("#amount").focus(), 380); },
    result(ok, msg, c, b) {
      busy = false; $("#go").removeAttribute("disabled");
      flash(Array.isArray(msg) ? msg[0] : msg, ok); setBal(c, b, true);
      if (ok) $("#amount").value = "";
      setTab(tab === "history" ? "history" : tab); flash(Array.isArray(msg) ? msg[0] : msg, ok);
    },
    history(list) {
      list = Array.isArray(list) ? list : Object.values(list || {});
      const box = $("#hlist"); box.textContent = "";
      if (!list.length) { box.innerHTML = '<div class="empty">No transactions yet.</div>'; return; }
      list.forEach((t, i) => {
        const inn = t.kind === "deposit" || t.kind === "received" || t.kind === "credit";
        const d = new Date(t.ts * 1000), row = UI.el("div", "row"); row.style.setProperty("--i", Math.min(i, 12));
        const l = UI.el("div", "l"); l.appendChild(UI.el("span", "k", t.kind));
        l.appendChild(UI.el("span", "i", (t.info ? t.info + " · " : "") + d.toLocaleDateString() + " " + d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })));
        row.appendChild(l); row.appendChild(UI.el("span", "a " + (inn ? "pos" : "neg"), (inn ? "+" : "-") + money(t.amount)));
        box.appendChild(row);
      });
    },
  };
})();
