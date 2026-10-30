/* =====================================================================
   LINUX Game - Account UI  |  script.js
   1) CONFIG     2) HELPERS     3) SOUNDS & MUSIC   4) VALIDATION
   5) EVENTS     6) FEATURES (lockout, welcome, states, news...)
   7) MTA BRIDGE (what Lua sends / receives)
   ===================================================================== */

/* ---------- 1) CONFIG ---------- */
const CONFIG = {
  eventName: "lg:auth",     // name of the event sent to Lua
  minUser: 3, minPass: 6,
  unlockAfter: 8000,          // ms before a button unlocks if the server never answers
  toastTime: 5500,
  maxAttempts: 5,             // wrong passwords before the login locks
  lockSeconds: 30,            // lock duration
  sounds: true,
  lite: false,                // true = no shadows/animations at all (use it if the panel is still slow on weak PCs)               // click / error / success sounds
  music: { volume: 0.3 },     // the file name is set in client.lua (MUSIC_FILE); button hides if the file is missing
  links: {                    // social buttons (bottom of the sidebar)
    discord:   "https://discord.gg/yourserver",
    telegram:  "https://t.me/yourchannel",
    instagram: "https://instagram.com/yourpage",
    teamspeak: "ts3server://your.server.ip?port=9987",
  },
  msg: {
    needUser: "Enter your username.",  needPass: "Enter your password.",
    needOld: "Enter your current password.",
    userShort: "Username must be at least 3 characters.", userChars: "Use letters, numbers and _ only.", taken: "That username is already taken.",
    phone: "Enter a valid phone number (10-15 digits).", passShort: "Password must be at least 6 characters.",
    noMatch: "Passwords do not match.", rules: "You must accept the server rules.",
    code: "Enter the 6-digit code from Telegram.",
  },
};

/* ---------- 2) HELPERS ---------- */
const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
const val = id => $("#" + id).value.trim();
const ICONS = {
  err:  '<path d="M12 8v5M12 16.5v.5M10.3 3.9L2.4 18a2 2 0 0 0 1.7 3h15.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/>',
  ok:   '<circle cx="12" cy="12" r="9"/><path d="M8 12l3 3 5-6"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8v.5"/>',
};
const esc = t => String(t).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function notify(type, title, text) {            // type: "err" | "ok" | "info"
  const el = document.createElement("div");
  el.className = "toast " + type;
  el.innerHTML = '<svg viewBox="0 0 24 24">' + ICONS[type] + "</svg><div><b>" + esc(title) + "</b>" + esc(text) + "</div>";
  $("#toasts").appendChild(el);
  if (type === "err") sound("err"); else if (type === "ok") sound("ok");
  setTimeout(() => el.remove(), CONFIG.toastTime);
}
function switchTab(name) {
  $$(".tab").forEach(t => t.classList.toggle("on", t.dataset.tab === name));
  $$(".pane").forEach(p => p.classList.toggle("on", p.id === name));
  const first = $("#" + name + " input"); if (first) first.focus();
}

/* ---------- 3) SOUNDS & MUSIC ---------- */
let actx;
document.addEventListener("pointerdown", () => { try { actx = actx || new (window.AudioContext || window.webkitAudioContext)(); } catch (e) {} }, { once: true });   // create it on the first click so the first sound does not stutter
function sound(kind) {                           // kind: click | err | ok  (generated, no files needed)
  if (!CONFIG.sounds) return;
  try {
    actx = actx || new (window.AudioContext || window.webkitAudioContext)();
    const tones = { click: [[520, 0.04]], err: [[190, 0.16]], ok: [[660, 0.08], [880, 0.12]] }[kind];
    let t = actx.currentTime;
    tones.forEach(([f, d]) => {
      const o = actx.createOscillator(), g = actx.createGain();
      o.frequency.value = f; o.type = kind === "err" ? "square" : "sine";
      g.gain.setValueAtTime(0.04, t); g.gain.exponentialRampToValueAtTime(0.0001, t + d);
      o.connect(g); g.connect(actx.destination); o.start(t); o.stop(t + d); t += d;
    });
  } catch (e) {}
}

/* The audio itself is played by Lua (client.lua). This is only the controller:
   it renders the state and sends { volume, muted, final } to Lua. */
