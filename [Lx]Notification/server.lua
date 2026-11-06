-- [Lx]Notification (server)
-- exports["[Lx]Notification"]:notify(player, "success", "Bank", "5,000 deposited")      -- player, or root for everyone
local KINDS = { success = true, error = true, warning = true, info = true, money = true }

local function clip(s, max)
  if type(s) ~= "string" or not utf8.len(s) then return "" end
  s = s:gsub("%c", " "):gsub("#%x%x%x%x%x%x", "")
  if utf8.len(s) > max then local cut = utf8.offset(s, max + 1); if cut then s = s:sub(1, cut - 1) end end
  return s
end

function notify(target, kind, title, text, duration)
  if target ~= root and (not isElement(target) or getElementType(target) ~= "player") then return false end
  if not KINDS[kind] then kind = "info" end
  title, text = clip(title or "", 40), clip(text or "", 160)
  if title == "" and text == "" then return false end
  duration = math.max(1500, math.min(tonumber(duration) or 4500, 15000))
  triggerClientEvent(target, "lx:notification:add", resourceRoot, kind, title, text, duration)
  return true
end