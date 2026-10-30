/* =====================================================================
   LINUX Game - [Lx]HUD  |  script.js
   Lua calls:   HUD.init(settingsJson, cfg)   HUD.u({changed values})
                HUD.show(bool)                HUD.panel(bool)
   ===================================================================== */
(function () {
'use strict';

const $  = (s, r) => (r || document).querySelector(s);
const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
const h  = (tag, cls, html) => { const e = document.createElement(tag); if (cls) e.className = cls; if (html != null) e.innerHTML = html; return e; };
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const restart = (el, cls) => { el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls); };
const root = document.documentElement;

/* ---------------------------------------------------------------- settings */
const POS = ['tl', 'tc', 'tr', 'ml', 'mc', 'mr', 'bl', 'bc', 'br'];
const DEF = {
  show: { logo: 1, server: 1, clock: 1, date: 1, name: 1, id: 1, money: 1, wanted: 1, health: 1, armor: 1, weapon: 1, ammo: 1 },
  armorAuto: 1, weaponAuto: 1, wantedAuto: 0,
  accent: '#e4001e', style: 'full', bar: 'smooth', scale: 100, opacity: 100, anim: 1,
  pos: 'tr', ox: 28, oy: 24,
  h24: 1, secs: 1, cal: 'greg', digits: 'latin', dfmt: 'short',
};
const ACCENTS = ['#e4001e', '#ff6a00', '#ffb020', '#18e0a0', '#00d1ff', '#4aa3ff', '#8b5cf6', '#ff3d9a', '#ffffff'];

function sanitize(r) {
  const s = JSON.parse(JSON.stringify(DEF));
  if (!r || typeof r !== 'object') return s;
  if (r.show && typeof r.show === 'object') for (const k in s.show) if (k in r.show) s.show[k] = r.show[k] ? 1 : 0;
  for (const k of ['armorAuto', 'weaponAuto', 'wantedAuto', 'anim', 'h24', 'secs']) if (k in r) s[k] = r[k] ? 1 : 0;
  if (typeof r.accent === 'string' && /^#[0-9a-f]{6}$/i.test(r.accent)) s.accent = r.accent.toLowerCase();
  const en = (k, list) => { if (list.includes(r[k])) s[k] = r[k]; };
  en('style', ['full', 'compact', 'minimal']); en('bar', ['smooth', 'seg']); en('pos', POS);
  en('cal', ['greg', 'jalali']); en('digits', ['latin', 'fa']); en('dfmt', ['short', 'long']);
  const num = (k, a, b) => { const n = Number(r[k]); if (isFinite(n)) s[k] = Math.round(clamp(n, a, b)); };
  num('scale', 70, 140); num('opacity', 30, 100); num('ox', 0, 300); num('oy', 0, 300);
  return s;
}
let S = sanitize(null);

/* ---------------------------------------------------------------- elements */
const E = {
  stage: $('#stage'), hud: $('#hud'),
  wHead: $('#w-head'), wName: $('#w-name'), wMoney: $('#w-money'), wHp: $('#w-hp'), wAr: $('#w-ar'), wWeapon: $('#w-weapon'),
  brand: $('#e-brand'), logo: $('#e-logo'), server: $('#e-server'), date: $('#e-date'), bt: $('.bt'),
  clock: $('#e-clock'), ch: $('#c-h'), cm: $('#c-m'), cs: $('#c-s'), cap: $('#c-ap'),
  name: $('#e-name'), idp: $('#e-id'), idv: $('#e-idv'), dot: $('.dot'),
  money: $('#e-money'), mval: $('#m-val'), deltas: $('#m-d'), stars: $('#e-wanted'),
  rHp: $('#r-hp'), rAr: $('#r-ar'),
  wico: $('#w-ico'), wname: $('#w-name-t'), ammo: $('#e-ammo'), aclip: $('#a-clip'), ares: $('#a-res'),
  pwrap: $('#pwrap'), panel: $('#panel'),
};
const BAR = {
  hp: { row: E.rHp, fill: $('.fill', E.rHp), ghost: $('.ghost', E.rHp), val: $('.val', E.rHp), shown: 100, cur: null },
  ar: { row: E.rAr, fill: $('.fill', E.rAr), ghost: $('.ghost', E.rAr), val: $('.val', E.rAr), shown: 0, cur: null },
};

/* ---------------------------------------------------------------- state from Lua */
const st = { name: 'Player', id: 0, hp: 100, mhp: 100, ar: 0, money: 0, wanted: 0, wid: 0, wname: 'Fist', clip: 0, total: 0 };
const primed = {};
let shownOn = false;

/* ---------------------------------------------------------------- tween engine (one rAF loop, only while something moves) */
const tw = new Map(); let raf = 0;
function step(t) {
  raf = 0;
  tw.forEach((a, k) => {
    const p = clamp((t - a.t0) / a.ms, 0, 1), e = 1 - Math.pow(1 - p, 4);
    a.fn(a.from + (a.to - a.from) * e);
    if (p >= 1) tw.delete(k);
  });
  if (tw.size) raf = requestAnimationFrame(step);
}
function tween(key, from, to, ms, fn) {
  if (!S.anim || from === to) { tw.delete(key); fn(to); return; }
  tw.set(key, { from, to, ms, fn, t0: performance.now() });
  if (!raf) raf = requestAnimationFrame(step);
}

/* ---------------------------------------------------------------- weapons */
const NOAMMO = { fist: 1, melee: 1, misc: 1 };
function catOf(id) {
  if (id === 0) return 'fist';
  if (id >= 1 && id <= 15) return 'melee';
  if (id === 16 || id === 17 || id === 18 || id === 39) return 'thrown';
  if (id >= 22 && id <= 24) return 'pistol';
  if (id >= 25 && id <= 27) return 'shotgun';
  if (id === 28 || id === 29 || id === 32) return 'smg';
  if (id === 30 || id === 31) return 'rifle';
  if (id === 33 || id === 34) return 'sniper';
  if (id >= 35 && id <= 38) return 'heavy';
  if (id >= 41 && id <= 43) return 'spray';
  return 'misc';
}
const WI = {
  fist:   '<path d="M13 10a3 3 0 0 1 3-3h14a4 4 0 0 1 4 4v1.500h2.500a3 3 0 0 1 0 6H34v.500a3.500 3.500 0 0 1-3.500 3.500H17a4 4 0 0 1-4-4z"/><path d="M20.500 7.500v6M26 7.500v6" stroke="#0a0b0e" stroke-width="1.600" stroke-linecap="round"/>',
  melee:  '<path transform="rotate(-22 22 12)" d="M4 10.500L20 11l14-2.200a3.200 3.200 0 0 1 0 6.400L20 13l-16 .5a1.500 1.500 0 0 1 0-3z"/>',
  pistol: '<path d="M5 5.500h30a1.500 1.500 0 0 1 1.500 1.500v5.500H5A1.500 1.500 0 0 1 3.500 11V7A1.500 1.500 0 0 1 5 5.500z"/><path d="M9 12.500h9.500l-2.200 9.200a1.500 1.500 0 0 1-1.500 1.100h-3.600a1.500 1.500 0 0 1-1.500-1.800z"/><path d="M20.500 12.500v3.300h7v-3.300" fill="none" stroke="currentColor" stroke-width="1.500"/>',
  shotgun:'<path d="M2 8h33v3.200H2z"/><path d="M11 11.200h12V14H11z"/><path d="M33 7h5.500l8 2.500-2.500 6.500h-6.500l-2-3.500H33z"/><path d="M26 11.200h7v4.300h-7z" opacity=".55"/>',
  smg:    '<path d="M1 7.500h6V9H1z"/><path d="M7 6h22v6H7z"/><path d="M29 7h7l8 2-1.500 4H36l-2-2.500h-5z"/><path d="M15 12h4.500v10H15z"/><path d="M9 12h4l-1 7H8z"/>',
  rifle:  '<path d="M1 8.500h8V10H1z"/><path d="M9 7h26v4.500H9z"/><path d="M35 6.500h9l2 6h-7l-1.500-2.500H35z"/><path d="M19 11.500h5.500l2.500 10h-5.500z"/><path d="M12 11.500h4l-1 6h-3.500z"/><path d="M22 4.500h9V7h-9z"/>',
  sniper: '<path d="M1 10.500h12V12H1z"/><path d="M13 9.500h24v3.500H13z"/><path d="M37 8.500h9v7h-7l-2-2.500z"/><path d="M15 4.500h14v3.200H15z"/><path d="M19 7.700h2v2h-2zM25 7.700h2v2h-2z"/><path d="M22 13h4l-1 6h-3z"/>',
  heavy:  '<path d="M3 7h33v8H3z"/><path d="M36 5h6l4 2v8l-4 2h-6z"/><path d="M1.500 6h3v10h-3z"/><path d="M17 15h5v7h-5z"/><path d="M26 15h3l1 4h-3z"/>',
  thrown: '<circle cx="24" cy="14" r="7.500"/><path d="M21 3.500h6v3.500h-6z"/><path d="M27 5h5" stroke="currentColor" stroke-width="1.800" fill="none"/>',
  spray:  '<path d="M16 8h12v14a1.500 1.500 0 0 1-1.500 1.500h-9A1.500 1.500 0 0 1 16 22z"/><path d="M19 3h6v5h-6z"/><path d="M29 4.500l5-2M29 7l6 0M29 9.500l5 2" stroke="currentColor" stroke-width="1.500" fill="none" stroke-linecap="round"/>',
  misc:   '<path d="M24 3l2.800 6.200 6.700.8-5 4.600 1.400 6.600L24 17.800l-5.900 3.400 1.400-6.600-5-4.600 6.700-.8z"/>',
};

/* ---------------------------------------------------------------- Jalali (Persian) calendar */
function g2j(gy, gm, gd) {
  const gdm = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
  const gy2 = gm > 2 ? gy + 1 : gy;
  let days = 355666 + 365 * gy + Math.floor((gy2 + 3) / 4) - Math.floor((gy2 + 99) / 100) + Math.floor((gy2 + 399) / 400) + gd + gdm[gm - 1];
  let jy = -1595 + 33 * Math.floor(days / 12053);
  days %= 12053;
  jy += 4 * Math.floor(days / 1461);
  days %= 1461;
  if (days > 365) { jy += Math.floor((days - 1) / 365); days = (days - 1) % 365; }
  const jm = days < 186 ? 1 + Math.floor(days / 31) : 7 + Math.floor((days - 186) / 30);
  const jd = 1 + (days < 186 ? days % 31 : (days - 186) % 30);
  return [jy, jm, jd];
}
const GM = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const GD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const JM_EN = ['Farvardin', 'Ordibehesht', 'Khordad', 'Tir', 'Mordad', 'Shahrivar', 'Mehr', 'Aban', 'Azar', 'Dey', 'Bahman', 'Esfand'];
const JM_FA = ['فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور', 'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند'];
const JD_EN = ['Yekshanbe', 'Doshanbe', 'Seshanbe', 'Chaharshanbe', 'Panjshanbe', 'Jomeh', 'Shanbe'];
const JD_FA = ['یکشنبه', 'دوشنبه', 'سه‌شنبه', 'چهارشنبه', 'پنجشنبه', 'جمعه', 'شنبه'];
const p2 = n => (n < 10 ? '0' : '') + n;
const FA = '۰۱۲۳۴۵۶۷۸۹';
const dg = s => (S.digits === 'fa' ? String(s).replace(/\d/g, d => FA[d]) : String(s));

function fmtDate(d) {
  const y = d.getFullYear(), m = d.getMonth() + 1, day = d.getDate(), wd = d.getDay();
  let out, rtl = false;
  if (S.cal === 'jalali') {
    const j = g2j(y, m, day), fa = S.digits === 'fa';
    if (S.dfmt === 'short') out = j[0] + '/' + p2(j[1]) + '/' + p2(j[2]);
    else { out = (fa ? JD_FA[wd] + '، ' : JD_EN[wd] + ', ') + j[2] + ' ' + (fa ? JM_FA : JM_EN)[j[1] - 1] + ' ' + j[0]; rtl = fa; }
  } else {
    out = S.dfmt === 'short' ? y + '/' + p2(m) + '/' + p2(day) : GD[wd] + ', ' + day + ' ' + GM[m - 1] + ' ' + y;
  }
  return { text: dg(out), rtl };
}

/* ---------------------------------------------------------------- clock */
const ck = { h: '', m: '', s: '', ap: '', d: '' };
function tickClock(force) {
  const now = new Date();
  let H = now.getHours(), ap = '';
  if (!S.h24) { ap = H >= 12 ? 'PM' : 'AM'; H = H % 12 || 12; }
  const hs = dg(p2(H)), ms = dg(p2(now.getMinutes())), ss = dg(p2(now.getSeconds()));
  if (hs !== ck.h) { E.ch.textContent = hs; if (ck.h && !force) restart(E.ch, 'tick'); ck.h = hs; }
  if (ms !== ck.m) { E.cm.textContent = ms; if (ck.m && !force) restart(E.cm, 'tick'); ck.m = ms; }
  if (ss !== ck.s) { E.cs.textContent = ss; ck.s = ss; }
  if (ap !== ck.ap) { E.cap.textContent = ap; ck.ap = ap; }
  const d = fmtDate(now), key = d.text + d.rtl;
  if (key !== ck.d) { E.date.textContent = d.text; E.date.dir = d.rtl ? 'rtl' : 'ltr'; ck.d = key; }
}
function clockLoop() { tickClock(false); setTimeout(clockLoop, 1005 - (Date.now() % 1000)); }

/* ---------------------------------------------------------------- layout: which rows are visible */
const setW = (el, on) => el.classList.toggle('off', !on);
function layout() {
  const sh = S.show;
  E.logo.hidden = !sh.logo;
  E.server.hidden = !sh.server;
  E.date.hidden = !sh.date;
  E.bt.hidden = !(sh.server || sh.date);
  E.brand.hidden = !(sh.logo || sh.server || sh.date);
  E.clock.hidden = !sh.clock;
  E.cs.hidden = !S.secs;
  E.cap.hidden = !!S.h24;
  setW(E.wHead, sh.logo || sh.server || sh.date || sh.clock);

  E.name.hidden = !sh.name;
  E.idp.hidden = !sh.id;
  E.dot.hidden = !sh.name;
  setW(E.wName, sh.name || sh.id);

  const starsOn = sh.wanted;
  E.stars.hidden = !starsOn;
  E.stars.classList.toggle('gone', !!(S.wantedAuto && st.wanted === 0));
  E.money.hidden = !sh.money;
  setW(E.wMoney, sh.money || (starsOn && !(S.wantedAuto && st.wanted === 0)));

  setW(E.wHp, sh.health);
  setW(E.wAr, sh.armor && !(S.armorAuto && st.ar <= 0));

  const cat = catOf(st.wid);
  E.ammo.hidden = !sh.ammo || !!NOAMMO[cat];
  setW(E.wWeapon, sh.weapon && !(S.weaponAuto && st.wid === 0));
}

/* ---------------------------------------------------------------- apply settings */
function hex2rgb(x) { return [1, 3, 5].map(i => parseInt(x.substr(i, 2), 16)); }
function setAccent(hex) {
  const c = hex2rgb(hex), hi = c.map(v => Math.round(v + (255 - v) * .2));
  const r = root.style;
  r.setProperty('--ac', hex);
  r.setProperty('--ac-rgb', c.join(','));
  r.setProperty('--ac-hi', 'rgb(' + hi.join(',') + ')');
}
let curPos = null, posTimer = 0;
function applyPos(animate) {
  clearTimeout(posTimer);
  const go = () => { E.stage.className = 'pos-' + S.pos; curPos = S.pos; E.hud.classList.remove('hop'); };
  E.pwrap.classList.toggle('right', S.pos[1] === 'l');
  if (curPos === S.pos) return;
  if (animate && curPos && E.hud.classList.contains('on') && S.anim) { E.hud.classList.add('hop'); posTimer = setTimeout(go, 180); }
  else go();
}
function fit() {
  const vs = clamp(Math.min(innerWidth / 1920, innerHeight / 1080), .55, 2.6);
  root.style.setProperty('--vs', vs.toFixed(4));
}
function apply(animatePos) {
  setAccent(S.accent);
  const r = root.style;
  r.setProperty('--us', (S.scale / 100).toFixed(3));
  r.setProperty('--op', (S.opacity / 100).toFixed(2));
  r.setProperty('--ox', S.ox);
  r.setProperty('--oy', S.oy);
  root.classList.toggle('lite', !S.anim);
  E.hud.classList.remove('s-full', 's-compact', 's-minimal', 'b-smooth', 'b-seg');
  E.hud.classList.add('s-' + S.style, 'b-' + S.bar);
  applyPos(animatePos);
  layout();
  tickClock(true);
}

/* ---------------------------------------------------------------- HUD data -> DOM */
function setBar(b, val, max, instant) {
  const pct = clamp(val / max, 0, 1), old = b.cur;
  const t = 'scaleX(' + pct + ')';
  b.fill.style.transform = t; b.ghost.style.transform = t;
  tween(b === BAR.hp ? 'hp' : 'ar', b.shown, val, 450, v => { b.shown = v; b.val.textContent = Math.round(v); });
  if (!instant && old !== null) {
    if (val < old) restart(b.row, 'hit');
    else if (val > old) restart(b.row, 'heal');
  }
  b.cur = val;
}
function updHp() {
  setBar(BAR.hp, st.hp, st.mhp, !primed.hp); primed.hp = 1;
  E.rHp.classList.toggle('low', st.hp > 0 && st.hp / st.mhp <= .25);
}
function updAr() { setBar(BAR.ar, st.ar, 100, !primed.ar); primed.ar = 1; layout(); }

let shownMoney = 0, lastChip = null;
function renderMoney(v) {
  const n = Math.round(v);
  E.mval.textContent = Math.abs(n).toLocaleString('en-US');
  E.money.classList.toggle('neg', n < 0);
}
function chip(d) {
  const now = performance.now(), pos = d > 0;
  const money = Math.abs(d).toLocaleString('en-US');
  if (lastChip && lastChip.el.isConnected && now - lastChip.t < 700 && lastChip.pos === pos) {
    lastChip.sum += Math.abs(d); lastChip.t = now;
    lastChip.el.textContent = (pos ? '+$' : '-$') + lastChip.sum.toLocaleString('en-US');
    restart(lastChip.el, 'd');
    return;
  }
  const el = h('div', 'd ' + (pos ? 'p' : 'n'), (pos ? '+$' : '-$') + money);
  E.deltas.appendChild(el);
  while (E.deltas.children.length > 4) E.deltas.removeChild(E.deltas.firstChild);
  el.addEventListener('animationend', () => el.remove());
  lastChip = { el, t: now, pos, sum: Math.abs(d) };
}
function updMoney() {
  const v = st.money;
  if (!primed.money) { primed.money = 1; shownMoney = v; renderMoney(v); st.lastMoney = v; return; }
  const d = v - st.lastMoney; st.lastMoney = v;
  tween('money', shownMoney, v, 750, x => { shownMoney = x; renderMoney(x); });
  if (d !== 0 && S.anim) chip(d);
}

const STAR = '<svg viewBox="0 0 24 24"><path d="M12 2.500l2.900 6 6.600.9-4.800 4.600 1.200 6.500L12 17.400 6.100 20.500l1.200-6.500L2.500 9.400l6.600-.9z"/></svg>';
E.stars.innerHTML = STAR.repeat(6);
const STARS = $$('svg', E.stars);
function updWanted() {
  const n = clamp(st.wanted | 0, 0, 6);
  STARS.forEach((s, i) => {
    if (i < n) {
      if (!s.classList.contains('on')) {
        s.classList.add('on');
        if (primed.wanted && S.anim) { s.style.animationDelay = (i * 55) + 'ms'; restart(s, 'pop'); }
      }
    } else s.classList.remove('on', 'pop');
  });
  primed.wanted = 1;
  layout();
}

const wShown = { id: -1, main: null, res: null };
function updWeapon() {
  const id = st.wid, cat = catOf(id);
  if (id !== wShown.id) {
    const first = wShown.id === -1;
    E.wico.innerHTML = '<svg viewBox="0 0 48 24">' + WI[cat] + '</svg>';
    E.wname.textContent = (st.wname || 'Unknown').toUpperCase();
    wShown.id = id;
    if (!first && S.anim) { restart(E.wico, 'swap'); restart(E.wname, 'swap'); restart(E.ammo, 'swap'); }
  }
  const hasClip = id >= 22 && id <= 34;
  const main = hasClip ? st.clip : st.total;
  const res = hasClip ? '/ ' + Math.max(0, st.total - st.clip) : '';
  if (main !== wShown.main) {
    E.aclip.textContent = main;
    if (wShown.main !== null && S.anim && !NOAMMO[cat]) restart(E.ammo, 'bump');
    wShown.main = main;
  }
  if (res !== wShown.res) { E.ares.textContent = res; wShown.res = res; }
  E.ammo.classList.toggle('empty', hasClip ? (st.clip === 0 && st.total > 0) || st.total === 0 : st.total === 0);
  layout();
}

function update(o) {
  Object.assign(st, o);
  if ('name' in o) E.name.textContent = st.name || 'Player';
  if ('id' in o) E.idv.textContent = st.id > 0 ? st.id : '–';
  if ('hp' in o || 'mhp' in o) { st.mhp = Math.max(1, st.mhp | 0); updHp(); }
  if ('ar' in o) updAr();
  if ('money' in o) updMoney();
  if ('wanted' in o) updWanted();
  if ('wid' in o || 'wname' in o || 'clip' in o || 'total' in o) updWeapon();
}

/* replay the intro of values every time the HUD is shown */
function replay() {
  [['hp', st.hp, st.mhp], ['ar', st.ar, 100]].forEach(([k, v, max]) => {
    const b = BAR[k];
    b.fill.style.transition = 'none'; b.ghost.style.transition = 'none';
    b.fill.style.transform = 'scaleX(0)'; b.ghost.style.transform = 'scaleX(0)';
    void b.fill.offsetWidth;
    b.fill.style.transition = ''; b.ghost.style.transition = '';
    b.shown = 0; b.val.textContent = 0;
    const pct = clamp(v / max, 0, 1);
    b.fill.style.transform = 'scaleX(' + pct + ')'; b.ghost.style.transform = 'scaleX(' + pct + ')';
    tween(k, 0, v, 900, x => { b.shown = x; b.val.textContent = Math.round(x); });
  });
  shownMoney = 0; renderMoney(0);
  tween('money', 0, st.money, 1100, x => { shownMoney = x; renderMoney(x); });
}

/* ---------------------------------------------------------------- CUSTOMIZER PANEL */
const IC = {
  logo: '<rect x="3" y="3" width="18" height="18" rx="4"/><path d="M7 16l3.500-4.500 2.500 3 2-2 3 3.500"/>',
  server: '<rect x="3" y="4" width="18" height="6" rx="2"/><rect x="3" y="14" width="18" height="6" rx="2"/><path d="M7 7h.01M7 17h.01"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  date: '<rect x="3" y="5" width="18" height="16" rx="3"/><path d="M3 10h18M8 3v4M16 3v4"/>',
  name: '<circle cx="12" cy="8" r="4"/><path d="M4 21c1-4 4-6 8-6s7 2 8 6"/>',
  id: '<path d="M5 9h14M5 15h14M10 4L8 20M16 4l-2 16"/>',
  money: '<circle cx="12" cy="12" r="9"/><path d="M14.500 9.200c-.6-.8-1.500-1.200-2.500-1.200-1.400 0-2.500.8-2.500 2s1 1.600 2.500 2 2.500.8 2.500 2-1.100 2-2.500 2c-1 0-1.900-.4-2.500-1.200M12 6v2m0 8v2"/>',
  wanted: '<path d="M12 3l2.700 5.600 6.100.9-4.400 4.300 1 6.100L12 17l-5.400 2.900 1-6.100L3.200 9.500l6.100-.9z"/>',
  health: '<path d="M12 20s-7-4.400-9-9.200C1.800 7.200 4 4 7.200 4c2 0 3.400 1 4.800 3 1.400-2 2.800-3 4.800-3C20 4 22.200 7.200 21 10.800 19 15.600 12 20 12 20z"/>',
  armor: '<path d="M12 3l8 3v6c0 4.500-3.400 8-8 9-4.600-1-8-4.500-8-9V6z"/>',
  weapon: '<path d="M3 9h13l2-2h3v4h-3l-1 2h-4l-1 5H8l1-5H3z"/>',
  ammo: '<path d="M9 21v-9l3-8 3 8v9zM9 15h6"/>',
  eye: '<path d="M2 12s3.500-7 10-7 10 7 10 7-3.500 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21c1-4 4-6 8-6s7 2 8 6"/>',
  spark: '<path d="M12 3l1.800 5.200L19 10l-5.200 1.800L12 17l-1.800-5.200L5 10l5.200-1.800zM19 17l.8 2.200L22 20l-2.200.8L19 23l-.8-2.200L16 20l2.200-.8z"/>',
};
const ELEMENTS = [
  ['logo', 'Logo'], ['server', 'Server name'], ['clock', 'Time'], ['date', 'Date'],
  ['name', 'Name'], ['id', 'Player ID'], ['money', 'Money'], ['wanted', 'Wanted level'],
  ['health', 'Health'], ['armor', 'Armor'], ['weapon', 'Weapon'], ['ammo', 'Ammo'],
];

const sync = [];
let saveTimer = 0, resetTimer = 0;
const getP = p => p.split('.').reduce((o, k) => o[k], S);
const setP = (p, v) => { const a = p.split('.'), k = a.pop(); a.reduce((o, x) => o[x], S)[k] = v; };

function changed(key) {
  apply(key === 'pos');
  sync.forEach(f => f());
  clearTimeout(saveTimer);
  saveTimer = setTimeout(save, 450);
}
function save() {
  try { if (window.mta) mta.triggerEvent('Lx:hud:save', JSON.stringify(S)); } catch (e) {}
  const el = $('#p-saved');
  restart(el, 'flash');
  setTimeout(() => el.classList.remove('flash'), 1400);
}

function mkToggle(path, label, icon) {
  const b = h('button', 't', (icon ? '<svg viewBox="0 0 24 24">' + IC[icon] + '</svg>' : '') + '<span>' + label + '</span><i class="sw"></i>');
  b.onclick = () => { setP(path, getP(path) ? 0 : 1); changed(path); };
  sync.push(() => b.classList.toggle('on', !!getP(path)));
  return b;
}
function mkSeg(key, opts) {
  const w = h('div', 'seg'), th = h('i', 'th');
  th.style.width = 'calc((100% - 8px) / ' + opts.length + ')';
  w.appendChild(th);
  const btns = opts.map(o => {
    const b = h('button', '', o[1]);
    b.onclick = () => { S[key] = o[0]; changed(key); };
    w.appendChild(b); return b;
  });
  sync.push(() => {
    const i = Math.max(0, opts.findIndex(o => o[0] === S[key]));
    th.style.transform = 'translateX(' + (i * 100) + '%)';
    btns.forEach((b, j) => b.classList.toggle('on', j === i));
  });
  return w;
}
function mkSlider(key, label, min, max, unit, disabledFn) {
  const w = h('div', 'sl', '<div class="sl-h"><span>' + label + '</span><b></b></div>');
  const inp = h('input'); inp.type = 'range'; inp.min = min; inp.max = max; inp.step = 1;
  w.appendChild(inp);
  inp.oninput = () => { S[key] = +inp.value; changed(key); };
  sync.push(() => {
    inp.value = S[key];
    inp.style.setProperty('--p', ((S[key] - min) / (max - min) * 100) + '%');
    $('b', w).textContent = S[key] + unit;
    if (disabledFn) w.classList.toggle('dis', disabledFn());
  });
  return w;
}
function hue2hex(hh) {
  const s = .9, l = .55, a = s * Math.min(l, 1 - l);
  const f = n => { const k = (n + hh / 30) % 12; return Math.round(255 * (l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1)))); };
  return '#' + [f(0), f(8), f(4)].map(v => p2h(v)).join('');
}
const p2h = v => (v < 16 ? '0' : '') + v.toString(16);
function hexHue(hex) {
  let [r, g, b] = hex2rgb(hex).map(v => v / 255);
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn;
  if (!d) return 0;
  let hh = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
  hh = Math.round(hh * 60); return hh < 0 ? hh + 360 : hh;
}
const lab = t => h('div', 'lab', t);

