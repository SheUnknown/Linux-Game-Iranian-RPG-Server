local CFG = {
  -- MySQL (XAMPP defaults: host 127.0.0.1, port 3306, user root, empty password)
  mysql = { host = "127.0.0.1", port = 3306, database = "linux_game", user = "root", password = "" },

  -- Telegram bot (Cloudflare Worker, see linux_bot/README.txt)
  telegram = {
    -- Worker URL(s), tried in order. Add a 2nd/3rd URL as a fallback (see linux_bot/README.txt, "403 from Iran").
    api = {
      "https://linux-game-bot.hexsartan.workers.dev/",
      -- "https://your-second-address.example.com",
    },
    key = "N7vK2mR9xP4qT8bL5wH1cF6zD3aJ0eG",                           -- same value as the worker secret API_KEY
    bot = "LinuxGameOfficialBot",                                     -- bot username without @
  },
  linkTtl = 900,                        -- seconds the player has to finish the Telegram verification

  minUser = 3, maxUser = 20,            -- username length (letters, numbers, _)
  minPass = 6, maxPass = 30,
  maxAttempts = 5,                      -- wrong passwords before lock (per serial)
  lockSeconds = 30,
  loginTimeout = 600,                   -- seconds an unauthenticated player may sit on the login screen before being kicked
  bcryptCost = 10,
  mtaAccounts = true,                   -- also log the player into a normal MTA account with the same name
  setNick = true,                       -- nickname = username after login (nick changes are blocked for everyone)
  tempNick = "Connecting...",           -- name every player gets while he is on the login screen

  codeTtl = 600, codeMaxTries = 5, codeCooldown = 60,   -- recovery codes (sent through Telegram)

  multi = {                             -- multi-account detection
    strictSerialHistory = true,         -- a PC that already hosted ANY account in the last N days cannot register a new one
    historyDays = 30,
    ipWindowDays = 30,                  -- look-back for accounts that shared an IP
    staffAlertWeight = 50,              -- flags with weight >= this are shown to online staff
  },

  profile = {                           -- profile wizard shown right after registration
    minAge = 13,                        -- youngest allowed player
    ttl = 1800,                         -- seconds to finish the wizard right after registering (otherwise it is shown at the next login)
    sources = { discord = true, telegram = true, instagram = true, youtube = true, tiktok = true, google = true, friend = true, other = true },
  },

  adminGroup = "Admin",                 -- ACL group: staff commands + login during maintenance
  maintenance = false,

  spawn = { x = 1481.0, y = -1750.0, z = 15.5, rot = 0, skin = 0, interior = 0, dimension = 0 },

  announcements = {                     -- max 3 shown on the login screen
    { title = "WELCOME", text = "Welcome to LINUX Game. Read the rules on Discord.", date = "2026" },
  },
}

addEvent("lg:server:auth", true)
addEvent("lg:server:ready", true)
addEvent("lg:onReferral")               -- addEventHandler("lg:onReferral", root, function(userId, referrerId) end)  -> give rewards here
addEvent("lg:onLogin")                  -- other resources: addEventHandler("lg:onLogin", root, function(userId, username) end)

local db
local authed, busy, lastAct, fails, codes, mailCd, pendingReg, profilePending = {}, {}, {}, {}, {}, {}, {}, {}
local maintenance = CFG.maintenance
local readyCd, joinedAt = {}, {}
local rcodes, resetCd = {}, {}                 -- password-reset codes (by account id) / resend cooldown (by serial)
local actions = {}

--------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------
local function now() return getRealTime().timestamp end
local function str(v) return type(v) == "string" and v or "" end

-- nickname control: only this script may change a player's name
local nickOK = false
local function forceName(player, name)
  nickOK = true
  local ok = setPlayerName(player, name)
  nickOK = false
  return ok
end
local function setTempName(player)
  if not isElement(player) then return end
  if forceName(player, CFG.tempNick) then return end
  for i = 2, 99 do                              -- name already used by another player: Connecting...2, Connecting...3 ...
    if forceName(player, CFG.tempNick .. i) then return end
  end
end

local function ui(player, fn, ...)
  if isElement(player) then triggerClientEvent(player, "lg:client:ui", resourceRoot, fn, { ... }) end
end
local function notify(player, kind, title, text) ui(player, "notify", kind, title, text) end
local function reject(player, title, text) notify(player, "err", title, text); ui(player, "unlock") end

local function validUser(u) return #u >= CFG.minUser and #u <= CFG.maxUser and u:match("^[%w_]+$") ~= nil end
local function validPass(p) return #p >= CFG.minPass and #p <= CFG.maxPass end
local function validCode(c) return c:match("^%d%d%d%d%d%d$") ~= nil end

-- Same rules as normPhone() in worker.js: digits only, Iranian local formats -> 98xxxxxxxxxx
local function normPhone(raw)
  local d = raw:gsub("%D", "")
  if d:sub(1, 2) == "00" then d = d:sub(3) end
  if #d == 11 and d:sub(1, 2) == "09" then d = "98" .. d:sub(2)
  elseif #d == 10 and d:sub(1, 1) == "9" then d = "98" .. d end
  if #d < 10 or #d > 15 then return nil end
  return d
end

local function query(sql, ...)
  if not db then return nil end
  local h = dbQuery(db, sql, ...)
  if not h then return nil end
  local r = dbPoll(h, -1)
  return r or nil
end
local function getUser(name)
  local r = query("SELECT * FROM lg_accounts WHERE username = ? LIMIT 1", name)
  return r and r[1] or nil
end
local function getBySerial(serial)
  local r = query("SELECT * FROM lg_accounts WHERE serial = ? LIMIT 1", serial)
  return r and r[1] or nil
end
local function nameOf(id)
  local r = query("SELECT username FROM lg_accounts WHERE id = ? LIMIT 1", id)
  return r and r[1] and r[1].username or ("#" .. tostring(id))
end

local function isStaff(accName)
  local g = aclGetGroup(CFG.adminGroup)
  return g and isObjectInACLGroup("user." .. accName, g) or false
end

local function hashPass(pass, cb)
  if not passwordHash(pass, "bcrypt", { cost = CFG.bcryptCost }, cb) then cb(false) end
end
local function verifyPass(pass, hashStr, cb)
  if not passwordVerify(pass, hashStr, {}, cb) then cb(false) end
end

local function ensureMtaAccount(name, pass)       -- returns account / true / false
  if not CFG.mtaAccounts then return true end
  local acc = getAccount(name)
  if not acc then acc = addAccount(name, pass) end
  if not acc then return false end
  if not getAccount(name, pass) then setAccountPassword(acc, pass) end
  return acc
end

