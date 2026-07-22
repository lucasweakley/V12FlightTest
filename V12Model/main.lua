-- V12FlightTest v1.1.1 Model Image Edition
-- Compact 320x240 flight-test dashboard for EdgeTX color radios.
-- Betaflight + ExpressLRS/CRSF telemetry.
-- Install as: /WIDGETS/V12Model/main.lua

local NAME = "V12Model"

local options = {
  { "LQWarn", VALUE, 70, 0, 100 },
  { "LQCrit", VALUE, 40, 0, 100 },
  { "VWarn",  VALUE, 350, 280, 420 }, -- centivolts/cell
  { "VCrit",  VALUE, 330, 280, 420 },
  { "Cells",  VALUE, 0, 0, 8 },       -- 0 = auto detect
  { "BatAlarm", BOOL, 1 },              -- battery audio warnings on/off
  { "LampTest", SOURCE, 0 },              -- switch/logical switch; active above center
}

local C = {
  black  = lcd.RGB(0, 0, 0),
  panel  = lcd.RGB(0, 0, 0),
  line   = lcd.RGB(112, 122, 128),
  annBorder = lcd.RGB(145, 153, 158),
  dim    = lcd.RGB(68, 76, 82),
  battBg = lcd.RGB(38, 43, 47),
  text   = lcd.RGB(235, 239, 240),
  green  = lcd.RGB(35, 210, 105),
  teal   = lcd.RGB(38, 190, 178),
  amber  = lcd.RGB(245, 184, 27),
  red    = lcd.RGB(239, 68, 68),
  sky    = lcd.RGB(26, 78, 120),
  ground = lcd.RGB(88, 58, 34),
}

local SENSOR = {
  rxBat = { "RxBt", "VFAS", "Batt", "Bat" },
  curr  = { "Curr", "Current" },
  capa  = { "Capa", "Fuel" },
  lq    = { "RQly", "LQ" },
  rssi1 = { "1RSS", "RSSI" },
  rssi2 = { "2RSS" },
  rsnr  = { "RSNR", "SNR" },
  ant   = { "ANT" },
  rfmd  = { "RFMD" },
  tpwr  = { "TPWR" },
  trss  = { "TRSS" },
  tqly  = { "TQly" },
  tsnr  = { "TSNR" },
  fm    = { "FM", "Mode", "FltMode", "FlMd" },
  pitch = { "Ptch", "Pitch", "PITCH" },
  roll  = { "Roll", "ROLL" },
  yaw   = { "Yaw", "YAW" },
  txBat = { "tx-voltage", "TxBt", "TX Voltage" },
}

local RF_RATE = {
  [0]=4, [1]=25, [2]=50, [3]=100, [4]=100, [5]=150,
  [6]=200, [7]=250, [8]=333, [9]=500, [10]=1000,
}

-- ExpressLRS 3.x RF mode sensitivity limits in dBm. Signal coloring uses
-- margin above the receiver limit, rather than one fixed RSSI number.
local RF_SENSITIVITY = {
  [1]=-123, [2]=-115, [3]=-117, [4]=-112, [5]=-112,
  [6]=-112, [7]=-108, [8]=-105, [9]=-105,
  [10]=-104, [11]=-104, [12]=-104, [13]=-104,
  [14]=-112, [16]=-101, [19]=-101,
}

local FLRC_MODE = { [10]=true, [11]=true, [12]=true, [13]=true }

local function readRaw(names)
  for _, name in ipairs(names) do
    local ok, value = pcall(getValue, name)
    if ok and value ~= nil and value ~= 0 and value ~= "" then return value end
    if type(getFieldInfo) == "function" then
      local okInfo, info = pcall(getFieldInfo, name)
      if okInfo and type(info) == "table" and info.id then
        local okValue, byId = pcall(getValue, info.id)
        if okValue and byId ~= nil and byId ~= 0 and byId ~= "" then return byId end
      end
    end
  end
  return nil
end

local function readNum(names)
  local v = readRaw(names)
  return type(v) == "number" and v or nil
end

-- Attitude values legitimately spend a lot of time at exactly zero. The generic
-- telemetry reader treats zero as "missing" because EdgeTX also returns zero for
-- nonexistent/stale sources. For Ptch/Roll we first prove that the sensor exists,
-- then accept zero as a valid live value while the CRSF link is up.
local function readAttitudeNum(names)
  for _, name in ipairs(names) do
    if type(getFieldInfo) == "function" then
      local okInfo, info = pcall(getFieldInfo, name)
      if okInfo and type(info) == "table" and info.id then
        local okValue, value = pcall(getValue, info.id)
        if okValue and type(value) == "number" then return value, name end
      end
    end
  end
  return nil, nil
end

local function readStr(names)
  local v = readRaw(names)
  if type(v) == "string" then return v end
  if type(v) == "number" then return tostring(v) end
  return nil
end

