--[[ =====================================================================
   LINUX Game - Account System | client.lua
   Flow: welcome chat -> silent file download (chat lines only)
         -> hidden page preload -> intro -> login panel.
   There is NO download screen and NO loading screen any more.
   ===================================================================== ]]

local URL_UI         = "http://mta/local/ui/index.html"  -- main UI (intro + login), preloaded invisibly
local MUSIC_FILE     = "music.mp3"
local DEFAULT_VOLUME = 0.3
local SETTINGS_FILE  = "settings.txt"
local REMEMBER_FILE  = "remember.txt"
local KEY_FILE       = "remember.key"
local VERSION_FILE   = "assets.ver"
local ASSET_VERSION  = "3"        -- bump this number every time you change a file in ui/ : every player re-downloads them once

-- Every file listed here MUST have download="false" in meta.xml (they are fetched with downloadFile).
local FILES = {
  "ui/index.html", "ui/style.css", "ui/flow.css", "ui/script.js", "ui/flow.js", "ui/qrcode.js",
  "ui/bg.jpg", "ui/fonts/title.ttf", "ui/fonts/body.ttf", MUSIC_FILE,
}
local OPTIONAL = { [MUSIC_FILE] = true }   -- the server still works if these cannot be downloaded

-- Chat lines (MTA's chat cannot shape Persian/Arabic text, so keep these in English)
local TXT = {
  welcome = {
    "#ff2442» #ffffffWelcome to #ff2442LINUX Game#ffffff.",
    "#ff2442» #ffffffYou are entering the server, please wait...",
  },
  downloading = "#ff2442» #ffffffDownloading server files (%d). Please do not close the game.",
  downloaded  = "#ff2442» #ffffffDownload complete.",
  loading     = "#ff2442» #ffffffPreparing everything for you...",
  ready       = "#ff2442» #ffffffEverything is ready. Enjoy your stay!",
}

addEvent("lg:auth", true)                -- fired by the page: mta.triggerEvent("lg:auth", ...)
addEvent("lg:client:ui", true)           -- fired by server.lua
addEvent("lg:client:close", true)

local gui, browser, ready, queue = nil, nil, false, {}
local created, loadRetries = false, 0
local rememberWanted, pendingPass = false, nil
local blockChat, ownMsg, ours = false, false, {}
local dl, serverAck, askTimer, askTries, audioTimer = nil, false, nil, 0, nil

-- functions the server / this script may call inside the page (window.lg.*)
local ALLOWED = {
  notify = true, unlock = true, switchTab = true, setPlayers = true, setState = true, setAnnouncements = true,
  loginSuccess = true, loginFailed = true, codeSent = true, usernameStatus = true, lock = true, setSerial = true,
  fill = true, setRemember = true, noMusic = true, setMusic = true, registerDone = true, changeDone = true, recoverDone = true,
  verifyStart = true, verifyStep = true, verifyClose = true,
  profileStart = true, profileError = true, profileDone = true, refStatus = true,
  resetCodeSent = true, resetDone = true,
}

--------------------------------------------------------------------------
-- Lua value -> JavaScript literal
--------------------------------------------------------------------------
local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function jsStr(s)
  s = tostring(s):gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end)
  s = s:gsub("\226\128\168", "\\u2028"):gsub("\226\128\169", "\\u2029")
  return '"' .. s .. '"'
end
local function js(v)
  local t = type(v)
  if t == "string" then return jsStr(v) end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "table" then
    local out = {}
    if v[1] ~= nil then
      for i = 1, #v do out[i] = js(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    for k, x in pairs(v) do out[#out + 1] = jsStr(k) .. ":" .. js(x) end
    if #out == 0 then return "[]" end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end
local function jsCall(ns, fn, ...)
  local args = {}
  for i = 1, select("#", ...) do args[i] = js((select(i, ...))) end
  return ns .. "." .. fn .. "(" .. table.concat(args, ",") .. ")"
end