--------------------------------------------------------------------------
-- Telegram bot API (Cloudflare Worker)
--------------------------------------------------------------------------
local function baseList()                      -- usable worker URLs (placeholders are skipped)
  local a, list = CFG.telegram.api, {}
  for _, u in ipairs(type(a) == "table" and a or { a }) do
    if type(u) == "string" and u ~= "" and not u:find("YOUR%-SUBDOMAIN") then list[#list + 1] = (u:gsub("/+$", "")) end
  end
  return list
end
local function telegramReady()
  local t = CFG.telegram
  return #baseList() > 0 and not t.key:find("PUT_THE") and not t.bot:find("YourBotUsername")
end

-- Cloudflare blocks requests that do not look like a browser (403 / error 1010), so we always send browser-like headers.
local function requestHeaders(withKey, isPost)
  local h = {
    ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    ["Accept"] = "application/json, text/plain, */*",
    ["Accept-Language"] = "en-US,en;q=0.9",
    ["Cache-Control"] = "no-cache",
  }
  if withKey then h["X-API-Key"] = CFG.telegram.key end
  if isPost then h["Content-Type"] = "application/x-www-form-urlencoded" end
  return h
end
local function status(info) return type(info) == "table" and info.statusCode or info end
local function snippet(resp) return (tostring(resp or ""):gsub("%s+", " "):sub(1, 90)) end

local function urlEncode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function formEncode(t)
  local parts = {}
  for k, v in pairs(t or {}) do parts[#parts + 1] = urlEncode(k) .. "=" .. urlEncode(v) end
  return table.concat(parts, "&")
end
local function parseFlat(body)                    -- the worker answers with flat JSON ({"ok":true,"status":"pending",...})
  local t = {}
  if type(body) ~= "string" then return t end
  for k, v in body:gmatch('"([%w_]+)"%s*:%s*([^,}]+)') do
    v = v:gsub('^%s*"(.*)"%s*$', "%1")
    if v == "true" then v = true elseif v == "false" then v = false end
    t[k] = v
  end
  return t
end

local baseIdx = 1                              -- last base URL that worked (sticky)

-- cb(ok, data)   ok = the worker answered {"ok":true,...}. Falls back to the next URL when one is blocked / unreachable.
local function apiCall(method, path, params, cb, tried)
  tried = tried or 0
  local list = baseList()
  if #list == 0 then return cb(false, { error = "not_configured" }) end
  local idx = ((baseIdx - 1 + tried) % #list) + 1
  local url, body = list[idx] .. path, formEncode(params)
  local opts = { method = method, headers = requestHeaders(true, method == "POST"), connectionAttempts = 2 }
  if method == "POST" then opts.postData = body elseif body ~= "" then url = url .. "?" .. body end

  local function failed(reason)
    outputServerLog(("[linux_auth] %s %s via %s failed: %s"):format(method, path, list[idx], reason))
    if tried + 1 < #list then return apiCall(method, path, params, cb, tried + 1) end
    cb(false, { error = "unreachable" })
  end
  local queued = fetchRemote(url, opts, function(resp, info)
    local t = parseFlat(resp)
    if t.ok ~= nil then                          -- the worker itself answered: its answer is final
      baseIdx = idx
      if t.ok == false then
        local hints = {
          unauthorized = "CFG.telegram.key does not match the worker secret API_KEY (wrangler secret put API_KEY, then wrangler deploy)",
          server = "the worker crashed: run 'wrangler tail'; was schema.sql executed with --remote and is database_id in wrangler.toml correct?",
          bad_params = "the worker rejected the parameters",
        }
        outputServerLog(("[linux_auth] %s %s -> worker error '%s' %s | %s"):format(method, path, tostring(t.error), tostring(t.detail or ""), hints[t.error] or ""))
      end
      return cb(t.ok == true, t)
    end
    failed("HTTP " .. tostring(status(info)) .. " " .. snippet(resp) .. "  (run /lgtest in the server console)")
  end)
  if not queued then failed("request could not be queued") end
end

--------------------------------------------------------------------------
-- multi-account detection
--------------------------------------------------------------------------
local function alertStaff(text)
  for p, a in pairs(authed) do
    if isStaff(a.username) then outputChatBox("#ffaa00[Multi-Account] #ffffff" .. text, p, 255, 255, 255, true) end
  end
end

-- kinds: MULTI_REGISTER, PHONE_REUSE, SHARED_DEVICE, SERIAL_SHARED, IP_ONLINE, IP_SHARED
local function addFlag(kind, weight, userId, otherId, serial, ip, info)
  if not db then return end
  local dup = query("SELECT id FROM lg_flags WHERE kind = ? AND serial = ? AND user_id = ? AND other_id = ? AND ts > ? LIMIT 1",
    kind, serial, userId, otherId, now() - 21600)
  if dup and dup[1] then return end
  dbExec(db, "INSERT INTO lg_flags (user_id, other_id, kind, weight, serial, ip, info, ts) VALUES (?,?,?,?,?,?,?,?)",
    userId, otherId, kind, weight, serial, ip, info:sub(1, 250), now())
  if weight >= CFG.multi.staffAlertWeight then alertStaff(kind .. " (" .. weight .. "): " .. info) end
end

local function recordLogin(player, row)
  local serial, ip = getPlayerSerial(player), getPlayerIP(player) or ""
  dbExec(db, "INSERT INTO lg_logins (user_id, serial, ip, ts) VALUES (?,?,?,?)", row.id, serial, ip, now())

  for p2, a2 in pairs(authed) do                                  -- same IP, another account online right now
    if p2 ~= player and a2.id ~= row.id and getPlayerIP(p2) == ip then
      addFlag("IP_ONLINE", 40, row.id, a2.id, serial, ip, row.username .. " and " .. a2.username .. " are online from the same IP")
    end
  end
  local since = now() - CFG.multi.ipWindowDays * 86400
  local byIp = query("SELECT DISTINCT l.user_id AS uid, a.username AS name FROM lg_logins l JOIN lg_accounts a ON a.id = l.user_id " ..
    "WHERE l.ip = ? AND l.user_id <> ? AND l.ts > ? LIMIT 5", ip, row.id, since)
  for _, r in ipairs(byIp or {}) do
    addFlag("IP_SHARED", 20, row.id, r.uid, serial, ip, row.username .. " shares an IP with " .. r.name)
  end
  local bySerial = query("SELECT DISTINCT l.user_id AS uid, a.username AS name FROM lg_logins l JOIN lg_accounts a ON a.id = l.user_id " ..
    "WHERE l.serial = ? AND l.user_id <> ? LIMIT 5", serial, row.id)
  for _, r in ipairs(bySerial or {}) do
    addFlag("SERIAL_SHARED", 100, row.id, r.uid, serial, ip, row.username .. " used the same PC as " .. r.name)
  end
end

--------------------------------------------------------------------------
-- brute-force protection (per serial)
--------------------------------------------------------------------------
local function lockLeft(serial)
  local f = fails[serial]
  if not f then return 0 end
  local left = math.ceil((f.lockUntil - getTickCount()) / 1000)
  return left > 0 and left or 0
end
local function badCreds(player, serial, isLogin)
  local f = fails[serial] or { count = 0, lockUntil = 0 }; fails[serial] = f
  f.count = f.count + 1
  if f.count >= CFG.maxAttempts then
    f.count = 0; f.lockUntil = getTickCount() + CFG.lockSeconds * 1000
    ui(player, "lock", CFG.lockSeconds)
    notify(player, "err", "Too many attempts", "Try again in " .. CFG.lockSeconds .. " seconds.")
    ui(player, "unlock")
  elseif isLogin then
    ui(player, "loginFailed", CFG.maxAttempts - f.count)
  else
    reject(player, "Wrong credentials", (CFG.maxAttempts - f.count) .. " attempt(s) left.")
  end
end
local function isLockedNow(player, serial, isLogin)
  local left = lockLeft(serial)
  if left <= 0 then return false end
  if isLogin then ui(player, "lock", left) else reject(player, "Locked", "Try again in " .. left .. " seconds.") end
  return true
end

--------------------------------------------------------------------------
-- profile wizard (real name, birth date, gender, height, weight, referral code, how they found us)
--------------------------------------------------------------------------
local REF_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

local function profileOpts()
  local t = getRealTime()
  return { minAge = CFG.profile.minAge, today = string.format("%04d-%02d-%02d", t.year + 1900, t.month + 1, t.monthday) }
end

local function completeLogin(player)
  local a = authed[player]
  if not a or a.completed then return end
  a.completed = true
  ui(player, "loginSuccess", a.username)
  triggerEvent("lg:onLogin", player, a.id, a.username)
end

local function cleanText(s)                      -- trim + collapse spaces, drop control characters
  s = s:gsub("%c", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  return s
end
local function parseBirth(s)                     -- "YYYY-MM-DD" -> y, m, d (real calendar date) or nil
  local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 then days[2] = 29 end
  if m < 1 or m > 12 or d < 1 or d > days[m] then return nil end
  return y, m, d
end
local function ageOf(y, m, d)
  local t = getRealTime()
  local age = (t.year + 1900) - y
  if (t.month + 1) < m or ((t.month + 1) == m and t.monthday < d) then age = age - 1 end
  return age
end
local function validRefFormat(c) return #c == 6 and c:match("^[" .. REF_CHARS .. "]+$") ~= nil end
local function newRefCode()
  for _ = 1, 20 do
    local c = {}
    for i = 1, 6 do local k = math.random(1, #REF_CHARS); c[i] = REF_CHARS:sub(k, k) end
    local code = table.concat(c)
    local r = query("SELECT id FROM lg_accounts WHERE ref_code = ? LIMIT 1", code)
    if r and not r[1] then return code end
  end
end
local function profileTarget(player)             -- who may fill the profile: just registered, or logged in without one
  local a, ctx = authed[player], profilePending[player]
  if a and a.needProfile then return a.id, a.username end
  if not a and ctx and ctx.expires > now() then return ctx.id, ctx.username end
end

--------------------------------------------------------------------------
-- registration: pending until the Telegram verification is finished
--------------------------------------------------------------------------
local function stopPending(player, release)
  local p = pendingReg[player]
  if not p then return end
  if isTimer(p.timer) then killTimer(p.timer) end
  pendingReg[player] = nil
  if release then apiCall("POST", "/api/link/release", { token = p.token }, function() end) end
end

local function makeToken(serial)
  return hash("sha256", table.concat({ serial, tostring(getTickCount()), tostring(math.random()), tostring(math.random()), tostring(now()) }, "|")):lower():sub(1, 24)
end

local function finalizeRegistration(player, p, t)
  p.finishing = true
  if tostring(t.phone) ~= p.phone then
    stopPending(player, true); ui(player, "verifyClose")
    return reject(player, "Phone mismatch", "The verified number does not match the one you entered.")
  end
  apiCall("POST", "/api/link/consume", { token = p.token }, function(ok, r)
    if pendingReg[player] ~= p then return end
    stopPending(player, false)
    if not isElement(player) then return end
    if not ok then
      ui(player, "verifyClose")
      local msg = r.error == "tg_taken" and "This Telegram account is already linked to another game account."
        or r.error == "phone_taken" and "This phone number is already registered."
        or "Could not complete the verification. Try again."
      return reject(player, "Verification failed", msg)
    end
    local inserted = dbExec(db,
      "INSERT INTO lg_accounts (username, phone, tg_id, tg_chat_id, password, serial, reg_ip, last_ip, created, banned) VALUES (?,?,?,?,?,?,?,?,?,0)",
      p.username, p.phone, tostring(t.tg_id), tostring(t.chat_id), p.hash, p.serial, p.ip, p.ip, now())
    if not inserted then
      apiCall("POST", "/api/link/release", { token = p.token }, function() end)
      ui(player, "verifyClose")
      return reject(player, "Error", "Could not create the account (username, phone or PC already registered).")
    end
    ui(player, "verifyStep", 3)
    ui(player, "verifyClose", 900)
    local created = getUser(p.username)
    if not created then                          -- should never happen; fall back to the normal flow
      notify(player, "ok", "Account created", "Your phone is verified. You can now log in.")
      return ui(player, "registerDone", p.username)
    end
    profilePending[player] = { id = created.id, username = p.username, expires = now() + CFG.profile.ttl }
    notify(player, "ok", "Phone verified", "One last thing: complete your profile.")
    ui(player, "profileStart", p.username, profileOpts())
  end)
end

local function startPolling(player)
  local p = pendingReg[player]
  p.timer = setTimer(function()
    if pendingReg[player] ~= p or not isElement(player) then return stopPending(player, true) end
    if p.finishing or p.polling then return end
    if now() > p.expires then
      stopPending(player, true); ui(player, "verifyClose")
      return reject(player, "Verification expired", "Start the registration again.")
    end
    p.polling = true
    apiCall("GET", "/api/link/status", { token = p.token }, function(ok, t)
      p.polling = false
      if pendingReg[player] ~= p or not isElement(player) or not ok then return end   -- transient error: next tick
      if t.status == "missing" or t.status == "expired" then
        stopPending(player, true); ui(player, "verifyClose")
        return reject(player, "Verification expired", "Start the registration again.")
      end
      local step = tonumber(t.step) or 0
      if step ~= p.step then p.step = step; ui(player, "verifyStep", step) end
      if t.status == "verified" and not p.finishing then finalizeRegistration(player, p, t) end
    end)
  end, 3000, 0)
end

--------------------------------------------------------------------------
-- actions (UI -> client.lua -> here)
--------------------------------------------------------------------------
function actions.checkUsername(player, d)
  local name = str(d.username)
  if #name < CFG.minUser then return end
  if not validUser(name) then return ui(player, "usernameStatus", name, false, "Invalid") end
  local free = not getUser(name) and not (CFG.mtaAccounts and getAccount(name))
  ui(player, "usernameStatus", name, free and true or false)
end

function actions.register(player, d)
  local user, pass = str(d.username), str(d.password)
  local serial, ip = getPlayerSerial(player), getPlayerIP(player) or ""
  if not telegramReady() then return reject(player, "Unavailable", "Telegram verification is not configured yet. Contact staff.") end
  if maintenance then return reject(player, "Maintenance", "Registration is closed during maintenance.") end
  if not validUser(user) then return reject(player, "Invalid input", "Username: " .. CFG.minUser .. "-" .. CFG.maxUser .. " letters, numbers or _.") end
  local phone = normPhone(str(d.phone))
  if not phone then return reject(player, "Invalid input", "Enter a valid phone number (with country code if it is not Iranian).") end
  if not validPass(pass) then return reject(player, "Invalid input", "Password: " .. CFG.minPass .. "-" .. CFG.maxPass .. " characters.") end

  -- ONE ACCOUNT PER PC
  local owner = getBySerial(serial)
  if owner then
    addFlag("MULTI_REGISTER", 80, 0, owner.id, serial, ip, "A PC that owns '" .. owner.username .. "' tried to register '" .. user .. "'")
    return reject(player, "One account per PC", "This PC already has an account. Use Login or Account Recovery.")
  end
  if CFG.multi.strictSerialHistory then
    local h = query("SELECT user_id FROM lg_logins WHERE serial = ? AND ts > ? LIMIT 1", serial, now() - CFG.multi.historyDays * 86400)
    if h and h[1] then
      addFlag("MULTI_REGISTER", 80, 0, h[1].user_id, serial, ip, "A PC that recently hosted '" .. nameOf(h[1].user_id) .. "' tried to register '" .. user .. "'")
      return reject(player, "One account per PC", "This PC is already linked to another account.")
    end
  end
  if getUser(user) or (CFG.mtaAccounts and getAccount(user)) then return reject(player, "Username taken", "That username is already taken.") end
  local ph = query("SELECT id FROM lg_accounts WHERE phone = ? LIMIT 1", phone)
  if ph and ph[1] then
    addFlag("PHONE_REUSE", 80, 0, ph[1].id, serial, ip, "Phone of '" .. nameOf(ph[1].id) .. "' was used to register '" .. user .. "'")
    return reject(player, "Phone in use", "This phone number is already registered.")
  end
  for p2, pr in pairs(pendingReg) do
    if p2 ~= player and (pr.username:lower() == user:lower() or pr.phone == phone) then
      return reject(player, "Please wait", "Another registration with this username or phone is in progress.")
    end
  end

  stopPending(player, true)
  busy[player] = true
  hashPass(pass, function(hashed)
    if not isElement(player) then return end
    if not hashed then busy[player] = nil; return reject(player, "Error", "Could not create the account.") end
    local token = makeToken(serial)
    apiCall("POST", "/api/link/create", { token = token, username = user, phone = phone, ttl = CFG.linkTtl }, function(ok, r)
      busy[player] = nil
      if not isElement(player) then return end
      if not ok then
        if r.error == "unreachable" then return reject(player, "Telegram service", "Could not reach the verification service. Try again in a moment.") end
        return reject(player, "Telegram service", "The verification service is misconfigured. Contact staff (see the server console).")
      end
      pendingReg[player] = { token = token, username = user, phone = phone, hash = hashed, serial = serial, ip = ip, expires = now() + CFG.linkTtl, step = 0 }
      startPolling(player)
      ui(player, "verifyStart", "https://t.me/" .. CFG.telegram.bot .. "?start=" .. token, CFG.linkTtl)
    end)
  end)
end

function actions.checkRef(player, d)
  local id = profileTarget(player)
  if not id then return end
  local code = (str(d.code):upper():gsub("%s", ""))
  local valid = false
  if validRefFormat(code) then
    local r = query("SELECT id FROM lg_accounts WHERE ref_code = ? AND profile_done = 1 LIMIT 1", code)
    valid = r and r[1] ~= nil and tonumber(r[1].id) ~= tonumber(id) or false
  end
  ui(player, "refStatus", code, valid and true or false)
end

function actions.saveProfile(player, d)
  local id, username = profileTarget(player)
  if not id then return end
  local rows = query("SELECT * FROM lg_accounts WHERE id = ? LIMIT 1", id)
  local row = rows and rows[1]
  if not row then return end
  local function bad(field, msg) ui(player, "profileError", field, msg) end

  if tonumber(row.profile_done) == 1 then        -- double submit: just show the result again
    local a, ctx = authed[player], profilePending[player]
    if a then a.needProfile = false end
    if ctx then ctx.done = true end
    return ui(player, "profileDone", str(row.ref_code))
  end

  -- 1) real name
  local name = cleanText(str(d.name))
  local len = utf8 and utf8.len(name) or #name
  if not len or len < 3 or len > 40 or name:find("[^%a%s%-'%.\128-\255]") then
    return bad("name", "Enter your real name (letters only, 3-40 characters).")
  end
  -- 2) birth date
  local by, bm, bd = parseBirth(str(d.birth))
  if not by then return bad("birth", "Enter a valid date of birth.") end
  local age = ageOf(by, bm, bd)
  if age < CFG.profile.minAge then return bad("birth", "You must be at least " .. CFG.profile.minAge .. " years old to play.") end
  if age > 100 then return bad("birth", "Enter a valid date of birth.") end
  -- 3) gender
  local gender = ({ male = "m", female = "f", other = "o" })[str(d.gender)]
  if not gender then return bad("gender", "Select your gender.") end
  -- 4) height / 5) weight
  local height, weight = tonumber(d.height), tonumber(d.weight)
  if not height or height ~= math.floor(height) or height < 100 or height > 250 then return bad("height", "Height must be between 100 and 250 cm.") end
  if not weight or weight ~= math.floor(weight) or weight < 30 or weight > 300 then return bad("weight", "Weight must be between 30 and 300 kg.") end
  -- 7) how they found us (validated before the optional referral so the order of the wizard matches)
  local source = str(d.source)
  if not CFG.profile.sources[source] then return bad("source", "Tell us how you found the server.") end
  local other = ""
  if source == "other" then other = cleanText((str(d.other):gsub("[^%w%s%-'%.,\128-\255]", ""))):sub(1, 40) end
  -- 6) referral code (optional)
  local referrer = 0
  local code = (str(d.ref):upper():gsub("%s", ""))
  if code ~= "" then
    if not validRefFormat(code) then return bad("ref", "Invalid referral code.") end
    local r = query("SELECT id, reg_ip, last_ip FROM lg_accounts WHERE ref_code = ? AND profile_done = 1 LIMIT 1", code)
    if not r or not r[1] or tonumber(r[1].id) == tonumber(id) then return bad("ref", "Invalid referral code.") end
    referrer = tonumber(r[1].id)
    local ip = getPlayerIP(player) or ""
    if ip ~= "" and (ip == r[1].reg_ip or ip == r[1].last_ip) then       -- inviter and invited share an IP: possible fake invites
      addFlag("REFERRAL_SAME_IP", 70, id, referrer, getPlayerSerial(player), ip, username .. " used the referral code of " .. nameOf(referrer) .. " from the same IP")
    end
  end

  local myCode = str(row.ref_code) ~= "" and str(row.ref_code) or newRefCode()
  if not myCode then return bad("", "Could not finish your profile. Try again.") end
  local saved = dbExec(db, "UPDATE lg_accounts SET real_name = ?, birth_date = ?, gender = ?, height_cm = ?, weight_kg = ?, source = ?, source_other = ?, referred_by = ?, ref_code = ?, profile_done = 1 WHERE id = ? AND profile_done = 0",
    name, string.format("%04d-%02d-%02d", by, bm, bd), gender, height, weight, source, other, referrer, myCode, id)
  if not saved then return bad("", "Could not save your profile. Try again.") end

  local a, ctx = authed[player], profilePending[player]
  if a then a.needProfile = false end
  if ctx then ctx.done = true end
  ui(player, "profileDone", myCode)
  if referrer > 0 then triggerEvent("lg:onReferral", player, id, referrer) end
