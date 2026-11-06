-- [Lx]Inventory (server). The server owns every item: the client can only ASK (move / use / drop / give).
local G = exports["[Lx]Global"]
local N = exports["[Lx]Notification"]
local SLOTS, MAX_W = INV_CFG.slots, INV_CFG.maxWeight
local db
local INV = {}                                         -- [player] = { uid, slots = {[i]={item,count}}, dirty, ready }

---------------------------------------------------------------- helpers
local function weightOf(inv)
  local w = 0
  for _, s in pairs(inv.slots) do w = w + ITEMS[s.item].weight * s.count end
  return w
end

local function tryAdd(inv, item, count)                -- all-or-nothing
  local def = ITEMS[item]
  if weightOf(inv) + def.weight * count > MAX_W + 1e-6 then return false, "weight" end
  local room, empty = 0, 0
  for i = 1, SLOTS do
    local s = inv.slots[i]
    if not s then empty = empty + 1 elseif s.item == item then room = room + (def.stack - s.count) end
  end
  if room + empty * def.stack < count then return false, "full" end
  local left = count
  for i = 1, SLOTS do
    local s = inv.slots[i]
    if left > 0 and s and s.item == item and s.count < def.stack then
      local put = math.min(left, def.stack - s.count); s.count = s.count + put; left = left - put
    end
  end
  for i = 1, SLOTS do
    if left > 0 and not inv.slots[i] then
      local put = math.min(left, def.stack); inv.slots[i] = { item = item, count = put }; left = left - put
    end
  end
  inv.dirty = true
  return true
end

local function countOf(inv, item)
  local n = 0
  for _, s in pairs(inv.slots) do if s.item == item then n = n + s.count end end
  return n
end

local function tryRemove(inv, item, count)
  if countOf(inv, item) < count then return false, "missing" end
  local left = count
  for i = SLOTS, 1, -1 do                              -- take from the back first
    local s = inv.slots[i]
    if left > 0 and s and s.item == item then
      local take = math.min(left, s.count); s.count = s.count - take; left = left - take
      if s.count <= 0 then inv.slots[i] = nil end
    end
  end
  inv.dirty = true
  return true
end

local function ready(player) local inv = INV[player]; return inv and inv.ready and inv or nil end

