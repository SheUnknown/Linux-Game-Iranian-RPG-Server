-- [Lx]Bank (server). Wallet = cash + bank per user id. The server memory is the single source of truth while the player is online
-- (all changes are synchronous, so two actions can never race), and it is written to MySQL every 20 s, on quit and on stop.
local G = exports["[Lx]Global"]
local N = exports["[Lx]Notification"]
local CFG = BANK_CFG
local db
local W = {}                                                    -- [player] = { uid, cash, bank, dirty }

---------------------------------------------------------------- core
local function wallet(player) return W[player] end
local function showCash(player)
  local w = W[player]; if w then setPlayerMoney(player, math.min(w.cash, 2147483647), true) end   -- the HUD reads this
end

local function tx(w, kind, amount, info)
  if not db then return end
  dbExec(db, "INSERT INTO lx_bank_tx (user_id, ts, kind, amount, balance, info) VALUES (?,?,?,?,?,?)",
    w.uid, getRealTime().timestamp, kind, amount, w.bank, G:cleanText(info or "", 80))
end

local function save(w)
  if not db or not w.dirty then return end
  w.dirty = false
  dbExec(db, "INSERT INTO lx_wallet (user_id, cash, bank) VALUES (?,?,?) ON DUPLICATE KEY UPDATE cash = VALUES(cash), bank = VALUES(bank)", w.uid, w.cash, w.bank)
end

local function amountOf(v) return G:toInt(v, 1, CFG.maxBank) end

local function change(player, field, delta, reason)             -- delta may be negative; false if it would go below 0 or above the limit
  local w = wallet(player); if not w then return false, "not_ready" end
  local limit = field == "cash" and CFG.maxCash or CFG.maxBank
  local new = w[field] + delta
  if new < 0 then return false, "not_enough" end
  if new > limit then return false, "limit" end
  w[field] = new; w.dirty = true
  if field == "cash" then showCash(player) end
  if reason then G:log("money", ("%s %+d (%s) -> cash %d bank %d"):format(field, delta, reason, w.cash, w.bank), player) end
  return true
end

---------------------------------------------------------------- exports
function getCash(player) local w = wallet(player); return w and w.cash or 0 end
function getBank(player) local w = wallet(player); return w and w.bank or 0 end
function addCash(player, amount, reason)  amount = amountOf(amount); if not amount then return false, "bad_amount" end return change(player, "cash",  amount, reason or "addCash") end
function takeCash(player, amount, reason) amount = amountOf(amount); if not amount then return false, "bad_amount" end return change(player, "cash", -amount, reason or "takeCash") end
function addBank(player, amount, reason)  amount = amountOf(amount); if not amount then return false, "bad_amount" end local ok, why = change(player, "bank",  amount, reason or "addBank"); if ok then tx(W[player], "credit", amount, reason) end return ok, why end
function takeBank(player, amount, reason) amount = amountOf(amount); if not amount then return false, "bad_amount" end local ok, why = change(player, "bank", -amount, reason or "takeBank"); if ok then tx(W[player], "debit", amount, reason) end return ok, why end

---------------------------------------------------------------- load / save lifecycle
local function loadFor(player)
  local uid = G:getUserId(player)
  if not uid or W[player] ~= nil or not db then return end
  W[player] = false                                             -- loading marker (wallet() is falsy until the row is here)
  dbQuery(function(h)
    local rows = dbPoll(h, 0)
    if not isElement(player) then return end
    if not rows then W[player] = nil; N:notify(player, "error", "Bank", "Could not load your money. Reconnect or contact staff."); return end
    local w
    if rows[1] then w = { uid = uid, cash = tonumber(rows[1].cash) or 0, bank = tonumber(rows[1].bank) or 0, dirty = false }
    else
      w = { uid = uid, cash = CFG.startCash, bank = CFG.startBank, dirty = true }                  -- brand new account
      save(w)
    end
    W[player] = w
    showCash(player)
  end, db, "SELECT cash, bank FROM lx_wallet WHERE user_id = ?", uid)
end