end

function actions.profileContinue(player)         -- the wizard's "Continue" button
  local a, ctx = authed[player], profilePending[player]
  if a then
    if not a.needProfile then completeLogin(player) end
  elseif ctx and ctx.done then
    profilePending[player] = nil
    notify(player, "ok", "Profile saved", "You can now log in.")
    ui(player, "registerDone", ctx.username)
  end
end

function actions.cancelVerify(player)
  stopPending(player, true)
  ui(player, "unlock")
end

function actions.login(player, d)
  local serial = getPlayerSerial(player)
  if isLockedNow(player, serial, true) then return end
  local user, pass = str(d.username), str(d.password)
  if not validUser(user) or not validPass(pass) then return badCreds(player, serial, true) end
  local row = getUser(user)
  if not row then return badCreds(player, serial, true) end
  busy[player] = true
  verifyPass(pass, row.password, function(ok)
    busy[player] = nil
    if not isElement(player) or authed[player] then return end
    if not ok then return badCreds(player, serial, true) end

    if tonumber(row.banned) == 1 then
      ui(player, "setState", "banned", { message = "This account has been banned from the server.", extra = str(row.ban_reason) })
      return ui(player, "unlock")
    end
    if maintenance and not isStaff(row.username) then
      return reject(player, "Maintenance", "The server is under maintenance. Please come back soon.")
    end
    if row.serial ~= serial then
      local owner = getBySerial(serial)                         -- this PC owns a different account -> suspicious
      if owner and owner.id ~= row.id then
        addFlag("SHARED_DEVICE", 60, row.id, owner.id, serial, getPlayerIP(player) or "",
          "PC of '" .. owner.username .. "' tried to log into '" .. row.username .. "'")
      end
      ui(player, "switchTab", "recover")
      return reject(player, "New PC detected", "This account is linked to another PC. Use Account Recovery.")
    end
    for _, a in pairs(authed) do
      if a.id == row.id then return reject(player, "Account in use", "This account is already online.") end
    end

    local acc = ensureMtaAccount(row.username, pass)
    if not acc then return reject(player, "Error", "Could not load your account. Contact staff.") end
    if acc ~= true then
      local other = getAccountPlayer(acc)
      if other and other ~= player then return reject(player, "Account in use", "This account is already online.") end
      local cur = getPlayerAccount(player)
      if cur and not isGuestAccount(cur) then logOut(player) end
      if not logIn(player, acc, pass) then return reject(player, "Error", "Login was blocked. Contact staff.") end
    end

    authed[player] = { id = row.id, username = row.username, spawned = false, completed = false, needProfile = tonumber(row.profile_done) ~= 1 }
    fails[serial] = nil
    dbExec(db, "UPDATE lg_accounts SET last_login = ?, last_ip = ? WHERE id = ?", now(), getPlayerIP(player) or "", row.id)
    recordLogin(player, row)
    setElementData(player, "lg.id", row.id)
    setElementData(player, "lg.username", row.username)
    if CFG.setNick then forceName(player, row.username) end
    if authed[player].needProfile then
      ui(player, "profileStart", row.username, profileOpts())     -- old account / wizard abandoned: finish it first
    else
      completeLogin(player)                           -- UI plays the welcome animation, then sends "welcomeDone"
    end
  end)