const music = { vol: CONFIG.music.volume, last: CONFIG.music.volume, muted: false };
let mTimer = 0;
function renderMusic() {
  const eff = music.muted ? 0 : music.vol, pct = Math.round(music.vol * 100), v = $("#vol");
  const box = $("#musicBox");
  box.classList.toggle("on", eff > 0);
  box.dataset.lv = eff === 0 ? 0 : eff < 0.5 ? 1 : 2;       // speaker icon: off / low / high
  v.value = pct; v.style.setProperty("--p", pct + "%");
  $("#volPct").textContent = eff === 0 ? "OFF" : pct + "%";
  $("#musicBtn").setAttribute("aria-pressed", String(eff > 0));
}
function pushMusic(final) { send("music", { volume: music.vol, muted: music.muted ? 1 : 0, final: final ? 1 : 0 }); }
function pushMusicSoon() { if (!mTimer) mTimer = setTimeout(() => { mTimer = 0; pushMusic(false); }, 50); }
function setVolume(v, final) {
  music.vol = Math.max(0, Math.min(1, v));
  if (music.vol > 0) { music.last = music.vol; music.muted = false; }
  renderMusic(); final ? pushMusic(true) : pushMusicSoon();
}
function toggleMusic() {
  if (music.muted || music.vol === 0) { music.muted = false; if (music.vol === 0) music.vol = music.last || CONFIG.music.volume; }
  else music.muted = true;
  sound("click"); renderMusic(); pushMusic(true);
}
$("#musicBtn").onclick = toggleMusic;
$("#vol").addEventListener("input", e => setVolume(e.target.value / 100, false));
$("#vol").addEventListener("change", e => setVolume(e.target.value / 100, true));
$("#vol").addEventListener("pointerdown", () => $("#musicBox").classList.add("drag"));
window.addEventListener("pointerup", () => $("#musicBox").classList.remove("drag"));
$("#musicBox").addEventListener("wheel", e => {                // mouse wheel = volume +-5%
  e.preventDefault(); setVolume(music.vol + (e.deltaY < 0 ? 0.05 : -0.05), true);
}, { passive: false });
document.addEventListener("keydown", e => {                    // M = mute / unmute (when no text field is focused)
  const t = document.activeElement && document.activeElement.tagName;
  if ((e.key || "").toLowerCase() === "m" && !e.ctrlKey && !e.altKey && !e.metaKey && t !== "INPUT" && !$("#musicBox").hidden) toggleMusic();
});
renderMusic();

/* ---------- 4) VALIDATION ----------
   Return [elementId, message] when something is wrong, or null when OK. */
const M = CONFIG.msg; let userFree = null;      // result of the username check (true/false/null)
const phoneOk = p => /^\+?[\d\s\-()]{10,20}$/.test(p) && p.replace(/\D/g, "").length >= 10 && p.replace(/\D/g, "").length <= 15;
const codeShown = () => !$("#codeField").hidden;
const RULES = {
  login: () => !val("l_user") ? ["l_user", M.needUser] : !val("l_pass") ? ["l_pass", M.needPass] : null,
  register: () =>
    val("r_user").length < CONFIG.minUser ? ["r_user", M.userShort] :
    !/^\w+$/.test(val("r_user")) ? ["r_user", M.userChars] :
    userFree === false ? ["r_user", M.taken] :
    !phoneOk(val("r_phone")) ? ["r_phone", M.phone] :
    val("r_pass").length < CONFIG.minPass ? ["r_pass", M.passShort] :
    val("r_pass") !== val("r_conf") ? ["r_conf", M.noMatch] :
    !$("#acceptRules").classList.contains("on") ? ["acceptRules", M.rules] : null,
  change: () =>
    !val("c_user") ? ["c_user", M.needUser] : !val("c_old") ? ["c_old", M.needOld] :
    val("c_new").length < CONFIG.minPass ? ["c_new", M.passShort] :
    val("c_new") !== val("c_conf") ? ["c_conf", M.noMatch] : null,
  recover: () =>
    !val("s_user") ? ["s_user", M.needUser] : !val("s_pass") ? ["s_pass", M.needPass] :
    codeShown() && !/^\d{6}$/.test(val("s_code")) ? ["s_code", M.code] : null,
};
const PAYLOAD = {    // data sent to Lua per action
  login:    () => ({ username: val("l_user"), password: val("l_pass"), remember: $("#remember").classList.contains("on") }),
  register: () => ({ username: val("r_user"), phone: val("r_phone"), password: val("r_pass") }),
  change:   () => ({ username: val("c_user"), oldPassword: val("c_old"), newPassword: val("c_new") }),
  recover:  () => ({ username: val("s_user"), password: val("s_pass"), code: codeShown() ? val("s_code") : "" }),
};

/* ---------- 5) EVENTS ---------- */
let lockedUntil = 0; const isLocked = () => Date.now() < lockedUntil;

