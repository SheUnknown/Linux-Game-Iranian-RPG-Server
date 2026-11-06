-- [Lx]Admin (server). Ranks: 1 Moderator, 2 Admin, 3 Head Admin, 4 Owner.
-- First owner: type in the SERVER CONSOLE:   lxsetrank <username> 4
-- Every action is checked on the server: login, rank, hierarchy, rate limit, and it is logged to lx_logs (category "admin").
local G = exports["[Lx]Global"]
local N = exports["[Lx]Notification"]
local db
local STAFF, MUTE = {}, {}                              -- [player] = rank | [userId] = unix time the mute ends
local BAN_SERIAL, BAN_UID = {}, {}                      -- caches of ACTIVE bans: { id, expires (0 = permanent), reason }
local RANK_NAME = { [1] = "Moderator", [2] = "Admin", [3] = "Head Admin", [4] = "Owner" }
local NEED = { kick = 1, mute = 1, unmute = 1, freeze = 1, ["goto"] = 1, bring = 1, heal = 1, ban = 2, announce = 2, unban = 3 }

local function now() return getRealTime().timestamp end
local function clean(p) return (getPlayerName(p):gsub("#%x%x%x%x%x%x", "")) end
local function rankOf(p) return STAFF[p] or 0 end
local function say(text, r, g, b) outputChatBox(text, root, r or 255, g or 255, b or 255, true) end

local function acIgnore(p, ms)                           -- tell the anti-cheat that a server-side teleport is coming
  local res = getResourceFromName("[Lx]Anti-Cheat")
  if res and getResourceState(res) == "running" then exports["[Lx]Anti-Cheat"]:ignore(p, ms) end
end

---------------------------------------------------------------- exports
function getRank(p) return rankOf(p) end
function isStaff(p, min) return rankOf(p) >= (tonumber(min) or 1) end
function notifyStaff(text, min)
  min = tonumber(min) or 1
  for p, r in pairs(STAFF) do if r >= min and isElement(p) then outputChatBox("#ff4a5e[STAFF] #ffffff" .. tostring(text), p, 255, 255, 255, true) end end
end

---------------------------------------------------------------- bans
local function banText(e)
  if e.expires == 0 then return e.reason .. " (permanent)" end
  local t = getRealTime(e.expires)
  return ("%s (until %04d-%02d-%02d %02d:%02d server time)"):format(e.reason, t.year + 1900, t.month + 1, t.monthday, t.hour, t.minute)
end

local function loadBans()                               -- builds NEW tables and swaps them, so there is never an empty window
  dbQuery(function(h)
    local rows = dbPoll(h, 0); if not rows then return end
    local s, u = {}, {}
    for _, r in ipairs(rows) do
      local e = { id = tonumber(r.id), expires = tonumber(r.expires) or 0, reason = r.reason }
      if r.serial and r.serial ~= "" then s[r.serial] = e end
      if r.user_id then u[tonumber(r.user_id)] = e end
    end
    BAN_SERIAL, BAN_UID = s, u
  end, db, "SELECT id, user_id, serial, reason, expires FROM lx_bans WHERE active = 1 AND (expires = 0 OR expires > ?)", now())
end

local function live(e)                                  -- nil when the ban has run out
  if not e then return nil end
  if e.expires ~= 0 and e.expires <= now() then dbExec(db, "UPDATE lx_bans SET active = 0 WHERE id = ?", e.id); return nil end
  return e
end

addEventHandler("onPlayerConnect", root, function(nick, ip, username, serial)
  local e = live(BAN_SERIAL[serial])
  if e then cancelEvent(true, "Banned: " .. banText(e)) end
end)

local function kickBanned(p)
  local uid = G:getUserId(p)
  local e = uid and live(BAN_UID[uid]) or live(BAN_SERIAL[getPlayerSerial(p)])
  if e then kickPlayer(p, "Anti-Ban", "Banned: " .. banText(e)); return true end
