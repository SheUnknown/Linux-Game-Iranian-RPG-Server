-- [Lx]Global (server)

---------------------------------------------------------------- user lookup
function getPlayerByUserId(id)
  id = tonumber(id)
  if not id then return false end
  for _, p in ipairs(getElementsByType("player")) do
    if tonumber(getElementData(p, "lg.id")) == id then return p end
  end
  return false
end

---------------------------------------------------------------- rate limit
-- if not exports["[Lx]Global"]:rateLimit(client, "bank:withdraw", 800) then return end
-- true = allowed (and the timer restarts), false = too fast.
local limits = {}
function rateLimit(player, key, ms)
  if not isElement(player) or type(key) ~= "string" then return false end
  local t, p = getTickCount(), limits[player]
  if not p then p = {}; limits[player] = p end
  if p[key] and t - p[key] < (tonumber(ms) or 500) then return false end
  p[key] = t
  return true
end
addEventHandler("onPlayerQuit", root, function() limits[source] = nil end)

---------------------------------------------------------------- logging (SQLite, async, auto-trimmed)
-- exports["[Lx]Global"]:log("bank", "withdraw 5000", player)       -- player is optional
local db
local KEEP_DAYS = 30

local function openDb()
  db = dbConnect("sqlite", "lx_logs.db")
  if not db then outputServerLog("[Lx]Global: cannot open lx_logs.db, logs go to server.log only"); return end
  dbExec(db, "CREATE TABLE IF NOT EXISTS lx_logs (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, cat TEXT NOT NULL, user_id INTEGER, serial TEXT, msg TEXT NOT NULL)")
  dbExec(db, "CREATE INDEX IF NOT EXISTS lx_logs_cat_ts ON lx_logs (cat, ts)")
end

function log(category, message, player)
  category = cleanText(category, 32); message = cleanText(tostring(message or ""), 500)
  if category == "" or message == "" then return false end
  local uid, serial
  if isElement(player) and getElementType(player) == "player" then
    uid, serial = getUserId(player) or nil, getPlayerSerial(player)
  end
  if db then
    dbExec(db, "INSERT INTO lx_logs (ts, cat, user_id, serial, msg) VALUES (?,?,?,?,?)", getRealTime().timestamp, category, uid, serial, message)
  else
    outputServerLog(("[Lx:%s] %s%s"):format(category, uid and ("#" .. uid .. " ") or "", message))
  end
  return true
end

addEventHandler("onResourceStart", resourceRoot, function()
  openDb()
  setTimer(function()                                       -- trim once an hour
    if db then dbExec(db, "DELETE FROM lx_logs WHERE ts < ?", getRealTime().timestamp - KEEP_DAYS * 86400) end
  end, 3600000, 0)
end)


---------------------------------------------------------------- shared MySQL connection (linux_game)
-- Every [Lx] resource uses THIS connection:  local db = exports["[Lx]Global"]:getDb()
-- Set these values locally before starting the resource. Do not commit real credentials.
local DBCFG = { host = "YOUR_DB_HOST", port = 3306, database = "YOUR_DATABASE", user = "YOUR_DB_USER", password = "YOUR_DB_PASSWORD" }
local mysql

function getDb()
  if mysql and isElement(mysql) then return mysql end
  mysql = dbConnect("mysql",
    ("dbname=%s;host=%s;port=%d;charset=utf8mb4"):format(DBCFG.database, DBCFG.host, DBCFG.port),
    DBCFG.user, DBCFG.password, "share=1")
  if not mysql then outputServerLog("[Lx]Global: MySQL connection FAILED (check DBCFG in [Lx]Global/server.lua)") end
  return mysql or false
end
addEventHandler("onResourceStart", resourceRoot, function() getDb() end)
