/* Toast manager. Rules: only transform/opacity change; each toast has a fixed slot (translateY) that is recomputed
   when the stack changes; identical messages are merged into one toast with a counter. */
(function () {
  "use strict";
  const MAX = 5, GAP = 10, stack = document.getElementById("stack");
  const ICONS = {
    success: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    error:   '<path d="M6 6l12 12M18 6L6 18"/>',
    warning: '<path d="M12 4l9 16H3z"/><path d="M12 10v4M12 17.5v.01"/>',
    info:    '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8v.01"/>',
    money:   '<circle cx="12" cy="12" r="9"/><path d="M14.5 9.2c-.5-.8-1.4-1.2-2.5-1.2-1.5 0-2.5.8-2.5 1.9 0 2.7 5.2 1.3 5.2 4 0 1.1-1.1 1.9-2.7 1.9-1.1 0-2.1-.5-2.7-1.3M12 6.5V8M12 16v1.5"/>',
  };
  const items = [];            // oldest first
  let alive = 0;

  const report = () => { try { mta.triggerEvent("Lx:notification:count", alive); } catch (e) {} };

  function layout() {
    let y = 0;
    for (const it of items) {
      if (it.dying) continue;
      it.y = y;
      it.el.style.transform = "translate3d(0," + y + "px,0)";
      y += it.el.offsetHeight + GAP;
    }
  }

  function kill(it) {
    if (it.dying) return;
    it.dying = true; clearTimeout(it.timer);
    it.el.classList.remove("show"); it.el.classList.add("out");
    it.el.style.transform = "translate3d(0," + (it.y - 12) + "px,0)";
    layout();
    setTimeout(() => {
      it.el.remove(); items.splice(items.indexOf(it), 1);
      alive = items.length; report();
    }, 340);
  }

  function arm(it, ms) {
    clearTimeout(it.timer);
    const bar = it.el.querySelector(".pg");
    bar.style.transition = "none"; bar.style.transform = "scaleX(1)";
    void bar.offsetWidth;                                      // restart the bar
    bar.style.transition = "transform " + ms + "ms linear"; bar.style.transform = "scaleX(0)";
    it.timer = setTimeout(() => kill(it), ms);
  }

  window.N = {
    add(kind, title, text, ms) {
      kind = ICONS[kind] ? kind : "info"; ms = Math.max(1500, Math.min(+ms || 4500, 15000));
      const same = items.find(i => !i.dying && i.key === kind + "|" + title + "|" + text);
      if (same) {                                               // merge duplicates: counter + restart timer
        same.n++; same.el.querySelector(".cn").textContent = "×" + same.n; arm(same, ms); return;
      }
      while (items.filter(i => !i.dying).length >= MAX) kill(items.find(i => !i.dying));

      const el = document.createElement("div");
      el.className = "t " + kind;
      el.innerHTML = '<div class="ic"><svg viewBox="0 0 24 24">' + ICONS[kind] + '</svg></div>' +
        '<div class="tx"><div class="ti"></div><div class="bd"></div></div><div class="cn"></div><div class="pg"></div>';
      el.querySelector(".ti").textContent = title;              // textContent only: no HTML injection possible
      el.querySelector(".bd").textContent = text;
      stack.appendChild(el);

      const it = { el, key: kind + "|" + title + "|" + text, n: 1, y: 0, dying: false, timer: 0 };
      items.push(it); alive = items.length; report();
      // start slightly above its slot, then glide in
      let y = 0; for (const o of items) if (o !== it && !o.dying) y += o.el.offsetHeight + GAP;
      it.y = y; el.style.transform = "translate3d(0," + (y - 14) + "px,0) scale(.97)";
      void el.offsetWidth;
      el.classList.add("show"); layout(); arm(it, ms);
    },
  };
})();