end

function actions.welcomeDone(player)
  local a = authed[player]
  if not a or a.spawned or not a.completed then return end
  a.spawned = true
  local s = CFG.spawn
  spawnPlayer(player, s.x, s.y, s.z, s.rot, s.skin, s.interior, s.dimension)
  fadeCamera(player, true)
  setCameraTarget(player, player)
  setCameraInterior(player, s.interior)
  triggerClientEvent(player, "lg:client:close", resourceRoot)
end

function actions.change(player, d)
  local serial = getPlayerSerial(player)
  if isLockedNow(player, serial, false) then return end
  local user, old, new = str(d.username), str(d.oldPassword), str(d.newPassword)
  if not validUser(user) or not validPass(old) then return badCreds(player, serial, false) end
  if not validPass(new) then return reject(player, "Invalid input", "New password: " .. CFG.minPass .. "-" .. CFG.maxPass .. " characters.") end
  if old == new then return reject(player, "Invalid input", "The new password must be different.") end
  local row = getUser(user)
  if not row then return badCreds(player, serial, false) end
  busy[player] = true
  verifyPass(old, row.password, function(ok)
    if not isElement(player) then busy[player] = nil return end
    if not ok then busy[player] = nil return badCreds(player, serial, false) end
    hashPass(new, function(hashed)
      busy[player] = nil
      if not isElement(player) then return end
      if not hashed then return reject(player, "Error", "Could not change the password.") end
      if not dbExec(db, "UPDATE lg_accounts SET password = ? WHERE id = ?", hashed, row.id) then
        return reject(player, "Error", "Could not change the password.")
      end
      if CFG.mtaAccounts then
        local acc = getAccount(row.username)
        if acc then setAccountPassword(acc, new) else addAccount(row.username, new) end
      end
      notify(player, "ok", "Password changed", "Your password was updated.")
      ui(player, "changeDone")
    end)
  end)
