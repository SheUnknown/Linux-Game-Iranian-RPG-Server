-- [Lx]Anti-Cheat (server). Everything here is checked on the SERVER, because anything a client reports can be faked.
-- Each detection adds "strike points"; points fade 1 per minute; at KICK_AT the player is kicked. Every strike is logged (category "ac")
-- and heavy ones are shown to online staff when [Lx]Admin is running.
local G = exports["[Lx]Global"]
local CFG = {
  kickAt = 12,                       -- points before an automatic kick
  decayEverySec = 60,                -- -1 point per minute
  maxFootSpeed = 130,                -- units/second on foot (sprint ~8, falling ~60, jetpack ~40)
  maxVehicleSpeed = 330,             -- units/second in a vehicle
  graceAfterSpawnMs = 6000,
  maxRemoteEventsPerSec = 70,        -- client -> server events per second before extra events are dropped
  checkMoney = true,                 -- needs [Lx]Bank: the MTA money MUST equal the Bank cash (any other source is reverted)
  bannedWeapons = { [35] = true, [36] = true, [37] = true, [38] = true, [39] = true, [40] = true, [18] = true },   -- rocket, heat seeker, flamethrower, minigun, satchel, detonator, molotov
}

local S = {}                                           -- [player] = { score, ignoreUntil, x,y,z,t, int,dim }

local function st(p) S[p] = S[p] or { score = 0, ignoreUntil = 0 }; return S[p] end
local function clean(p) return (getPlayerName(p):gsub("#%x%x%x%x%x%x", "")) end
local function running(name) local r = getResourceFromName(name); return r and getResourceState(r) == "running" end

function ignore(p, ms)
  if not isElement(p) then return false end
  local s = st(p); s.ignoreUntil = math.max(s.ignoreUntil, getTickCount() + (tonumber(ms) or 3000)); s.x = nil
  return true
end
function getStrikes(p) return S[p] and S[p].score or 0 end

local function strike(p, weight, reason)
  if not isElement(p) or not G:isLoggedIn(p) then return end
  local s = st(p); s.score = s.score + weight
  G:log("ac", ("%s (+%d => %d)"):format(reason, weight, s.score), p)
  if weight >= 3 and running("[Lx]Admin") then
    exports["[Lx]Admin"]:notifyStaff(("AC: %s - %s (+%d => %d/%d)"):format(clean(p), reason, weight, s.score, CFG.kickAt), 1)
  end
  if s.score >= CFG.kickAt then
    G:log("ac", "auto kick: " .. reason, p)
    kickPlayer(p, "Anti-Cheat", "Suspicious activity: " .. reason)
  end
end

---------------------------------------------------------------- 1) teleport / speed (positions sampled once a second)
setTimer(function()
  local tk = getTickCount()
  for _, p in ipairs(getElementsByType("player")) do
    if G:isLoggedIn(p) and not isPedDead(p) then
      local s = st(p)
      local x, y, z = getElementPosition(p)
      local int, dim = getElementInterior(p), getElementDimension(p)
      local veh = getPedOccupiedVehicle(p)
      if s.x and tk >= s.ignoreUntil and int == s.int and dim == s.dim and not s.veh == not veh then
        local dt = (tk - s.t) / 1000
        if dt > 0.5 then
          local speed = getDistanceBetweenPoints3D(x, y, z, s.x, s.y, s.z) / dt
          local limit = veh and CFG.maxVehicleSpeed or CFG.maxFootSpeed
          if speed > limit then strike(p, speed > limit * 3 and 5 or 3, ("teleport/speed %.0f u/s (limit %d)"):format(speed, limit)) end
        end
      end
      s.x, s.y, s.z, s.t, s.int, s.dim, s.veh = x, y, z, tk, int, dim, veh and true or false
    end
  end
end, 1000, 0)

addEventHandler("onPlayerSpawn", root, function() ignore(source, CFG.graceAfterSpawnMs) end)
addEventHandler("onPlayerWasted", root, function() ignore(source, CFG.graceAfterSpawnMs) end)
addEventHandler("onElementDataChange", root, function(key)
  if key == "lg.id" and getElementType(source) == "player" then ignore(source, CFG.graceAfterSpawnMs) end
end)
addEventHandler("onPlayerQuit", root, function() S[source] = nil end)

---------------------------------------------------------------- 2) money must match the bank, 3) weapons, 4) health / armor
setTimer(function()
  local bank = CFG.checkMoney and running("[Lx]Bank")
  for _, p in ipairs(getElementsByType("player")) do
    if G:isLoggedIn(p) and not isPedDead(p) then
      if bank then
        local want = math.min(exports["[Lx]Bank"]:getCash(p), 2147483647)
        if getPlayerMoney(p) ~= want and want >= 0 then
          if exports["[Lx]Bank"]:getCash(p) > 0 or getPlayerMoney(p) > 0 then
            strike(p, 5, ("money mismatch (client %d, bank %d)"):format(getPlayerMoney(p), want))
          end
          setPlayerMoney(p, want, true)
        end
      end
      local w = getPedWeapon(p)
      if CFG.bannedWeapons[w] then takeWeapon(p, w); strike(p, 4, "banned weapon " .. w) end
      if getElementHealth(p) > 100.5 then setElementHealth(p, 100); strike(p, 2, "health above 100") end
      if getPedArmor(p) > 100.5 then setPedArmor(p, 100); strike(p, 2, "armor above 100") end
    end
  end
end, 2000, 0)

---------------------------------------------------------------- 5) event flood: more than N remote events/second from one client are dropped
local flood = {}
addEventHandler("onResourceStart", resourceRoot, function()
  addDebugHook("preEvent", function(srcRes, name, source_, client_)
    if not client_ or getElementType(client_) ~= "player" then return end            -- only events that a CLIENT triggered
    local t = getTickCount()
    local f = flood[client_]
    if not f or t - f.t >= 1000 then f = { t = t, n = 0, warned = false }; flood[client_] = f end
    f.n = f.n + 1
    if f.n > CFG.maxRemoteEventsPerSec then
      if not f.warned then f.warned = true; strike(client_, 4, ("event flood (%s)"):format(tostring(name))) end
      return "skip"
    end
  end)
end)
addEventHandler("onPlayerQuit", root, function() flood[source] = nil end)

---------------------------------------------------------------- strikes fade
setTimer(function() for _, s in pairs(S) do if s.score > 0 then s.score = s.score - 1 end end end, CFG.decayEverySec * 1000, 0)
