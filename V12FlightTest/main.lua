-- V12FlightTest v1.0
-- Compact 320x240 flight-test dashboard for EdgeTX color radios.
-- Betaflight + ExpressLRS/CRSF telemetry.
-- Install as: /WIDGETS/V12FlightTest/main.lua

local NAME = "V12FlightTest"

local options = {
  { "LQWarn", VALUE, 70, 0, 100 },
  { "LQCrit", VALUE, 40, 0, 100 },
  { "VWarn",  VALUE, 350, 280, 420 }, -- centivolts/cell
  { "VCrit",  VALUE, 330, 280, 420 },
  { "Cells",  VALUE, 0, 0, 8 },       -- 0 = auto detect
  { "BatAlarm", BOOL, 1 },              -- battery audio warnings on/off
}

local C = {
  black  = lcd.RGB(0, 0, 0),
  panel  = lcd.RGB(0, 0, 0),
  line   = lcd.RGB(112, 122, 128),
  dim    = lcd.RGB(68, 76, 82),
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

local function drawBattery(x, y, w, h, packV, cells, cellV, warnV, critV)
  panel(x, y, w, h)
  centeredText(x, y + 3, w, "BATTERY", C.text, SMLSIZE)

  local bx, by = x + 14, y + 24
  local bw, bh = w - 28, h - 66
  lcd.setColor(CUSTOM_COLOR, C.line)
  lcd.drawRectangle(bx, by, bw, bh, 2, CUSTOM_COLOR)
  lcd.drawFilledRectangle(bx + math.floor(bw/3), by - 4, math.floor(bw/3), 4, CUSTOM_COLOR)

  local pct = 0
  if cellV and cellV > 0 then pct = clamp((cellV - 3.20) / 1.00, 0, 1) end
  local fillH = math.floor((bh - 6) * pct + 0.5)
  local levelColor = C.green
  if not cellV or cellV <= critV then levelColor = C.red
  elseif cellV <= warnV then levelColor = C.amber end
  lcd.setColor(CUSTOM_COLOR, levelColor)
  lcd.drawFilledRectangle(bx + 3, by + bh - 3 - fillH, bw - 6, fillH, CUSTOM_COLOR)

  centeredText(x, y + h - 38, w, fmt(packV, "%.1fV"), C.text, MIDSIZE)
  centeredText(x, y + h - 19, w, cells > 0 and fmt(cellV, "%.2f/c") or "--/c", levelColor, SMLSIZE)
end

local function drawMetric(x, y, w, h, label, value, unit, valueColor)
  panel(x, y, w, h)
  drawText(x + 5, y + 2, label, C.dim, SMLSIZE)
  local val = value or "--"
  centeredText(x, y + 14, w, val, valueColor or C.text, MIDSIZE)
  if unit and unit ~= "" then drawText(x + w - 4, y + h - 14, unit, C.dim, SMLSIZE + RIGHT) end
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

local function drawHorizon(x, y, w, h, pitch, roll, yawRate, valid)
  panel(x, y, w, h)
  centeredText(x, y + 3, w, "ATTITUDE", C.text, SMLSIZE)

  local hx1, hx2 = x + 5, x + w - 6
  local hy1, hy2 = y + 20, y + h - 19
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
    local hcy = cy + pitchPx

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
          local horizonY = hcy - ((px - cx) * sr / cr)
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
          local boundaryX = cx
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

    -- Pitch ladder uses clean 10-degree spacing through +/-60 degrees.
    -- Each complete rung is clipped geometrically to the viewport, so marks
    -- leave the display naturally instead of collecting at its edges.
    lcd.setColor(CUSTOM_COLOR, C.text)
    for deg = -60, 60, 10 do
      if deg ~= 0 then
        local offset = deg * 1.05
        local lx = cx + nx * offset
        local ly = hcy + ny * offset
        local len = 15
        local ax, ay = lx - tx * len, ly - ty * len
        local bx, by = lx + tx * len, ly + ty * len
        local cax, cay, cbx, cby = clipLine(ax, ay, bx, by, hx1, hy1, hx2, hy2)
        if cax then
          lcd.drawLine(
            math.floor(cax + 0.5), math.floor(cay + 0.5),
            math.floor(cbx + 0.5), math.floor(cby + 0.5),
            SOLID, CUSTOM_COLOR)
        end
      end
    end

    -- Fixed aircraft reference symbol.
    lcd.setColor(CUSTOM_COLOR, C.text)
    lcd.drawLine(cx - 18, cy, cx - 5, cy, SOLID, CUSTOM_COLOR)
    lcd.drawLine(cx + 5, cy, cx + 18, cy, SOLID, CUSTOM_COLOR)
    lcd.drawLine(cx - 5, cy, cx, cy + 4, SOLID, CUSTOM_COLOR)
    lcd.drawLine(cx + 5, cy, cx, cy + 4, SOLID, CUSTOM_COLOR)
    lcd.drawLine(cx, cy - 3, cx, cy + 3, SOLID, CUSTOM_COLOR)

    centeredText(x, y + h - 17, w,
      string.format("P%+.0f R%+.0f Y%+.0f/s", pitch, roll, yawRate or 0), C.dim, SMLSIZE)
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

  if style == "safe" then
    edge, txt = C.green, C.green
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
  lcd.setColor(CUSTOM_COLOR, edge)
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
    splashUntil=(getTime and getTime() or 0) + 100,
    lastPitch=nil, lastRoll=nil, lastYaw=nil, lastYawTime=nil, yawRate=0,
    battAudioState=0, lastCritAlarm=0, battMissingSince=nil }
