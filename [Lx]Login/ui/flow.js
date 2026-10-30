/* =====================================================================
   LINUX Game - flow.js : invisible preload -> intro -> login reveal
   (loaded after script.js). The page is transparent while it preloads
   (the game chat stays visible); the intro starts only when fonts,
   images, audio and the server answer are REALLY ready, so it never lags.
   ===================================================================== */
(function () {
  "use strict";
  const q = s => document.querySelector(s), root = document.documentElement, L = window.lg;
  const intro = q("#intro");
  const INTRO_MS = 5600;                       // total intro length (the progress line in flow.css is 5.4 s)

  /* ----- 1) wait (invisibly) until everything is really loaded ----- */
  const need = { fonts: false, visual: false, audio: false, server: false };
  let started = false;

  function mark(id) { if (!need[id]) { need[id] = true; check(); } }
  function check() {
    if (started || !Object.values(need).every(Boolean)) return;
    started = true; prepared();
  }

  const fonts = document.fonts
    ? Promise.all([document.fonts.load("700 14px LGTitle"), document.fonts.load("14px LGBody"), document.fonts.ready])
    : Promise.resolve();
  fonts.then(() => mark("fonts"), () => mark("fonts"));

  const img = u => new Promise(res => {
    const i = new Image(); i.onload = i.onerror = () => res(); i.src = u;
    if (i.decode) i.decode().then(res, res);
  });
  Promise.all([img("bg.jpg"), img("logo.png")]).then(() => mark("visual"));

  if (L) {                                     // Lua tells us when the sound / the server answer really arrived
    const sm = L.setMusic, nm = L.noMusic, ss = L.setSerial;
    L.setMusic = function () { sm.apply(L, arguments); mark("audio"); };
    L.noMusic = function () { nm.apply(L, arguments); mark("audio"); };
    L.setSerial = function () { ss.apply(L, arguments); mark("server"); };
  }
  if (!window.mta) setTimeout(() => { mark("audio"); mark("server"); }, 600);      // preview in a normal browser

  /* never hang: after 10 s the intro starts anyway (late answers still update the page) */
  setTimeout(() => { if (!started) { started = true; prepared(); } }, 10000);

  function prepared() {
    try {                                      // create the audio engine now, so the first intro sound does not stutter
      actx = actx || new (window.AudioContext || window.webkitAudioContext)();
      if (actx.state === "suspended") actx.resume();
    } catch (e) {}
    send("stage", { name: "loaded" });         // Lua prints the final chat line
    setTimeout(startIntro, 900);               // the player can read it first
  }

  /* ----- 2) intro ----- */
  let introOn = false, introT0 = 0, introTimer = 0, ended = false;

  function sfx() {
    if (!CONFIG.sounds) return;
    try {
      actx = actx || new (window.AudioContext || window.webkitAudioContext)();
      if (actx.state === "suspended") actx.resume();
      const t = actx.currentTime;
      const tone = (type, f0, f1, at, dur, vol) => {
        const o = actx.createOscillator(), g = actx.createGain();
        o.type = type; o.frequency.setValueAtTime(f0, t + at); o.frequency.exponentialRampToValueAtTime(f1, t + at + dur);
        g.gain.setValueAtTime(0.0001, t + at); g.gain.exponentialRampToValueAtTime(vol, t + at + dur * 0.15);
        g.gain.exponentialRampToValueAtTime(0.0001, t + at + dur);
        o.connect(g); g.connect(actx.destination); o.start(t + at); o.stop(t + at + dur + 0.05);
      };
      tone("sawtooth", 70, 800, 0.1, 1.2, 0.025);     // rising sweep
      tone("sine", 130, 36, 1.3, 1.0, 0.11);          // impact when the logo lands
      tone("sine", 1760, 880, 1.4, 1.3, 0.018);       // shimmer
    } catch (e) {}
  }

  function startIntro() {
    /* two frames: the browser finishes its last layout first, then every animation starts on a clean frame */
    requestAnimationFrame(() => requestAnimationFrame(() => {
      root.classList.remove("pre");             // the page becomes opaque here
      intro.classList.add("run");               // all intro animations start together (they were pre-rendered, paused)
      introOn = true; introT0 = performance.now();
      send("stage", { name: "intro" });         // Lua: hide chat, start the music
      sfx();
      introTimer = setTimeout(() => endIntro(false), INTRO_MS);
    }));
  }

  function endIntro() {
    if (ended) return; ended = true;
    clearTimeout(introTimer);
    intro.classList.add("out");
    reveal();                                   // the login panel starts sliding in WHILE the intro opens: no dark gap
  }

  /* staggered form entrance whenever a tab opens */
  function enter(name, first) {
    const p = q("#" + name); if (!p) return;
    p.classList.remove("enter", "first"); void p.offsetWidth;
    p.classList.add("enter"); if (first) p.classList.add("first");
    clearTimeout(p._t); p._t = setTimeout(() => p.classList.remove("enter", "first"), first ? 2000 : 1100);
  }
  const swOrig = window.switchTab;
  if (typeof swOrig === "function") {
    window.switchTab = function (n) { swOrig(n); enter(n); };
    if (L) L.switchTab = n => window.switchTab(n);
  }

  function reveal() {
    enter("login", true);
    root.classList.add("reveal", "ui-in");
    root.classList.remove("ui-off");
    setTimeout(() => {
      intro.classList.add("gone"); introOn = false;
      const u = q("#l_user"), p = q("#l_pass");
      (u.value ? p : u).focus();
      send("stage", { name: "login" });         // Lua: show the cursor
    }, 1100);
    setTimeout(() => root.classList.remove("ui-in", "reveal"), 2200);
  }

  const skip = () => { if (introOn && performance.now() - introT0 > 800) endIntro(); };
  window.addEventListener("keydown", skip, true);
  intro.addEventListener("pointerdown", skip);

  /* ----- 3) forgot password (Telegram code) ----- */
  const rShown = () => !q("#resetBox").hidden, rBtn = () => q('.btn[data-action="reset"]');
  RULES.reset = () =>
    !val("f_user") ? ["f_user", M.needUser] :
    rShown() && !/^\d{6}$/.test(val("f_code")) ? ["f_code", M.code] :
    rShown() && val("f_pass").length < CONFIG.minPass ? ["f_pass", M.passShort] :
    rShown() && val("f_pass") !== val("f_conf") ? ["f_conf", M.noMatch] : null;
  PAYLOAD.reset = () => ({ username: val("f_user"), code: rShown() ? val("f_code") : "", password: rShown() ? val("f_pass") : "" });
  q("#f_resend").onclick = () => { if (val("f_user")) { sound("click"); send("reset", { username: val("f_user"), code: "", password: "" }); } };
  if (L) {
    L.resetCodeSent = () => {
      q("#resetBox").hidden = false; rBtn().textContent = "Reset Password"; unlock(); q("#f_code").focus();
      notify("info", "Code sent", "If this account exists, a 6-digit code was sent to its Telegram bot.");
    };
    L.resetDone = u => {
      ["f_user", "f_code", "f_pass", "f_conf"].forEach(i => (q("#" + i).value = ""));
      q("#resetBox").hidden = true; rBtn().textContent = "Send Code";
      switchTab("login"); q("#l_user").value = u || ""; q("#l_pass").focus(); unlock();
    };
  }
})();