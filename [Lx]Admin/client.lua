-- [Lx]Admin (client): F9 opens the panel for staff. The page only displays and asks; the server checks everything.
local G = exports["[Lx]Global"]
local gui, browser, ready, open, pending = nil, nil, false, false, nil
local who = {}
local refresh

local function json(t) local s = toJSON(t, true); return s:sub(2, -2) end
local function js(code) if ready and isElement(browser) then executeBrowserJavascript(browser, code) end end

local function canOpen()
  if not G:isLoggedIn(localPlayer) then return false end
  if isChatBoxInputActive() or isConsoleActive() or isMainMenuActive() then return false end
  if getElementData(localPlayer, "Lx.radar.map") or getElementData(localPlayer, "Lx.hud.panel") then return false end
  local other = getElementData(localPlayer, "Lx.ui.open")
  return not other or other == "admin"
end

local function ensureBrowser()
  if gui then return end
  gui = guiCreateBrowser(0, 0, 1, 1, true, true, true)
  browser = guiGetBrowser(gui)
  guiSetVisible(gui, false)
  addEventHandler("onClientBrowserCreated", browser, function() loadBrowserURL(source, "http://mta/local/ui/index.html") end)
  addEventHandler("onClientBrowserDocumentReady", browser, function(url)
    if not url:find("index.html", 1, true) then return end
    ready = true; setBrowserRenderingPaused(browser, true)
    if pending then local p = pending; pending = nil; triggerEvent("lx:admin:list", resourceRoot, unpack(p)) end
  end)
end

local function hideUI()
  if not open then return end
  open = false
  if refresh and isTimer(refresh) then killTimer(refresh) end
  js("A.show(false)"); guiSetInputEnabled(false); showCursor(false)
  setElementData(localPlayer, "Lx.ui.open", false, false)
  setTimer(function() if not open and isElement(browser) then guiSetVisible(gui, false); setBrowserRenderingPaused(browser, true) end end, 350, 1)
end

local function toggle()
  if open then return hideUI() end
  if not canOpen() or (getElementData(localPlayer, "lx.rank") or 0) < 1 then return end
  ensureBrowser()
  triggerServerEvent("lx:admin:open", resourceRoot, true)
end

addEvent("lx:admin:list", true)
addEventHandler("lx:admin:list", resourceRoot, function(list, players, rank, show)
  who = players or {}
  if show and not ready then pending = { list, players, rank, show }; return end
  if show and not open then
    if not canOpen() then return end
    open = true
    setElementData(localPlayer, "Lx.ui.open", "admin", false)
    guiSetVisible(gui, true); setBrowserRenderingPaused(browser, false); focusBrowser(browser); guiSetInputEnabled(true); showCursor(true)
    refresh = setTimer(function() triggerServerEvent("lx:admin:open", resourceRoot, false) end, 3000, 0)
    js("A.show(true)")
  end
  if open then js(("A.list(%s,%d)"):format(json(list), rank)) end
end)

addEvent("lx:admin:bansData", true)
addEventHandler("lx:admin:bansData", resourceRoot, function(list) if open then js(("A.bans(%s)"):format(json(list))) end end)

for _, e in ipairs({ "do", "bans", "unban", "close" }) do addEvent("Lx:admin:ui:" .. e, false) end
addEventHandler("Lx:admin:ui:do", root, function(action, idx, uid, a, b)
  local t = who[(tonumber(idx) or -1) + 1]
  triggerServerEvent("lx:admin:do", resourceRoot, tostring(action), t, tonumber(uid), tostring(a or ""), tonumber(b) or 0)
end)
addEventHandler("Lx:admin:ui:bans", root, function() triggerServerEvent("lx:admin:bans", resourceRoot) end)
addEventHandler("Lx:admin:ui:unban", root, function(id) triggerServerEvent("lx:admin:unban", resourceRoot, tonumber(id)) end)
addEventHandler("Lx:admin:ui:close", root, hideUI)

addEventHandler("onClientResourceStart", resourceRoot, function() bindKey("F9", "down", toggle) end)
addEventHandler("onClientKey", root, function(key, press) if open and press and key == "escape" then hideUI() end end)
addEventHandler("onClientResourceStop", resourceRoot, function()
  if open then guiSetInputEnabled(false); showCursor(false) end
  setElementData(localPlayer, "Lx.ui.open", false, false)
end)