end

local function update(w, opts)
  w.options = opts
end

local function refresh(w, event, touchState)
  local W = LCD_W or w.zone.w or 320
  local H = LCD_H or w.zone.h or 240
  lcd.clear(C.black)

  -- This first release is laid out specifically for 320x240. Center it if larger.
  local ox = math.max(0, math.floor((W - 320) / 2))
  local oy = math.max(0, math.floor((H - 240) / 2))
  local now = getTime()

  -- Brief startup identification screen.
  if w.splashUntil and now < w.splashUntil then
    lcd.setColor(CUSTOM_COLOR, C.teal)
    lcd.drawRectangle(ox + 20, oy + 35, 280, 170, 2, CUSTOM_COLOR)
    centeredText(ox, oy + 78, 320, "V12FlightTest", C.teal, DBLSIZE)
    centeredText(ox, oy + 121, 320, "PROFESSIONAL FLIGHT DISPLAY", C.text, SMLSIZE)
    centeredText(ox, oy + 153, 320, "VERSION 1.0", C.dim, SMLSIZE)
    return
  end

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

  local battLevel = 0
  if cellV then
    if cellV <= critV then battLevel = 2 elseif cellV <= warnV then battLevel = 1 end
  end
  local lqLevel = 0
  if lq ~= nil then
    if lq <= lqCrit then lqLevel = 2 elseif lq <= lqWarn then lqLevel = 1 end
  end
  local blinkOn = (math.floor(now / 50) % 2) == 0

  -- Header: model left, clock centered, transmitter battery right.
  panel(ox, oy, 320, 25)
  drawText(ox + 5, oy + 5, string.sub(modelName(), 1, 12), C.text, SMLSIZE)
  centeredText(ox + 92, oy + 5, 136, dateTimeText(), C.text, SMLSIZE)
  local txPct = txBatteryPercent()
  local txText = txPct and string.format("TX %d%%", txPct) or "TX --%"
  drawText(ox + 315, oy + 5, txText, txBatteryColor(txPct), SMLSIZE + RIGHT)

  -- Main instruments: smaller attitude display with bordered telemetry cells.
  drawBattery(ox, oy + 27, 68, 142, packV, w.cells, cellV, warnV, critV)
  drawHorizon(ox + 70, oy + 27, 120, 96, pitch or 0, roll or 0, w.yawRate or 0, attValid)
  drawMetric(ox + 70,  oy + 125, 59, 44, "CURRENT", curr and string.format("%.1f", curr) or "--", "A", C.text)
  drawMetric(ox + 131, oy + 125, 59, 44, "USED", capa and string.format("%.0f", capa) or "--", "mAh", C.text)

  drawMetric(ox + 192, oy + 27, 63, 46, "LQ", lq and string.format("%d", lq) or "--", "%", lqLevel == 2 and C.red or (lqLevel == 1 and C.amber or C.text))
  drawMetric(ox + 257, oy + 27, 63, 46, "1RSS", rssi1 and string.format("%d", rssi1) or "--", "dBm", C.text)
  drawMetric(ox + 192, oy + 75, 63, 46, "RSNR", rsnr and string.format("%d", rsnr) or "--", "dB", C.text)
  drawMetric(ox + 257, oy + 75, 63, 46, "2RSS", rssi2 and string.format("%d", rssi2) or "--", "dBm", C.text)
  local rate = rfmd and (RF_RATE[rfmd] or rfmd) or nil
  drawMetric(ox + 192, oy + 123, 63, 46, "RF", rate and string.format("%d", rate) or "--", "Hz", C.text)
  drawMetric(ox + 257, oy + 123, 63, 46, "POWER", tpwr and string.format("%d", tpwr) or "--", "mW", C.text)

  -- Warning grid: 3 x 2
  local ay = oy + 171
  local aw, ah = 106, 27
  drawAnnunciator(ox,       ay,      aw, ah, "LOW BAT", battLevel == 1 and 1 or 0, blinkOn)
  drawAnnunciator(ox + 107, ay,      aw, ah, armed and "ARM" or "SAFE", 0, blinkOn, armed and "armed" or "safe")
  drawAnnunciator(ox + 214, ay,      aw, ah, mode == "ACRO" and "AIR MODE" or mode, 0, blinkOn, mode == "ACRO" and "airmode" or "mode")
  drawAnnunciator(ox,       ay + 28, aw, ah, "CRIT BAT", battLevel == 2 and 2 or 0, blinkOn)
  drawAnnunciator(ox + 107, ay + 28, aw, ah, "LOW LINK", lqLevel, blinkOn)
  drawAnnunciator(ox + 214, ay + 28, aw, ah, "TELEM LOST", telemStale and 2 or 0, blinkOn)

  updateBatteryAudio(w, battLevel, cellV, warnV, now)

  -- Footer telemetry strip
  panel(ox, oy + 227, 320, 13)
  local footer = string.format("ANT:%s   DL RSS:%s   DL LQ:%s%%   DL SNR:%s",
    ant and tostring(ant) or "-",
    trss and string.format("%.0f", trss) or "--",
    tqly and string.format("%.0f", tqly) or "--",
    tsnr and string.format("%.0f", tsnr) or "--")
  centeredText(ox, oy + 228, 320, footer, C.dim, SMLSIZE)
  drawText(ox + 317, oy + 228, "v1.0", C.dim, SMLSIZE + RIGHT)
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