function submit(action) {
  if (!$("#verify").hidden || !$("#profile").hidden) return;      // Telegram verification / profile wizard is open
  if (action === "login" && isLocked()) return;
  const err = RULES[action]();
  if (err) {                                    // shake the bad element + notification
    const el = $("#" + err[0]), box = el.matches("input") ? el.parentNode : el;
    box.classList.remove("bad"); void box.offsetWidth; box.classList.add("bad");
    if (el.matches("input")) el.focus();
    return notify("err", "Invalid input", err[1]);
  }
  const btn = $('.btn[data-action="' + action + '"]');
  btn.disabled = true; sound("click");
  send(action, PAYLOAD[action]());
  setTimeout(() => { if (!(action === "login" && isLocked())) btn.disabled = false; }, CONFIG.unlockAfter);
}
$$(".tab").forEach(t => (t.onclick = () => { sound("click"); switchTab(t.dataset.tab); }));
$$(".btn").forEach(b => (b.onclick = () => submit(b.dataset.action)));
$$(".check").forEach(c => (c.onclick = () => { c.classList.toggle("on"); c.classList.remove("bad"); sound("click"); }));
$("#forgotUser").onclick = () => send("forgotUsername", {});          // server replies with a notification
$$("[data-link]").forEach(b => (b.onclick = () => {
  const n = b.dataset.link, name = n[0].toUpperCase() + n.slice(1);
  sound("click"); send("openLink", { name: n, url: CONFIG.links[n] });   // Lua: setClipboard(url)
  if (window.mta) notify("info", name, "Link copied to clipboard.");
  else window.open(CONFIG.links[n]);
}));
$$("[data-eye]").forEach(e => (e.onclick = () => { const i = e.parentNode.querySelector("input"); i.type = i.type === "password" ? "text" : "password"; }));

$$("input[type=text],input[type=password]").forEach(i => {
  i.addEventListener("input", () => i.parentNode.classList.remove("bad"));
  i.addEventListener("keydown", e => {
    if (e.key === "Enter") submit($(".pane.on .btn").dataset.action);
    if (i.id === "l_pass") $("#caps").style.display = e.getModifierState && e.getModifierState("CapsLock") ? "block" : "none";
  });
});

/* register: live password rules */
$("#r_pass").addEventListener("input", e => {
  const p = e.target.value, ok = { len: p.length >= CONFIG.minPass, case: /[A-Z]/.test(p) && /[a-z]/.test(p), num: /\d/.test(p), sym: /[^\w\s]/.test(p) };
  $$("#pwRules span").forEach(s => s.classList.toggle("ok", ok[s.dataset.r]));
});
/* register: username availability (asks Lua, which answers with lg.usernameStatus) */
let uTimer;
$("#r_user").addEventListener("input", e => {
  clearTimeout(uTimer); userFree = null; const u = e.target.value.trim(), s = $("#uStatus");
  s.className = "mini"; s.textContent = "";
  if (u.length < CONFIG.minUser) return;
  s.textContent = "Checking..."; uTimer = setTimeout(() => send("checkUsername", { username: u }), 450);
});

/* ---------- 6) FEATURES ---------- */
let lockTimer;
function lock(seconds) {                         // login lockout with countdown
  lockedUntil = Date.now() + seconds * 1000;
  const btn = $('.btn[data-action="login"]'); btn.classList.add("locked"); btn.disabled = true;
  clearInterval(lockTimer);
  const tick = () => {
    const left = Math.ceil((lockedUntil - Date.now()) / 1000);
    if (left <= 0) { clearInterval(lockTimer); btn.classList.remove("locked"); btn.disabled = false; btn.textContent = "Login"; return; }
    btn.textContent = "Locked  " + left + "s";
  };
  tick(); lockTimer = setInterval(tick, 250);
}

function setState(kind, info) {                  // "maintenance" | "banned" | "normal"
  const box = $("#blocked"); info = info || {};
  if (kind === "normal") return (box.hidden = true);
  const maint = kind === "maintenance";
  $("#bIcon").innerHTML = maint
    ? '<svg viewBox="0 0 24 24"><path d="M14.7 6.3a4 4 0 0 0-5 5L3 18l3 3 6.700-6.700a4 4 0 0 0 5-5l-2.500 2.500-2.500-.5-.5-2.500z"/></svg>'
    : '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M5.600 5.600l12.800 12.800"/></svg>';
  $("#bTitle").textContent = maint ? "MAINTENANCE" : "ACCOUNT BANNED";
  $("#bText").textContent = info.message || (maint ? "The server is being updated. Please come back soon." : "This account has been banned from the server.");
  $("#bExtra").textContent = info.extra || ""; box.hidden = false;
}

