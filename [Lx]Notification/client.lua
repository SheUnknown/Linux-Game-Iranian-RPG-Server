-- [Lx]Notification (client)
-- One small transparent browser. While nothing is shown, the browser is paused and NO render handler is attached,
-- so the resource costs nothing when idle.
local SW, SH = guiGetScreenSize()
local W, H = 420, 560                          -- browser size (CSS px)
local browser, ready, queue = nil, false, {}
local active, drawing, idleTimer = 0, false, nil
local KINDS = { success = true, error = true, warning = true, info = true, money = true }

local function jsStr(s)
  return (tostring(s):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" else return " " end
  end))
end

local function render()
  local sc = math.max(0.85, math.min(1.15, SH / 1080))
  local w, h = W * sc, H * sc
  dxDrawImage((SW - w) / 2, 22 * sc, w, h, browser, 0, 0, 0, tocolor(255, 255, 255, 255), true)
end

local function startDraw()
  if idleTimer and isTimer(idleTimer) then killTimer(idleTimer); idleTimer = nil end
  if drawing then return end
  drawing = true
  setBrowserRenderingPaused(browser, false)
  addEventHandler("onClientRender", root, render)
end

local function stopDrawLater()
  if idleTimer and isTimer(idleTimer) then killTimer(idleTimer) end
  idleTimer = setTimer(function()
    idleTimer = nil
    if active > 0 or not drawing then return end
    drawing = false
    removeEventHandler("onClientRender", root, render)
    if isElement(browser) then setBrowserRenderingPaused(browser, true) end
  end, 700, 1)
end

local function push(kind, title, text, duration)
  if not ready then
    if #queue < 20 then queue[#queue + 1] = { kind, title, text, duration } end
    return
  end
  startDraw()
  executeBrowserJavascript(browser, ('N.add("%s","%s","%s",%d)'):format(kind, jsStr(title), jsStr(text), duration))
end

function notify(kind, title, text, duration)
  if not KINDS[kind] then kind = "info" end
  if type(title) ~= "string" then title = "" end
  if type(text) ~= "string" then text = "" end
  if title == "" and text == "" then return false end
  duration = math.max(1500, math.min(tonumber(duration) or 4500, 15000))
  push(kind, title:sub(1, 120), text:sub(1, 480), duration)
  return true
end

addEvent("lx:notification:add", true)
addEventHandler("lx:notification:add", resourceRoot, function(kind, title, text, duration)
  notify(kind, title, text, duration)
end)

addEvent("Lx:notification:count", false)       -- sent by the page: how many toasts are alive
addEventHandler("Lx:notification:count", root, function(n)
  active = tonumber(n) or 0
  if active > 0 then startDraw() else stopDrawLater() end
end)

addEventHandler("onClientResourceStart", resourceRoot, function()
  browser = createBrowser(W, H, true, true)
  addEventHandler("onClientBrowserCreated", browser, function() loadBrowserURL(source, "http://mta/local/ui/index.html") end)
  addEventHandler("onClientBrowserDocumentReady", browser, function(url)
    if not url:find("index.html", 1, true) then return end
    ready = true
    setBrowserRenderingPaused(browser, true)
    for _, q in ipairs(queue) do push(unpack(q)) end
    queue = {}
  end)
end)
