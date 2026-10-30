--[[ =====================================================================
   LINUX Game - [Lx]HUD | client.lua
   Feeds the CEF page (ui/index.html) with the player's data and handles
   the F6 customizer panel.  Only CHANGED values are pushed (~15x/s).
   ===================================================================== ]]

local Config = {
  serverName    = "LINUX GAME",
  panelKey      = "F6",        -- opens / closes the customizer
  command       = "hud",       -- /hud shows or hides the whole HUD
  requireLogin  = true,        -- wait for the [Lx]Login resource (it sets the "lg.id" element data)
  loginKey      = "lg.id",
  waitForSpawn  = true,        -- stay hidden while the camera is not on the player (login screen / intro)
  hideDefaultHud = true,       -- hide GTA's own health / armour / money / clock / wanted / weapon / ammo
  hideOnMap     = true,        -- hide while the F11 map is open
  updateMs      = 66,          -- how often values are checked (~15 times per second)
}

local URL           = "http://mta/local/ui/index.html"
local SETTINGS_FILE = "settings.json"
local DEFAULT_HUD   = { "health", "armour", "money", "clock", "wanted", "weapon", "ammo" }

addEvent("Lx:hud:save", false)     -- page -> here   (mta.triggerEvent)
addEvent("Lx:hud:panel", false)    -- page -> here   (close button)
addEvent("Lx:hud:id", true)        -- server -> here

