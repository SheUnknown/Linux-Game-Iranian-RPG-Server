/* =====================================================================
   LINUX Game - [Lx]Radar | map.js   (F11 map : UI layer only)
   The map itself (image, grid, blips, waypoint, player) is drawn natively
   by client.lua at full frame rate. This page only holds the UI chrome
   (header, tools, side drawer) and is repainted only when the UI changes.
   Lua calls:  RM.init(cfg, names)  RM.cfg(cfg)  RM.open(bool)
               RM.p(x,y,wpDist)  RM.i(cell,x,y,dist)  RM.g(rows)
               RM.wp(x,y | null)  RM.toast(text)
   ===================================================================== */
(function () {
'use strict';

const $  = (s, r) => (r || document).querySelector(s);
const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
const h  = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; };
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const root = document.documentElement;
const send = (...a) => { try { if (window.mta) mta.triggerEvent(...a); } catch (e) {} };
const p2 = n => (n < 10 ? '0' : '') + n;
const fmtDist = d => (d >= 1000 ? (d / 1000).toFixed(1) + ' km' : Math.round(d) + ' m');

/* ---------------------------------------------------------------- state */
let W = innerWidth, H = innerHeight, vs = 1;
let open = false, wp = null, wd = -1;
let cfg = { shape: 'rounded', size: 260, pos: 'bl', ox: 28, oy: 28, zoom: 320, rotate: 1, auto: 1, opacity: 100, zone: 1, coords: 0, bsize: 100, accent: '#e4001e', north: 1, grid: 1, labels: 1 };
let names = {};
let groupsData = [];
const me = { x: 0, y: 0 };
const hidden = new Set();
let drawerOn = true, tab = 'legend';

const E = {
  app: $('#app'), top: $('#top'), tools: $('#tools'),
  tPos: $('#t-pos'), cDist: $('#c-dist'), tDist: $('#t-dist'),
  iCell: $('#i-cell'), iXY: $('#i-xy'), iDist: $('#i-dist'),
  drawer: $('#drawer'), toast: $('#toast'),
  bWp: $('#b-wp'), bGrid: $('#b-grid'), bLab: $('#b-lab'), bMenu: $('#b-menu'),
};
const txt = (el, t) => { if (el.textContent !== t) el.textContent = t; };

/* ---------------------------------------------------------------- layout / hit areas */
function sendUI() {
  // rectangles (screen px) where the mouse belongs to this page and not to the map
  const r = [];
  r.push([28, 24, E.top.offsetWidth * vs, E.top.offsetHeight * vs]);
  const tw = E.tools.offsetWidth * vs, th = E.tools.offsetHeight * vs;
  r.push([W - 28 - tw, H - 24 - th, tw, th]);
  if (drawerOn) { const dw = 368 * vs; r.push([W - 28 - dw, 24, dw, H - 48 - 74 * vs]); }
  send('Lx:radar:ui', r.map(a => a.map(v => Math.round(v)).join(',')).join(';'));
}
function fit() {
  W = innerWidth; H = innerHeight;
  vs = clamp(Math.min(W / 1920, H / 1080), 0.55, 2.6);
  root.style.setProperty('--vs', vs.toFixed(4));
  sendUI();
}
function setAccent(hex) {
  const c = [1, 3, 5].map(i => parseInt(hex.substr(i, 2), 16)), hi = c.map(v => Math.round(v + (255 - v) * 0.2));
  const r = root.style;
  r.setProperty('--ac', hex); r.setProperty('--ac-rgb', c.join(',')); r.setProperty('--ac-hi', 'rgb(' + hi.join(',') + ')');
}

/* ---------------------------------------------------------------- small UI helpers */
let toastT = 0;
function toast(text) {
  E.toast.textContent = text; E.toast.classList.add('on');
  clearTimeout(toastT); toastT = setTimeout(() => E.toast.classList.remove('on'), 1800);
}
function updTop() {
  txt(E.tPos, Math.round(me.x) + ', ' + Math.round(me.y));
  const was = E.cDist.hidden;
  if (wp && wd >= 0) { E.cDist.hidden = false; txt(E.tDist, fmtDist(wd)); } else E.cDist.hidden = true;
  if (was !== E.cDist.hidden) sendUI();
  const w = $('.lg-wp span');
  if (w && wd >= 0) txt(w, fmtDist(wd) + ' away');
}

/* ---------------------------------------------------------------- legend */
const legendRows = new Map();
let legendSig = '';
const pg = n => $('.pg[data-p="' + n + '"]');
const sendHidden = () => send('Lx:radar:hide', Array.from(hidden).join(','));

function legendRow(g) {
  const row = h('div', 'lg');
  const ic = h('div', 'ic');
  if (g.icon === 0) { const i = h('i'); i.style.setProperty('--m', 'url(blips/square.png)'); i.style.setProperty('--c', '#fff'); ic.appendChild(i); }
  else { const im = h('img'); im.alt = ''; im.src = 'blips/' + p2(g.icon) + '.png'; im.onerror = () => { im.style.visibility = 'hidden'; }; ic.appendChild(im); }
  row.append(ic, h('span', '', g.icon === 0 ? 'Players' : (names[g.icon] || 'Icon ' + p2(g.icon))), h('em', '', '0'), h('i', 'eye'));
  row.onclick = () => { if (hidden.has(g.key)) hidden.delete(g.key); else hidden.add(g.key); row.classList.toggle('off', hidden.has(g.key)); sendHidden(); };
  return row;
}
function legend(force) {
  const box = pg('legend');
  if (!box) return;
  if (!box.firstChild) {
    box.append(h('div', 'lab row', '<span>Blips on the map</span><span><button class="mini" data-a="all">All</button><button class="mini" data-a="none">None</button></span>'),
      h('div', 'lg-list'), h('div', 'lab', 'Waypoint'), h('div', 'lg-wp'));
    box.addEventListener('click', e => {
      const a = e.target.dataset && e.target.dataset.a;
      if (a === 'all') hidden.clear();
      if (a === 'none') groupsData.forEach(g => hidden.add(g.key));
      if (a) { legendRows.forEach((row, k) => row.classList.toggle('off', hidden.has(k))); sendHidden(); }
    });
  }
  const list = $('.lg-list', box), gs = groupsData;
  const sig = gs.map(g => g.key + ':' + g.n).join('|') + (wp ? 'w' : '');
  if (!force && sig === legendSig) return;
  legendSig = sig;
  const seen = new Set();
  gs.forEach((g, i) => {
    seen.add(g.key);
    let row = legendRows.get(g.key);
    if (!row) { row = legendRow(g); legendRows.set(g.key, row); }
    $('em', row).textContent = g.n;
    row.classList.toggle('off', hidden.has(g.key));
    if (list.children[i] !== row) list.insertBefore(row, list.children[i] || null);
  });
  legendRows.forEach((row, k) => { if (!seen.has(k)) { row.remove(); legendRows.delete(k); } });
  let empty = $('.empty', list);
  if (!gs.length && !empty) list.appendChild(h('div', 'empty', 'NO BLIPS IN THIS AREA'));
  if (gs.length && empty) empty.remove();
  const w = $('.lg-wp', box);
  w.innerHTML = '';
  if (wp) {
    const r = h('div', 'lg', '<div class="ic"><img src="pin.png" alt=""></div><span>' + (wd >= 0 ? fmtDist(wd) + ' away' : 'Waypoint') + '</span><button class="mini" style="margin:0">Clear</button>');
    $('button', r).onclick = e => { e.stopPropagation(); send('Lx:radar:act', 'wpclear'); };
    r.onclick = () => send('Lx:radar:act', 'wpfly');
    w.appendChild(r);
  } else w.appendChild(h('div', 'empty', 'RIGHT-CLICK THE MAP'));
}

/* ---------------------------------------------------------------- minimap customizer */
const sync = [];
let resetT = 0, savedT = 0;
function set(key, val) {
  cfg[key] = val;
  if (key === 'accent') setAccent(val);
  sync.forEach(f => f());
  if (key === 'grid') E.bGrid.classList.toggle('on', !!val);
  if (key === 'labels') E.bLab.classList.toggle('on', !!val);
  send('Lx:radar:set', key, String(val));
  const el = $('#d-saved'); el.classList.add('flash'); clearTimeout(savedT); savedT = setTimeout(() => el.classList.remove('flash'), 1300);
}
const lab = t => h('div', 'lab', t);
function mkToggle(key, label) {
  const b = h('button', 't', '<span>' + label + '</span><i class="sw"></i>');
  b.onclick = () => set(key, cfg[key] ? 0 : 1);
  sync.push(() => b.classList.toggle('on', !!cfg[key]));
  return b;
}
function mkSeg(key, opts) {
  const w = h('div', 'seg'), th = h('i', 'th');
  th.style.width = 'calc((100% - 8px) / ' + opts.length + ')'; w.appendChild(th);
  const bs = opts.map(o => { const b = h('button', '', o[1]); b.onclick = () => set(key, o[0]); w.appendChild(b); return b; });
  sync.push(() => { const i = Math.max(0, opts.findIndex(o => o[0] === cfg[key])); th.style.transform = 'translateX(' + (i * 100) + '%)'; bs.forEach((b, j) => b.classList.toggle('on', j === i)); });
  return w;
}
function mkSlider(key, label, min, max, unit) {
  const w = h('div', 'sl', '<div class="sl-h"><span>' + label + '</span><b></b></div>');
  const inp = h('input'); inp.type = 'range'; inp.min = min; inp.max = max; inp.step = 1; w.appendChild(inp);
  inp.oninput = () => set(key, +inp.value);
  sync.push(() => { inp.value = cfg[key]; inp.style.setProperty('--p', ((cfg[key] - min) / (max - min) * 100) + '%'); $('b', w).textContent = cfg[key] + unit; });
  return w;
}
const ACCENTS = ['#e4001e', '#ff6a00', '#ffb020', '#18e0a0', '#00d1ff', '#4aa3ff', '#8b5cf6', '#ff3d9a', '#ffffff'];
function buildMini() {
  const box = pg('mini');
  const sw = h('div', 'sws');
  ACCENTS.forEach(c => { const b = h('button', 's'); b.style.background = c; b.onclick = () => set('accent', c); sync.push(() => b.classList.toggle('on', cfg.accent === c)); sw.appendChild(b); });
  const pad = h('div', 'pad');
  ['tl', 'tr', 'bl', 'br'].forEach(p => { const b = h('button'); b.onclick = () => set('pos', p); sync.push(() => b.classList.toggle('on', cfg.pos === p)); pad.appendChild(b); });
  const g = h('div', 'tg');
  g.append(mkToggle('rotate', 'Rotate'), mkToggle('auto', 'Auto zoom'), mkToggle('zone', 'Zone name'), mkToggle('coords', 'Coordinates'), mkToggle('north', 'North mark'));
  box.append(
    lab('Shape'), mkSeg('shape', [['circle', 'Circle'], ['rounded', 'Rounded'], ['square', 'Square'], ['wide', 'Wide']]),
    lab('Corner'), pad,
    lab('Size & position'), mkSlider('size', 'Size', 160, 420, ' px'), mkSlider('ox', 'Horizontal', 0, 300, ' px'), mkSlider('oy', 'Vertical', 0, 300, ' px'),
    lab('View'), mkSlider('zoom', 'Range', 120, 900, ' m'), mkSlider('bsize', 'Blip size', 60, 160, '%'), mkSlider('opacity', 'Opacity', 30, 100, '%'),
    lab('Options'), g,
    lab('Accent color'), sw);
  $$('.pg', E.drawer).forEach(p => Array.from(p.children).forEach((c, i) => c.style.setProperty('--n', i)));
}

function setTab(t) {
  tab = t;
  const tabs = $$('#d-tabs button');
  tabs.forEach((b, i) => { b.classList.toggle('on', b.dataset.t === t); if (b.dataset.t === t) $('.ind', E.drawer).style.transform = 'translateX(' + (i * 100) + '%)'; });
  $$('.pg', E.drawer).forEach(p => p.classList.toggle('on', p.dataset.p === t));
  $('#d-body').scrollTop = 0;
  $('#d-saved').parentNode.style.visibility = t === 'mini' ? 'visible' : 'hidden';
  send('Lx:radar:preview', t === 'mini' && drawerOn && open ? '1' : '0');
}
function showDrawer(on) {
  drawerOn = on; E.drawer.classList.toggle('show', on); E.bMenu.classList.toggle('on', on);
  send('Lx:radar:preview', tab === 'mini' && on && open ? '1' : '0');
  sendUI();
}

/* ---------------------------------------------------------------- buttons */
$$('#d-tabs button').forEach(b => b.onclick = () => setTab(b.dataset.t));
$('#d-x').onclick = () => showDrawer(false);
E.bMenu.onclick = () => showDrawer(!drawerOn);
$('#b-me').onclick = () => send('Lx:radar:act', 'me');
E.bWp.onclick = () => send('Lx:radar:act', 'wpclear');
E.bGrid.onclick = () => set('grid', cfg.grid ? 0 : 1);
E.bLab.onclick = () => set('labels', cfg.labels ? 0 : 1);
$('#b-in').onclick = () => send('Lx:radar:act', 'in');
$('#b-out').onclick = () => send('Lx:radar:act', 'out');
$('#d-reset').onclick = function () {
  if (!this.classList.contains('sure')) {
    this.classList.add('sure'); this.textContent = 'Click again';
    clearTimeout(resetT); resetT = setTimeout(() => { this.classList.remove('sure'); this.textContent = 'Reset'; }, 2600);
    return;
  }
  clearTimeout(resetT); this.classList.remove('sure'); this.textContent = 'Reset';
  send('Lx:radar:reset');
};
addEventListener('contextmenu', e => e.preventDefault());

/* ---------------------------------------------------------------- API for Lua */
let built = false;
function applyCfg(c) {
  for (const k in c) if (k in cfg) cfg[k] = c[k];
  setAccent(cfg.accent);
  E.bGrid.classList.toggle('on', !!cfg.grid); E.bLab.classList.toggle('on', !!cfg.labels);
  sync.forEach(f => f());
}
window.RM = {
  init(c, n) {
    names = n || {};
    if (!built) { built = true; buildMini(); legend(true); }
    applyCfg(c || {});
    setTab('legend'); showDrawer(true);
    fit();
  },
  cfg: applyCfg,
  open(v) {
    v = !!v;
    if (v === open) return;
    open = v;
    E.app.classList.toggle('open', v);
    if (v) { legend(true); showDrawer(drawerOn); fit(); }
    else send('Lx:radar:preview', '0');
  },
  p(x, y, d) { me.x = x; me.y = y; wd = d; if (open) updTop(); },
  i(cell, x, y, d) { txt(E.iCell, cell); txt(E.iXY, x + ', ' + y); txt(E.iDist, d); },
  g(rows) {
    groupsData = rows.map(r => ({ key: r[0], icon: r[1], n: r[2] }));
    legend(false);
  },
  wp(x, y) {
    if (x === null || x === undefined) { wp = null; wd = -1; E.bWp.disabled = true; }
    else { wp = { x, y }; E.bWp.disabled = false; }
    updTop(); legend(true);
  },
  toast,
};

addEventListener('resize', fit);
fit();
})();
