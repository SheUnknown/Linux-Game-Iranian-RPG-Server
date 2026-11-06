-- [Lx]Bank (client): ATM markers + "Press E" hint, and the page. All logic and validation are on the server.
local G = exports["[Lx]Global"]
local CFG = BANK_CFG
local gui, browser, ready, open, near = nil, nil, false, false, nil
local pending
local LOCK = { "fire", "aim_weapon", "next_weapon", "previous_weapon", "action" }

local function json(t) local s = toJSON(t, true); return s:sub(2, -2) end
local function js(code) if ready and isElement(browser) then executeBrowserJavascript(browser, code) end end

local function canOpen()
  if not G:isLoggedIn(localPlayer) then return false end
  if isChatBoxInputActive() or isConsoleActive() or isMainMenuActive() then return false end
  if getElementData(localPlayer, "Lx.radar.map") or getElementData(localPlayer, "Lx.hud.panel") then return false end
  local other = getElementData(localPlayer, "Lx.ui.open")
  return not other or other == "bank"
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
    if pending then local p = pending; pending = nil; triggerEvent("lx:bank:show", resourceRoot, unpack(p)) end
  end)
end

local function hideUI()
  if not open then return end
  open = false
  js("B.show(false)")
  guiSetInputEnabled(false)
  setElementData(localPlayer, "Lx.ui.open", false, false)
  for _, c in ipairs(LOCK) do toggleControl(c, true) end
  showCursor(false)
  setTimer(function() if not open and isElement(browser) then guiSetVisible(gui, false); setBrowserRenderingPaused(browser, true) end end, 350, 1)
end

addEvent("lx:bank:show", true)
addEventHandler("lx:bank:show", resourceRoot, function(cash, bank, fee, maxT)
  if not ready then pending = { cash, bank, fee, maxT }; return end
  if open or not canOpen() then return end
  open = true
  setElementData(localPlayer, "Lx.ui.open", "bank", false)
  guiSetVisible(gui, true); setBrowserRenderingPaused(browser, false); focusBrowser(browser)
  guiSetInputEnabled(true); showCursor(true)
  for _, c in ipairs(LOCK) do toggleControl(c, false) end
  js(("B.open(%d,%d,%s,%d)"):format(cash, bank, tostring(fee), maxT))
end)

addEvent("lx:bank:result", true)
addEventHandler("lx:bank:result", resourceRoot, function(ok, msg, cash, bank)
  js(("B.result(%s,%s,%d,%d)"):format(tostring(ok), json({ tostring(msg) }), cash, bank))     -- message travels as a JSON array: ["text"]
end)

addEvent("lx:bank:historyData", true)
addEventHandler("lx:bank:historyData", resourceRoot, function(list)
  if open then js(("B.history(%s)"):format(json(list))) end
end)

-- page -> Lua
for _, e in ipairs({ "do", "history", "close" }) do addEvent("Lx:bank:ui:" .. e, false) end
addEventHandler("Lx:bank:ui:do", root, function(kind, amount, target)
  if kind ~= "deposit" and kind ~= "withdraw" and kind ~= "transfer" then return end
  triggerServerEvent("lx:bank:action", resourceRoot, kind, tonumber(amount), tostring(target or ""))
end)
addEventHandler("Lx:bank:ui:history", root, function() triggerServerEvent("lx:bank:history", resourceRoot) end)
addEventHandler("Lx:bank:ui:close", root, hideUI)

-- ATM markers and the "Press E" hint (the hint is only drawn while the player is next to an ATM)
local function hint()
  if open or not near then return end
  local sw, sh = guiGetScreenSize()
  local t = "Press  E  -  " .. near.name
  dxDrawText(t, 1, sh * 0.78 + 1, sw + 1, sh, tocolor(0, 0, 0, 200), 1.25, "default-bold", "center", "top", false, false, true)
  dxDrawText(t, 0, sh * 0.78, sw, sh, tocolor(255, 255, 255, 235), 1.25, "default-bold", "center", "top", false, false, true)
end

local function interact()
  if open or not near or not canOpen() then return end
  ensureBrowser()
  triggerServerEvent("lx:bank:open", resourceRoot)
end

addEventHandler("onClientResourceStart", resourceRoot, function()
  for _, a in ipairs(CFG.atms) do
    local m = createMarker(a.x, a.y, a.z - 0.9, "cylinder", 1.1, 228, 0, 30, 120)
    setElementInterior(m, a.int); setElementDimension(m, a.dim)
  end
  setTimer(function()                                           -- proximity check 4x per second instead of every frame
    local was = near; near = nil
    if G:isLoggedIn(localPlayer) and not isPedDead(localPlayer) then
      local x, y, z = getElementPosition(localPlayer)
      local int, dim = getElementInterior(localPlayer), getElementDimension(localPlayer)
      for _, a in ipairs(CFG.atms) do
        if a.int == int and a.dim == dim and getDistanceBetweenPoints3D(x, y, z, a.x, a.y, a.z) <= CFG.atmRange then near = a; break end
      end
    end
    if near and not was then addEventHandler("onClientRender", root, hint)
    elseif was and not near then removeEventHandler("onClientRender", root, hint) end
    if open and not near then hideUI() end                      -- walked away
  end, 250, 0)
  bindKey("e", "down", interact)
  setTimer(ensureBrowser, 2500, 1)
end)
addEventHandler("onClientKey", root, function(key, press) if open and press and key == "escape" then hideUI() end end)
addEventHandler("onClientResourceStop", resourceRoot, function()
  if open then guiSetInputEnabled(false); showCursor(false); for _, c in ipairs(LOCK) do toggleControl(c, true) end end
  setElementData(localPlayer, "Lx.ui.open", false, false)
end)