end

function actions.recover(player, d)
  local serial = getPlayerSerial(player)
  if isLockedNow(player, serial, false) then return end
  local user, pass, code = str(d.username), str(d.password), str(d.code)
  if not validUser(user) or not validPass(pass) then return badCreds(player, serial, false) end
  local row = getUser(user)
  if not row then return badCreds(player, serial, false) end
  if code ~= "" and not validCode(code) then return reject(player, "Invalid input", "Enter the 6-digit code from the Telegram bot.") end
  busy[player] = true
  verifyPass(pass, row.password, function(ok)
    busy[player] = nil
    if not isElement(player) then return end
    if not ok then return badCreds(player, serial, false) end
    if tonumber(row.banned) == 1 then return reject(player, "Banned", "This account has been banned.") end
    if row.serial == serial then return reject(player, "Already linked", "This PC is already linked to the account. Just log in.") end
    local owner = getBySerial(serial)                          -- ONE ACCOUNT PER PC: the target PC must be free
    if owner and owner.id ~= row.id then
      addFlag("SHARED_DEVICE", 60, row.id, owner.id, serial, getPlayerIP(player) or "",
        "PC of '" .. owner.username .. "' tried to take over '" .. row.username .. "'")
      return reject(player, "One account per PC", "This PC already has another account.")
    end

    local entry, t = codes[row.id], now()
    if code == "" then                                         -- step 1: send the code to the linked Telegram
      if entry and entry.expires > t and entry.serial == serial and t - entry.sent < CFG.codeCooldown then
        notify(player, "info", "Code already sent", "Check the Telegram bot (wait a minute to resend).")
        return ui(player, "codeSent")
      end
      if not telegramReady() then return reject(player, "Unavailable", "Telegram is not configured. Contact staff.") end
      local c = string.format("%06d", math.random(0, 999999))
      codes[row.id] = { code = c, serial = serial, expires = t + CFG.codeTtl, sent = t, tries = 0 }
      busy[player] = true
      return apiCall("POST", "/api/send", { chat_id = row.tg_chat_id, kind = "code", code = c, ttl = math.floor(CFG.codeTtl / 60), username = row.username },
        function(sent, r)
          busy[player] = nil
          if not isElement(player) then return end
          if not sent then
            codes[row.id] = nil
            return reject(player, "Telegram error", r.error == "blocked" and "Open the bot and press Start, then try again." or "Could not send the code. Try again.")
          end
          ui(player, "codeSent")
        end)
    end

    if not entry or entry.expires <= t then                    -- step 2: confirm the code
      codes[row.id] = nil
      return reject(player, "Code expired", "Request a new code (clear the code box and press the button).")
    end
    if entry.serial ~= serial then return reject(player, "Wrong PC", "Use the same PC that requested the code.") end
    entry.tries = entry.tries + 1
    if entry.tries > CFG.codeMaxTries then
      codes[row.id] = nil
      return reject(player, "Too many tries", "Request a new code.")
    end
    if entry.code ~= code then return reject(player, "Wrong code", (CFG.codeMaxTries - entry.tries + 1) .. " attempt(s) left.") end
    codes[row.id] = nil
    if not dbExec(db, "UPDATE lg_accounts SET serial = ? WHERE id = ?", serial, row.id) then
      return reject(player, "Error", "Could not update your account.")
    end
    apiCall("POST", "/api/send", { chat_id = row.tg_chat_id, kind = "moved", username = row.username }, function() end)
    notify(player, "ok", "Account recovered", "This PC is now linked. You can log in.")
    ui(player, "recoverDone")
    ui(player, "fill", row.username)
  end)