function setAnnouncements(list) {                // [{title, text, date}] (max 3 shown)
  const box = $("#news"); box.innerHTML = ""; box.hidden = !list || !list.length;
  (list || []).slice(0, 3).forEach(n => box.insertAdjacentHTML("beforeend",
    '<div class="n"><b>' + esc(n.title) + "<i>" + esc(n.date || "") + "</i></b><p>" + esc(n.text) + "</p></div>"));
}
function setPlayers(count) { $("#online").classList.add("live"); $("#onlineCount").textContent = count; }

function loginSuccess(username) {                // fade + welcome animation, then tells Lua to close the UI
  sound("ok"); $("#wName").textContent = username || "Player"; $("#welcome").hidden = false;
  setTimeout(() => send("welcomeDone", {}), 2300);
}
function loginFailed(left) { notify("err", "Login failed", "Wrong username or password. " + left + " attempt(s) left."); unlock(); }
function unlock() { $$(".btn").forEach(b => { if (!(b.dataset.action === "login" && isLocked())) b.disabled = false; }); }
function codeSent() {                            // recovery step 2: show the 6-digit field
  $("#codeField").hidden = false; $("#s_code").focus();
  $('.btn[data-action="recover"]').textContent = "Confirm Code"; unlock();
  notify("info", "Code sent", "Check the Telegram bot for your 6-digit code.");
}
function usernameStatus(name, free, reason) {            // answer to "checkUsername"
  if (name !== val("r_user")) return;
  userFree = !!free; const s = $("#uStatus"); s.className = "mini " + (free ? "ok" : "bad"); s.textContent = free ? "Available" : (reason || "Already taken");
}

/* ---------- TELEGRAM VERIFICATION (shown after "Create Account") ---------- */
let vTick = 0;
function drawQR(text) {
  const cv = $("#qr"), ctx = cv.getContext("2d");
  ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, cv.width, cv.height);
  try {
    const q = qrcode(0, "M"); q.addData(text); q.make();
    const n = q.getModuleCount(), cell = Math.floor((cv.width - 16) / n), off = Math.floor((cv.width - cell * n) / 2);
    ctx.fillStyle = "#000";
    for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (q.isDark(r, c)) ctx.fillRect(off + c * cell, off + r * cell, cell, cell);
  } catch (e) { cv.style.visibility = "hidden"; }       // QR failed: the link below still works
}
function verifyStep(n) {                         // n = completed steps (0..3)
  $$("#vsteps li").forEach((li, i) => { li.classList.toggle("done", i < n); li.classList.toggle("active", i === n); });
  if (n >= 3) sound("ok"); else if (n > 0) sound("click");
}
function verifyStart(link, ttl) {
  if (document.activeElement) document.activeElement.blur();
  $("#vLink").value = link; $("#qr").style.visibility = "visible"; drawQR(link); verifyStep(0);
  const end = Date.now() + ttl * 1000;
  const tick = () => {
    const s = Math.max(0, Math.ceil((end - Date.now()) / 1000));
    $("#vTimer").textContent = s ? "Expires in " + String(Math.floor(s / 60)).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0") : "Expired";
  };
  clearInterval(vTick); tick(); vTick = setInterval(tick, 1000);
  $("#verify").hidden = false; unlock();
  send("openLink", { name: "verify", url: link });                       // Lua: setClipboard(url)
  notify("info", "Link copied", "Open Telegram and paste it, or scan the QR code.");
}
function verifyClose(ms) { setTimeout(() => { clearInterval(vTick); $("#verify").hidden = true; unlock(); }, ms || 0); }
$("#vCopy").onclick = () => { send("openLink", { name: "verify", url: $("#vLink").value }); notify("ok", "Copied", "Link copied to clipboard."); };
$("#vCancel").onclick = () => { sound("click"); send("cancelVerify", {}); verifyClose(); };

