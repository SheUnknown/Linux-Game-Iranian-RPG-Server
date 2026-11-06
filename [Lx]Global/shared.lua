-- [Lx]Global : helpers shared by every [Lx] resource (both sides).
-- Usage from another resource:  exports["[Lx]Global"]:isLoggedIn(player)

-- A player counts as logged in when [Lx]Login has set his user id (element data "lg.id", synced to all clients).
function isLoggedIn(player)
  if not isElement(player) or getElementType(player) ~= "player" then return false end
  return getElementData(player, "lg.id") and true or false
end

function getUserId(player)
  if not isElement(player) or getElementType(player) ~= "player" then return false end
  return tonumber(getElementData(player, "lg.id")) or false
end

-- 1234567 -> "1,234,567"   (sep defaults to ",")
function formatNumber(n, sep)
  n = tonumber(n)
  if not n or n ~= n then return "0" end
  sep = type(sep) == "string" and sep or ","
  local neg = n < 0
  local s = string.format("%.0f", math.abs(n))            -- never scientific notation
  local out, len = {}, #s
  for i = 1, len do
    out[#out + 1] = s:sub(i, i)
    local left = len - i
    if left > 0 and left % 3 == 0 then out[#out + 1] = sep end
  end
  return (neg and "-" or "") .. table.concat(out)
end

-- Safe text from a player: no control chars, no #RRGGBB colour codes, single spaces, valid UTF-8, max length.
-- Returns "" for anything that is not valid text.
function cleanText(s, maxLen)
  if type(s) ~= "string" then return "" end
  if not utf8.len(s) then return "" end                      -- invalid UTF-8 -> reject
  s = s:gsub("%c", " "):gsub("#%x%x%x%x%x%x", ""):gsub("%s+", " ")
  s = s:gsub("^ ", ""):gsub(" $", "")
  maxLen = tonumber(maxLen)
  if maxLen and (utf8.len(s) or 0) > maxLen then
    local cut = utf8.offset(s, maxLen + 1)
    if cut then s = s:sub(1, cut - 1) end
  end
  return s
end

-- Number from untrusted input: returns an integer inside [min, max] or nil (NaN / inf / text / out of range -> nil).
function toInt(v, min, max)
  v = tonumber(v)
  if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
  v = math.floor(v)
  if min and v < min then return nil end
  if max and v > max then return nil end
  return v
end