end

---------------------------------------------------------------- lifecycle
addEventHandler("onResourceStart", resourceRoot, function()
  db = G:getDb()
  if not db then outputServerLog("[Lx]Admin: no database, resource idle"); return end
  dbExec(db, [[CREATE TABLE IF NOT EXISTS lx_staff (user_id INT UNSIGNED NOT NULL PRIMARY KEY, level TINYINT UNSIGNED NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
  dbExec(db, [[CREATE TABLE IF NOT EXISTS lx_bans (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, user_id INT UNSIGNED NULL, serial CHAR(32) NOT NULL DEFAULT '', ip VARCHAR(45) NOT NULL DEFAULT '',
    reason VARCHAR(120) NOT NULL, by_name VARCHAR(32) NOT NULL, ts INT UNSIGNED NOT NULL, expires INT UNSIGNED NOT NULL DEFAULT 0, active TINYINT NOT NULL DEFAULT 1,
    KEY idx_active (active, serial), KEY idx_user (user_id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
  loadBans()
  for _, p in ipairs(getElementsByType("player")) do
    local uid = G:getUserId(p)
    if uid then dbQuery(function(h) local r = dbPoll(h, 0); if r and r[1] and isElement(p) then STAFF[p] = tonumber(r[1].level); setElementData(p, "lx.rank", STAFF[p], true) end end, db, "SELECT level FROM lx_staff WHERE user_id = ?", uid) end
  end
end)
addEventHandler("onPlayerQuit", root, function() STAFF[source] = nil end)

addEventHandler("onElementDataChange", root, function(key)
  if key ~= "lg.id" or getElementType(source) ~= "player" or not db then return end
  local p = source
  if kickBanned(p) then return end
  dbQuery(function(h)
    local r = dbPoll(h, 0)
    if r and r[1] and isElement(p) and (tonumber(r[1].level) or 0) > 0 then
      STAFF[p] = tonumber(r[1].level); setElementData(p, "lx.rank", STAFF[p], true)
      N:notify(p, "info", "Staff", "Logged in as " .. RANK_NAME[STAFF[p]] .. ". Press F9.")
    end
  end, db, "SELECT level FROM lx_staff WHERE user_id = ?", G:getUserId(p))
end)

addEventHandler("onPlayerChat", root, function(msg)
  local uid = G:getUserId(source)
  if uid and MUTE[uid] then
    if MUTE[uid] > now() then cancelEvent(); N:notify(source, "warning", "Muted", "You are muted for " .. math.ceil((MUTE[uid] - now()) / 60) .. " more minute(s).", 3000)
    else MUTE[uid] = nil end
  end
end)

---------------------------------------------------------------- console / owner command: set a rank (works for offline players too)
addCommandHandler("lxsetrank", function(player, _, name, level)
  local console = not isElement(player) or getElementType(player) == "console"
  if not console and rankOf(player) < 4 then return end
  local function reply(t) if console then outputServerLog("[Lx]Admin: " .. t) else outputChatBox(t, player) end end
  level = G:toInt(level, 0, 4)
  if type(name) ~= "string" or not level then return reply("usage: lxsetrank <username> <0-4>   (0 removes staff)") end
  dbQuery(function(h)
    local r = dbPoll(h, 0)
    if not r or not r[1] then return reply("no account named " .. tostring(name)) end
    local uid = tonumber(r[1].id)
    if level == 0 then dbExec(db, "DELETE FROM lx_staff WHERE user_id = ?", uid)
    else dbExec(db, "INSERT INTO lx_staff (user_id, level) VALUES (?,?) ON DUPLICATE KEY UPDATE level = VALUES(level)", uid, level) end
    local p = G:getPlayerByUserId(uid)
    if p then STAFF[p] = level > 0 and level or nil; setElementData(p, "lx.rank", level > 0 and level or false, true) end
    G:log("admin", ("setrank uid %d -> %d"):format(uid, level), isElement(player) and player or nil)
    reply(("%s is now %s"):format(name, level > 0 and RANK_NAME[level] or "a normal player"))
  end, db, "SELECT id FROM lg_accounts WHERE username = ?", G:cleanText(name, 32))
end)

---------------------------------------------------------------- panel data
local function sendList(p, show)
  local list, who = {}, {}
  for _, t in ipairs(getElementsByType("player")) do
    if G:isLoggedIn(t) then
      local uid = G:getUserId(t)
      list[#list + 1] = { id = uid, name = clean(t), ping = getPlayerPing(t), hp = math.floor(getElementHealth(t)), rank = rankOf(t), muted = (MUTE[uid] and MUTE[uid] > now()) and true or false }
      who[#who + 1] = t
    end
  end
  triggerClientEvent(p, "lx:admin:list", resourceRoot, list, who, rankOf(p), show and true or false)
end

addEvent("lx:admin:open", true)
addEventHandler("lx:admin:open", resourceRoot, function(show)
  if G:isLoggedIn(client) and rankOf(client) >= 1 and G:rateLimit(client, "admin:open", 800) then sendList(client, show) end
end)

addEvent("lx:admin:bans", true)
addEventHandler("lx:admin:bans", resourceRoot, function()
  local p = client
  if rankOf(p) < 1 or not G:rateLimit(p, "admin:bans", 1500) then return end
  dbQuery(function(h)
    local rows = dbPoll(h, 0) or {}
    if not isElement(p) then return end
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = { id = tonumber(r.id), user = tonumber(r.user_id), reason = r.reason, by = r.by_name, ts = tonumber(r.ts), expires = tonumber(r.expires) } end
    triggerClientEvent(p, "lx:admin:bansData", resourceRoot, out)
  end, db, "SELECT id, user_id, reason, by_name, ts, expires FROM lx_bans WHERE active = 1 AND (expires = 0 OR expires > ?) ORDER BY id DESC LIMIT 40", now())
end)

addEvent("lx:admin:unban", true)
addEventHandler("lx:admin:unban", resourceRoot, function(id)
  local p = client
  id = G:toInt(id, 1, 2147483647)
  if not id or rankOf(p) < NEED.unban or not G:rateLimit(p, "admin:unban", 800) then return end
  dbExec(db, "UPDATE lg_accounts a JOIN lx_bans b ON b.user_id = a.id SET a.banned = 0 WHERE b.id = ?", id)
  dbExec(db, "UPDATE lx_bans SET active = 0 WHERE id = ?", id)
  loadBans()
  G:log("admin", "unban #" .. id, p)
  N:notify(p, "success", "Admin", "Ban #" .. id .. " removed.")
end)

---------------------------------------------------------------- actions
local function deny(p, text) N:notify(p, "error", "Admin", text, 3000) end

addEvent("lx:admin:do", true)
addEventHandler("lx:admin:do", resourceRoot, function(action, target, expectUid, a, b)
  local p = client
  if not G:isLoggedIn(p) or not G:rateLimit(p, "admin:do", 400) then return end
  local rank, need = rankOf(p), NEED[action]
  if not need or rank < need then return end
  local an = clean(p)

  if action == "announce" then
    local text = G:cleanText(a, 120); if text == "" then return end
    say("#ff4a5e[ANNOUNCEMENT] #ffffff" .. text)
    N:notify(root, "info", "Announcement", text, 9000)
    return G:log("admin", "announce: " .. text, p)
  end

  if not isElement(target) or getElementType(target) ~= "player" or not G:isLoggedIn(target) then return deny(p, "Player not found.") end
  if G:getUserId(target) ~= tonumber(expectUid) then return deny(p, "The player list changed. Try again.") end
  if target == p and action ~= "heal" then return deny(p, "You cannot do that to yourself.") end
  if target ~= p and rankOf(target) >= rank then return deny(p, "You cannot act on someone of equal or higher rank.") end
  local tn, uid = clean(target), G:getUserId(target)
  local reason = G:cleanText(a, 80); if reason == "" then reason = "No reason given" end

  if action == "kick" then
    say(("#ff4a5e[ADMIN] #ffffff%s was kicked by %s: %s"):format(tn, an, reason))
    G:log("admin", ("kick #%d: %s"):format(uid, reason), p)
    kickPlayer(target, p, reason)

  elseif action == "ban" then
    local minutes = G:toInt(b, 0, 525600)
    if not minutes then return deny(p, "Bad duration.") end
    if minutes == 0 and rank < 3 then return deny(p, "Only Head Admins can ban permanently.") end
    local expires = minutes > 0 and now() + minutes * 60 or 0
    dbExec(db, "INSERT INTO lx_bans (user_id, serial, ip, reason, by_name, ts, expires, active) VALUES (?,?,?,?,?,?,?,1)", uid, getPlayerSerial(target), getPlayerIP(target), reason, an, now(), expires)
    if minutes == 0 then dbExec(db, "UPDATE lg_accounts SET banned = 1 WHERE id = ?", uid) end
    loadBans()
    say(("#ff4a5e[ADMIN] #ffffff%s was banned by %s (%s): %s"):format(tn, an, minutes == 0 and "permanent" or (minutes .. " min"), reason))
    G:log("admin", ("ban #%d %s: %s"):format(uid, minutes == 0 and "perm" or (minutes .. "min"), reason), p)
    kickPlayer(target, p, "Banned: " .. reason)

  elseif action == "mute" then
    local minutes = G:toInt(b, 1, 1440); if not minutes then return deny(p, "Mute 1-1440 minutes.") end
    MUTE[uid] = now() + minutes * 60
    N:notify(target, "warning", "Muted", ("%s muted you for %d min: %s"):format(an, minutes, reason), 6000)
    N:notify(p, "success", "Admin", tn .. " muted for " .. minutes .. " min.")
    G:log("admin", ("mute #%d %dmin: %s"):format(uid, minutes, reason), p)

  elseif action == "unmute" then
    MUTE[uid] = nil; N:notify(target, "success", "Muted", "You can chat again."); N:notify(p, "success", "Admin", tn .. " unmuted.")
    G:log("admin", "unmute #" .. uid, p)

  elseif action == "freeze" then
    local veh = getPedOccupiedVehicle(target)
    local frozen = not isElementFrozen(veh or target)
    setElementFrozen(veh or target, frozen); if veh then setElementFrozen(target, frozen) end
    N:notify(target, "warning", "Admin", frozen and "You were frozen by staff." or "You were unfrozen.")
    N:notify(p, "success", "Admin", tn .. (frozen and " frozen." or " unfrozen."))
    G:log("admin", (frozen and "freeze #" or "unfreeze #") .. uid, p)

  elseif action == "goto" or action == "bring" then
    local mover, dest = p, target
    if action == "bring" then mover, dest = target, p end
    local x, y, z = getElementPosition(dest)
    acIgnore(mover, 6000)
    setElementInterior(mover, getElementInterior(dest)); setElementDimension(mover, getElementDimension(dest))
    setElementPosition(mover, x + 1.2, y, z + 0.3)
    G:log("admin", action .. " #" .. uid, p)

  elseif action == "heal" then
    setElementHealth(target, 100)
    N:notify(target, "success", "Admin", "You were healed by staff.")
    G:log("admin", "heal #" .. uid, p)
  end
end)

---------------------------------------------------------------- staff chat
addCommandHandler("a", function(p, _, ...)
  if rankOf(p) < 1 then return end
  local text = G:cleanText(table.concat({ ... }, " "), 200); if text == "" then return end
  notifyStaff(("%s (%s): %s"):format(clean(p), RANK_NAME[rankOf(p)], text), 1)
end)