addEventHandler("onResourceStart", resourceRoot, function()
  db = G:getDb()
  if not db then outputServerLog("[Lx]Bank: no database, resource idle"); return end
  dbExec(db, [[CREATE TABLE IF NOT EXISTS lx_wallet (
    user_id INT UNSIGNED NOT NULL PRIMARY KEY, cash BIGINT NOT NULL DEFAULT 0, bank BIGINT NOT NULL DEFAULT 0) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
  dbExec(db, [[CREATE TABLE IF NOT EXISTS lx_bank_tx (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, user_id INT UNSIGNED NOT NULL, ts INT UNSIGNED NOT NULL,
    kind VARCHAR(16) NOT NULL, amount BIGINT NOT NULL, balance BIGINT NOT NULL, info VARCHAR(80) NOT NULL DEFAULT '',
    KEY idx_user (user_id, id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
  for _, p in ipairs(getElementsByType("player")) do loadFor(p) end
  setTimer(function() for _, w in pairs(W) do if w and w.dirty then save(w) end end end, 20000, 0)
end)
addEventHandler("onResourceStop", resourceRoot, function() for _, w in pairs(W) do if w then save(w) end end end)
addEventHandler("onPlayerQuit", root, function() local w = W[source]; if w then save(w) end W[source] = nil end)
addEventHandler("onPlayerSpawn", root, function() showCash(source) end)
addEventHandler("onElementDataChange", root, function(key)
  if key == "lg.id" and getElementType(source) == "player" then loadFor(source) end      -- [Lx]Login just logged the player in
end)

---------------------------------------------------------------- ATM proximity (checked on the SERVER: a cheater cannot open the bank from anywhere)
local function nearATM(player)
  local x, y, z = getElementPosition(player)
  local int, dim = getElementInterior(player), getElementDimension(player)
  for _, a in ipairs(CFG.atms) do
    if a.int == int and a.dim == dim and getDistanceBetweenPoints3D(x, y, z, a.x, a.y, a.z) <= CFG.atmRange then return true end
  end
  return false
end
local function usable(player, key, ms)
  return isElement(player) and G:isLoggedIn(player) and not isPedDead(player) and wallet(player) and G:rateLimit(player, "bank:" .. key, ms) and nearATM(player)
end

addEvent("lx:bank:open", true)
addEventHandler("lx:bank:open", resourceRoot, function()
  if not usable(client, "open", 500) then return end
  local w = wallet(client)
  triggerClientEvent(client, "lx:bank:show", resourceRoot, w.cash, w.bank, CFG.feePercent, CFG.maxTransfer)
end)

local function result(player, ok, msg)
  local w = wallet(player)
  triggerClientEvent(player, "lx:bank:result", resourceRoot, ok and true or false, msg, w and w.cash or 0, w and w.bank or 0)
end

local function findOnline(name)
  name = G:cleanText(name, 32):lower()
  if name == "" then return nil end
  for _, p in ipairs(getElementsByType("player")) do
    if G:isLoggedIn(p) and getPlayerName(p):gsub("#%x%x%x%x%x%x", ""):lower() == name then return p end
  end
end

addEvent("lx:bank:action", true)
addEventHandler("lx:bank:action", resourceRoot, function(kind, amount, target)
  local p = client
  if not usable(p, "action", 700) then return end
  amount = G:toInt(amount, 1, CFG.maxBank)
  if not amount then return result(p, false, "Enter a valid amount.") end
  local w = wallet(p)

  if kind == "deposit" then
    if amount > w.cash then return result(p, false, "You do not have that much cash.") end
    if w.bank + amount > CFG.maxBank then return result(p, false, "Bank limit reached.") end
    change(p, "cash", -amount); change(p, "bank", amount)
    tx(w, "deposit", amount, "ATM deposit"); G:log("bank", "deposit " .. amount, p)
    return result(p, true, "Deposited $" .. G:formatNumber(amount))

  elseif kind == "withdraw" then
    if amount > w.bank then return result(p, false, "Not enough money in the bank.") end
    if w.cash + amount > CFG.maxCash then return result(p, false, "You cannot carry that much cash.") end
    change(p, "bank", -amount); change(p, "cash", amount)
    tx(w, "withdraw", amount, "ATM withdraw"); G:log("bank", "withdraw " .. amount, p)
    return result(p, true, "Withdrew $" .. G:formatNumber(amount))

  elseif kind == "transfer" then
    if amount > CFG.maxTransfer then return result(p, false, "Maximum per transfer is $" .. G:formatNumber(CFG.maxTransfer)) end
    local t = findOnline(target)
    if not t then return result(p, false, "Player not found (they must be online).") end
    if t == p then return result(p, false, "You cannot send money to yourself.") end
    local tw = wallet(t); if not tw then return result(p, false, "That player is not ready yet.") end
    local fee = math.floor(amount * CFG.feePercent / 100)
    if w.bank < amount + fee then return result(p, false, "Not enough in the bank (fee $" .. G:formatNumber(fee) .. ").") end
    if tw.bank + amount > CFG.maxBank then return result(p, false, "The receiver cannot hold more money.") end
    change(p, "bank", -(amount + fee)); change(t, "bank", amount)
    local pn, tn = getPlayerName(p):gsub("#%x%x%x%x%x%x", ""), getPlayerName(t):gsub("#%x%x%x%x%x%x", "")
    tx(w, "transfer", amount + fee, "To " .. tn); tx(tw, "received", amount, "From " .. pn)
    G:log("bank", ("transfer %d (fee %d) -> #%d"):format(amount, fee, tw.uid), p)
    N:notify(t, "money", "Bank", ("You received $%s from %s"):format(G:formatNumber(amount), pn))
    return result(p, true, ("Sent $%s to %s"):format(G:formatNumber(amount), tn))
  end
end)

addEvent("lx:bank:history", true)
addEventHandler("lx:bank:history", resourceRoot, function()
  local p = client
  if not usable(p, "history", 1500) then return end
  local w = wallet(p)
  dbQuery(function(h)
    local rows = dbPoll(h, 0) or {}
    if not isElement(p) then return end
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = { ts = tonumber(r.ts), kind = r.kind, amount = tonumber(r.amount), balance = tonumber(r.balance), info = r.info } end
    triggerClientEvent(p, "lx:bank:historyData", resourceRoot, out)
  end, db, "SELECT ts, kind, amount, balance, info FROM lx_bank_tx WHERE user_id = ? ORDER BY id DESC LIMIT 25", w.uid)
end)