local function opt(w, key, fallback)
  local v = w.options and w.options[key]
  return v ~= nil and v or fallback
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function stripMode(raw)
  if type(raw) ~= "string" then return "----", false, false end
  local disarmed = string.sub(raw, -1) == "*"
  local failsafe = string.find(raw, "!", 1, true) ~= nil
  local chars = {}
  for i = 1, #raw do
    local ch = string.sub(raw, i, i)
    if ch ~= "*" and ch ~= "!" and ch ~= " " then chars[#chars+1] = ch end
  end
  local mode = string.upper(table.concat(chars))
  local map = { AIR="ACRO", STAB="ANGLE", ANGL="ANGLE", HOR="HORIZ", HRZN="HORIZ", WAIT="WAIT", FS="FAILSAFE" }
  return map[mode] or (mode ~= "" and mode or "----"), not disarmed and not failsafe and mode ~= "WAIT", failsafe
end

local function modelName()
  if type(model) == "table" and type(model.getInfo) == "function" then
    local ok, info = pcall(model.getInfo)
    if ok and info and info.name and info.name ~= "" then return info.name end
  end
  return "MODEL"
end

local TX_LION_CURVE = {
  {4.20,100},{4.10,90},{4.00,80},{3.90,70},{3.80,60},{3.70,50},
  {3.65,40},{3.60,30},{3.50,20},{3.40,10},{3.30,5},{3.20,0},
}

local function txBatteryPercent()
  local v = readNum(SENSOR.txBat)
  if not v or v <= 0 then return nil end
  if v > 20 then v = v / 10 end
  local cells = 2 -- HelloRadio V12 uses a 2-cell Li-Ion pack.
  local cv = v / cells
  if cv >= TX_LION_CURVE[1][1] then return 100 end
  for i = 1, #TX_LION_CURVE - 1 do
    local a, b = TX_LION_CURVE[i], TX_LION_CURVE[i+1]
    if cv >= b[1] then
      local f = (cv - b[1]) / (a[1] - b[1])
      return clamp(math.floor(b[2] + f * (a[2] - b[2]) + 0.5), 0, 100)
    end
  end
  return 0
end

local function dateTimeText()
  local text = "--/-- --:--"
  if type(getDateTime) == "function" then
    local ok, d = pcall(getDateTime)
    if ok and type(d) == "table" and d.mon and d.day and d.hour and d.min then
      text = string.format("%02d/%02d  %02d:%02d", d.mon, d.day, d.hour, d.min)
    end
  end
  return text
end

local function txBatteryColor(pct)
  if pct == nil then return C.dim end
  if pct <= 20 then return C.red end
  if pct <= 45 then return C.amber end
  return C.green
end

local function detectCells(packV, forced, previous)
  if forced and forced > 0 then return forced end
  if not packV or packV <= 0 then return previous or 0 end
  if previous and previous > 0 then
    local pc = packV / previous
    if pc >= 2.8 and pc <= 4.4 then return previous end
  end
  for n = 1, 8 do
    local pc = packV / n
    if pc >= 3.45 and pc <= 4.30 then return n end
  end
  return previous or 0
end

local function drawText(x, y, text, color, flags)
  lcd.setColor(CUSTOM_COLOR, color or C.text)
  lcd.drawText(x, y, text or "--", (flags or 0) + CUSTOM_COLOR)
end

local function panel(x, y, w, h)
  lcd.setColor(CUSTOM_COLOR, C.panel)
  lcd.drawFilledRectangle(x, y, w, h, CUSTOM_COLOR)
  lcd.setColor(CUSTOM_COLOR, C.line)
  lcd.drawRectangle(x, y, w, h, 1, CUSTOM_COLOR)
end

local function centeredText(x, y, w, text, color, flags)
  local f = flags or 0
  local tw = lcd.sizeText(text, f)
  drawText(x + math.floor((w - tw) / 2), y, text, color, f)
end

local function fmt(v, format, fallback)
  if v == nil then return fallback or "--" end
  return string.format(format, v)
end

local function drawBattery(x, y, w, h, packV, cells, cellV, warnV, critV, capa)
  panel(x, y, w, h)

  -- The label is omitted so the gauge can use the full upper portion of the panel.
  local bx, by = x + 14, y + 12
  local bw, bh = w - 28, 68
  lcd.setColor(CUSTOM_COLOR, C.line)
  lcd.drawRectangle(bx, by, bw, bh, 2, CUSTOM_COLOR)
  lcd.drawFilledRectangle(bx + math.floor(bw/3), by - 4, math.floor(bw/3), 4, CUSTOM_COLOR)

  -- Dark empty-pack background makes the remaining level visible at a glance.
  lcd.setColor(CUSTOM_COLOR, C.battBg)
  lcd.drawFilledRectangle(bx + 3, by + 3, bw - 6, bh - 6, CUSTOM_COLOR)

  local pct = 0
  if cellV and cellV > 0 then pct = clamp((cellV - 3.20) / 1.00, 0, 1) end
  local fillH = math.floor((bh - 6) * pct + 0.5)
  local levelColor = C.green
  if not cellV or cellV <= critV then levelColor = C.red
  elseif cellV <= warnV then levelColor = C.amber end
  if fillH > 0 then
    lcd.setColor(CUSTOM_COLOR, levelColor)
    lcd.drawFilledRectangle(bx + 3, by + bh - 3 - fillH, bw - 6, fillH, CUSTOM_COLOR)
  end

  centeredText(x, y + h - 55, w, fmt(packV, "%.1fV"), C.text, MIDSIZE)
  centeredText(x, y + h - 36, w, cells > 0 and fmt(cellV, "%.2f/c") or "--/c", levelColor, SMLSIZE)
  centeredText(x, y + h - 19, w, capa and string.format("%dmAh", math.floor(capa + 0.5)) or "--mAh", C.text, SMLSIZE)
end

local function drawMetric(x, y, w, h, label, value, unit, valueColor)
  panel(x, y, w, h)
  drawText(x + 5, y + 2, label, C.dim, SMLSIZE)
  local val = value or "--"
  centeredText(x, y + 14, w, val, valueColor or C.text, MIDSIZE)
  if unit and unit ~= "" then drawText(x + w - 4, y + h - 14, unit, C.dim, SMLSIZE + RIGHT) end
end

local function lqSignalColor(value)
  if value == nil then return C.text end
  if value < 60 then return C.red end
  if value < 90 then return C.amber end
  return C.green
end

local function snrSignalColor(value, rate, rfmd)
  if value == nil then return C.text end
  -- ELRS FLRC modes report SNR as 0, so it cannot be meaningfully graded.
  if rfmd and FLRC_MODE[rfmd] then return C.text end
  local bad, good = 0, 8.5
  if rate == 500 or rate == 333 then bad, good = 5, 9.5
  elseif rate == 250 then bad, good = 3, 8.5
  elseif rate == 150 or rate == 100 then bad, good = 0, 8.5
  elseif rate == 50 then bad, good = -1, 6.5
  elseif rate == 200 then bad, good = 1, 3
  elseif rate == 25 then bad, good = -3, 0.5 end
  if value < bad then return C.red end
  if value < good then return C.amber end
  return C.green
end

local function rssiSignalColor(value, rfmd, rate)
  if value == nil then return C.text end
  local limit = rfmd and RF_SENSITIVITY[rfmd] or nil
  if not limit then
    if rate == 500 or rate == 333 then limit = -105
    elseif rate == 250 then limit = -108
    elseif rate == 200 or rate == 150 or rate == 100 then limit = -112
    elseif rate == 50 then limit = -115
    elseif rate == 25 then limit = -123
    else limit = -108 end
  end
  -- Red inside 5 dB of the sensitivity limit; amber from 5-10 dB margin.
  if value <= limit + 5 then return C.red end
  if value < limit + 10 then return C.amber end
  return C.green
end


-- Clip a line segment to a rectangular viewport using Liang-Barsky.
-- Returns nil when the segment lies completely outside; unlike endpoint
-- clamping, this preserves the original angle and lets ladder lines disappear
-- naturally through the edge of the attitude window.
local function clipLine(x1, y1, x2, y2, xmin, ymin, xmax, ymax)
  local dx, dy = x2 - x1, y2 - y1
  local t0, t1 = 0, 1
  local function test(p, q)
    if p == 0 then return q >= 0 end
    local r = q / p
    if p < 0 then
      if r > t1 then return false end
      if r > t0 then t0 = r end
    else
      if r < t0 then return false end
      if r < t1 then t1 = r end
    end
    return true
  end
  if not test(-dx, x1 - xmin) then return nil end
  if not test( dx, xmax - x1) then return nil end
  if not test(-dy, y1 - ymin) then return nil end
  if not test( dy, ymax - y1) then return nil end
  return x1 + t0*dx, y1 + t0*dy, x1 + t1*dx, y1 + t1*dy
end

local function loadModelBitmap(w)
  if type(model) ~= "table" or type(model.getInfo) ~= "function"
      or type(Bitmap) ~= "table" or type(Bitmap.open) ~= "function" then
    w.modelBitmap = nil
    w.modelBitmapName = nil
    return
  end

  local ok, info = pcall(model.getInfo)
  local bitmapName = ok and type(info) == "table" and info.bitmap or nil
  if type(bitmapName) ~= "string" or bitmapName == "" then
    w.modelBitmap = nil
    w.modelBitmapName = nil
    return
  end

  if w.modelBitmapName == bitmapName and w.modelBitmap ~= nil then return end

  w.modelBitmapName = bitmapName
  local path = "/IMAGES/" .. bitmapName
  local openOk, bitmap = pcall(Bitmap.open, path)
  if openOk then w.modelBitmap = bitmap else w.modelBitmap = nil end
end

local function drawModelImage(w, x, y, width, height)
  panel(x, y, width, height)
  loadModelBitmap(w)

  local bitmap = w.modelBitmap
  if bitmap == nil or type(Bitmap.getSize) ~= "function" then
    centeredText(x, y + math.floor(height / 2) - 12, width, "NO MODEL IMAGE", C.dim, SMLSIZE)
    centeredText(x, y + math.floor(height / 2) + 2, width, "ASSIGN IN MODEL SETUP", C.dim, SMLSIZE)
    return
  end

  local ok, imageW, imageH = pcall(Bitmap.getSize, bitmap)
  if not ok or not imageW or not imageH or imageW <= 0 or imageH <= 0 then
    centeredText(x, y + math.floor(height / 2) - 5, width, "IMAGE LOAD FAILED", C.red, SMLSIZE)
    return
  end

  -- Leave a small black margin inside the panel and preserve aspect ratio.
  local availableW, availableH = width - 10, height - 10
  local scale = math.floor(math.min(availableW / imageW, availableH / imageH) * 100)
  scale = math.max(1, scale)

  local drawnW = math.floor(imageW * scale / 100 + 0.5)
  local drawnH = math.floor(imageH * scale / 100 + 0.5)
  local imageX = x + math.floor((width - drawnW) / 2)
  local imageY = y + math.floor((height - drawnH) / 2)

  lcd.drawBitmap(bitmap, imageX, imageY, scale)
end

local function drawHorizon(x, y, w, h, pitch, roll, yawRate, valid)
  panel(x, y, w, h)

  -- The roll scale occupies the former ATTITUDE title area, above the
  -- artificial-horizon viewport so it never overlaps the pitch ladder.
  local hx1, hx2 = x + 5, x + w - 6
  -- Leave a visible gap between the roll scale and the horizon viewport.
  local hy1, hy2 = y + 26, y + h - 5
  local hw, hh = hx2 - hx1 + 1, hy2 - hy1 + 1
  local cx, cy = math.floor((hx1 + hx2) / 2), math.floor((hy1 + hy2) / 2)

  lcd.setColor(CUSTOM_COLOR, C.black)
  lcd.drawFilledRectangle(hx1, hy1, hw, hh, CUSTOM_COLOR)

  if valid then
    -- Custom color attitude display. Betaflight values arrive in radians and
    -- have already been converted to degrees before this function is called.
    -- Preserve the complete Betaflight roll angle. Using sin/cos instead of
    -- tan avoids the 90-degree singularity and lets the display rotate smoothly
    -- through knife-edge and fully inverted attitudes.
    local rollDeg = ((roll + 180) % 360) - 180
    local r = math.rad(rollDeg)
    local sr, cr = math.sin(r), math.cos(r)
    -- Betaflight pitch sign is opposite the visual convention used by this HUD.
    local visualPitch = -pitch
    local pitchPx = visualPitch * 1.05

    -- Pitch displacement must rotate with roll. Applying pitch only on the
    -- screen Y axis makes the indication reverse when the aircraft is inverted.
    -- Offset the horizon along its rotated normal instead.
    local hcx = cx + sr * pitchPx
    local hcy = cy + cr * pitchPx

    -- Paint the sky, ground, and white horizon as one rasterized background.
    -- Pitch is intentionally not clamped: the boundary is allowed to travel
    -- completely off-screen. Once it is beyond the window, fill the viewport
    -- from pitch alone. This avoids the Euler roll flip near +/-90 degrees from
    -- incorrectly swapping sky and ground during a straight nose-up/down move.
    if hcy < hy1 - hh then
      lcd.setColor(CUSTOM_COLOR, C.ground)
      lcd.drawFilledRectangle(hx1, hy1, hw, hh, CUSTOM_COLOR)
    elseif hcy > hy2 + hh then
      lcd.setColor(CUSTOM_COLOR, C.sky)
      lcd.drawFilledRectangle(hx1, hy1, hw, hh, CUSTOM_COLOR)
    else
      for px = hx1, hx2 do
        if math.abs(cr) > 0.015 then
          local horizonY = hcy - ((px - hcx) * sr / cr)
          local split = math.floor(horizonY + 0.5)
          if cr > 0 then
            local skyBottom = math.min(split - 1, hy2)
            if skyBottom >= hy1 then
              lcd.setColor(CUSTOM_COLOR, C.sky)
              lcd.drawLine(px, hy1, px, skyBottom, SOLID, CUSTOM_COLOR)
            end
            if split >= hy1 and split <= hy2 then
              lcd.setColor(CUSTOM_COLOR, C.text)
              lcd.drawPoint(px, split, CUSTOM_COLOR)
            end
            local groundTop = math.max(split + 1, hy1)
            if groundTop <= hy2 then
              lcd.setColor(CUSTOM_COLOR, C.ground)
              lcd.drawLine(px, groundTop, px, hy2, SOLID, CUSTOM_COLOR)
            end
          else
            local groundBottom = math.min(split - 1, hy2)
            if groundBottom >= hy1 then
              lcd.setColor(CUSTOM_COLOR, C.ground)
              lcd.drawLine(px, hy1, px, groundBottom, SOLID, CUSTOM_COLOR)
            end
            if split >= hy1 and split <= hy2 then
              lcd.setColor(CUSTOM_COLOR, C.text)
              lcd.drawPoint(px, split, CUSTOM_COLOR)
            end
            local skyTop = math.max(split + 1, hy1)
            if skyTop <= hy2 then
              lcd.setColor(CUSTOM_COLOR, C.sky)
              lcd.drawLine(px, skyTop, px, hy2, SOLID, CUSTOM_COLOR)
            end
          end
        else
          -- At knife-edge the boundary is vertical. Reserve the center boundary
          -- column itself for white, with sky and ground on the correct sides.
          local boundaryX = math.floor(hcx + 0.5)
          if px == boundaryX then
            lcd.setColor(CUSTOM_COLOR, C.text)
          else
            local side = (px - boundaryX) * sr
            lcd.setColor(CUSTOM_COLOR, side < 0 and C.sky or C.ground)
          end
          lcd.drawLine(px, hy1, px, hy2, SOLID, CUSTOM_COLOR)
        end
      end
    end

    -- Shared basis for the pitch ladder. Screen Y increases downward, so the
    -- horizon tangent is (cos,-sin), with pitch displacement along (sin,cos).
    local tx, ty = cr, -sr
    local nx, ny = sr, cr

    -- Pitch ladder keeps 10-degree rungs, but only labels every 20 degrees
    -- to reduce clutter. Labels remain upright while the ladder rotates.
    lcd.setColor(CUSTOM_COLOR, C.text)
    for deg = -60, 60, 10 do
      if deg ~= 0 then
        local offset = deg * 1.05
        local lx = hcx + nx * offset
        local ly = hcy + ny * offset
        local len = (math.abs(deg) % 20 == 0) and 20 or 16
        local ax, ay = lx - tx * len, ly - ty * len
        local bx, by = lx + tx * len, ly + ty * len
        local cax, cay, cbx, cby = clipLine(ax, ay, bx, by, hx1, hy1, hx2, hy2)
        if cax then
          lcd.drawLine(
            math.floor(cax + 0.5), math.floor(cay + 0.5),
            math.floor(cbx + 0.5), math.floor(cby + 0.5),
            SOLID, CUSTOM_COLOR)
        end

        if math.abs(deg) % 20 == 0 then
          local label = tostring(math.abs(deg))
          local lw = lcd.sizeText(label, SMLSIZE)
          local labelGap = 4
          local leftX = math.floor(ax - tx * labelGap - lw / 2 + 0.5)
          local leftY = math.floor(ay - ty * labelGap - 4 + 0.5)
          local rightX = math.floor(bx + tx * labelGap - lw / 2 + 0.5)
          local rightY = math.floor(by + ty * labelGap - 4 + 0.5)
          if leftX >= hx1 and leftX + lw <= hx2 and leftY >= hy1 and leftY + 8 <= hy2 then
            drawText(leftX, leftY, label, C.text, SMLSIZE)
          end
          if rightX >= hx1 and rightX + lw <= hx2 and rightY >= hy1 and rightY + 8 <= hy2 then
            drawText(rightX, rightY, label, C.text, SMLSIZE)
          end
        end
      end
    end

    -- Straight, screen-referenced bank scale in the title strip above the
    -- horizon viewport. The scale is fixed and the solid white caret moves.
    local bankY = y + 8
    local bankLeft, bankRight = hx1 + 18, hx2 - 18
    local bankWidth = bankRight - bankLeft
    lcd.setColor(CUSTOM_COLOR, C.text)
    lcd.drawLine(bankLeft, bankY, bankRight, bankY, SOLID, CUSTOM_COLOR)
    local bankAngles = {-60, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60}
    for _, bankDeg in ipairs(bankAngles) do
      local px = bankLeft + ((bankDeg + 60) / 120) * bankWidth
      local major = bankDeg == 0 or math.abs(bankDeg) == 30 or math.abs(bankDeg) == 60
      local tick = major and 5 or (math.abs(bankDeg) == 45 and 4 or 3)
      lcd.drawLine(math.floor(px + 0.5), bankY, math.floor(px + 0.5), bankY + tick, SOLID, CUSTOM_COLOR)
      if major then
        local label = tostring(math.abs(bankDeg))
        local lw = lcd.sizeText(label, SMLSIZE)
        drawText(math.floor(px - lw / 2 + 0.5), y + 11, label, C.text, SMLSIZE)
      end
    end

    -- Clamp the moving caret to the displayed +/-60-degree range and fill it
    -- as a solid white downward-pointing triangle.
    local pointerX = math.floor(bankLeft + ((clamp(rollDeg, -60, 60) + 60) / 120) * bankWidth + 0.5)
    local caretTop = y + 2
    for row = 0, 4 do
      local half = 4 - row
      lcd.drawLine(pointerX - half, caretTop + row, pointerX + half, caretTop + row, SOLID, CUSTOM_COLOR)
    end

    -- Fixed aircraft reference symbol.
    lcd.setColor(CUSTOM_COLOR, C.text)
    lcd.drawLine(cx - 18, cy, cx - 5, cy, SOLID, CUSTOM_COLOR)
    lcd.drawLine(cx + 5, cy, cx + 18, cy, SOLID, CUSTOM_COLOR)
    lcd.drawLine(cx - 5, cy, cx, cy + 4, SOLID, CUSTOM_COLOR)
    lcd.drawLine(cx + 5, cy, cx, cy + 4, SOLID, CUSTOM_COLOR)
    lcd.drawLine(cx, cy - 3, cx, cy + 3, SOLID, CUSTOM_COLOR)

  else
    lcd.setColor(CUSTOM_COLOR, C.red)
    lcd.drawLine(hx1 + 7, hy1 + 7, hx2 - 7, hy2 - 7, SOLID, CUSTOM_COLOR)
    lcd.drawLine(hx2 - 7, hy1 + 7, hx1 + 7, hy2 - 7, SOLID, CUSTOM_COLOR)
    centeredText(x, y + math.floor(h/2) - 5, w, "ATT LOST", C.red, SMLSIZE)
  end
end

local function drawAnnunciator(x, y, w, h, label, level, blinkOn, style)
  local active = level > 0
  local fill, edge, txt = C.panel, C.dim, C.dim

  if style == "battery_good" then
    fill, edge, txt = C.green, C.green, C.black
  elseif style == "safe" then
    -- Disarmed: neutral grey, not highlighted
    edge, txt = C.dim, C.dim
  elseif style == "armed" then
    -- Teal indicates a normal active/advisory state rather than a caution.
    fill, edge, txt = C.teal, C.teal, C.black
  elseif style == "airmode" then
    -- AIR MODE is the normal/default flight mode, so show it as an active teal advisory.
    fill, edge, txt = C.teal, C.teal, C.black
  elseif style == "mode" then
    -- Other flight modes remain neutral: white text on the black panel.
    fill, edge, txt = C.panel, C.line, C.text
  elseif active then
    local activeColor = level >= 2 and C.red or C.amber
    if blinkOn then fill, edge, txt = activeColor, activeColor, C.black
    else edge, txt = activeColor, activeColor end
  end

  lcd.setColor(CUSTOM_COLOR, fill)
  lcd.drawFilledRectangle(x, y, w, h, CUSTOM_COLOR)
  -- Use a fixed light-gray outline so every annunciator remains visibly bounded.
  lcd.setColor(CUSTOM_COLOR, C.annBorder)
  lcd.drawRectangle(x, y, w, h, 1, CUSTOM_COLOR)
  centeredText(x, y + 5, w, label, txt, SMLSIZE)
end

local function alertPulse(count, frequency)
  for i = 1, count do
    local pause = (i < count) and 35 or 0
    if type(playHaptic) == "function" then pcall(playHaptic, 25, pause, 0) end
    if type(playTone) == "function" then pcall(playTone, frequency, 90, pause) end
  end
end

-- Standard English EdgeTX sound-pack filenames. If a particular sound pack
-- does not contain one of these files, the tone pattern still provides the
-- warning, so the alarm never silently fails.
local function playBatteryTrack(kind)
  if type(playFile) ~= "function" then return false end
  local file = kind == "critical"
    and "/SOUNDS/en/SYSTEM/critbat.wav"
    or  "/SOUNDS/en/SYSTEM/lowbat.wav"
  local ok = pcall(playFile, file)
  return ok
end

-- Battery-only audio behavior:
--   * LOW BAT: one announcement/pulse when first crossed.
--   * CRIT BAT: play the Critical Battery track once, then repeat the same
--     four-pulse critical alarm cadence used by EdgeDeck every five seconds.
-- The latch resets only after the pack recovers clearly above the warning
-- threshold (or is disconnected), preventing repeated chatter from voltage sag.
local function updateBatteryAudio(w, battLevel, cellV, warnV, now)
  if opt(w, "BatAlarm", 1) == 0 then
    w.battAudioState = 0
    w.lastCritAlarm = 0
    return
  end

  local previous = w.battAudioState or 0

  if battLevel >= 2 then
    if previous < 2 then
      playBatteryTrack("critical")
      alertPulse(4, 880)
      w.lastCritAlarm = now
    elseif (now - (w.lastCritAlarm or 0)) >= 500 then
      alertPulse(4, 880)
      w.lastCritAlarm = now
    end
    w.battAudioState = 2
    w.battMissingSince = nil
    return
  end

  if battLevel == 1 then
    if previous == 0 then
      playBatteryTrack("low")
      alertPulse(2, 660)
    end
    -- Do not downgrade a critical latch to low while voltage is bouncing.
    if previous < 2 then w.battAudioState = 1 end
    w.battMissingSince = nil
    return
  end

  if cellV == nil then
    if not w.battMissingSince then w.battMissingSince = now end
    if (now - w.battMissingSince) >= 300 then
      w.battAudioState = 0
      w.lastCritAlarm = 0
    end
  elseif cellV >= (warnV + 0.10) then
    w.battAudioState = 0
    w.lastCritAlarm = 0
    w.battMissingSince = nil
  end
end

local function create(zone, opts)
  return { zone=zone, options=opts, cells=0, lastAtt=0, lastTelem=0,
    lastPitch=nil, lastRoll=nil, lastYaw=nil, lastYawTime=nil, yawRate=0,
    battAudioState=0, lastCritAlarm=0, battMissingSince=nil,
    modelBitmap=nil, modelBitmapName=nil }
end

local function update(w, opts)
  w.options = opts
end

local function sourceActive(source)
  if source == nil or source == 0 then return false end
  local ok, value = pcall(getValue, source)
  if not ok then return false end
  if type(value) == "boolean" then return value end
  return type(value) == "number" and value > 0
end

local function refresh(w, event, touchState)
  local W = LCD_W or w.zone.w or 320
  local H = LCD_H or w.zone.h or 240
  lcd.clear(C.black)

  -- This first release is laid out specifically for 320x240. Center it if larger.
  local ox = math.max(0, math.floor((W - 320) / 2))
  local oy = math.max(0, math.floor((H - 240) / 2))
  local now = getTime()
  local lampTest = sourceActive(opt(w, "LampTest", 0))

  local packV = readNum(SENSOR.rxBat)
  local curr = readNum(SENSOR.curr)
  local capa = readNum(SENSOR.capa)
  local lq = readNum(SENSOR.lq)
  local rssi1 = readNum(SENSOR.rssi1)
  local rssi2 = readNum(SENSOR.rssi2)
  local rsnr = readNum(SENSOR.rsnr)
  local ant = readNum(SENSOR.ant)
  local rfmd = readNum(SENSOR.rfmd)
  local tpwr = readNum(SENSOR.tpwr)
  local trss = readNum(SENSOR.trss)
  local tqly = readNum(SENSOR.tqly)
  local tsnr = readNum(SENSOR.tsnr)
  local pitchRaw = readAttitudeNum(SENSOR.pitch)
  local rollRaw = readAttitudeNum(SENSOR.roll)
  local yawRaw = readAttitudeNum(SENSOR.yaw)
  -- Betaflight CRSF Ptch/Roll sensors are expressed in radians. Convert once
  -- here because the drawing code and displayed labels use degrees.
  local pitch = pitchRaw and math.deg(pitchRaw) or nil
  local roll = rollRaw and math.deg(rollRaw) or nil
  local yaw = yawRaw and math.deg(yawRaw) or nil
  if yaw ~= nil then
    if w.lastYaw ~= nil and w.lastYawTime ~= nil and now > w.lastYawTime then
      local dy = yaw - w.lastYaw
      while dy > 180 do dy = dy - 360 end
      while dy < -180 do dy = dy + 360 end
      local dt = (now - w.lastYawTime) / 100
      if dt > 0 then
        local instant = clamp(dy / dt, -999, 999)
        w.yawRate = (w.yawRate or 0) * 0.65 + instant * 0.35
      end
    end
    w.lastYaw, w.lastYawTime = yaw, now
  end
  local mode, armed, failsafe = stripMode(readStr(SENSOR.fm))

  local telemUp = lq ~= nil and lq > 0
  if telemUp then w.lastTelem = now end
  local telemStale = (now - (w.lastTelem or 0)) > 200

  local attValid = pitch ~= nil and roll ~= nil and telemUp
  if attValid then
    w.lastAtt = now
    w.lastPitch = pitch
    w.lastRoll = roll
  end
  local attStale = (now - (w.lastAtt or 0)) > 100
  attValid = attValid and not attStale
  -- Keep the last good attitude for drawing during a single dropped frame. The
  -- ATT LOST annunciator still activates after the one-second stale timeout.
  if pitch == nil then pitch = w.lastPitch end
  if roll == nil then roll = w.lastRoll end

  w.cells = detectCells(packV, opt(w, "Cells", 0), w.cells)
  local cellV = (packV and w.cells > 0) and packV / w.cells or nil
  local warnV = opt(w, "VWarn", 350) / 100
  local critV = opt(w, "VCrit", 330) / 100
  local lqWarn = opt(w, "LQWarn", 70)
  local lqCrit = opt(w, "LQCrit", 40)

  -- A cached battery value can remain after the CRSF link is lost. Only treat
  -- battery telemetry as live while the link itself is currently up.
  local battTelemetryValid = cellV ~= nil and telemUp and not telemStale
  local battLevel = 0
  if battTelemetryValid then
    if cellV <= critV then battLevel = 2 elseif cellV <= warnV then battLevel = 1 end
  end
  local lqLevel = 0
  if lq ~= nil then
    if lq <= lqCrit then lqLevel = 2 elseif lq <= lqWarn then lqLevel = 1 end
  end
  local blinkOn = (math.floor(now / 50) % 2) == 0

  -- Lamp test substitutes representative worst-case display values while the
  -- assigned switch is held. It is visual only: real telemetry state, cached
  -- values, and battery audio alarms are not changed or triggered.
  local displayPackV, displayCells, displayCellV, displayCapa = packV, w.cells, cellV, capa
  local displayLq, displayRsnr, displayRssi1, displayRssi2 = lq, rsnr, rssi1, rssi2
  local displayBattLevel, displayLqLevel = battLevel, lqLevel
  local displayBattValid = battTelemetryValid
  local displayArmed, displayFailsafe, displayTelemStale = armed, failsafe, telemStale
  local displayMode = mode
  if lampTest then
    displayCells = w.cells > 0 and w.cells or opt(w, "Cells", 0)
    if displayCells == 0 then displayCells = 4 end
    displayCellV = math.max(2.80, critV - 0.10)
    displayPackV = displayCellV * displayCells
    displayCapa = 9999
    displayLq, displayRsnr = 0, -20
    displayRssi1, displayRssi2 = -130, -130
    displayBattLevel, displayLqLevel = 2, 2
    displayBattValid = true
    displayArmed, displayFailsafe, displayTelemStale = true, true, true
    displayMode = "AIR MODE"
  end

  -- Header: model left, clock centered, transmitter battery right.
  panel(ox, oy, 320, 25)
  drawText(ox + 5, oy + 5, string.sub(modelName(), 1, 12), C.text, SMLSIZE)
  centeredText(ox + 92, oy + 5, 136, dateTimeText(), C.text, SMLSIZE)
  local txPct = txBatteryPercent()
  local txText = txPct and string.format("TX %d%%", txPct) or "TX --%"
  drawText(ox + 315, oy + 5, txText, txBatteryColor(txPct), SMLSIZE + RIGHT)

  -- Main instruments: battery left, expanded attitude display center, link right.
  drawBattery(ox, oy + 27, 68, 142, displayPackV, displayCells, displayCellV, warnV, critV, displayCapa)
  drawModelImage(w, ox + 70, oy + 27, 180, 142)

  local displayRssi = nil
  if displayRssi1 ~= nil and displayRssi2 ~= nil then displayRssi = math.max(displayRssi1, displayRssi2)
  else displayRssi = displayRssi1 or displayRssi2 end
  local rate = rfmd and (RF_RATE[rfmd] or rfmd) or nil
  drawMetric(ox + 252, oy + 27, 68, 46, "LQ", displayLq and string.format("%d", displayLq) or "--", "%", lqSignalColor(displayLq))
  drawMetric(ox + 252, oy + 75, 68, 46, "SNR", displayRsnr and string.format("%+d", displayRsnr) or "--", "dB", snrSignalColor(displayRsnr, rate, rfmd))
  drawMetric(ox + 252, oy + 123, 68, 46, "RSSI", displayRssi and string.format("%d", displayRssi) or "--", "dBm", rssiSignalColor(displayRssi, rfmd, rate))

  -- Warning grid: 3 x 2
  local ay = oy + 171
  local aw, ah = 106, 27
  local battLabel = displayBattLevel == 2 and "CRITICAL BAT" or (displayBattLevel == 1 and "LOW BAT" or "BATTERY")
  drawAnnunciator(ox,       ay,      aw, ah, battLabel, displayBattLevel, blinkOn, displayBattValid and displayBattLevel == 0 and "battery_good" or nil)
  drawAnnunciator(ox + 107, ay,      aw, ah, displayArmed and "ARMED" or "DISARMED", 0, blinkOn, displayArmed and "armed" or "safe")
  drawAnnunciator(ox + 214, ay,      aw, ah, displayMode == "ACRO" and "AIR MODE" or displayMode, 0, blinkOn, (displayMode == "ACRO" or displayMode == "AIR MODE") and "airmode" or "mode")
  drawAnnunciator(ox,       ay + 28, aw, ah, "FAILSAFE", displayFailsafe and 2 or 0, blinkOn)
  local lowLinkAnnunciator = (displayLqLevel > 0) and 1 or 0
  drawAnnunciator(ox + 107, ay + 28, aw, ah, "LOW LINK", lowLinkAnnunciator, blinkOn)
  drawAnnunciator(ox + 214, ay + 28, aw, ah, "TELEM LOST", displayTelemStale and 2 or 0, blinkOn)

  if not lampTest then
    updateBatteryAudio(w, battLevel, battTelemetryValid and cellV or nil, warnV, now)
  end

  -- Footer telemetry strip: RF packet rate and transmitter power.
  panel(ox, oy + 227, 320, 13)
  local footer = string.format("RF: %s Hz                 POWER: %s mW",
    rate and string.format("%d", rate) or "--",
    tpwr and string.format("%d", tpwr) or "--")
  centeredText(ox, oy + 228, 320, footer, C.text, SMLSIZE)
end

local function background(w)
  -- Keep no expensive state while hidden; telemetry is read on the next refresh.
end

return {
  name = NAME,
  options = options,
  create = create,
  update = update,
  refresh = refresh,
  background = background,
}