/* ---------- PROFILE WIZARD (after registration, or at login when the profile is missing) ---------- */
const MON_G = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const MON_J = ["فروردین", "اردیبهشت", "خرداد", "تیر", "مرداد", "شهریور", "مهر", "آبان", "آذر", "دی", "بهمن", "اسفند"];
function g2j(gy, gm, gd) {                       // Gregorian -> Jalali (Solar Hijri)
  const gdm = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334], gy2 = gm > 2 ? gy + 1 : gy;
  let days = 355666 + 365 * gy + ~~((gy2 + 3) / 4) - ~~((gy2 + 99) / 100) + ~~((gy2 + 399) / 400) + gd + gdm[gm - 1];
  let jy = -1595 + 33 * ~~(days / 12053); days %= 12053;
  jy += 4 * ~~(days / 1461); days %= 1461;
  if (days > 365) { jy += ~~((days - 1) / 365); days = (days - 1) % 365; }
  return [jy, days < 186 ? 1 + ~~(days / 31) : 7 + ~~((days - 186) / 30), 1 + (days < 186 ? days % 31 : (days - 186) % 30)];
}
function j2g(jy, jm, jd) {                       // Jalali -> Gregorian
  jy += 1595;
  let days = -355668 + 365 * jy + ~~(jy / 33) * 8 + ~~(((jy % 33) + 3) / 4) + jd + (jm < 7 ? (jm - 1) * 31 : (jm - 7) * 30 + 186);
  let gy = 400 * ~~(days / 146097); days %= 146097;
  if (days > 36524) { gy += 100 * ~~(--days / 36524); days %= 36524; if (days >= 365) days++; }
  gy += 4 * ~~(days / 1461); days %= 1461;
  if (days > 365) { gy += ~~((days - 1) / 365); days = (days - 1) % 365; }
  let gd = days + 1, gm;
  const sal = [0, 31, (gy % 4 === 0 && gy % 100 !== 0) || gy % 400 === 0 ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  for (gm = 0; gm < 13 && gd > sal[gm]; gm++) gd -= sal[gm];
  return [gy, gm, gd];
}
const jLeap = y => { const r = g2j(...j2g(y, 12, 30)); return r[0] === y && r[1] === 12 && r[2] === 30; };
const daysIn = (cal, y, m) => cal === "g" ? new Date(y, m, 0).getDate() : m <= 6 ? 31 : m <= 11 ? 30 : (jLeap(y) ? 30 : 29);
const pad2 = n => String(n).padStart(2, "0");

const P = { step: 0, cal: "g", gender: "", source: "", refOk: null, busy: false, minAge: 13, today: [2026, 1, 1], timer: 0 };
const FIELD_BOX = { name: "f_name", birth: "f_birth", gender: "f_gender", height: "f_height", weight: "f_weight", ref: "f_ref", source: "f_source" };
const FIELD_STEP = { name: 0, birth: 0, gender: 0, height: 1, weight: 1, ref: 2, source: 2 };

const D = { d: 0, m: 0, y: 0 };                 // chosen date, expressed in the current calendar
const DDK = ["d", "m", "y"], DDID = { d: "dd_day", m: "dd_mon", y: "dd_year" }, DDPH = { d: "Day", m: "Month", y: "Year" };
const monthNames = () => (P.cal === "g" ? MON_G : MON_J);
function yearList() {                            // youngest allowed year first
  const [ty, tm, td] = P.today, hi = [ty - P.minAge, tm, td], lo = [ty - 100, tm, td];
  const top = P.cal === "g" ? hi[0] : g2j(...hi)[0], bottom = P.cal === "g" ? lo[0] : g2j(...lo)[0], out = [];
  for (let y = top; y >= bottom; y--) out.push([y, String(y)]);
  return out;
}
function ddItems(k) {
  if (k === "d") { const n = D.y && D.m ? daysIn(P.cal, D.y, D.m) : 31; return Array.from({ length: n }, (_, i) => [i + 1, String(i + 1)]); }
  if (k === "m") return monthNames().map((n, i) => [i + 1, n]);
  return yearList();
}
function ddRender(k) {
  const box = $("#" + DDID[k]), txt = !D[k] ? "" : k === "m" ? monthNames()[D[k] - 1] : String(D[k]);
  box.querySelector(".ddv").textContent = txt || DDPH[k]; box.classList.toggle("empty", !txt);
}
function ddClose() { $$("#f_birth .dd.open").forEach(b => b.classList.remove("open")); }
function ddOpen(k) {
  ddClose();
  const box = $("#" + DDID[k]), list = box.querySelector(".ddl"), frag = document.createDocumentFragment();
  ddItems(k).forEach(([v, t]) => {
    const o = document.createElement("div"); o.className = "o" + (v === D[k] ? " sel" : ""); o.dataset.v = v; o.textContent = t; frag.appendChild(o);
  });
  list.innerHTML = ""; list.appendChild(frag); box.classList.add("open");
  let target = list.querySelector(".sel");
  if (!target && k === "y") {                    // nothing chosen yet: start near a typical birth year (2000 / 1379)
    const want = P.cal === "g" ? 2000 : 1379;
    target = [...list.children].reduce((best, el) => Math.abs(+el.dataset.v - want) < Math.abs(+best.dataset.v - want) ? el : best);
  }
  if (target) list.scrollTop = target.offsetTop - list.clientHeight / 2 + target.offsetHeight / 2;
}
function ddPick(k, v) {
  D[k] = v;
  if (D.d && D.y && D.m && D.d > daysIn(P.cal, D.y, D.m)) D.d = 0;     // e.g. 31 -> February: pick the day again
  ddClose(); DDK.forEach(ddRender);
  $("#f_birth").classList.remove("bad"); $("#pErr").textContent = ""; sound("click");
  const next = DDK.find(x => !D[x]);             // guide the user: open the next empty list automatically
  if (next) setTimeout(() => ddOpen(next), 80);
}
function resetDate(keep) {
  Object.assign(D, { d: 0, m: 0, y: 0 }, keep || {}); ddClose(); DDK.forEach(ddRender);
}
function birthG() {                              // selected date as Gregorian [y, m, d] or null
  if (!D.d || !D.m || !D.y || D.d > daysIn(P.cal, D.y, D.m)) return null;
  return P.cal === "g" ? [D.y, D.m, D.d] : j2g(D.y, D.m, D.d);
}
function ageOf([y, m, d]) { const [ty, tm, td] = P.today; let a = ty - y; if (tm < m || (tm === m && td < d)) a--; return a; }
function setCal(c) {
  if (c === P.cal) return;
  const g = birthG(); P.cal = c;
  $$("#pCal b").forEach(b => b.classList.toggle("on", b.dataset.c === c));
  if (g) { const [y, m, d] = c === "g" ? g : g2j(...g); resetDate({ y, m, d }); } else resetDate();
  sound("click");
}

function focusStep() {
  const el = [$("#p_name"), $("#p_height"), $("#p_ref")][P.step];
  if (el) setTimeout(() => el.focus(), 30);
}
function showStep(n) {
  P.step = n; ddClose();
  $$("#profile .pp").forEach(p => p.classList.toggle("on", +p.dataset.p === n));
  $$("#pTabs li").forEach((li, i) => { li.classList.toggle("active", i === n); li.classList.toggle("done", i < n || n === 3); });
  $("#pBack").style.visibility = n > 0 && n < 3 ? "visible" : "hidden";
  $("#pNext").textContent = n === 2 ? "Finish" : "Next";
  $(".pnav").hidden = n === 3; $("#pErr").textContent = "";
}
function flag(field, msg) {                      // shake the broken field + show the reason under the step
  const el = $("#" + FIELD_BOX[field]); el.classList.remove("bad"); void el.offsetWidth; el.classList.add("bad");
  $("#pErr").textContent = msg; sound("err");
  if (field === "birth") { const k = DDK.find(x => !D[x]); if (k) setTimeout(() => ddOpen(k), 60); }   // show the user what is missing
  else { const inp = el.querySelector("input"); if (inp) inp.focus(); }
  return false;
}
function validate(n) {
  if (n === 0) {
    const name = $("#p_name").value.replace(/\s+/g, " ").trim(), len = [...name].length;
    if (len < 3 || len > 40 || !/^[\p{L}\p{M}][\p{L}\p{M}\u200c\s'.\-]*$/u.test(name)) return flag("name", "Enter your real name (letters only, 3-40 characters).");
    const g = birthG();
    if (!g) return flag("birth", "Select your full date of birth.");
    const age = ageOf(g);
    if (age < P.minAge) return flag("birth", "You must be at least " + P.minAge + " years old to play.");
    if (age > 100) return flag("birth", "Enter a valid date of birth.");
    if (!P.gender) return flag("gender", "Select your gender.");
  } else if (n === 1) {
    const h = $("#p_height").value, w = $("#p_weight").value;
    if (!/^\d{3}$/.test(h) || +h < 100 || +h > 250) return flag("height", "Height must be between 100 and 250 cm.");
    if (!/^\d{2,3}$/.test(w) || +w < 30 || +w > 300) return flag("weight", "Weight must be between 30 and 300 kg.");
  } else if (n === 2) {
    const r = $("#p_ref").value;
    if (r && (!/^[A-HJ-NP-Z2-9]{6}$/.test(r) || P.refOk === false)) return flag("ref", "That referral code is not valid.");
    if (!P.source) return flag("source", "Tell us how you found the server.");
  }
  return true;
}
function setBusy(b) { $("#pNext").disabled = b; $("#pBack").disabled = b; }
function submitProfile() {
  const g = birthG();
  P.busy = true; setBusy(true);
  send("saveProfile", {
    name: $("#p_name").value.replace(/\s+/g, " ").trim(), birth: g[0] + "-" + pad2(g[1]) + "-" + pad2(g[2]), gender: P.gender,
    height: +$("#p_height").value, weight: +$("#p_weight").value, ref: $("#p_ref").value,
    source: P.source, other: P.source === "other" ? $("#p_other").value.trim() : "",
  });
  clearTimeout(P.timer);
  P.timer = setTimeout(() => { if (P.busy) { P.busy = false; setBusy(false); notify("err", "No response", "The server did not answer. Try again."); } }, 10000);
}
function nextStep() {
  if (P.busy || P.step > 2 || !validate(P.step)) return;
  sound("click");
  if (P.step < 2) { showStep(P.step + 1); focusStep(); } else submitProfile();
}

/* wiring */
$("#pNext").onclick = nextStep;
$("#pBack").onclick = () => { if (!P.busy && P.step > 0 && P.step < 3) { sound("click"); showStep(P.step - 1); focusStep(); } };
$("#profile").addEventListener("keydown", e => {
  if (e.key === "Escape") return ddClose();
  if (e.key === "Enter" && e.target.tagName !== "BUTTON" && !e.target.closest(".dd")) { e.preventDefault(); nextStep(); }
});
$$("#pCal b").forEach(b => (b.onclick = () => setCal(b.dataset.c)));
$("#f_birth").addEventListener("click", e => {           // open / choose
  const o = e.target.closest(".o"), box = e.target.closest(".dd");
  if (o && box) return ddPick(box.dataset.k, +o.dataset.v);
  if (e.target.closest(".ddl")) return;                          // scrollbar / padding of the open list: do nothing
  if (box) { const was = box.classList.contains("open"); ddClose(); if (!was) { sound("click"); ddOpen(box.dataset.k); } }
});
$("#f_birth").addEventListener("keydown", e => {
  const box = e.target.closest && e.target.closest(".dd");
  if (box && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); e.stopPropagation(); box.classList.contains("open") ? ddClose() : ddOpen(box.dataset.k); }
});
document.addEventListener("pointerdown", e => { if (!(e.target.closest && e.target.closest(".dd"))) ddClose(); });
function singleSelect(boxId, onPick) {
  $$("#" + boxId + " button").forEach(b => (b.onclick = () => {
    $$("#" + boxId + " button").forEach(x => x.classList.toggle("on", x === b));
    $("#" + boxId).classList.remove("bad"); $("#pErr").textContent = ""; sound("click"); onPick(b.dataset.v);
  }));
}
singleSelect("f_gender", v => (P.gender = v));
singleSelect("f_source", v => { P.source = v; $("#f_other").hidden = v !== "other"; if (v === "other") $("#p_other").focus(); });

function bump(inp, dir) {                        // + / - buttons: first press starts from a sensible default
  const min = +inp.dataset.min, max = +inp.dataset.max, def = +inp.dataset.def, cur = parseInt(inp.value, 10);
  inp.value = isNaN(cur) ? def : Math.max(min, Math.min(max, cur + dir));
  inp.parentNode.classList.remove("bad"); $("#pErr").textContent = "";
}
$$("#profile .sb").forEach(b => {
  let hold = 0, rep = 0;
  const stop = () => { clearTimeout(hold); clearInterval(rep); };
  b.addEventListener("pointerdown", e => {
    e.preventDefault(); stop(); const inp = $("#" + b.dataset.t), d = +b.dataset.d;
    bump(inp, d); hold = setTimeout(() => { rep = setInterval(() => bump(inp, d), 60); }, 400);
  });
  ["pointerup", "pointerleave", "pointercancel"].forEach(ev => b.addEventListener(ev, stop));
});
["p_height", "p_weight"].forEach(id => $("#" + id).addEventListener("input", e => (e.target.value = e.target.value.replace(/\D/g, ""))));

let refTimer = 0;
$("#p_ref").addEventListener("input", e => {    // live referral check (asks the server)
  const el = e.target, st = $("#refStatus");
  el.value = el.value.toUpperCase().replace(/[^A-Z0-9]/g, "");
  clearTimeout(refTimer); P.refOk = null; st.className = "mini"; st.textContent = "";
  if (el.value.length !== 6) return;
  if (!/^[A-HJ-NP-Z2-9]{6}$/.test(el.value)) { P.refOk = false; st.className = "mini bad"; st.textContent = "Invalid code"; return; }
  st.textContent = "Checking..."; refTimer = setTimeout(() => send("checkRef", { code: el.value }), 400);
});
$("#pCopy").onclick = () => { send("openLink", { name: "referral", url: $("#pCode").textContent }); notify("ok", "Copied", "Referral code copied."); };
$("#pGo").onclick = () => { sound("click"); $("#profile").hidden = true; send("profileContinue", {}); };

/* called by Lua */
function profileStart(username, opts) {
  opts = opts || {};
  P.minAge = opts.minAge || 13;
  P.today = String(opts.today || "").split("-").map(Number);
  if (P.today.length !== 3 || P.today.some(isNaN)) { const n = new Date(); P.today = [n.getFullYear(), n.getMonth() + 1, n.getDate()]; }
  Object.assign(P, { cal: "g", gender: "", source: "", refOk: null, busy: false });
  ["p_name", "p_height", "p_weight", "p_ref", "p_other"].forEach(i => ($("#" + i).value = ""));
  $$("#profile .seg button,#profile .chips button").forEach(b => b.classList.remove("on"));
  $$("#profile .bad").forEach(b => b.classList.remove("bad"));
  $$("#pCal b").forEach(b => b.classList.toggle("on", b.dataset.c === "g"));
  $("#f_other").hidden = true; $("#refStatus").textContent = ""; $("#refStatus").className = "mini";
  $("#pHello").textContent = "Welcome, " + username;
  resetDate(); showStep(0); setBusy(false);
  const open = () => { $("#profile").hidden = false; unlock(); focusStep(); };
  if (!$("#verify").hidden) setTimeout(open, 900); else open();
}
function profileError(field, msg) {
  P.busy = false; clearTimeout(P.timer); setBusy(false);
  if (field in FIELD_STEP) { showStep(FIELD_STEP[field]); flag(field, msg); } else $("#pErr").textContent = msg;
  notify("err", "Profile", msg);
}
function profileDone(code) {
  P.busy = false; clearTimeout(P.timer); setBusy(false);
  $("#pCode").textContent = code || "------"; showStep(3); sound("ok");
}
function refStatus(code, ok) {
  if (code !== $("#p_ref").value) return;
  P.refOk = !!ok; const st = $("#refStatus"); st.className = "mini " + (ok ? "ok" : "bad"); st.textContent = ok ? "Valid code" : "Invalid code";
}

/* ---------- 7) MTA BRIDGE ----------
   UI -> Lua : mta.triggerEvent("lg:auth", action, key1, value1, key2, value2, ...)
     actions : login | register | change | recover | forgotUsername | checkUsername | cancelVerify | saveProfile | checkRef | profileContinue | openLink | music | welcomeDone
   Lua -> UI : executeBrowserJavascript(browser, "lg.notify('ok','Done','Welcome')")  */
function send(action, data) {
  if (window.mta) mta.triggerEvent(CONFIG.eventName, action, ...Object.entries(data || {}).flat());
  else console.log(action, data);                // preview in a normal browser
}
const clear = ids => ids.forEach(i => ($("#" + i).value = ""));
window.lg = {
  notify, unlock, switchTab, setPlayers, setState, setAnnouncements, loginSuccess, loginFailed, codeSent, usernameStatus, lock,
  setSerial: s => ($("#s_serial").value = s),    // show serial in the Recovery tab
  fill: (u, p) => { $("#l_user").value = u; if (p) $("#l_pass").value = p; $("#l_pass").focus(); },   // Remember me: username (+ password)   // prefill username (Remember me)
  setRemember: on => $("#remember").classList.toggle("on", !!on),
  verifyStart, verifyStep, verifyClose, profileStart, profileError, profileDone, refStatus,
  noMusic: () => ($("#musicBox").hidden = true),
  setMusic: (v, m) => { music.vol = v; if (v > 0) music.last = v; music.muted = !!m; renderMusic(); },
  registerDone: u => {
    clear(["r_user", "r_phone", "r_pass", "r_conf"]); $("#uStatus").textContent = ""; userFree = null;
    $$("#pwRules span").forEach(x => x.classList.remove("ok")); $("#acceptRules").classList.remove("on");
    switchTab("login"); $("#l_user").value = u; $("#l_pass").focus(); unlock();
  },
  changeDone: () => { clear(["c_user", "c_old", "c_new", "c_conf"]); switchTab("login"); unlock(); },
  recoverDone: () => {
    clear(["s_user", "s_pass", "s_code"]); $("#codeField").hidden = true;
    $('.btn[data-action="recover"]').textContent = "Recover Account"; switchTab("login"); unlock();
  },
};
$("#l_user").focus();

/* ---------- PERFORMANCE ----------
   CONFIG.lite = true forces the light mode. Otherwise flow.js measures the real FPS while the intro plays
   and switches to light mode by itself on a weak PC (it can no longer misfire while the page preloads). */
if (CONFIG.lite) document.documentElement.classList.add("lite");
