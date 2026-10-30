--[[ =====================================================================
   LINUX Game - [Lx]Radar | client.lua
   * Minimap : pure dx. The map texture is drawn into a render target
               (rotated with the camera) and a pixel shader cuts it into a
               circle / rounded square and draws the ring + glow.
   * F11 map : CEF page (map.html). Pan, zoom, grid, legend, waypoint and the
               minimap customizer all live there.
   * Blips   : every normal MTA blip is used (createBlip / createBlipAttachedTo,
               from any resource). Icons 1-63 -> blips/01.png ... blips/63.png,
               icon 0 (player blips) -> blips/up.png / down.png / square.png
               depending on the height difference.
   * Security: nothing is trusted. Events coming from the page are local only
               (not remotely triggerable), every value is validated and clamped,
               the settings file is parsed as plain key=value text.
   ===================================================================== ]]

local Config = {
  mapKey         = "F11",
  command        = "radar",           -- /radar shows or hides the minimap
  zoomInKey      = "num_add",         -- temporary extra zoom for the minimap
  zoomOutKey     = "num_sub",

  requireLogin   = true,              -- wait for the [Lx]Login resource (it sets the "lg.id" element data)
  loginKey       = "lg.id",
  waitForSpawn   = true,              -- hidden while the camera is not on the player (login screen / intro)

  hideDefaultRadar = true,            -- hide GTA's radar and area name
  arriveDistance = 25,                -- the waypoint is cleared when you get this close (metres)
  maxBlips       = 300,
  worldSize      = 6000,              -- the map image covers -3000 .. 3000 on both axes

  -- optional names shown in the F11 legend:  [blipIcon] = "Name"
  blipNames = {
    -- [12] = "Gym", [41] = "Waypoint",
  },
}

--------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------
local floor, max, min, sin, cos, sqrt, rad, deg, atan2, abs, exp = math.floor, math.max, math.min, math.sin, math.cos, math.sqrt, math.rad, math.deg, math.atan2, math.abs, math.exp
local SW, SH = guiGetScreenSize()
local MAP_W = Config.worldSize
local HALF = MAP_W / 2

local function clamp(v, a, b) return max(a, min(b, v)) end
local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function uiScale() return clamp(min(SW / 1920, SH / 1080), 0.6, 2.5) end
local function ease3(t) t = 1 - t; return 1 - t * t * t end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function jsStr(s)
  s = tostring(s):gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end)
  s = s:gsub("\226\128\168", "\\u2028"):gsub("\226\128\169", "\\u2029")
  return '"' .. s .. '"'
end
local function js(v)
  local t = type(v)
  if t == "string" then return jsStr(v) end
  if t == "number" then return finite(v) and tostring(v) or "0" end
  if t == "boolean" then return tostring(v) end
  if t == "table" then
    local out = {}
    if v[1] ~= nil or next(v) == nil then
      for i = 1, #v do out[i] = js(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    for k, x in pairs(v) do out[#out + 1] = jsStr(k) .. ":" .. js(x) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end

--------------------------------------------------------------------------
-- settings (validated, saved as key=value text)
--------------------------------------------------------------------------
local DEF = {
  shape = "rounded", size = 260, pos = "bl", ox = 28, oy = 28, zoom = 320,
  rotate = 1, auto = 1, opacity = 100, zone = 1, coords = 0, bsize = 100,
  accent = "#e4001e", north = 1, grid = 1, labels = 1,
}
local ENUM  = { shape = { circle = true, rounded = true, square = true, wide = true }, pos = { bl = true, br = true, tl = true, tr = true } }
local RANGE = { size = { 160, 420 }, ox = { 0, 300 }, oy = { 0, 300 }, zoom = { 120, 900 }, opacity = { 30, 100 }, bsize = { 60, 160 } }
local BOOL  = { rotate = true, auto = true, zone = true, coords = true, north = true, grid = true, labels = true }

local function clean(key, v)
  if ENUM[key] then v = tostring(v); return ENUM[key][v] and v or nil end
  if RANGE[key] then
    v = tonumber(v)
    if not finite(v) then return nil end
    local r = RANGE[key]
    return floor(clamp(v, r[1], r[2]) + 0.5)
  end
  if BOOL[key] then
    if v == true or v == 1 or v == "1" or v == "true" then return 1 end
    if v == false or v == 0 or v == "0" or v == "false" then return 0 end
    return nil
  end
  if key == "accent" then
    v = tostring(v):lower()
    return v:match("^#%x%x%x%x%x%x$") and v or nil
  end
end

local S = {}
for k, v in pairs(DEF) do S[k] = v end

local SETTINGS_FILE = "settings.txt"
local function readFile(name, maxLen)
  if not fileExists(name) then return nil end
  local f = fileOpen(name, true)
  if not f then return nil end
  local txt = fileRead(f, min(fileGetSize(f), maxLen))
  fileClose(f)
  return type(txt) == "string" and txt or nil
end
local function writeFile(name, txt)
  if fileExists(name) then fileDelete(name) end
  local f = fileCreate(name)
  if f then fileWrite(f, txt); fileClose(f) end
end
local function loadSettings()
  local txt = readFile(SETTINGS_FILE, 2048)
  if not txt then return end
  for line in txt:gmatch("[^\r\n]+") do
    local k, v = line:match("^(%w+)=(.+)$")
    if k and DEF[k] ~= nil then
      local c = clean(k, v)
      if c ~= nil then S[k] = c end
    end
  end