end

-- Forgot password: the code goes to the Telegram bot linked to the account; no old password needed.
-- Step 1 (code == ""): send a code. Step 2: code + new password. Unknown usernames get the same answer as known ones.
function actions.reset(player, d)
  local serial = getPlayerSerial(player)
  if isLockedNow(player, serial, false) then return end
  local user, code, new = str(d.username), str(d.code), str(d.password)
  if not validUser(user) then return reject(player, "Invalid input", "Enter your username.") end
  local row, t = getUser(user), now()

  if code == "" then                                           -- step 1
    if resetCd[serial] and t - resetCd[serial] < CFG.codeCooldown then
      notify(player, "info", "Code already sent", "Check the Telegram bot (wait a minute to resend).")
      return ui(player, "resetCodeSent")
    end
    if not telegramReady() then return reject(player, "Unavailable", "Telegram is not configured. Contact staff.") end
    resetCd[serial] = t
    if not row or tonumber(row.banned) == 1 then return ui(player, "resetCodeSent") end     -- same answer: no username probing
    local c = string.format("%06d", math.random(0, 999999))
    rcodes[row.id] = { code = c, serial = serial, expires = t + CFG.codeTtl, tries = 0 }
    busy[player] = true
    return apiCall("POST", "/api/send", { chat_id = row.tg_chat_id, kind = "code", code = c, ttl = math.floor(CFG.codeTtl / 60), username = row.username },
      function(sent, r)
        busy[player] = nil
        if not isElement(player) then return end
        if not sent then
          rcodes[row.id] = nil; resetCd[serial] = nil
          return reject(player, "Telegram error", r.error == "blocked" and "Open the bot and press Start, then try again." or "Could not send the code. Try again.")
        end
        ui(player, "resetCodeSent")
      end)
  end

  if not validCode(code) then return reject(player, "Invalid input", "Enter the 6-digit code from the Telegram bot.") end    -- step 2
  if not validPass(new) then return reject(player, "Invalid input", "New password: " .. CFG.minPass .. "-" .. CFG.maxPass .. " characters.") end
  if not row then return badCreds(player, serial, false) end
  local entry = rcodes[row.id]
  if not entry or entry.expires <= t then
    rcodes[row.id] = nil
    return reject(player, "Code expired", "Request a new code.")
  end
  if entry.serial ~= serial then return reject(player, "Wrong PC", "Use the same PC that requested the code.") end
  entry.tries = entry.tries + 1
  if entry.tries > CFG.codeMaxTries then
    rcodes[row.id] = nil
    return reject(player, "Too many tries", "Request a new code.")
  end
  if entry.code ~= code then return badCreds(player, serial, false) end
  rcodes[row.id] = nil
  if tonumber(row.banned) == 1 then return reject(player, "Banned", "This account has been banned.") end
  local owner = getBySerial(serial)                            -- ONE ACCOUNT PER PC still applies
  if owner and owner.id ~= row.id then
    addFlag("SHARED_DEVICE", 60, row.id, owner.id, serial, getPlayerIP(player) or "",
      "PC of '" .. owner.username .. "' tried to reset the password of '" .. row.username .. "'")
    return reject(player, "One account per PC", "This PC already has another account.")
  end
  busy[player] = true
  hashPass(new, function(hashed)
    busy[player] = nil
    if not isElement(player) then return end
    if not hashed then return reject(player, "Error", "Could not reset the password.") end
    local moved = row.serial ~= serial                          -- the Telegram code also proves ownership: link this PC
    local ok
    if moved then ok = dbExec(db, "UPDATE lg_accounts SET password = ?, serial = ? WHERE id = ?", hashed, serial, row.id)
    else ok = dbExec(db, "UPDATE lg_accounts SET password = ? WHERE id = ?", hashed, row.id) end
    if not ok then return reject(player, "Error", "Could not reset the password.") end
    if CFG.mtaAccounts then
      local acc = getAccount(row.username)
      if acc then setAccountPassword(acc, new) else addAccount(row.username, new) end
    end
    for pl, a in pairs(authed) do                                -- anyone still logged in with the old password is removed
      if a.id == row.id then kickPlayer(pl, "Password was reset") end
    end
    fails[serial] = nil
    if moved and telegramReady() then apiCall("POST", "/api/send", { chat_id = row.tg_chat_id, kind = "moved", username = row.username }, function() end) end
    notify(player, "ok", "Password reset", "You can now log in with your new password.")
    ui(player, "resetDone", row.username)
  end)
end

function actions.forgotUsername(player)
  local serial = getPlayerSerial(player)
  local t = now()
  if mailCd[serial] and t - mailCd[serial] < CFG.codeCooldown then
    return notify(player, "err", "Please wait", "Try again in a minute.")
  end
  mailCd[serial] = t
  local row = getBySerial(serial)
  if row and telegramReady() then
    apiCall("POST", "/api/send", { chat_id = row.tg_chat_id, kind = "username", username = row.username }, function() end)
  end
  notify(player, "info", "Check Telegram", "If an account is linked to this PC, its username was sent to the Telegram bot.")
end

--------------------------------------------------------------------------
-- events
--------------------------------------------------------------------------
local POST = { welcomeDone = true, saveProfile = true, profileContinue = true, checkRef = true }   -- allowed after login / right after registration
local TYPING = { checkUsername = true, checkRef = true }                                           -- lightweight lookups while the player types

addEventHandler("lg:server:auth", resourceRoot, function(action, data)
  local player = client
  if not isElement(player) or getElementType(player) ~= "player" or type(action) ~= "string" then return end
  if type(data) ~= "table" then data = {} end
  local fn = actions[action]
  if not fn then return end
  if authed[player] then
    if not POST[action] then return end
  elseif POST[action] then
    if action == "welcomeDone" or not profilePending[player] then return end
  end
  -- one throttle PER action: typing helpers (username / referral check) must never swallow a real Login / Register click
  local t, light = getTickCount(), TYPING[action]
  local la = lastAct[player] or {}
  lastAct[player] = la
  if la[action] and t - la[action] < (light and 150 or 250) then
    if not light then ui(player, "unlock") end
    return
  end
  la[action] = t
  if busy[player] and not light then return end
  local ok, err = pcall(fn, player, data)
  if not ok then
    busy[player] = nil
    outputServerLog("[linux_auth] error in action '" .. action .. "': " .. tostring(err))
    reject(player, "Error", "Something went wrong. Try again.")
  end
end)

