--[[ =====================================================================
   LINUX Game - [Lx]HUD | server.lua
   Gives every player a short numeric ID (the lowest free number) and
   sends it to that player's HUD.
   Other resources:  exports["LxHUD"]:getPlayerID(player)
                     exports["LxHUD"]:getPlayerFromID(5)
   (replace "LxHUD" with the folder name of this resource)
   ===================================================================== ]]

addEvent("Lx:hud:ready", true)
addEvent("Lx:hud:id", true)

local idOf, playerOf = {}, {}     -- [player] = id   /   [id] = player

local function assign(player)
  if idOf[player] then return idOf[player] end
  local id = 1
  while playerOf[id] do id = id + 1 end
  idOf[player], playerOf[id] = id, player
  return id
end

local function release(player)
  local id = idOf[player]
  if id then playerOf[id] = nil end
  idOf[player] = nil
end

local function send(player)
  if isElement(player) then triggerClientEvent(player, "Lx:hud:id", resourceRoot, assign(player)) end
end

-- the HUD asks for its ID as soon as its page is loaded (also covers late joiners and resource restarts)
addEventHandler("Lx:hud:ready", resourceRoot, function()
  if isElement(client) and getElementType(client) == "player" then send(client) end
end)

addEventHandler("onPlayerJoin", root, function() assign(source) end)
addEventHandler("onPlayerQuit", root, function() release(source) end)
addEventHandler("onResourceStart", resourceRoot, function()
  for _, p in ipairs(getElementsByType("player")) do assign(p) end
end)

function getPlayerID(player) return isElement(player) and idOf[player] or false end
function getPlayerFromID(id) return playerOf[tonumber(id)] or false end