local function callUI(fn, ...)
  if not ALLOWED[fn] then return end
  local code = jsCall("lg", fn, ...)
  if ready and isElement(browser) then executeBrowserJavascript(browser, code) else queue[#queue + 1] = code end
end

--------------------------------------------------------------------------
-- chat: only OUR lines are shown until the player is logged in
--------------------------------------------------------------------------
local function say(txt)
  ours[txt] = true
  ownMsg = true
  outputChatBox(txt, 255, 255, 255, true)
  ownMsg = false
end
addEventHandler("onClientChatMessage", root, function(text)
  if blockChat and not ownMsg and not ours[text] then cancelEvent() end
end)

--------------------------------------------------------------------------
-- small file helpers (client-side, inside the resource's private folder)
--------------------------------------------------------------------------
local function readFile(name, maxLen)
  if not fileExists(name) then return nil end
  local f = fileOpen(name, true)
  if not f then return nil end
  local txt = fileRead(f, math.min(fileGetSize(f), maxLen))
  fileClose(f)
  return type(txt) == "string" and txt or nil
end
local function writeFile(name, txt)
  if fileExists(name) then fileDelete(name) end
  if not txt or txt == "" then return end
  local f = fileCreate(name)
  if f then fileWrite(f, txt); fileClose(f) end
end

-- when ASSET_VERSION changes, the old cached ui files are deleted so the player always gets the newest version
local function refreshCache()
  if readFile(VERSION_FILE, 16) == ASSET_VERSION then return end
  for _, n in ipairs(FILES) do
    if not OPTIONAL[n] and fileExists(n) then fileDelete(n) end
  end
  writeFile(VERSION_FILE, ASSET_VERSION)
end

local function rememberKey()                    -- random key generated once on this PC
  local k = readFile(KEY_FILE, 64)
  if not k or #k < 16 then
    math.randomseed(getTickCount() + getRealTime().timestamp)
    k = hash("sha256", tostring(getTickCount()) .. tostring(math.random()) .. tostring(getRealTime().timestamp)):sub(1, 32)
    writeFile(KEY_FILE, k)
  end
  return k
end
local function saveRemember(user, pass)             -- user = nil -> forget everything
  if type(user) ~= "string" or user == "" then return writeFile(REMEMBER_FILE, "") end
  local enc = type(pass) == "string" and pass ~= "" and base64Encode(teaEncode(pass, rememberKey())) or ""
  writeFile(REMEMBER_FILE, user .. "\n" .. enc)
end
local function loadRemember()                       -- returns username, password (password may be nil)
  local txt = readFile(REMEMBER_FILE, 256)
  if not txt then return nil end
  local name, enc = txt:match("^([%w_]+)\n?(.*)$")
  if not name or #name < 3 or #name > 20 then return nil end
  local pass
  if enc and enc ~= "" then
    local raw = base64Decode(enc)
    pass = raw and teaDecode(raw, rememberKey())
    if type(pass) ~= "string" or pass == "" or #pass > 30 then pass = nil end
  end
  return name, pass
end

--------------------------------------------------------------------------
-- music: state, smooth fades, persistence
--------------------------------------------------------------------------
local music = { volume = DEFAULT_VOLUME, muted = false }
local bgm, curVol, fade = nil, 0, nil

local function truthy(v) return v == true or v == 1 or v == "1" or v == "true" end
local function clamp01(v) return math.max(0, math.min(1, tonumber(v) or 0)) end
local function musicTarget() return (music.muted or music.volume <= 0) and 0 or music.volume end

local function loadSettings()
  local v, m = (readFile(SETTINGS_FILE, 16) or ""):match("^(%d+);([01])$")
  if v then music.volume = clamp01(tonumber(v) / 100); music.muted = (m == "1") end
end
local function saveSettings()
  writeFile(SETTINGS_FILE, string.format("%d;%d", math.floor(music.volume * 100 + 0.5), music.muted and 1 or 0))
end

local function setVol(v)
  curVol = v
  if isElement(bgm) then setSoundVolume(bgm, v) end
end
local function fadeTo(to, ms, done)
  if not isElement(bgm) then if done then done() end return end
  fade = { from = curVol, to = to, t0 = getTickCount(), ms = math.max(1, ms), done = done }
end
addEventHandler("onClientRender", root, function()
  if not fade then return end
  local k = (getTickCount() - fade.t0) / fade.ms
  if k >= 1 then
    local f = fade
    fade = nil
    setVol(f.to)
    if f.done then f.done() end
  else
    setVol(fade.from + (fade.to - fade.from) * k)
  end
end)

local function applyMusic(ms)
  if not isElement(bgm) then return end
  local to = musicTarget()
  if to > 0 then
    setSoundPaused(bgm, false)
    fadeTo(to, ms)
  else
    fadeTo(0, ms, function() if isElement(bgm) then setSoundPaused(bgm, true) end end)
  end
end

-- preload stage: create the sound silently and report to the page when it is REALLY loaded
local function startAudio()
  if isElement(bgm) then return callUI("setMusic", music.volume, music.muted) end
  if not fileExists(MUSIC_FILE) then return callUI("noMusic") end
  bgm = playSound(MUSIC_FILE, true)
  if not bgm then return callUI("noMusic") end
  setVol(0)
  local tries = 0
  audioTimer = setTimer(function()
    tries = tries + 1
    if not isElement(bgm) then
      killTimer(audioTimer); return callUI("noMusic")
    end
    if (tonumber(getSoundLength(bgm)) or 0) > 0 or tries >= 50 then      -- 5 s max
      killTimer(audioTimer)
      callUI("setMusic", music.volume, music.muted)
    end
  end, 100, 0)
end

-- intro stage: start from the beginning and fade in
local function beginMusic()
  if not isElement(bgm) then return end
  setSoundPosition(bgm, 0)
  if musicTarget() == 0 then setSoundPaused(bgm, true) else setSoundPaused(bgm, false); fadeTo(musicTarget(), 2500) end
end

local function stopMusic(instant)
  if isTimer(audioTimer) then killTimer(audioTimer) end
  if not isElement(bgm) then bgm = nil return end
  if instant then
    fade = nil
    stopSound(bgm)
    bgm = nil
  else
    fadeTo(0, 1200, function() if isElement(bgm) then stopSound(bgm) end bgm = nil end)
  end
end

--------------------------------------------------------------------------
-- browser (one page: index.html, loaded invisibly while the chat is still shown)
--------------------------------------------------------------------------
local function askServer()                        -- wait for the server's answer (retries until it comes)
  if serverAck or not gui then return end
  askTries = askTries + 1
  triggerServerEvent("lg:server:ready", resourceRoot)
  askTimer = setTimer(askServer, 3000, 1)
end

local function onDocumentReady(url)
  if ready or type(url) ~= "string" or not url:find("index.html", 1, true) then return end
  ready = true
  for _, code in ipairs(queue) do executeBrowserJavascript(source, code) end
  queue = {}
  focusBrowser(source)
  local name, pass = loadRemember()
  if name then callUI("fill", name, pass or ""); callUI("setRemember", true) end
  startAudio()
  serverAck, askTries = false, 0
  askServer()
end

local function onLoadFailed(url, code, desc)
  outputDebugString("[linux_auth] browser failed to load " .. tostring(url) .. " (" .. tostring(code) .. " " .. tostring(desc) .. ")", 1)
  loadRetries = loadRetries + 1
  if loadRetries > 5 then return end
  setTimer(function() if isElement(browser) then loadBrowserURL(browser, URL_UI) end end, 2000, 1)
end

local function loadUI()
  if isElement(gui) then return end
  ready, loadRetries, created = false, 0, false
  say(TXT.loading)
  gui = guiCreateBrowser(0, 0, 1, 1, true, true, true)       -- local, transparent (the chat stays visible), relative
  browser = guiGetBrowser(gui)
  addEventHandler("onClientBrowserCreated", browser, function() created = true; loadBrowserURL(source, URL_UI) end)
  addEventHandler("onClientBrowserDocumentReady", browser, onDocumentReady)
  addEventHandler("onClientBrowserLoadingFailed", browser, onLoadFailed)
end

--------------------------------------------------------------------------
-- file download (downloadFile; MTA's own transfer box shows the real progress)
--------------------------------------------------------------------------
local startFile

local function finishDownloads()
  dl.finished = true
  if isTimer(dl.watch) then killTimer(dl.watch) end
  if dl.needed > 0 then say(TXT.downloaded) end
  loadUI()
end

local function markDone(name)
  local f = dl and dl.files[name]
  if not f or f.done then return end
  f.done = true
  dl.done = dl.done + 1
  if dl.done >= dl.total then finishDownloads() end
end

local function failFile(name)
  local f = dl.files[name]
  f.tries = f.tries + 1
  if OPTIONAL[name] and f.tries >= 3 then return markDone(name) end
  outputDebugString("[linux_auth] download problem: " .. name .. " (attempt " .. f.tries .. ")", 2)
  setTimer(function() if dl and not dl.finished then startFile(name) end end, f.tries <= 3 and 1500 or 8000, 1)
end

startFile = function(name)
  local f = dl.files[name]
  if f.done then return end
  if fileExists(name) then return markDone(name) end                   -- already on this PC (and up to date, see refreshCache)
  if not downloadFile(name) then
    if fileExists(name) then return markDone(name) end
    failFile(name)
  end
end

local function startDownloads()
  dl = { files = {}, done = 0, total = #FILES, needed = 0, finished = false }
  for _, n in ipairs(FILES) do
    dl.files[n] = { done = false, tries = 0 }
    if not fileExists(n) then dl.needed = dl.needed + 1 end
  end
  if dl.needed > 0 then say(TXT.downloading:format(dl.needed)) end
  dl.watch = setTimer(function()                                       -- safety net: a finished file whose event was missed
    if not dl or dl.finished then return end
    for n, f in pairs(dl.files) do if not f.done and fileExists(n) then markDone(n) end end
  end, 500, 0)
  for _, n in ipairs(FILES) do startFile(n) end
end

addEventHandler("onClientFileDownloadComplete", root, function(name, success)
  if not dl or dl.finished or not dl.files[name] then return end
  if success then markDone(name) else failFile(name) end
end)

--------------------------------------------------------------------------
-- open / close
--------------------------------------------------------------------------
local function openUI()
  if gui or dl then return end
  ready, queue = false, {}
  loadSettings()
  blockChat = true
  clearChatBox()
  showChat(true)
  setPlayerHudComponentVisible("all", false)
  guiSetInputEnabled(true)
  showCursor(false)
  fadeCamera(false, 0)
  setCameraMatrix(1481, -1790, 160, 1481, -1700, 140)
  for _, line in ipairs(TXT.welcome) do say(line) end
  refreshCache()
  startDownloads()
end

local function closeUI(instant)
  stopMusic(instant)
  if isTimer(askTimer) then killTimer(askTimer) end
  if dl and isTimer(dl.watch) then killTimer(dl.watch) end
  if isElement(gui) then destroyElement(gui) end
  gui, browser, ready, queue, dl, created = nil, nil, false, {}, nil, false
  pendingPass = nil
  blockChat = false
  guiSetInputEnabled(false)
  showCursor(false)
  clearChatBox()
  showChat(true)
  setPlayerHudComponentVisible("all", true)
end

addEventHandler("onClientResourceStart", resourceRoot, openUI)
addEventHandler("onClientResourceStop", resourceRoot, function()
  if gui or dl then closeUI(true) end
end)
addEventHandler("lg:client:close", resourceRoot, function() closeUI(false) end)

--------------------------------------------------------------------------
-- server -> page
--------------------------------------------------------------------------
addEventHandler("lg:client:ui", resourceRoot, function(fn, args)
  if type(fn) ~= "string" or type(args) ~= "table" or not gui then return end
  if fn == "setSerial" then                                  -- first answer of the server = "server connection" ready
    serverAck = true
    if isTimer(askTimer) then killTimer(askTimer) end
  elseif fn == "loginSuccess" then
    if rememberWanted then saveRemember(tostring(args[1] or ""), pendingPass) else saveRemember(nil) end
    pendingPass = nil
    if isElement(bgm) and musicTarget() > 0 then fadeTo(musicTarget() * 0.35, 1200) end   -- duck during the welcome screen
  end
  callUI(fn, unpack(args))
end)

--------------------------------------------------------------------------
-- page -> client / server   (mta.triggerEvent("lg:auth", action, key1, val1, key2, val2, ...))
--------------------------------------------------------------------------
addEventHandler("lg:auth", root, function(action, ...)
  if type(action) ~= "string" or not gui then return end
  local a, data = { ... }, {}
  for i = 1, #a, 2 do
    if type(a[i]) == "string" then data[a[i]] = a[i + 1] end
  end

  if action == "stage" then                                      -- flow messages: handled here, never sent to the server
    local n = tostring(data.name or "")
    if n == "loaded" then
      say(TXT.ready)
    elseif n == "intro" then
      showChat(false)
      beginMusic()
    elseif n == "login" then
      fadeCamera(true, 0)
      showCursor(true)
      focusBrowser(browser)
    end
    return
  elseif action == "openLink" then                               -- copy social link to the clipboard
    if type(data.url) == "string" and data.url ~= "" then setClipboard(data.url) end
    return
  elseif action == "music" then
    music.volume = clamp01(data.volume)
    music.muted = truthy(data.muted)
    local final = truthy(data.final)
    applyMusic(final and 300 or 90)
    if final then saveSettings() end
    return
  elseif action == "login" then
    rememberWanted = truthy(data.remember)
    pendingPass = type(data.password) == "string" and data.password or nil
  end

  triggerServerEvent("lg:server:auth", resourceRoot, action, data)
end)