addEventHandler("lg:server:ready", resourceRoot, function()
  local p = client
  if not isElement(p) or authed[p] then return end
  local tk = getTickCount()
  if readyCd[p] and tk - readyCd[p] < 1500 then return end      -- the client retries every 3 s: ignore floods
  readyCd[p] = tk
  joinedAt[p] = joinedAt[p] or tk
  ui(p, "setSerial", getPlayerSerial(p))
  ui(p, "setPlayers", getPlayerCount())
  ui(p, "setAnnouncements", CFG.announcements)
  local left = lockLeft(getPlayerSerial(p))
  if left > 0 then ui(p, "lock", left) end
end)

addEventHandler("onPlayerQuit", root, function()
  stopPending(source, true)
  authed[source], busy[source], lastAct[source], profilePending[source] = nil, nil, nil, nil
  readyCd[source], joinedAt[source] = nil, nil
end)
addEventHandler("onPlayerChat", root, function() if not authed[source] then cancelEvent() end end)
addEventHandler("onPlayerCommand", root, function() if not authed[source] then cancelEvent() end end)

-- every new player is called "Connecting..." until he logs in; after that his name is the account name
addEventHandler("onPlayerJoin", root, function() setTempName(source) end)

-- nobody (before or after login) can change his nickname: only this script (forceName) may
addEventHandler("onPlayerChangeNick", root, function()
  if not nickOK then cancelEvent() end
end)

addEventHandler("onResourceStart", resourceRoot, function()
  math.randomseed(getTickCount() + now())
  for _, p in ipairs(getElementsByType("player")) do          -- resource (re)started with players online
    if not authed[p] then setTempName(p) end
  end
  local m = CFG.mysql
  db = dbConnect("mysql",
    ("dbname=%s;host=%s;port=%d;charset=utf8mb4"):format(m.database, m.host, m.port),
    m.user, m.password, "share=1;autoreconnect=1")
  if not db then
    outputServerLog("[linux_auth] could not connect to MySQL. Is XAMPP/MySQL running and database '" .. m.database .. "' created? Stopping.")
    return stopResource(resource)
  end
  local tail = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci"
  local ok = dbExec(db, [[CREATE TABLE IF NOT EXISTS lg_accounts (
      id INT UNSIGNED NOT NULL AUTO_INCREMENT,
      username VARCHAR(20) NOT NULL,
      phone VARCHAR(16) NOT NULL,
      tg_id VARCHAR(20) NOT NULL,
      tg_chat_id VARCHAR(20) NOT NULL,
      password VARCHAR(100) NOT NULL,
      serial CHAR(32) NOT NULL,
      reg_ip VARCHAR(45) DEFAULT NULL,
      last_ip VARCHAR(45) DEFAULT NULL,
      created INT UNSIGNED DEFAULT NULL,
      last_login INT UNSIGNED DEFAULT NULL,
      banned TINYINT(1) NOT NULL DEFAULT 0,
      ban_reason VARCHAR(255) DEFAULT NULL,
      PRIMARY KEY (id),
      UNIQUE KEY uq_username (username),
      UNIQUE KEY uq_phone (phone),
      UNIQUE KEY uq_tg (tg_id),
      UNIQUE KEY uq_serial (serial)
    )]] .. tail)
    and dbExec(db, [[CREATE TABLE IF NOT EXISTS lg_logins (
      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
      user_id INT UNSIGNED NOT NULL,
      serial CHAR(32) NOT NULL,
      ip VARCHAR(45) NOT NULL,
      ts INT UNSIGNED NOT NULL,
      PRIMARY KEY (id), KEY idx_serial (serial), KEY idx_ip (ip), KEY idx_user (user_id)
    )]] .. tail)
    and dbExec(db, [[CREATE TABLE IF NOT EXISTS lg_flags (
      id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
      user_id INT UNSIGNED NOT NULL DEFAULT 0,
      other_id INT UNSIGNED NOT NULL DEFAULT 0,
      kind VARCHAR(24) NOT NULL,
      weight SMALLINT NOT NULL DEFAULT 0,
      serial CHAR(32) NOT NULL DEFAULT '',
      ip VARCHAR(45) NOT NULL DEFAULT '',
      info VARCHAR(255) NOT NULL DEFAULT '',
      ts INT UNSIGNED NOT NULL,
      PRIMARY KEY (id), KEY idx_dedupe (kind, serial, ts), KEY idx_user (user_id)
    )]] .. tail)
  if not ok then
    outputServerLog("[linux_auth] could not create the database tables. Stopping.")
    return stopResource(resource)
  end
  -- profile columns (also upgrades a table created by an older version)
  local function ensureColumn(col, ddl)
    local r = query("SELECT COUNT(*) AS n FROM information_schema.COLUMNS WHERE table_schema = DATABASE() AND table_name = 'lg_accounts' AND column_name = ?", col)
    if r and r[1] and tonumber(r[1].n) == 0 then dbExec(db, "ALTER TABLE lg_accounts ADD COLUMN " .. ddl) end
  end
  ensureColumn("real_name", "real_name VARCHAR(80) DEFAULT NULL")
  ensureColumn("birth_date", "birth_date DATE DEFAULT NULL")
  ensureColumn("gender", "gender CHAR(1) DEFAULT NULL")
  ensureColumn("height_cm", "height_cm SMALLINT UNSIGNED DEFAULT NULL")
  ensureColumn("weight_kg", "weight_kg SMALLINT UNSIGNED DEFAULT NULL")
  ensureColumn("source", "source VARCHAR(16) DEFAULT NULL")
  ensureColumn("source_other", "source_other VARCHAR(40) DEFAULT NULL")
  ensureColumn("ref_code", "ref_code CHAR(6) DEFAULT NULL")
  ensureColumn("referred_by", "referred_by INT UNSIGNED NOT NULL DEFAULT 0")
  ensureColumn("profile_done", "profile_done TINYINT(1) NOT NULL DEFAULT 0")
  local idx = query("SELECT COUNT(*) AS n FROM information_schema.STATISTICS WHERE table_schema = DATABASE() AND table_name = 'lg_accounts' AND index_name = 'uq_ref'")
  if idx and idx[1] and tonumber(idx[1].n) == 0 then dbExec(db, "ALTER TABLE lg_accounts ADD UNIQUE KEY uq_ref (ref_code)") end
  dbExec(db, "DELETE FROM lg_logins WHERE ts < ?", now() - 90 * 86400)
  if not telegramReady() then
    outputServerLog("[linux_auth] WARNING: CFG.telegram is not configured - registration is disabled until you set api / key / bot.")
  end
  setTimer(function()                                      -- refresh the online counter on login screens
    local n = getPlayerCount()
    for _, p in ipairs(getElementsByType("player")) do
      if not authed[p] then ui(p, "setPlayers", n) end
    end
  end, 10000, 0)
  setTimer(function()                                      -- forget old lock / cooldown entries (these tables are keyed by serial and would only ever grow)
    local tk, t = getTickCount(), now()
    for k, f in pairs(fails) do if f.lockUntil < tk - 600000 then fails[k] = nil end end
    for k, v in pairs(mailCd) do if t - v > 3600 then mailCd[k] = nil end end
    for k, v in pairs(resetCd) do if t - v > 3600 then resetCd[k] = nil end end
    for id, e in pairs(codes) do if e.expires <= t then codes[id] = nil end end
    for id, e in pairs(rcodes) do if e.expires <= t then rcodes[id] = nil end end
  end, 300000, 0)
  setTimer(function()                                      -- kick players who idle on the login screen
    local tk = getTickCount()
    for p, since in pairs(joinedAt) do
      if not isElement(p) or authed[p] then joinedAt[p] = nil
      elseif not pendingReg[p] and not profilePending[p] and tk - since > CFG.loginTimeout * 1000 then
        joinedAt[p] = nil
        kickPlayer(p, "Login timeout")
      end
    end
  end, 30000, 0)
end)

