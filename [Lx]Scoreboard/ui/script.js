(function () {
  "use strict";
  const $ = UI.$, rows = $("#rows"), pool = [];                 // row elements are reused: no DOM churn once per second
  const RANK = { 1: "MOD", 2: "ADMIN", 3: "HEAD", 4: "OWNER" };
  window.S = {
    show(on) { document.body.classList.toggle("on", !!on); },
    update(list, max) {
      list = Array.isArray(list) ? list : Object.values(list || {});
      $("#cnt").textContent = list.length + " / " + max;
      while (pool.length < list.length) {
        const r = UI.el("div", "r"), id = UI.el("span", "id"), n = UI.el("span", "n"), p = UI.el("span", "p");
        r.append(id, n, p); r._f = { id, n, p }; pool.push(r); rows.appendChild(r);
      }
      pool.forEach((r, i) => {
        const x = list[i]; r.style.display = x ? "" : "none"; if (!x) return;
        r.className = "r" + (x.me ? " me" : ""); r._f.id.textContent = "#" + x.id; r._f.p.textContent = x.ping + " ms";
        r._f.n.textContent = x.name; if (x.rank > 0) r._f.n.appendChild(UI.el("span", "tag", RANK[x.rank]));
      });
    },
  };
})();
