/* [Lx]Ui helpers (tiny, no dependencies) */
window.UI = (function () {
  const $ = (s, r) => (r || document).querySelector(s);
  const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const fmt = n => { n = Math.round(+n || 0); return (n < 0 ? "-" : "") + String(Math.abs(n)).replace(/\B(?=(\d{3})+(?!\d))/g, ","); };
  const send = (name, ...a) => { try { mta.triggerEvent(name, ...a); } catch (e) {} };     // page -> client Lua
  const debounce = (fn, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };
  const raf2 = fn => requestAnimationFrame(() => requestAnimationFrame(fn));
  return { $, $$, el, fmt, send, debounce, raf2 };
})();