--------------------------------------------------------------------------
-- admin commands
--------------------------------------------------------------------------
local function canAdmin(p)
  if getElementType(p) == "console" then return true end
  local a = getPlayerAccount(p)
  return a and not isGuestAccount(a) and isStaff(getAccountName(a)) or false
end
local function say(p, msg)
  if getElementType(p) == "console" then outputServerLog("[linux_auth] " .. msg) else outputChatBox(msg, p, 255, 255, 255) end
end

addCommandHandler("maintenance", function(p, _, state)
  if not canAdmin(p) then return end
  if state == "on" then maintenance = true elseif state == "off" then maintenance = false else maintenance = not maintenance end
  say(p, "Maintenance is now " .. (maintenance and "ON" or "OFF") .. " (staff can still log in).")
end)

addCommandHandler("lgban", function(p, _, name, ...)
  if not canAdmin(p) then return end
  if not name then return say(p, "Usage: /lgban <username> [reason]") end
  local row = getUser(name)
  if not row then return say(p, "User not found.") end
  local reason = table.concat({ ... }, " ")
  if reason == "" then reason = "No reason given" end
  dbExec(db, "UPDATE lg_accounts SET banned = 1, ban_reason = ? WHERE id = ?", reason, row.id)
  for pl, a in pairs(authed) do
    if a.id == row.id then kickPlayer(pl, "Banned: " .. reason) end
  end
  say(p, row.username .. " has been banned.")
end)

addCommandHandler("lgunban", function(p, _, name)
  if not canAdmin(p) then return end
  local row = name and getUser(name)
  if not row then return say(p, "Usage: /lgunban <username>") end
  dbExec(db, "UPDATE lg_accounts SET banned = 0, ban_reason = NULL WHERE id = ?", row.id)
  say(p, row.username .. " has been unbanned.")
end)

-- delete an account completely (frees the username, phone, Telegram and PC)
addCommandHandler("lgdelete", function(p, _, name)
  if not canAdmin(p) then return end
  local row = name and getUser(name)
  if not row then return say(p, "Usage: /lgdelete <username>") end
  for pl, a in pairs(authed) do
    if a.id == row.id then kickPlayer(pl, "Account deleted") end
  end
  dbExec(db, "DELETE FROM lg_accounts WHERE id = ?", row.id)
  if CFG.mtaAccounts then
    local acc = getAccount(row.username)
    if acc then removeAccount(acc) end
  end
  if telegramReady() then apiCall("POST", "/api/link/release", { tg_id = row.tg_id }, function() end) end
  say(p, row.username .. " was deleted.")
end)

-- accounts connected to <username> by PC / IP + recent flags
addCommandHandler("lgmulti", function(p, _, name)
  if not canAdmin(p) then return end
  local row = name and getUser(name)
  if not row then return say(p, "Usage: /lgmulti <username>") end
  say(p, "== " .. row.username .. " | phone ****" .. tostring(row.phone):sub(-3) .. " ==")
  local s = query("SELECT DISTINCT a.username AS n FROM lg_logins l JOIN lg_accounts a ON a.id = l.user_id " ..
    "WHERE l.serial IN (SELECT serial FROM lg_logins WHERE user_id = ?) AND l.user_id <> ? LIMIT 10", row.id, row.id)
  say(p, "Same PC: " .. (s and #s > 0 and (function() local t = {} for _, r in ipairs(s) do t[#t + 1] = r.n end return table.concat(t, ", ") end)() or "none"))
  local i = query("SELECT DISTINCT a.username AS n FROM lg_logins l JOIN lg_accounts a ON a.id = l.user_id " ..
    "WHERE l.ip IN (SELECT ip FROM lg_logins WHERE user_id = ?) AND l.user_id <> ? LIMIT 10", row.id, row.id)
  say(p, "Same IP: " .. (i and #i > 0 and (function() local t = {} for _, r in ipairs(i) do t[#t + 1] = r.n end return table.concat(t, ", ") end)() or "none"))
  local f = query("SELECT kind, weight, info FROM lg_flags WHERE user_id = ? OR other_id = ? ORDER BY id DESC LIMIT 8", row.id, row.id)
  for _, r in ipairs(f or {}) do say(p, "  [" .. r.kind .. " " .. r.weight .. "] " .. r.info) end
end)

addCommandHandler("lgflags", function(p)
  if not canAdmin(p) then return end
  local f = query("SELECT kind, weight, info FROM lg_flags ORDER BY id DESC LIMIT 10")
  if not f or #f == 0 then return say(p, "No flags.") end
  for _, r in ipairs(f) do say(p, "[" .. r.kind .. " " .. r.weight .. "] " .. r.info) end
end)

-- connection test to every worker URL: tells you if the 403 comes from Cloudflare or from the worker
addCommandHandler("lgtest", function(p)
  if not canAdmin(p) then return end
  local list = baseList()
  if #list == 0 or not telegramReady() then return say(p, "CFG.telegram is not configured (api / key / bot).") end
  for i, base in ipairs(list) do
    local function probe(label, path, withKey)
      fetchRemote(base .. path, { method = "GET", headers = requestHeaders(withKey, false), connectionAttempts = 2 }, function(resp, info)
        say(p, ("[%d] %s %s -> HTTP %s  %s"):format(i, base, label, tostring(status(info)), snippet(resp)))
      end)
    end
    probe("ping", "/api/ping", false)
    probe("auth", "/api/link/status?token=test", true)
  end
  say(p, "Expect: ping -> 200 {\"ok\":true...}, auth -> 200 {\"ok\":true,\"status\":\"missing\"...}. 401 = wrong API key. 403/HTML = blocked by Cloudflare.")
end)

-- show the profile a player filled in (staff only)
addCommandHandler("lgprofile", function(p, _, name)
  if not canAdmin(p) then return end
  local row = name and getUser(name)
  if not row then return say(p, "Usage: /lgprofile <username>") end
  if tonumber(row.profile_done) ~= 1 then return say(p, row.username .. " has not completed the profile yet.") end
  local g = ({ m = "male", f = "female", o = "other" })[str(row.gender)] or "?"
  say(p, ("== %s | %s | born %s | %s | %s cm | %s kg =="):format(row.username, str(row.real_name), tostring(row.birth_date), g, tostring(row.height_cm), tostring(row.weight_kg)))
  local ref = tonumber(row.referred_by) > 0 and nameOf(tonumber(row.referred_by)) or "-"
  say(p, ("Found us via: %s %s | referral code: %s | invited by: %s"):format(str(row.source), str(row.source_other), str(row.ref_code), ref))
end)