function buildPanel() {
  const P = n => $('.pg[data-p="' + n + '"]');
  /* elements */
  let g = h('div', 'tg');
  ELEMENTS.forEach(e => g.appendChild(mkToggle('show.' + e[0], e[1], e[0])));
  P('elements').append(lab('Visible elements'), g);
  g = h('div', 'tg one');
  g.append(mkToggle('armorAuto', 'Hide armor when empty', 'armor'), mkToggle('wantedAuto', 'Hide stars when not wanted', 'wanted'), mkToggle('weaponAuto', 'Hide weapon when unarmed', 'weapon'));
  P('elements').append(lab('Smart hiding'), g);

  /* style */
  const sw = h('div', 'sws');
  ACCENTS.forEach(c => {
    const b = h('button', 's'); b.style.background = c;
    b.onclick = () => { S.accent = c; changed('accent'); };
    sync.push(() => b.classList.toggle('on', S.accent === c));
    sw.appendChild(b);
  });
  const hue = h('div', 'sl'); const hi = h('input', 'hue'); hi.type = 'range'; hi.min = 0; hi.max = 360; hi.step = 1; hi.style.marginTop = '12px';
  hi.oninput = () => { S.accent = hue2hex(+hi.value); changed('accent'); };
  hue.appendChild(hi);
  sync.push(() => { if (document.activeElement !== hi) hi.value = hexHue(S.accent); hi.style.setProperty('--p', '0%'); });
  P('style').append(lab('Accent color'), sw, hue,
    lab('Layout style'), mkSeg('style', [['full', 'Full'], ['compact', 'Compact'], ['minimal', 'Minimal']]),
    lab('Bar style'), mkSeg('bar', [['smooth', 'Smooth'], ['seg', 'Segmented']]),
    lab('Size & visibility'), mkSlider('scale', 'Scale', 70, 140, '%'), mkSlider('opacity', 'Opacity', 30, 100, '%'),
    lab('Animations'), mkSeg('anim', [[1, 'Full'], [0, 'Lite (no animations)']]));

  /* layout */
  const pad = h('div', 'pad');
  POS.forEach(p => {
    const b = h('button'); b.onclick = () => { S.pos = p; changed('pos'); };
    sync.push(() => b.classList.toggle('on', S.pos === p));
    pad.appendChild(b);
  });
  P('layout').append(lab('Position on screen'), pad, lab('Distance from the edge'),
    mkSlider('ox', 'Horizontal', 0, 300, ' px', () => S.pos[1] === 'c'),
    mkSlider('oy', 'Vertical', 0, 300, ' px', () => S.pos[0] === 'm'));

  /* clock */
  P('clock').append(
    lab('Time format'), mkSeg('h24', [[1, '24 hour'], [0, '12 hour']]),
    lab('Seconds'), (() => { const g2 = h('div', 'tg one'); g2.appendChild(mkToggle('secs', 'Show seconds', 'clock')); return g2; })(),
    lab('Calendar'), mkSeg('cal', [['greg', 'Gregorian'], ['jalali', 'Jalali (Persian)']]),
    lab('Date format'), mkSeg('dfmt', [['short', 'Short'], ['long', 'Long']]),
    lab('Digits'), mkSeg('digits', [['latin', '1 2 3'], ['fa', '۱ ۲ ۳']]));

  /* stagger index for the entry animation */
  $$('.pg').forEach(pg => Array.from(pg.children).forEach((c, i) => c.style.setProperty('--n', i)));

  /* tabs */
  const tabs = $$('#p-tabs button'), ind = $('.ind');
  tabs.forEach((b, i) => b.onclick = () => {
    tabs.forEach(x => x.classList.toggle('on', x === b));
    $$('.pg').forEach(p => p.classList.toggle('on', p.dataset.p === b.dataset.t));
    ind.style.transform = 'translateX(' + (i * 100) + '%)';
    $('#p-body').scrollTop = 0;
  });

  $('#p-close').onclick = () => { try { if (window.mta) mta.triggerEvent('Lx:hud:panel', 'close'); } catch (e) {} };
  $('#p-reset').onclick = function () {
    if (!this.classList.contains('sure')) {
      this.classList.add('sure'); this.textContent = 'Click again';
      clearTimeout(resetTimer);
      resetTimer = setTimeout(() => { this.classList.remove('sure'); this.textContent = 'Reset'; }, 2600);
      return;
    }
    clearTimeout(resetTimer); this.classList.remove('sure'); this.textContent = 'Reset';
    S = sanitize(null); changed('pos');
  };
}

/* ---------------------------------------------------------------- public API (called from Lua) */
let built = false;
window.HUD = {
  init(json, cfg) {
    let parsed = null;
    try { if (json) parsed = JSON.parse(json); } catch (e) {}
    S = sanitize(parsed);
    cfg = cfg || {};
    if (cfg.server) { E.server.textContent = cfg.server; $('#p-srv').textContent = cfg.server; }
    if (cfg.key) $('#p-key').textContent = cfg.key;
    if (!built) { built = true; buildPanel(); }
    apply(false);
    sync.forEach(f => f());
  },
  u: update,
  show(v) {
    v = !!v;
    if (v === shownOn) return;
    shownOn = v;
    if (v) { replay(); requestAnimationFrame(() => requestAnimationFrame(() => E.hud.classList.add('on'))); }
    else E.hud.classList.remove('on');
  },
  panel(v) {
    E.panel.classList.toggle('open', !!v);
    if (!v) { const b = $('#p-reset'); clearTimeout(resetTimer); b.classList.remove('sure'); b.textContent = 'Reset'; }
  },
  _S: () => S,
};

E.logo.querySelector('img').addEventListener('error', () => E.logo.classList.add('nologo'));
addEventListener('resize', fit);
fit();
clockLoop();
layout();
})();
