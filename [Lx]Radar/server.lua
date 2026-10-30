--[[ =====================================================================
   LINUX Game - [Lx]Radar | server.lua
   Server side authority for the radar:
   * player blips are created HERE, per player, with a visibility rule
     ("all" / "team" / "none"). A client never receives blips it must not see,
     so a modified client cannot reveal hidden players.
   * validated waypoint API for other resources.
   Exports:  setPlayerWaypoint(player, x, y)   clearPlayerWaypoint(player)
   ===================================================================== ]]

local CFG = {
  playerBlips   = "team",     -- "all"  = every logged-in player sees every other player
                              -- "team" = only players of the same team see each other
                              -- "none" = no player blips
  size          = 2,          -- blip size
  requireLogin  = true,       -- only players that finished the [Lx]Login flow get a blip
  loginKey      = "lg.id",
  hiddenKey     = "Lx.radar.hidden",   -- set this element data to true on a player to remove him from every radar (admins...)
}

local blips, teamOf = {}, {}

local function eligible(p)
  if CFG.playerBlips == "none" then return false end
  if not isElement(p) or isPedDead(p) then return false end
  if CFG.requireLogin and not getElementData(p, CFG.loginKey) then return false end
  if getElementData(p, CFG.hiddenKey) then return false end
  return true
end

local function applyVisibility(p)
  local b = blips[p]
  if not isElement(b) then return end
  if CFG.playerBlips == "all" then
    setElementVisibleTo(b, root, true)
    setElementVisibleTo(b, p, false)          -- nobody needs a blip of himself
  else
    setElementVisibleTo(b, root, false)
    local t = getPlayerTeam(p)
    if t then setElementVisibleTo(b, t, true); setElementVisibleTo(b, p, false) end
  end
  teamOf[p] = getPlayerTeam(p) or false
end

local function destroyBlip(p)
  if isElement(blips[p]) then destroyElement(blips[p]) end
  blips[p], teamOf[p] = nil, nil
end

local function makeBlip(p)
  if blips[p] and isElement(blips[p]) then return end
  if not eligible(p) then return end
  local r, g, b = 255, 255, 255
  local t = getPlayerTeam(p)
  if t then r, g, b = getTeamColor(t) end
  blips[p] = createBlipAttachedTo(p, 0, CFG.size, r, g, b, 255, 0, 16383)
  applyVisibility(p)
end

addEventHandler("onPlayerSpawn", root, function() destroyBlip(source); makeBlip(source) end)
addEventHandler("onPlayerWasted", root, function() destroyBlip(source) end)
addEventHandler("onPlayerQuit", root, function() destroyBlip(source) end)

-- team changes / hidden flag are polled (cheap: only compares one value per player)
setTimer(function()
  for _, p in ipairs(getElementsByType("player")) do
    if eligible(p) then
      if not isElement(blips[p]) then makeBlip(p)
      elseif teamOf[p] ~= (getPlayerTeam(p) or false) then
        local t = getPlayerTeam(p)
        if t then local r, g, b = getTeamColor(t); setBlipColor(blips[p], r, g, b, 255) end
        applyVisibility(p)
      end
    else
      destroyBlip(p)
    end
  end
end, 2500, 0)

addEventHandler("onResourceStart", resourceRoot, function()
  for _, p in ipairs(getElementsByType("player")) do makeBlip(p) end
end)

--------------------------------------------------------------------------
-- waypoint API
--------------------------------------------------------------------------
local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

function setPlayerWaypoint(player, x, y)
  x, y = tonumber(x), tonumber(y)
  if not isElement(player) or getElementType(player) ~= "player" then return false end
  if not finite(x) or not finite(y) or math.abs(x) > 3100 or math.abs(y) > 3100 then return false end
  triggerClientEvent(player, "Lx:radar:setwp", resourceRoot, x, y)
  return true
end

function clearPlayerWaypoint(player)
  if not isElement(player) or getElementType(player) ~= "player" then return false end
  triggerClientEvent(player, "Lx:radar:clearwp", resourceRoot)
  return true
end