local SW, SH = guiGetScreenSize()
local browser, ready = nil, false
local shown, forcedOff, panelOpen, drawing = false, false, false, false
local last, myID, lastTick, pauseTimer = {}, 0, 0, nil
local queue = {}

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
    for k, x in pairs(v) do out[#out + 1] = jsStr(k) .. ":" .. js(x) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end
local function callUI(code)
  if ready and isElement(browser) then executeBrowserJavascript(browser, code) else queue[#queue + 1] = code end
end

--------------------------------------------------------------------------
-- settings file (client side, private to this resource)
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
  local f = fileCreate(name)
  if f then fileWrite(f, txt); fileClose(f) end
end

addEventHandler("Lx:hud:save", root, function(json)
  if type(json) == "string" and #json < 4096 then writeFile(SETTINGS_FILE, json) end
end)

--------------------------------------------------------------------------
-- default GTA HUD
--------------------------------------------------------------------------
local function setDefaultHud(visible)
  for i = 1, #DEFAULT_HUD do setPlayerHudComponentVisible(DEFAULT_HUD[i], visible) end
end

--------------------------------------------------------------------------
-- F6 panel (the browser is drawn with dxDrawImage, so mouse events are injected by hand)
--------------------------------------------------------------------------
local function cursorToBrowser()
  if not isCursorShowing() then return end
  local rx, ry = getCursorPosition()
  injectBrowserMouseMove(browser, rx * SW, ry * SH)
end

local function setPanel(state)
  state = state and true or false
  if state == panelOpen or not isElement(browser) then return end
  if state then
    if not shown or not ready then return end
    if isChatBoxInputActive() or isConsoleActive() or guiGetInputEnabled() or isMainMenuActive() then return end
    if isCursorShowing() then return end                 -- another resource already owns the cursor
  end
  panelOpen = state
  showCursor(state)
  if state then cursorToBrowser() end
  callUI("HUD.panel(" .. tostring(state) .. ")")
end

addEventHandler("onClientCursorMove", root, function(_, _, x, y)
  if panelOpen and isElement(browser) then injectBrowserMouseMove(browser, x, y) end
end)
addEventHandler("onClientClick", root, function(button, state, x, y)
  if not panelOpen or not isElement(browser) then return end
  injectBrowserMouseMove(browser, x, y)
  if state == "down" then injectBrowserMouseDown(browser, button) else injectBrowserMouseUp(browser, button) end
end)
bindKey("mouse_wheel_up", "down", function() if panelOpen then injectBrowserMouseWheel(browser, 60, 0) end end)
bindKey("mouse_wheel_down", "down", function() if panelOpen then injectBrowserMouseWheel(browser, -60, 0) end end)

addEventHandler("Lx:hud:panel", root, function(action)
  if action == "close" then setPanel(false) end
end)

--------------------------------------------------------------------------
-- visibility rules
--------------------------------------------------------------------------
local function shouldShow()
  if forcedOff then return false end
  if Config.requireLogin and not getElementData(localPlayer, Config.loginKey) then return false end
  if Config.waitForSpawn then
    local cam = getCameraTarget()
    if cam ~= localPlayer and cam ~= getPedOccupiedVehicle(localPlayer) then return false end
  end
  if Config.hideOnMap and isPlayerMapVisible() then return false end
  return true
end

local function applyVisibility(want)
  if want == shown then return end
  shown = want
  if isTimer(pauseTimer) then killTimer(pauseTimer) end
  if want then
    drawing = true
    setBrowserRenderingPaused(browser, false)
    last = {}                                            -- push everything again
  else
    if panelOpen then setPanel(false) end
    pauseTimer = setTimer(function()                     -- let the hide animation finish, then stop rendering
      drawing = false
      if isElement(browser) then setBrowserRenderingPaused(browser, true) end
    end, 1100, 1)
  end
  callUI("HUD.show(" .. tostring(want) .. ")")
end

--------------------------------------------------------------------------
-- data feed
--------------------------------------------------------------------------
local function cleanName(n) return (tostring(n):gsub("#%x%x%x%x%x%x", "")) end

local function collect()
  local p = localPlayer
  local weapon = getPedWeapon(p) or 0
  return {
    name  = cleanName(getPlayerName(p)),
    id    = myID,
    hp    = math.ceil(getElementHealth(p)),
    mhp   = getPedMaxHealth and math.floor(getPedMaxHealth(p)) or 100,
    ar    = math.ceil(getPedArmor(p)),
    money = getPlayerMoney(p),
    wanted = getPlayerWantedLevel(p) or 0,
    wid   = weapon,
    wname = getWeaponNameFromID(weapon) or "",
    clip  = getPedAmmoInClip(p) or 0,
    total = getPedTotalAmmo(p) or 0,
  }
end

local function push()
  local cur, diff, n = collect(), {}, 0
  for k, v in pairs(cur) do
    if last[k] ~= v then diff[k] = v; last[k] = v; n = n + 1 end
  end
  if n > 0 then callUI("HUD.u(" .. js(diff) .. ")") end
end

addEventHandler("onClientRender", root, function()
  if not isElement(browser) then return end

  if Config.hideDefaultHud then setDefaultHud(false) end   -- other resources may switch it back on

  if ready then
    local t = getTickCount()
    if t - lastTick >= Config.updateMs then
      lastTick = t
      applyVisibility(shouldShow())
      if shown then push() end
    end
    if drawing then dxDrawImage(0, 0, SW, SH, browser, 0, 0, 0, 0xFFFFFFFF, true) end
  end
end)

addEventHandler("Lx:hud:id", resourceRoot, function(id)
  myID = tonumber(id) or 0
end)

--------------------------------------------------------------------------
-- browser
--------------------------------------------------------------------------
local function onDocumentReady(url)
  if ready or type(url) ~= "string" or not url:find("index.html", 1, true) then return end
  ready = true
  local cfg = { server = Config.serverName, key = Config.panelKey:upper() }
  executeBrowserJavascript(source, "HUD.init(" .. jsStr(readFile(SETTINGS_FILE, 4096) or "") .. "," .. js(cfg) .. ")")
  for _, code in ipairs(queue) do executeBrowserJavascript(source, code) end
  queue = {}
  setBrowserRenderingPaused(source, true)                -- nothing to draw until the player is in the game
  triggerServerEvent("Lx:hud:ready", resourceRoot)
end

local function start()
  browser = createBrowser(SW, SH, true, true)            -- local page, transparent
  addEventHandler("onClientBrowserCreated", browser, function() loadBrowserURL(source, URL) end)
  addEventHandler("onClientBrowserDocumentReady", browser, onDocumentReady)
  addEventHandler("onClientBrowserLoadingFailed", browser, function(url, code, desc)
    outputDebugString("[Lx]HUD: could not load " .. tostring(url) .. " (" .. tostring(code) .. " " .. tostring(desc) .. ")", 1)
  end)
  setDefaultHud(false)
end

addEventHandler("onClientResourceStart", resourceRoot, function()
  start()
  bindKey(Config.panelKey, "down", function() setPanel(not panelOpen) end)
  addCommandHandler(Config.command, function() forcedOff = not forcedOff end)
end)

addEventHandler("onClientResourceStop", resourceRoot, function()
  if panelOpen then showCursor(false) end
  setDefaultHud(true)
end)