end
local saveTimer
local function saveSoon()
  if isTimer(saveTimer) then killTimer(saveTimer) end
  saveTimer = setTimer(function()
    local out = {}
    for k in pairs(DEF) do out[#out + 1] = k .. "=" .. tostring(S[k]) end
    table.sort(out)
    writeFile(SETTINGS_FILE, table.concat(out, "\n"))
  end, 700, 1)
end

--------------------------------------------------------------------------
-- state
--------------------------------------------------------------------------
local browser, ready = nil, false
local shown, mapOpen, preview, forcedOff = false, false, false, false
local vis = 0                                       -- minimap fade 0..1
local browserUntil = 0                              -- keep drawing the page until this tick (close animation)
local queue = {}
local WP = nil                                      -- { x, y }
local zoomMul, zoomCur = 1, nil
local blipCache, blipRefreshAt = {}, 0
local blipId, nextBlipId = setmetatable({}, { __mode = "k" }), 0
local savedControls, paused = nil, true
local lastTick = getTickCount()
local zone = { text = "", shown = "", a = 0, at = 0, city = "" }
local toast = { text = "", t = -9999 }
local G = {}                                        -- minimap geometry
local hiddenKeys = {}                               -- legend filters of the big map  ["p"|"12"] = true
local UI = {}                                       -- rectangles of the page that own the mouse
local uiCapture, wasOverUI = false, false
local born = {}                                     -- blip id -> first seen tick (pop-in animation)
local groupsSig, groupsRows = "", {}
local assets = {}

local function callUI(code)
  if ready and isElement(browser) then executeBrowserJavascript(browser, code) else queue[#queue + 1] = code end
end

local function hexRGB(hex)
  return tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
end

--------------------------------------------------------------------------
-- textures / fonts
--------------------------------------------------------------------------
local TEX = {}
local function tex(path)
  local t = TEX[path]
  if t ~= nil then return t or nil end
  if not fileExists(path) then TEX[path] = false; return nil end
  t = dxCreateTexture(path, "argb", true, "clamp")
  TEX[path] = t or false
  return t or nil
end
local function blipTex(icon) return tex(string.format("blips/%02d.png", icon)) end

local fontTitle, fontBody, fontCity
local function loadFonts()
  fontCity  = dxCreateFont("fonts/title.ttf", 15, true, "cleartype") or "default-bold"
  fontTitle = dxCreateFont("fonts/title.ttf", 11, false, "cleartype") or "default-bold"
  fontBody  = dxCreateFont("fonts/body.ttf", 12, false, "cleartype") or "default"
end

--------------------------------------------------------------------------
-- shader: rounded-rect / circle mask  +  ring and glow (same SDF)
--------------------------------------------------------------------------
local FX = [[
texture Tex;
sampler S0 = sampler_state { Texture = (Tex); MinFilter = Linear; MagFilter = Linear; MipFilter = None; AddressU = Clamp; AddressV = Clamp; };
float2 Quad = float2(256, 256);
float2 HalfSize = float2(128, 128);
float Radius = 24;
float Border = 3;
float Glow = 12;
float Mode = 0;
float4 FrameColor = float4(1, 0, 0, 1);

float4 PS(float2 uv : TEXCOORD0, float4 diff : COLOR0) : COLOR0
{
    float2 p = (uv - 0.5) * Quad;
    float2 q = abs(p) - (HalfSize - Radius);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - Radius;
    float inside = saturate(0.5 - d);
    float4 t = tex2D(S0, uv);
    float4 m = float4(t.rgb, t.a * inside * diff.a);
    float ring = inside * saturate(d + Border + 0.5);
    float glow = exp(-max(d, 0.0) / Glow) * 0.5 * (1.0 - inside);
    float a = max(ring, glow);
    float4 f = float4(FrameColor.rgb, FrameColor.a * a * diff.a);
    return lerp(m, f, Mode);
}

technique T { pass P0 { PixelShader = compile ps_2_0 PS(); } }
]]
local shMask, shFrame

local function applyShader()
  if not G.w then return end
  local ar, ag, ab = hexRGB(S.accent)
  local pad = G.pad
  if shMask then
    dxSetShaderValue(shMask, "Quad", { G.w, G.h })
    dxSetShaderValue(shMask, "HalfSize", { G.w / 2, G.h / 2 })
    dxSetShaderValue(shMask, "Radius", G.r)
    dxSetShaderValue(shMask, "Mode", 0)
    if G.rt then dxSetShaderValue(shMask, "Tex", G.rt) end
  end
  if shFrame then
    dxSetShaderValue(shFrame, "Quad", { G.w + pad * 2, G.h + pad * 2 })
    dxSetShaderValue(shFrame, "HalfSize", { G.w / 2, G.h / 2 })
    dxSetShaderValue(shFrame, "Radius", G.r)
    dxSetShaderValue(shFrame, "Border", max(2, 3 * G.s))
    dxSetShaderValue(shFrame, "Glow", 14 * G.s)
    dxSetShaderValue(shFrame, "Mode", 1)
    dxSetShaderValue(shFrame, "FrameColor", { ar / 255, ag / 255, ab / 255, 1 })
  end
end

--------------------------------------------------------------------------
-- minimap geometry
--------------------------------------------------------------------------
local function layout()
  local s = uiScale()
  local base = S.size * s
  local w, h = base, base
  if S.shape == "wide" then w = base * 1.55 end
  w, h = floor(w + 0.5), floor(h + 0.5)
  local mx, my = S.ox * s, S.oy * s
  local x = (S.pos == "bl" or S.pos == "tl") and mx or (SW - w - mx)
  local y = (S.pos == "tl" or S.pos == "tr") and my or (SH - h - my)
  local r = (S.shape == "circle") and min(w, h) / 2 or (S.shape == "square" and 5 * s or 28 * s)
  local newRT = (G.w ~= w or G.h ~= h or not isElement(G.rt))
  G.x, G.y, G.w, G.h, G.r, G.s, G.pad = x, y, w, h, r, s, floor(30 * s)
  if newRT then
    if isElement(G.rt) then destroyElement(G.rt) end
    G.rt = dxCreateRenderTarget(w, h, true)
    if not G.rt then outputDebugString("[Lx]Radar: could not create the render target", 1) end
  end
  applyShader()
end

--------------------------------------------------------------------------
-- blips
--------------------------------------------------------------------------
local function refreshBlips()
  local list, n = {}, 0
  local dim, int = getElementDimension(localPlayer), getElementInterior(localPlayer)
  local blips = getElementsByType("blip")
  local now = getTickCount()
  local counts, order = {}, {}
  for i = 1, #blips do
    local b = blips[i]
    if n >= Config.maxBlips then break end
    if isElement(b) and getElementDimension(b) == dim and getElementInterior(b) == int
       and getElementAttachedTo(b) ~= localPlayer then
      local id = blipId[b]
      if not id then nextBlipId = nextBlipId + 1; id = nextBlipId; blipId[b] = id end
      if not born[id] then born[id] = now end
      local r, g, bl = getBlipColor(b)
      local icon = getBlipIcon(b)
      local key = (icon == 0) and "p" or tostring(icon)
      n = n + 1
      list[n] = {
        el = b, id = id, icon = icon, key = key, born = born[id], t = (icon ~= 0) and blipTex(icon) or nil,
        ord = getBlipOrdering(b), size = getBlipSize(b), r = r, g = g, b = bl, dist = getBlipVisibleDistance(b),
      }
      if not counts[key] then counts[key] = { key, icon, 0 }; order[#order + 1] = counts[key] end
      counts[key][3] = counts[key][3] + 1
    end
  end
  table.sort(list, function(a, b) if a.ord ~= b.ord then return a.ord < b.ord end return a.id < b.id end)
  blipCache = list
  -- legend groups (sent to the page only when they change)
  table.sort(order, function(a, b) if a[3] ~= b[3] then return a[3] > b[3] end return a[2] < b[2] end)
  local parts = {}
  for i = 1, #order do parts[i] = order[i][1] .. ":" .. order[i][3] end
  local sig = table.concat(parts, "|")
  if sig ~= groupsSig then groupsSig, groupsRows = sig, order; if mapOpen then callUI("RM.g(" .. js(order) .. ")") end end
end

--------------------------------------------------------------------------
-- visibility rules
--------------------------------------------------------------------------
local visCheckAt, visCache = 0, false
local function shouldShow(now)
  if now - visCheckAt < 120 then return visCache end
  visCheckAt = now
  local ok = true
  if forcedOff then ok = false
  elseif Config.requireLogin and not getElementData(localPlayer, Config.loginKey) then ok = false
  elseif Config.waitForSpawn then
    local cam = getCameraTarget()
    if cam ~= localPlayer and cam ~= getPedOccupiedVehicle(localPlayer) then ok = false end
  end
  visCache = ok
  return ok
end

--------------------------------------------------------------------------
-- waypoint
--------------------------------------------------------------------------
local function setWaypoint(x, y, silent)
  x, y = tonumber(x), tonumber(y)
  if not finite(x) or not finite(y) or abs(x) > 3100 or abs(y) > 3100 then return false end
  WP = { x = x, y = y, t = getTickCount() }
  callUI("RM.wp(" .. string.format("%.1f,%.1f", x, y) .. ")")
  return true
end
local function clearWaypoint()
  WP = nil
  callUI("RM.wp(null)")
end
local function notify(text)
  toast.text, toast.t = text, getTickCount()
end

--------------------------------------------------------------------------
-- minimap drawing
--------------------------------------------------------------------------
local function shadowText(text, l, t, r, b, color, scale, font, ax, ay)
  dxDrawText(text, l + 1, t + 1, r + 1, b + 1, tocolor(0, 0, 0, 210), scale, font, ax, ay, false, false, true)
  dxDrawText(text, l, t, r, b, color, scale, font, ax, ay, false, false, true)
end

local V = { px = 0, py = 0, k = 1, cx = 0, cy = 0, c = 1, s = 0, W = 0, H = 0, circle = false }
local function toMini(wx, wy)
  local sx, sy = (wx - V.px) * V.k, -(wy - V.py) * V.k
  return V.cx + sx * V.c + sy * V.s, V.cy - sx * V.s + sy * V.c
end
local function edge(x, y, pad)
  local dx, dy = x - V.cx, y - V.cy
  if V.circle then
    local rr = min(V.W, V.H) / 2 - pad
    local d = sqrt(dx * dx + dy * dy)
    if d > rr and d > 0 then return V.cx + dx * rr / d, V.cy + dy * rr / d, true end
  else
    local hw, hh = V.W / 2 - pad, V.H / 2 - pad
    local t = max(abs(dx) / hw, abs(dy) / hh)
    if t > 1 then return V.cx + dx / t, V.cy + dy / t, true end
  end
  return x, y, false
end

local function drawMinimap(dt, now)
  local W, H = G.w, G.h
  if not W or not isElement(G.rt) then return end
  local s = G.s
  local ease = ease3(vis)
  local alpha = floor(255 * ease * S.opacity / 100)
  if alpha < 2 then return end

  local ar, ag, ab = hexRGB(S.accent)
  local veh = getPedOccupiedVehicle(localPlayer)
  local px, py, pz = getElementPosition(localPlayer)
  local interior = getElementInterior(localPlayer) ~= 0

  -- camera yaw (clockwise from north)
  local cx0, cy0, _, lx, ly = getCameraMatrix()
  local yaw = deg(atan2(lx - cx0, ly - cy0))
  local th = (S.rotate == 1) and yaw or 0
  local thr = rad(th)
  local cT, sT = cos(thr), sin(thr)

  -- zoom (visible metres across the smaller side), smooth, grows with vehicle speed
  local target = S.zoom * zoomMul
  if S.auto == 1 and veh then
    local vx, vy, vz = getElementVelocity(veh)
    local kmh = sqrt(vx * vx + vy * vy + vz * vz) * 180
    target = target * (1 + clamp(kmh / 130, 0, 1) * 0.7)
  end
  zoomCur = zoomCur or target
  zoomCur = zoomCur + (target - zoomCur) * (1 - exp(-dt * 4.5))
  local k = min(W, H) / zoomCur                    -- pixels per world unit
  local cx, cy = W / 2, H / 2

  local _, _, rz = getElementRotation(veh or localPlayer)
  local headCW = (360 - rz) % 360

  ---------------------------------------------------- render target
  dxSetRenderTarget(G.rt, true)
  if interior then
    dxDrawRectangle(0, 0, W, H, tocolor(10, 11, 14, 255))
  else
    local mt = assets.map
    local size = MAP_W * k
    local ix = cx - (px + HALF) * k
    local iy = cy - (HALF - py) * k
    if mt then
      dxDrawImage(ix, iy, size, size, mt, -th, cx - (ix + size / 2), cy - (iy + size / 2), tocolor(255, 255, 255, 255))
    else
      dxDrawRectangle(0, 0, W, H, tocolor(30, 32, 38, 255))
    end

    V.px, V.py, V.k, V.cx, V.cy, V.c, V.s, V.W, V.H, V.circle = px, py, k, cx, cy, cT, sT, W, H, (S.shape == "circle")

    -- waypoint
    if WP then
      local x, y = toMini(WP.x, WP.y)
      local ex, ey, clamped = edge(x, y, 16 * s)
      local pin = assets.pin
      local pulse = 0.5 + 0.5 * sin(now / 260)
      if pin then
        local ps = (clamped and 22 or 28) * s
        dxDrawImage(ex - ps / 2, ey - ps, ps, ps, pin, 0, 0, 0, tocolor(ar, ag, ab, 255))
      end
      if not clamped then
        local rs = (16 + pulse * 14) * s
        dxDrawImage(ex - rs / 2, ey - rs / 2, rs, rs, assets.ring or pin, 0, 0, 0, tocolor(ar, ag, ab, floor(150 * (1 - pulse))))
      end
    end

    -- blips
    local bs = s * S.bsize / 100
    for i = 1, #blipCache do
      local e = blipCache[i]
      local el = e.el
      if isElement(el) then
        local bx, by, bz = getElementPosition(el)
        local dxw, dyw = bx - px, by - py
        local dist2 = dxw * dxw + dyw * dyw
        local vd = e.dist or 16383
        if dist2 <= vd * vd then
          local x, y = toMini(bx, by)
          local scl = clamp(0.75 + 0.125 * e.size, 0.75, 2.2)
          if e.icon == 0 then                              -- player-style blips: coloured arrow by height
            if x > -20 and x < W + 20 and y > -20 and y < H + 20 then
              local dz = bz - pz
              local t = (dz > 5) and assets.up or (dz < -5 and assets.down or assets.square)
              local sz = 15 * bs * scl
              if t then dxDrawImage(x - sz / 2, y - sz / 2, sz, sz, t, 0, 0, 0, tocolor(e.r, e.g, e.b, 255)) end
            end
          else
            local t = e.t
            if t then
              local ex, ey = edge(x, y, 12 * bs)
              local sz = 22 * bs * min(scl, 1.6)
              dxDrawImage(ex - sz / 2, ey - sz / 2, sz, sz, t, 0, 0, 0, tocolor(255, 255, 255, 255))
            end
          end
        end
      end
    end

    -- view cone + player arrow
    local cone = assets.cone
    if cone then
      local cs = 150 * s
      dxDrawImage(cx - cs / 2, cy - cs, cs, cs, cone, (yaw - th), 0, cs / 2, tocolor(ar, ag, ab, 120))
    end
    local arrow = assets.arrow
    if arrow then
      local as = 26 * s
      dxDrawImage(cx - as / 2, cy - as / 2, as, as, arrow, headCW - th, 0, 0, tocolor(255, 255, 255, 255))
    end
  end
  dxSetRenderTarget()

  ---------------------------------------------------- compose on screen
  local slideDir = (S.pos == "bl" or S.pos == "tl") and -1 or 1
  local ox = slideDir * (1 - ease) * 50 * s
  local x, y = G.x + ox, G.y
  local color = tocolor(255, 255, 255, alpha)

  if shMask then dxDrawImage(x, y, W, H, shMask, 0, 0, 0, color, true) else dxDrawImage(x, y, W, H, G.rt, 0, 0, 0, color, true) end
  if shFrame then
    local p = G.pad
    dxDrawImage(x - p, y - p, W + p * 2, H + p * 2, shFrame, 0, 0, 0, tocolor(255, 255, 255, alpha), true)
  end

  if interior then
    shadowText("INTERIOR", x, y, x + W, y + H, tocolor(255, 255, 255, alpha), 1.2 * s, fontTitle, "center", "center")
  end

  -- north marker on the edge
  if S.north == 1 and S.rotate == 1 and not interior then
    local nx, ny = -sin(thr), -cos(thr)
    local hw, hh = W / 2 - 13 * s, H / 2 - 13 * s
    local ex, ey
    if S.shape == "circle" then
      local rr = min(W, H) / 2 - 13 * s
      ex, ey = nx * rr, ny * rr
    else
      local t = min(hw / max(abs(nx), 1e-4), hh / max(abs(ny), 1e-4))
      ex, ey = nx * t, ny * t
    end
    local bx, by = x + W / 2 + ex, y + H / 2 + ey
    local r = 10 * s
    dxDrawImage(bx - r, by - r, r * 2, r * 2, assets.dot or assets.arrow, 0, 0, 0, tocolor(ar, ag, ab, floor(alpha * 0.9)), true)
    dxDrawText("N", bx - r, by - r, bx + r, by + r, tocolor(255, 255, 255, alpha), 0.9 * s, fontTitle, "center", "center", false, false, true)
  end

  -- info bar: zone + coordinates
  if (S.zone == 1 or S.coords == 1) and not interior then
    local bh = 24 * s
    local above = (S.pos == "bl" or S.pos == "br")
    local by = above and (y - bh - 9 * s) or (y + H + 9 * s)
    dxDrawRectangle(x, by, W, bh, tocolor(8, 9, 12, floor(alpha * 0.72)), true)
    dxDrawRectangle(x, by, 3 * s, bh, tocolor(ar, ag, ab, alpha), true)
    if S.zone == 1 then
      shadowText(zone.shown, x + 12 * s, by, x + W - 8 * s, by + bh, tocolor(255, 255, 255, floor(alpha * zone.a)), 1.0 * s, fontTitle, "left", "center")
    end
    if S.coords == 1 then
      local fx, fy = floor(px), floor(py)
      if fx ~= G.cx or fy ~= G.cy then G.cx, G.cy, G.ctxt = fx, fy, fx .. ", " .. fy end
      shadowText(G.ctxt, x + 12 * s, by, x + W - 10 * s, by + bh, tocolor(190, 192, 200, alpha), 1.0 * s, fontBody, "right", "center")
    end
  end

  -- waypoint distance chip
  if WP and not interior then
    local d = sqrt((WP.x - px) ^ 2 + (WP.y - py) ^ 2)
    local dk = (d >= 1000) and floor(d / 100) or -floor(d)
    if dk ~= G.dk then G.dk = dk; G.dtxt = d >= 1000 and string.format("%.1f km", d / 1000) or (floor(d) .. " m") end
    local txt = G.dtxt
    local bw, bh = 74 * s, 20 * s
    local above = (S.pos == "bl" or S.pos == "br")
    local by = above and (y - bh - 40 * s - ((S.zone == 1 or S.coords == 1) and 24 * s or 0)) or (y + H + 40 * s + ((S.zone == 1 or S.coords == 1) and 24 * s or 0))
    dxDrawRectangle(x + W / 2 - bw / 2, by, bw, bh, tocolor(ar, ag, ab, floor(alpha * 0.85)), true)
    dxDrawText(txt, x + W / 2 - bw / 2, by, x + W / 2 + bw / 2, by + bh, tocolor(255, 255, 255, alpha), 1.0 * s, fontBody, "center", "center", false, false, true)
  end

  -- toast
  local ta = 1 - clamp((now - toast.t - 1800) / 500, 0, 1)
  if now - toast.t < 2300 then
    local a = floor(alpha * ta * clamp((now - toast.t) / 200, 0, 1))
    local up = (S.pos == "bl" or S.pos == "br")
    local ty = up and (y - 84 * s) or (y + H + 60 * s)
    shadowText(toast.text, x, ty, x + W, ty + 24 * s, tocolor(255, 255, 255, a), 1.1 * s, fontTitle, "center", "center")
  end
end

--------------------------------------------------------------------------
-- big map (CEF) : open / close, mouse injection, data feed
--------------------------------------------------------------------------
local LOCK = { "forwards", "backwards", "left", "right", "fire", "aim_weapon", "jump", "sprint", "enter_exit", "action", "next_weapon", "previous_weapon" }

local function lockControls(lock)
  if lock then
    savedControls = {}
    for i = 1, #LOCK do
      local c = LOCK[i]
      if isControlEnabled(c) then savedControls[#savedControls + 1] = c; toggleControl(c, false) end
    end
  elseif savedControls then
    for i = 1, #savedControls do toggleControl(savedControls[i], true) end
    savedControls = nil
  end
end

local function cursorToBrowser()
  if isCursorShowing() and isElement(browser) then
    local rx, ry = getCursorPosition()
    if rx then injectBrowserMouseMove(browser, rx * SW, ry * SH) end
  end
end

local function pushConfig()
  local t = {}
  for k, v in pairs(S) do t[k] = v end
  callUI("RM.cfg(" .. js(t) .. ")")
end

--------------------------------------------------------------------------
-- big map : view state (the map is drawn natively, the page only holds the UI)
--------------------------------------------------------------------------
local CELL, MAXS = 500, 1.6
local LETTERS = { "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L" }
local NUMS = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12" }
local CITIES = { { "L O S   S A N T O S", 1500, -1600 }, { "S A N   F I E R R O", -2150, 550 }, { "L A S   V E N T U R A S", 1900, 1500 } }
local M = { cx = 0, cy = 0, s = 0.26, tgt = 0.26, anchor = nil, fly = nil, vx = 0, vy = 0, drag = nil, vis = 0,
            mx = 0, my = 0, openAt = 0, rdown = nil, infoAt = 0, infoSig = "", chipAt = 0, chipSig = "", hover = nil }

local function minS() return SH / MAP_W * 0.95 end
local function w2sx(x) return SW / 2 + (x - M.cx) * M.s end
local function w2sy(y) return SH / 2 - (y - M.cy) * M.s end
local function s2wx(x) return M.cx + (x - SW / 2) / M.s end
local function s2wy(y) return M.cy - (y - SH / 2) / M.s end
local function clampView() M.cx = clamp(M.cx, -HALF, HALF); M.cy = clamp(M.cy, -HALF, HALF) end
local function fmtDist(d) return d >= 1000 and string.format("%.1f km", d / 1000) or (floor(d) .. " m") end
local function backOut(t) t = t - 1; return 1 + t * t * (2.2 * t + 1.2) end

local function zoomAt(mx, my, f)
  M.fly = nil; M.vx, M.vy = 0, 0
  M.anchor = { wx = s2wx(mx), wy = s2wy(my), mx = mx, my = my }
  M.tgt = clamp(M.tgt * f, minS(), MAXS)
end
local function flyTo(x, y, s, ms)
  M.anchor = nil; M.vx, M.vy = 0, 0
  M.fly = { x0 = M.cx, y0 = M.cy, s0 = M.s, x1 = clamp(x, -HALF, HALF), y1 = clamp(y, -HALF, HALF),
            s1 = clamp(s, minS(), MAXS), t0 = getTickCount(), ms = ms or 650 }
end
local function overUI(x, y)
  for i = 1, #UI do
    local r = UI[i]
    if x >= r[1] and x <= r[1] + r[3] and y >= r[2] and y <= r[2] + r[4] then return true end
  end
  return false
end

local function updateView(dt, now)
  local f = M.fly
  if f then
    local p = clamp((now - f.t0) / f.ms, 0, 1)
    local e = 1 - (1 - p) ^ 3
    M.cx = f.x0 + (f.x1 - f.x0) * e
    M.cy = f.y0 + (f.y1 - f.y0) * e
    M.s = exp(math.log(f.s0) + (math.log(f.s1) - math.log(f.s0)) * e)
    M.tgt = M.s
    if p >= 1 then M.fly = nil end
  else
    local dl = math.log(M.tgt / M.s)
    if abs(dl) > 0.0004 then
      M.s = M.s * exp(dl * (1 - exp(-dt * 11)))
      local a = M.anchor
      if a then M.cx = a.wx - (a.mx - SW / 2) / M.s; M.cy = a.wy + (a.my - SH / 2) / M.s end
    elseif M.s ~= M.tgt then
      M.s = M.tgt
    end
    if not M.drag and (abs(M.vx) > 8 or abs(M.vy) > 8) then            -- pan inertia
      M.cx = M.cx - M.vx * dt / M.s
      M.cy = M.cy + M.vy * dt / M.s
      local k = exp(-dt * 5); M.vx, M.vy = M.vx * k, M.vy * k
    end
  end
  clampView()
end

--------------------------------------------------------------------------
-- big map : drawing
--------------------------------------------------------------------------
local function drawBigMap(dt, now)
  local a = ease3(M.vis)
  if a < 0.004 then return end
  local us = uiScale()
  local A = floor(255 * a)
  local s = M.s
  local ar, ag, ab = hexRGB(S.accent)

  dxDrawRectangle(0, 0, SW, SH, tocolor(6, 7, 9, floor(248 * a)), true)

  -- map image
  local x0, y0 = w2sx(-HALF), w2sy(HALF)
  local size = MAP_W * s
  local x1, y1 = x0 + size, y0 + size
  if assets.map then dxDrawImage(x0, y0, size, size, assets.map, 0, 0, 0, tocolor(255, 255, 255, A), true) end

  -- border + grid
  local bc = tocolor(255, 255, 255, floor(41 * a))
  dxDrawLine(x0, y0, x1, y0, bc, 1, true); dxDrawLine(x0, y1, x1, y1, bc, 1, true)
  dxDrawLine(x0, y0, x0, y1, bc, 1, true); dxDrawLine(x1, y0, x1, y1, bc, 1, true)
  if S.grid == 1 then
    local gc = tocolor(255, 255, 255, floor(22 * a))
    local ya, yb, xa, xb = max(0, y0), min(SH, y1), max(0, x0), min(SW, x1)
    local step = CELL * s
    for i = 1, 11 do
      local gx = floor(x0 + i * step) + 0.5
      if gx > -2 and gx < SW + 2 then dxDrawLine(gx, ya, gx, yb, gc, 1, true) end
      local gy = floor(y0 + i * step) + 0.5
      if gy > -2 and gy < SH + 2 then dxDrawLine(xa, gy, xb, gy, gc, 1, true) end
    end
    local fa = tocolor(255, 255, 255, floor(255 * clamp(s * 5, 0.35, 0.9) * a))
    local top = 104 * us
    for i = 0, 11 do
      local cx = x0 + (i + 0.5) * step
      if cx > 20 and cx < SW - 20 then dxDrawText(LETTERS[i + 1], cx - 20, top - 10 * us, cx + 20, top + 10 * us, fa, us, fontTitle, "center", "center", false, false, true) end
    end
    for j = 0, 11 do
      local cy = y0 + (j + 0.5) * step
      if cy > 120 * us and cy < SH - 20 then dxDrawText(NUMS[j + 1], 14 * us, cy - 10 * us, 90 * us, cy + 10 * us, fa, us, fontTitle, "left", "center", false, false, true) end
    end
  end

  -- city names
  local la = (S.labels == 1) and clamp((0.62 - s) / 0.2, 0, 1) or 0
  if la > 0.01 then
    local ls = clamp(s * 3.4, 0.7, 1.6) * us
    local al = floor(215 * la * a)
    for i = 1, #CITIES do
      local c = CITIES[i]
      local cx, cy = w2sx(c[2]), w2sy(c[3])
      if cx > -400 and cx < SW + 400 and cy > -80 and cy < SH + 80 then
        dxDrawText(c[1], cx - 500 + 2, cy - 40 + 2, cx + 500 + 2, cy + 40 + 2, tocolor(0, 0, 0, al), ls, fontCity, "center", "center", false, false, true)
        dxDrawText(c[1], cx - 500, cy - 40, cx + 500, cy + 40, tocolor(255, 255, 255, al), ls, fontCity, "center", "center", false, false, true)
      end
    end
  end

  -- blips
  local px, py, pz = getElementPosition(localPlayer)
  local mx, my = M.mx, M.my
  local canHover = mapOpen and not M.drag and not uiCapture and not overUI(mx, my)
  local hv, hd2 = nil, (18 * us) ^ 2
  local base = 26 * us
  local prevHover = M.hover
  for i = 1, #blipCache do
    local e = blipCache[i]
    local el = e.el
    if not hiddenKeys[e.key] and isElement(el) then
      local bx, by, bz = getElementPosition(el)
      local sx, sy = w2sx(bx), w2sy(by)
      if sx > -30 and sx < SW + 30 and sy > -30 and sy < SH + 30 then
        local p = clamp((now - max(e.born, M.openAt + (i % 24) * 14)) / 420, 0, 1)
        if p > 0 then
          local t, sz, col
          local al = floor(255 * a * min(1, p * 2.5))
          if e.icon == 0 then
            local dz = bz - pz
            t = (dz > 5) and assets.up or (dz < -5 and assets.down or assets.square)
            sz = 16 * us
            col = tocolor(e.r, e.g, e.b, al)
          else
            t, sz, col = e.t, base, tocolor(255, 255, 255, al)
          end
          if t then
            if canHover then
              local d2 = (sx - mx) ^ 2 + (sy - my) ^ 2
              if d2 < hd2 then hd2 = d2; hv = e; e.hx, e.hy, e.hz = bx, by, bz end
            end
            sz = sz * backOut(p) * ((e == prevHover) and 1.2 or 1)
            dxDrawImage(sx - sz / 2, sy - sz / 2, sz, sz, t, 0, 0, 0, col, true)
          end
        end
      end
    end
  end
  M.hover = hv

  -- waypoint
  if WP then
    local wx, wy = w2sx(WP.x), w2sy(WP.y)
    if wx > -80 and wx < SW + 80 and wy > -80 and wy < SH + 80 then
      local p = clamp((now - WP.t) / 600, 0, 1)
      local e = 1 - (1 - p) ^ 3
      local ps = 36 * us * (0.6 + 0.4 * e)
      local pin = assets.pin
      local tt = (now % 1600) / 1600
      local rs = 44 * us * (0.35 + 0.9 * tt)
      if assets.ring then dxDrawImage(wx - rs / 2, wy - rs / 2, rs, rs, assets.ring, 0, 0, 0, tocolor(ar, ag, ab, floor(230 * (1 - tt) * a)), true) end
      if pin then dxDrawImage(wx - ps / 2, wy - ps - 26 * us * (1 - e), ps, ps, pin, 0, 0, 0, tocolor(255, 255, 255, floor(255 * a * min(1, p * 3))), true) end
      local d = sqrt((WP.x - px) ^ 2 + (WP.y - py) ^ 2)
      shadowText(fmtDist(d), wx - 60 * us, wy + 6 * us, wx + 60 * us, wy + 24 * us, tocolor(255, 255, 255, A), us, fontBody, "center", "top")
    end
  end

  -- me
  local sx, sy = w2sx(px), w2sy(py)
  if sx > -80 and sx < SW + 80 and sy > -80 and sy < SH + 80 then
    local veh = getPedOccupiedVehicle(localPlayer)
    local _, _, rz = getElementRotation(veh or localPlayer)
    local tt = (now % 2000) / 2000
    local rs = 52 * us * (0.35 + 0.9 * tt)
    if assets.ring then dxDrawImage(sx - rs / 2, sy - rs / 2, rs, rs, assets.ring, 0, 0, 0, tocolor(ar, ag, ab, floor(230 * (1 - tt) * a)), true) end
    if assets.arrow then
      local as = 30 * us
      dxDrawImage(sx - as / 2, sy - as / 2, as, as, assets.arrow, (360 - rz) % 360, 0, 0, tocolor(255, 255, 255, A), true)
    end
  end

  -- vignette
  if assets.vig then dxDrawImage(0, 0, SW, SH, assets.vig, 0, 0, 0, tocolor(255, 255, 255, A), true) end

  -- tooltip
  if hv then
    local name = (hv.icon == 0) and "PLAYER" or (Config.blipNames[hv.icon] or ("ICON " .. string.format("%02d", hv.icon))):upper()
    local dtxt = fmtDist(sqrt((hv.hx - px) ^ 2 + (hv.hy - py) ^ 2))
    local w = max(dxGetTextWidth(name, us, fontTitle), dxGetTextWidth(dtxt, us, fontBody)) + 30 * us
    local h = 48 * us
    local tx, ty = min(SW - w - 8, mx + 18), min(SH - h - 8, my + 14)
    dxDrawRectangle(tx, ty, w, h, tocolor(10, 11, 14, floor(246 * a)), true)
    dxDrawRectangle(tx, ty, 3 * us, h, tocolor(ar, ag, ab, A), true)
    dxDrawText(name, tx + 14 * us, ty + 6 * us, tx + w, ty + 26 * us, tocolor(255, 255, 255, A), us, fontTitle, "left", "center", false, false, true)
    dxDrawText(dtxt, tx + 14 * us, ty + 25 * us, tx + w, ty + 43 * us, tocolor(141, 142, 150, A), us, fontBody, "left", "center", false, false, true)
  end
end

--------------------------------------------------------------------------
-- big map : page feed, open / close
--------------------------------------------------------------------------
local function pushChip(force, px, py)
  local d = WP and floor(sqrt((WP.x - px) ^ 2 + (WP.y - py) ^ 2)) or -1
  local sig = floor(px) .. "," .. floor(py) .. "," .. d
  if force or sig ~= M.chipSig then
    M.chipSig = sig
    callUI(string.format("RM.p(%d,%d,%d)", floor(px), floor(py), d))
  end
end

local function pushInfo(px, py)
  local x, y = s2wx(M.mx), s2wy(M.my)
  local inMap = abs(x) <= HALF and abs(y) <= HALF
  local cell, d = "--", ""
  if inMap then
    cell = LETTERS[min(11, floor((x + HALF) / CELL)) + 1] .. (min(11, floor((HALF - y) / CELL)) + 1)
    d = fmtDist(sqrt((x - px) ^ 2 + (y - py) ^ 2))
  end
  local sig = cell .. floor(x) .. "," .. floor(y) .. d
  if sig ~= M.infoSig then
    M.infoSig = sig
    callUI(string.format("RM.i(%s,%d,%d,%s)", jsStr(cell), floor(x), floor(y), jsStr(d)))
  end
end

local function openMap(state)
  state = state and true or false
  if state == mapOpen or not isElement(browser) then return end
  if state then
    if not shown or not ready then return end
    if isChatBoxInputActive() or isConsoleActive() or guiGetInputEnabled() or isMainMenuActive() then return end
    if isCursorShowing() then return end
    refreshBlips()
  end
  mapOpen = state
  M.drag, M.rdown, uiCapture, wasOverUI = nil, nil, false, false
  if state then
    paused = false
    setBrowserRenderingPaused(browser, false)
    showCursor(true)
    local rx, ry = getCursorPosition()
    if rx then M.mx, M.my = rx * SW, ry * SH end
    cursorToBrowser()
    lockControls(true)
    local px, py = getElementPosition(localPlayer)
    M.openAt = getTickCount()
    M.s = clamp(0.26, minS(), MAXS); M.tgt = M.s
    M.cx, M.cy = px, py; M.anchor = nil; M.vx, M.vy = 0, 0; M.hover = nil
    flyTo(px, py, 0.42, 900)
    pushConfig()
    pushChip(true, px, py)
    callUI("RM.g(" .. js(groupsRows) .. ")")
    callUI("RM.open(true)")
    browserUntil = math.huge
  else
    preview = false
    showCursor(false)
    lockControls(false)
    callUI("RM.open(false)")
    browserUntil = getTickCount() + 700
  end
end

--------------------------------------------------------------------------
-- mouse : the page owns the mouse only over its own panels, everywhere else it is the map
--------------------------------------------------------------------------
addEventHandler("onClientCursorMove", root, function(_, _, x, y)
  if not mapOpen then return end
  M.mx, M.my = x, y
  local d = M.drag
  if d then
    local now = getTickCount()
    local dx, dy = x - d.lx, y - d.ly
    local dtm = max(8, now - d.t)
    d.t, d.lx, d.ly = now, x, y
    M.cx = M.cx - dx / M.s; M.cy = M.cy + dy / M.s
    clampView()
    M.vx = M.vx * 0.5 + (dx / dtm * 1000) * 0.5
    M.vy = M.vy * 0.5 + (dy / dtm * 1000) * 0.5
  end
  local over = overUI(x, y)
  if (over or uiCapture or wasOverUI) and isElement(browser) then injectBrowserMouseMove(browser, x, y) end
  wasOverUI = over
end)

addEventHandler("onClientClick", root, function(button, state, x, y)
  if not mapOpen or not isElement(browser) then return end
  if state == "down" then
    if overUI(x, y) then
      uiCapture = true
      injectBrowserMouseMove(browser, x, y)
      injectBrowserMouseDown(browser, button)
      return
    end
    if button == "left" or button == "middle" then
      M.drag = { lx = x, ly = y, t = getTickCount() }
      M.vx, M.vy = 0, 0; M.fly = nil; M.anchor = nil
    elseif button == "right" then
      M.rdown = { x = x, y = y }
    end
  else
    if uiCapture then
      injectBrowserMouseMove(browser, x, y)
      injectBrowserMouseUp(browser, button)
      if button == "left" then uiCapture = false end
      return
    end
    if (button == "left" or button == "middle") and M.drag then
      if getTickCount() - M.drag.t > 90 then M.vx, M.vy = 0, 0 end
      M.drag = nil
    elseif button == "right" and M.rdown then
      local r = M.rdown; M.rdown = nil
      if abs(x - r.x) + abs(y - r.y) < 6 and not overUI(x, y) then
        local wx, wy = s2wx(x), s2wy(y)
        if abs(wx) <= HALF and abs(wy) <= HALF then
          if WP and ((w2sx(WP.x) - x) ^ 2 + (w2sy(WP.y) - y) ^ 2) < (24 * uiScale()) ^ 2 then
            clearWaypoint(); callUI('RM.toast("Waypoint removed")')
          elseif setWaypoint(wx, wy) then
            callUI('RM.toast("Waypoint set")')
          end
        end
      end
    end
  end
end)

local function wheel(dir)
  if not mapOpen or not isElement(browser) then return end
  if overUI(M.mx, M.my) then injectBrowserMouseWheel(browser, dir * 80, 0)
  else zoomAt(M.mx, M.my, dir > 0 and 1.3 or 1 / 1.3) end
end
bindKey("mouse_wheel_up", "down", function() wheel(1) end)
bindKey("mouse_wheel_down", "down", function() wheel(-1) end)

-- the default MTA map must never open on its own.
-- NOTE: MTA reports function keys in upper case ("F11"), so the name is compared case-insensitively.
local MAPKEY = Config.mapKey:lower()
addEventHandler("onClientKey", root, function(key, press)
  local k = tostring(key):lower()
  if k == MAPKEY then
    cancelEvent()
    if press then
      if forcePlayerMap and isPlayerMapVisible() then forcePlayerMap(false) end
      openMap(not mapOpen)
    end
  elseif k == "escape" and press and mapOpen then
    openMap(false)
  end
end)

--------------------------------------------------------------------------
-- events from the page (local only; every value is validated)
--------------------------------------------------------------------------
addEvent("Lx:radar:close", false)
addEvent("Lx:radar:wp", false)
addEvent("Lx:radar:set", false)
addEvent("Lx:radar:reset", false)
addEvent("Lx:radar:preview", false)
addEvent("Lx:radar:setwp", true)          -- server -> client
addEvent("Lx:radar:clearwp", true)

addEventHandler("Lx:radar:close", root, function() openMap(false) end)

addEvent("Lx:radar:act", false)
addEvent("Lx:radar:hide", false)
addEvent("Lx:radar:ui", false)

addEventHandler("Lx:radar:act", root, function(a)
  if not mapOpen or type(a) ~= "string" then return end
  local px, py = getElementPosition(localPlayer)
  if a == "me" then flyTo(px, py, max(M.s, 0.5))
  elseif a == "in" then zoomAt(SW / 2, SH / 2, 1.5)
  elseif a == "out" then zoomAt(SW / 2, SH / 2, 1 / 1.5)
  elseif a == "wpfly" and WP then flyTo(WP.x, WP.y, max(M.s, 0.5))
  elseif a == "wpclear" and WP then clearWaypoint(); callUI('RM.toast("Waypoint removed")') end
end)

addEventHandler("Lx:radar:hide", root, function(csv)
  if type(csv) ~= "string" or #csv > 256 then return end
  local set = {}
  for tok in csv:gmatch("[^,]+") do
    if tok == "p" or tok:match("^%d+$") then set[tok] = true end
  end
  hiddenKeys = set
end)

addEventHandler("Lx:radar:ui", root, function(str)
  if type(str) ~= "string" or #str > 256 then return end
  local out = {}
  for x, y, w, h in str:gmatch("(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)") do
    if #out < 8 then out[#out + 1] = { tonumber(x), tonumber(y), tonumber(w), tonumber(h) } end
  end
  UI = out
end)

addEventHandler("Lx:radar:set", root, function(key, value)
  if type(key) ~= "string" or DEF[key] == nil then return end
  local c = clean(key, value)
  if c == nil then return end
  S[key] = c
  if key == "shape" or key == "size" or key == "pos" or key == "ox" or key == "oy" then layout() end
  if key == "accent" then applyShader() end
  saveSoon()
end)

addEventHandler("Lx:radar:reset", root, function()
  for k, v in pairs(DEF) do S[k] = v end
  layout(); saveSoon(); pushConfig()
end)

addEventHandler("Lx:radar:preview", root, function(v)
  if mapOpen then preview = (v == "1") end
end)

addEventHandler("Lx:radar:setwp", resourceRoot, function(x, y)
  if setWaypoint(x, y) then notify("NEW WAYPOINT") end
end)
addEventHandler("Lx:radar:clearwp", resourceRoot, function() clearWaypoint() end)

--------------------------------------------------------------------------
-- main loop
--------------------------------------------------------------------------
local pAt, bAt = 0, 0
local defMapForced = false
local hudAt = 0
addEventHandler("onClientRender", root, function()
  local now = getTickCount()
  local dt = clamp((now - lastTick) / 1000, 0, 0.1)
  lastTick = now

  -- MTA's own F11 map is handled inside the engine (cancelEvent can't stop it): force it closed
  if forcePlayerMap then
    if not defMapForced then defMapForced = true; forcePlayerMap(false) end
    if isPlayerMapVisible() then
      forcePlayerMap(false)
      if not mapOpen and shown then openMap(true) end
    end
  end

  if Config.hideDefaultRadar and now - hudAt > 500 then
    hudAt = now
    setPlayerHudComponentVisible("radar", false)
    setPlayerHudComponentVisible("area_name", false)
  end

  local on = shouldShow(now)
  if on ~= shown then
    shown = on
    if not on and mapOpen then openMap(false) end
  end

  -- big map feed (the map itself is drawn every frame below; the page only gets small, rare updates)
  if mapOpen then
    if now - blipRefreshAt >= 200 then blipRefreshAt = now; refreshBlips() end
    local px, py = getElementPosition(localPlayer)
    if now - M.chipAt >= 200 then M.chipAt = now; pushChip(false, px, py) end
    if now - M.infoAt >= 80 then M.infoAt = now; pushInfo(px, py) end
  elseif shown and now - blipRefreshAt >= 400 then
    blipRefreshAt = now; refreshBlips()
  end

  -- waypoint arrival
  if WP and shown then
    local px, py = getElementPosition(localPlayer)
    if sqrt((WP.x - px) ^ 2 + (WP.y - py) ^ 2) < Config.arriveDistance then
      clearWaypoint(); notify("DESTINATION REACHED")
    end
  end

  -- zone name (cross-fade)
  if shown and now - zone.at > 400 then
    zone.at = now
    local px, py, pz = getElementPosition(localPlayer)
    local area, city = getZoneName(px, py, pz), getZoneName(px, py, pz, true)
    local txt = (city ~= "Unknown" and city ~= area) and (area .. ", " .. city) or area
    zone.text = txt:upper()
  end
  if zone.text ~= zone.shown then
    zone.a = zone.a - dt * 5
    if zone.a <= 0 then zone.a = 0; zone.shown = zone.text end
  elseif zone.a < 1 then
    zone.a = min(1, zone.a + dt * 4)
  end

  -- big map (dx) -> minimap -> page (UI panels on top)
  M.vis = clamp(M.vis + (mapOpen and 1 or -1) * dt * 2.4, 0, 1)
  if M.vis > 0.003 then
    if mapOpen then updateView(min(dt, 0.05), now) end
    drawBigMap(dt, now)
  end

  local want = shown and (not mapOpen or preview)
  vis = clamp(vis + (want and 1 or -1) * dt * 3.2, 0, 1)
  if vis > 0.003 then drawMinimap(dt, now) end

  if isElement(browser) and now < browserUntil then
    dxDrawImage(0, 0, SW, SH, browser, 0, 0, 0, 0xFFFFFFFF, true)
  elseif isElement(browser) and ready and not mapOpen and not paused then
    paused = true
    setBrowserRenderingPaused(browser, true)
  end
end)

--------------------------------------------------------------------------
-- keys / commands
--------------------------------------------------------------------------
local function bindAll()
  bindKey(Config.zoomInKey, "down", function() zoomMul = clamp(zoomMul * 0.85, 0.45, 2.2) end)
  bindKey(Config.zoomOutKey, "down", function() zoomMul = clamp(zoomMul / 0.85, 0.45, 2.2) end)
  addCommandHandler(Config.command, function() forcedOff = not forcedOff end)
end

--------------------------------------------------------------------------
-- start / stop
--------------------------------------------------------------------------
local function onDocumentReady(url)
  if ready or type(url) ~= "string" or not url:find("map.html", 1, true) then return end
  ready = true
  local names = {}
  for k, v in pairs(Config.blipNames) do names[tostring(k)] = tostring(v) end
  local t = {}
  for k, v in pairs(S) do t[k] = v end
  executeBrowserJavascript(source, "RM.init(" .. js(t) .. "," .. js(names) .. ")")
  for _, code in ipairs(queue) do executeBrowserJavascript(source, code) end
  queue = {}
  setBrowserRenderingPaused(source, true)
end

addEventHandler("onClientResourceStart", resourceRoot, function()
  loadSettings()
  loadFonts()
  assets.map   = dxCreateTexture("map.jpg", "dxt1", true, "clamp") or tex("map.jpg")
  assets.arrow = tex("arrow.png")
  assets.pin   = tex("pin.png")
  assets.cone  = tex("cone.png")
  assets.dot   = tex("dot.png")
  assets.ring  = tex("ring.png")
  assets.vig   = tex("vignette.png")
  assets.up, assets.down, assets.square = tex("blips/up.png"), tex("blips/down.png"), tex("blips/square.png")
  if not assets.map then outputDebugString("[Lx]Radar: map.jpg could not be loaded", 1) end

  shMask, shFrame = dxCreateShader(FX), dxCreateShader(FX)
  if not shMask or not shFrame then
    outputDebugString("[Lx]Radar: shader unavailable, the minimap will be a plain square", 2)
    if isElement(shMask) then destroyElement(shMask) end
    if isElement(shFrame) then destroyElement(shFrame) end
    shMask, shFrame = nil, nil
  end
  layout()

  browser = createBrowser(SW, SH, true, true)
  addEventHandler("onClientBrowserCreated", browser, function() loadBrowserURL(source, "http://mta/local/map.html") end)
  addEventHandler("onClientBrowserDocumentReady", browser, onDocumentReady)
  addEventHandler("onClientBrowserLoadingFailed", browser, function(url, code, desc)
    outputDebugString("[Lx]Radar: could not load " .. tostring(url) .. " (" .. tostring(code) .. " " .. tostring(desc) .. ")", 1)
  end)
  bindAll()
end)

addEventHandler("onClientResourceStop", resourceRoot, function()
  if mapOpen then showCursor(false); lockControls(false) end
  setPlayerHudComponentVisible("radar", true)
  setPlayerHudComponentVisible("area_name", true)
end)

addEventHandler("onClientRestore", root, function()
  -- render targets can lose their content when the window is minimised; they are redrawn every frame anyway
  if G.w and not isElement(G.rt) then G.w = nil; layout() end
end)

--------------------------------------------------------------------------
-- exports
--------------------------------------------------------------------------
function setRadarWaypoint(x, y) return setWaypoint(x, y) end
function clearRadarWaypoint() clearWaypoint(); return true end
