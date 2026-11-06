# [Lx]Global
هسته‌ی مشترک؛ همه‌ی ریسورس‌های دیگر فقط از این استفاده می‌کنند.

## راه‌اندازی
پیش از شروع ریسورس، مقادیر `DBCFG` در `server.lua` را با تنظیمات محلی MySQL جایگزین کنید. اعتبارنامه‌های واقعی و فایل `lx_logs.db` را در مخزن عمومی قرار ندهید؛ فایل پایگاه داده‌ی SQLite هنگام اجرای ریسورس ساخته می‌شود.

| تابع | سمت | کار |
|---|---|---|
| `isLoggedIn(player)` / `getUserId(player)` | هر دو | بر اساس `lg.id` که `[Lx]Login` می‌گذارد |
| `getPlayerByUserId(id)` | سرور | پیدا کردن بازیکن آنلاین |
| `rateLimit(player, key, ms)` | سرور | جلوی اسپم event؛ `false` یعنی خیلی سریع |
| `log(category, text, player?)` | سرور | لاگ SQLite (`lx_logs.db`)، ۳۰ روز نگه می‌دارد |
| `formatNumber(n)` | هر دو | `1234567 -> 1,234,567` |
| `cleanText(s, max)` | هر دو | متن امن از بازیکن (UTF-8 معتبر، بدون کد رنگ/کنترل) |
| `toInt(v, min, max)` | هر دو | عدد صحیح امن یا `nil` |

## الگوی امن برای هر event (قانون همه‌ی ریسورس‌ها)
```lua
addEvent("lx:bank:withdraw", true)
addEventHandler("lx:bank:withdraw", resourceRoot, function(amount)
  local player = client                                   -- هرگز source یا آرگومان برای هویت بازیکن
  local G = exports["[Lx]Global"]
  if not G:isLoggedIn(player) then return end
  if not G:rateLimit(player, "bank:withdraw", 800) then return end
  amount = G:toInt(amount, 1, 10000000)                   -- ورودی کلاینت = غیرقابل اعتماد
  if not amount then return end
  -- ... پول/آیتم فقط سمت سرور تغییر می‌کند و در دیتابیس با query پارامتری ...
  G:log("bank", "withdraw " .. amount, player)
end)
```