local function sync(player, show)
  local inv = ready(player); if not inv then return end
  local list = {}
  for i = 1, SLOTS do local s = inv.slots[i]; if s then list[#list + 1] = { slot = i, item = s.item, count = s.count } end end
  triggerClientEvent(player, "lx:inv:sync", resourceRoot, list, math.floor(weightOf(inv) * 100 + 0.5) / 100, MAX_W, show and true or false)
end

---------------------------------------------------------------- persistence (upsert first, delete emptied slots after: never a window with a wiped inventory)
local function save(inv)
  if not db or not inv.dirty then return end
  inv.dirty = false
  local ph, args, empties = {}, {}, {}
  for i = 1, SLOTS do
    local s = inv.slots[i]
    if s then
      ph[#ph + 1] = "(?,?,?,?)"
      args[#args + 1] = inv.uid; args[#args + 1] = i; args[#args + 1] = s.item; args[#args + 1] = s.count
    else empties[#empties + 1] = i end
  end
  if #ph > 0 then
    dbExec(db, "INSERT INTO lx_inventory (user_id, slot, item, qty) VALUES " .. table.concat(ph, ",") ..
      " ON DUPLICATE KEY UPDATE item = VALUES(item), qty = VALUES(qty)", unpack(args))
  end
  if #empties > 0 then
    dbExec(db, "DELETE FROM lx_inventory WHERE user_id = ? AND slot IN (" .. table.concat(empties, ",") .. ")", inv.uid)
  end
end

local function loadFor(player)
  local uid = G:getUserId(player)
  if not uid or INV[player] or not db then return end
  local inv = { uid = uid, slots = {}, dirty = false, ready = false }
  INV[player] = inv
  dbQuery(function(h)
    local rows = dbPoll(h, 0)
    if not rows then if isElement(player) then N:notify(player, "error", "Inventory", "Could not load your inventory. Reconnect or contact staff.") end; return end
    if not isElement(player) or INV[player] ~= inv then return end
    for _, r in ipairs(rows) do
      local slot, def = tonumber(r.slot), ITEMS[r.item]
      if def and slot and slot >= 1 and slot <= SLOTS then inv.slots[slot] = { item = r.item, count = math.min(tonumber(r.qty) or 1, def.stack) }
      else G:log("inventory", ("dropped unknown row item=%s slot=%s"):format(tostring(r.item), tostring(r.slot)), player) end
    end
    inv.ready = true
    sync(player, false)
  end, db, "SELECT slot, item, qty FROM lx_inventory WHERE user_id = ?", uid)
end

addEventHandler("onResourceStart", resourceRoot, function()
  db = G:getDb()
  if not db then outputServerLog("[Lx]Inventory: no database, resource idle"); return end
  dbExec(db, [[CREATE TABLE IF NOT EXISTS lx_inventory (
    user_id INT UNSIGNED NOT NULL, slot SMALLINT UNSIGNED NOT NULL, item VARCHAR(32) NOT NULL, qty INT UNSIGNED NOT NULL,
    PRIMARY KEY (user_id, slot)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
  for _, p in ipairs(getElementsByType("player")) do loadFor(p) end
  setTimer(function() for _, inv in pairs(INV) do if inv.dirty then save(inv) end end end, 20000, 0)
end)

addEventHandler("onResourceStop", resourceRoot, function() for _, inv in pairs(INV) do save(inv) end end)
addEventHandler("onPlayerQuit", root, function() local inv = INV[source]; if inv then save(inv); INV[source] = nil end end)
addEventHandler("onElementDataChange", root, function(key)
  if key == "lg.id" and getElementType(source) == "player" then loadFor(source) end        -- [Lx]Login just logged the player in
end)

---------------------------------------------------------------- exports
local function valid(player, item, count)
  local inv = ready(player)
  if not inv then return nil, "not_ready" end
  if not ITEMS[item] then return nil, "unknown_item" end
  count = G:toInt(count, 1, 100000)
  if not count then return nil, "bad_count" end
  return inv, count
end

function addItem(player, item, count)
  local inv, c = valid(player, item, count); if not inv then return false, c end
  local ok, why = tryAdd(inv, item, c)
  if ok then sync(player, false) end
  return ok, why
end
function removeItem(player, item, count)
  local inv, c = valid(player, item, count); if not inv then return false, c end
  local ok, why = tryRemove(inv, item, c)
  if ok then sync(player, false) end
  return ok, why
end
function getItemCount(player, item) local inv = ready(player); return inv and ITEMS[item] and countOf(inv, item) or 0 end
function hasItem(player, item, count) return getItemCount(player, item) >= (tonumber(count) or 1) end
function canCarry(player, item, count)
  local inv, c = valid(player, item, count); if not inv then return false end
  local copy = { slots = {}, dirty = false }
  for i, s in pairs(inv.slots) do copy.slots[i] = { item = s.item, count = s.count } end
  return (tryAdd(copy, item, c))
end
function getWeight(player) local inv = ready(player); if not inv then return 0, MAX_W end return weightOf(inv), MAX_W end

---------------------------------------------------------------- use effects: return true to consume one, or false, "why not"
local function heal(p, amount)
  local hp = getElementHealth(p)
  if hp >= 100 then return false, "You are already at full health." end
  setElementHealth(p, math.min(100, hp + amount)); return true
end
local USE = {
  water = function(p) return heal(p, 5) end,
  cola = function(p) return heal(p, 5) end,
  bread = function(p) return heal(p, 8) end,
  burger = function(p) return heal(p, 12) end,
  bandage = function(p) return heal(p, 25) end,
  medkit = function(p) return heal(p, 60) end,
  repair = function(p)
    local veh = getPedOccupiedVehicle(p)
    if not veh then return false, "You must be inside a vehicle." end
    fixVehicle(veh); return true
  end,
}

---------------------------------------------------------------- client requests (identity is ALWAYS `client`)
local function guard(player, key, ms)
  return isElement(player) and G:isLoggedIn(player) and ready(player) and G:rateLimit(player, "inv:" .. key, ms)
end
local function slotOk(v) return G:toInt(v, 1, SLOTS) end

addEvent("lx:inv:request", true)
addEventHandler("lx:inv:request", resourceRoot, function()
  if guard(client, "request", 300) then sync(client, true) end
end)

addEvent("lx:inv:move", true)
addEventHandler("lx:inv:move", resourceRoot, function(from, to)
  if not guard(client, "move", 120) then return end
  from, to = slotOk(from), slotOk(to)
  local inv = ready(client)
  if not from or not to or from == to or not inv.slots[from] then return sync(client, false) end
  local a, b = inv.slots[from], inv.slots[to]
  if b and a.item == b.item then                                -- merge stacks
    local room = ITEMS[a.item].stack - b.count
    local put = math.min(room, a.count)
    if put > 0 then b.count = b.count + put; a.count = a.count - put; if a.count <= 0 then inv.slots[from] = nil end end
  else inv.slots[from], inv.slots[to] = b, a end              -- swap / move
  inv.dirty = true
  sync(client, false)
end)

addEvent("lx:inv:use", true)
addEventHandler("lx:inv:use", resourceRoot, function(slot)
  if not guard(client, "use", 400) then return end
  slot = slotOk(slot)
  local inv = ready(client); local s = slot and inv.slots[slot]
  if not s then return sync(client, false) end
  local def = ITEMS[s.item]
  if isPedDead(client) then return end
  if not def.use or not USE[def.use] then return N:notify(client, "warning", def.label, "This item cannot be used.") end
  local ok, why = USE[def.use](client)
  if not ok then return N:notify(client, "warning", def.label, why or "Cannot use it now.") end
  s.count = s.count - 1; if s.count <= 0 then inv.slots[slot] = nil end
  inv.dirty = true
  sync(client, false)
  N:notify(client, "success", def.label, "Used 1x " .. def.label, 2500)
end)

addEvent("lx:inv:drop", true)                                  -- v1: discards the items (world pickups come with a later resource)
addEventHandler("lx:inv:drop", resourceRoot, function(slot, count)
  if not guard(client, "drop", 400) then return end
  slot = slotOk(slot)
  local inv = ready(client); local s = slot and inv.slots[slot]
  count = G:toInt(count, 1, 100000)
  if not s or not count or count > s.count then return sync(client, false) end
  s.count = s.count - count; if s.count <= 0 then inv.slots[slot] = nil end
  inv.dirty = true
  G:log("inventory", ("discard %dx %s"):format(count, s.item), client)
  sync(client, false)
end)

addEvent("lx:inv:nearby", true)
addEventHandler("lx:inv:nearby", resourceRoot, function()
  if not guard(client, "nearby", 600) then return end
  local x, y, z = getElementPosition(client)
  local int, dim = getElementInterior(client), getElementDimension(client)
  local list, who = {}, {}
  for _, p in ipairs(getElementsByType("player")) do
    if p ~= client and G:isLoggedIn(p) and getElementInterior(p) == int and getElementDimension(p) == dim then
      local px, py, pz = getElementPosition(p)
      if getDistanceBetweenPoints3D(x, y, z, px, py, pz) <= 4 then
        list[#list + 1] = { name = (getPlayerName(p):gsub("#%x%x%x%x%x%x", "")) }; who[#who + 1] = p
      end
    end
  end
  triggerClientEvent(client, "lx:inv:nearbyList", resourceRoot, list, who)
end)

addEvent("lx:inv:give", true)
addEventHandler("lx:inv:give", resourceRoot, function(slot, count, target)
  if not guard(client, "give", 700) then return end
  slot = slotOk(slot)
  local inv = ready(client); local s = slot and inv.slots[slot]
  count = G:toInt(count, 1, 100000)
  if not s or not count or count > s.count then return sync(client, false) end
  if not isElement(target) or getElementType(target) ~= "player" or target == client or not G:isLoggedIn(target) then return end
  local tinv = ready(target)
  if not tinv then return end
  local x, y, z = getElementPosition(client); local tx, ty, tz = getElementPosition(target)
  if getElementInterior(client) ~= getElementInterior(target) or getElementDimension(client) ~= getElementDimension(target)
     or getDistanceBetweenPoints3D(x, y, z, tx, ty, tz) > 4.5 then
    return N:notify(client, "error", "Give", "That player is too far away.")
  end
  local item = s.item
  local ok, why = tryAdd(tinv, item, count)                    -- receiver first: if it does not fit, the sender loses nothing
  if not ok then return N:notify(client, "error", "Give", why == "weight" and "They cannot carry that much." or "Their inventory is full.") end
  tryRemove(inv, item, count)
  local label = ITEMS[item].label
  G:log("inventory", ("give %dx %s -> #%s"):format(count, item, tostring(G:getUserId(target))), client)
  sync(client, false); sync(target, false)
  N:notify(client, "success", "Give", ("You gave %dx %s"):format(count, label))
  N:notify(target, "info", "Received", ("%dx %s from %s"):format(count, label, (getPlayerName(client):gsub("#%x%x%x%x%x%x", ""))))
end)
