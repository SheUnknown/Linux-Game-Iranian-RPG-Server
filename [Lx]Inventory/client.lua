-- [Lx]Inventory (client): opens the page, forwards the player's requests, nothing else. The server decides everything.
local G = exports["[Lx]Global"]
local gui, browser, ready, open = nil, nil, false, false
local pendingShow, lastData
local LOCK = { "fire", "aim_weapon", "next_weapon", "previous_weapon", "action" }

local function json(t) local s = toJSON(t, true); return s:sub(2, -2) end          -- toJSON wraps a table in [ ]
local function js(code) if ready and isElement(browser) then executeBrowserJavascript(browser, code) end end

local function canOpen()
  if not G:isLoggedIn(localPlayer) then return false end
  if isChatBoxInputActive() or isConsoleActive() or isMainMenuActive() then return false end
  if getElementData(localPlayer, "Lx.radar.map") or getElementData(localPlayer, "Lx.hud.panel") then return false end
  local other = getElementData(localPlayer, "Lx.ui.open")
  if other and other ~= "inventory" then return false end
  return true
end

local function ensureBrowser()
  if gui then return end
  gui = guiCreateBrowser(0, 0, 1, 1, true, true, true)
  browser = guiGetBrowser(gui)
  guiSetVisible(gui, false)
  addEventHandler("onClientBrowserCreated", browser, function() loadBrowserURL(source, "http://mta/local/ui/index.html") end)
  addEventHandler("onClientBrowserDocumentReady", browser, function(url)
    if not url:find("index.html", 1, true) then return end
    ready = true
    setBrowserRenderingPaused(browser, true)
    if pendingShow then local d = pendingShow; pendingShow = nil; triggerEvent("lx:inv:sync", resourceRoot, unpack(d)) end
  end)
end

local function showUI()
  if open then return end
  open = true
  setElementData(localPlayer, "Lx.ui.open", "inventory", false)
  guiSetVisible(gui, true); setBrowserRenderingPaused(browser, false); focusBrowser(browser)
  showCursor(true)
  for _, c in ipairs(LOCK) do toggleControl(c, false) end
  js("INV.show(true)")
end

local function hideUI()
  if not open then return end
  open = false
  js("INV.show(false)")
  setElementData(localPlayer, "Lx.ui.open", false, false)
  for _, c in ipairs(LOCK) do toggleControl(c, true) end
  showCursor(false)
  setTimer(function()                                             -- let the closing animation finish, then stop rendering
    if not open and isElement(browser) then guiSetVisible(gui, false); setBrowserRenderingPaused(browser, true) end
  end, 350, 1)
end

local function toggle()
  if open then return hideUI() end
  if not canOpen() then return end
  ensureBrowser()
  triggerServerEvent("lx:inv:request", resourceRoot)
end

addEvent("lx:inv:sync", true)
addEventHandler("lx:inv:sync", resourceRoot, function(items, weight, maxWeight, show)
  if show and not canOpen() then return end
  if not ready then if show then pendingShow = { items, weight, maxWeight, show } end return end
  if not open and not show then return end
  js(("INV.sync(%s,%s,%s)"):format(json(items), tostring(weight), tostring(maxWeight)))
  if show then showUI() end
end)

addEvent("lx:inv:nearbyList", true)
local nearbyWho = {}
addEventHandler("lx:inv:nearbyList", resourceRoot, function(list, who)
  nearbyWho = who or {}
  if open then js(("INV.nearby(%s)"):format(json(list))) end
end)

-- page -> Lua (local events)
for _, e in ipairs({ "move", "use", "drop", "nearby", "give", "close" }) do addEvent("Lx:inv:ui:" .. e, false) end
addEventHandler("Lx:inv:ui:move",   root, function(a, b) triggerServerEvent("lx:inv:move", resourceRoot, tonumber(a), tonumber(b)) end)
addEventHandler("Lx:inv:ui:use",    root, function(s) triggerServerEvent("lx:inv:use", resourceRoot, tonumber(s)) end)
addEventHandler("Lx:inv:ui:drop",   root, function(s, c) triggerServerEvent("lx:inv:drop", resourceRoot, tonumber(s), tonumber(c)) end)
addEventHandler("Lx:inv:ui:nearby", root, function() triggerServerEvent("lx:inv:nearby", resourceRoot) end)
addEventHandler("Lx:inv:ui:give",   root, function(s, c, idx) local t = nearbyWho[(tonumber(idx) or 0) + 1]; if t then triggerServerEvent("lx:inv:give", resourceRoot, tonumber(s), tonumber(c), t) end end)
addEventHandler("Lx:inv:ui:close",  root, hideUI)

addEventHandler("onClientResourceStart", resourceRoot, function()
  bindKey("i", "down", toggle)
  setTimer(ensureBrowser, 2000, 1)                                -- create the (hidden, paused) page early so the first open is instant
end)
addEventHandler("onClientKey", root, function(key, press)
  if open and press and key == "escape" then hideUI() end        -- does not cancel: MTA's own menu still opens
end)
addEventHandler("onClientResourceStop", resourceRoot, function()
  if open then for _, c in ipairs(LOCK) do toggleControl(c, true) end showCursor(false) end
  setElementData(localPlayer, "Lx.ui.open", false, false)
end)
