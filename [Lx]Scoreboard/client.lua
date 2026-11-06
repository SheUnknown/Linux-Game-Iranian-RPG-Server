-- [Lx]Scoreboard (client only). Hold TAB. While it is not visible: no render handler, browser paused, no timer = zero cost.
local G = exports["[Lx]Global"]
local SW, SH = guiGetScreenSize()
local W, H = 720, 600
local browser, ready, shown, upd = nil, false, false, nil

local function json(t) local s = toJSON(t, true); return s:sub(2, -2) end
local function render()
  local sc = math.max(0.8, math.min(1.15, SH / 1080))
  dxDrawImage((SW - W * sc) / 2, (SH - H * sc) / 2, W * sc, H * sc, browser, 0, 0, 0, tocolor(255, 255, 255, 255), true)
end

local function push()
  local list = {}
  for _, p in ipairs(getElementsByType("player")) do
    local id = tonumber(getElementData(p, "lg.id"))
    if id then list[#list + 1] = { id = id, name = (getPlayerName(p):gsub("#%x%x%x%x%x%x", "")), ping = getPlayerPing(p), me = p == localPlayer, rank = tonumber(getElementData(p, "lx.rank")) or 0 } end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  executeBrowserJavascript(browser, ("S.update(%s,%d)"):format(json(list), getMaxPlayers()))
end

local function show(on)
  if on == shown or not ready then return end
  if on then
    if not G:isLoggedIn(localPlayer) or isChatBoxInputActive() or isConsoleActive() or getElementData(localPlayer, "Lx.ui.open") then return end
    shown = true
    setBrowserRenderingPaused(browser, false); push()
    executeBrowserJavascript(browser, "S.show(true)")
    addEventHandler("onClientRender", root, render)
    upd = setTimer(push, 1000, 0)
  else
    shown = false
    if upd and isTimer(upd) then killTimer(upd) end
    executeBrowserJavascript(browser, "S.show(false)")
    setTimer(function() if not shown then removeEventHandler("onClientRender", root, render); setBrowserRenderingPaused(browser, true) end end, 250, 1)
  end
end

addEventHandler("onClientResourceStart", resourceRoot, function()
  browser = createBrowser(W, H, true, true)
  addEventHandler("onClientBrowserCreated", browser, function() loadBrowserURL(source, "http://mta/local/ui/index.html") end)
  addEventHandler("onClientBrowserDocumentReady", browser, function(url)
    if url:find("index.html", 1, true) then ready = true; setBrowserRenderingPaused(browser, true) end
  end)
  bindKey("tab", "both", function(_, state) show(state == "down") end)
end)
addEventHandler("onClientResourceStop", resourceRoot, function() if shown then removeEventHandler("onClientRender", root, render) end end)
