-- Granule: a falling-sand sandbox. Rendering, UI, input and the 60 Hz loop.
local ffi = require("ffi")
local bit = require("bit")
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift
local floor, min, max = math.floor, math.min, math.max

local S = require("sim")
local I = S.ids
local W, H, N = S.W, S.H, S.N

local TICK = 1 / 60           -- simulation AND frame rate cap
local CELL = 2                -- screen pixels per cell
local SIM_W, SIM_H = W * CELL, H * CELL
local SIDE_W = 160
local BAR_H = 28
local WIN_W, WIN_H = SIM_W + SIDE_W, SIM_H + BAR_H

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local paused, stepOnce = false, false
local heatView = false
local showHelp = false
local brush, brushSquare = 4, false
local primary, secondary           -- selected items (element def or tool)
local category = 2
local mode, modeBtn                -- "draw" | "line" | "rect", which mouse button
local startX, startY, lastX, lastY = 0, 0, 0, 0
local toast, toastTime = nil, 0
local simMs, renderMs, partCount = 0, 0, 0
local hoverText = nil
local fonts = {}

local imgData, img, pix
local pal, fireLUT, heatLUT, BG

---------------------------------------------------------------------------
-- Sidebar content
---------------------------------------------------------------------------
local tools = {
  { tool="erase", name="ERASE", color={30,30,34},   desc="Remove particles." },
  { tool="heat",  name="HEAT",  color={255,90,30},  desc="Heat particles under the brush." },
  { tool="cool",  name="COOL",  color={70,150,255}, desc="Cool particles under the brush." },
}
local categories = {
  { name="Solids" }, { name="Powders" }, { name="Liquids" }, { name="Gases" }, { name="Tools", items=tools },
}
for _, c in ipairs(categories) do
  if not c.items then
    c.items = {}
    for id = 1, S.NUM_ELEMENTS do
      local e = S.elements[id]
      if e.cat == c.name then table.insert(c.items, e) end
    end
  end
end

local function toastMsg(s) toast, toastTime = s, 2.0 end

---------------------------------------------------------------------------
-- Colour tables (packed little-endian RGBA as int32: 0xAABBGGRR)
---------------------------------------------------------------------------
local ALPHA = lshift(255, 24)
local function rgba(r, g, b)
  r = max(0, min(255, floor(r))); g = max(0, min(255, floor(g))); b = max(0, min(255, floor(b)))
  return bor(ALPHA, lshift(b, 16), lshift(g, 8), r)
end
local function lerp(a, b, t) return a + (b - a) * t end
local function gradient(stops, v)
  for k = 1, #stops - 1 do
    local a, b = stops[k], stops[k + 1]
    if v <= b[1] then
      local t = (v - a[1]) / (b[1] - a[1])
      if t < 0 then t = 0 end
      return lerp(a[2], b[2], t), lerp(a[3], b[3], t), lerp(a[4], b[4], t)
    end
  end
  local l = stops[#stops]; return l[2], l[3], l[4]
end

local function buildPalettes()
  BG = rgba(12, 12, 16)
  pal = ffi.new("int32_t[?]", 256 * 8)
  for id = 1, S.NUM_ELEMENTS do
    local c = S.elements[id].color
    for s = 0, 7 do
      local f = 0.86 + s * 0.04
      pal[id * 8 + s] = rgba(c[1] * f, c[2] * f, c[3] * f)
    end
  end
  fireLUT = ffi.new("int32_t[128]")
  local fs = { {0, 70,8,0}, {12, 200,50,0}, {30, 255,150,20}, {55, 255,230,120}, {127, 255,250,200} }
  for k = 0, 127 do fireLUT[k] = rgba(gradient(fs, k)) end
  -- heat view: index = (T + 100) / 4, covering -100C .. ~4000C
  heatLUT = ffi.new("int32_t[1024]")
  local hs = { {-100, 20,0,90}, {0, 0,60,255}, {22, 0,170,230}, {100, 0,220,80},
               {300, 230,230,0}, {800, 255,70,0}, {1600, 255,0,120}, {4000, 255,255,255} }
  for k = 0, 1023 do heatLUT[k] = rgba(gradient(hs, k * 4 - 100)) end
end

---------------------------------------------------------------------------
-- Rendering the grid straight into an ImageData through an FFI pointer
---------------------------------------------------------------------------
local types, temps, lifes, shades = S.types, S.temp, S.life, S.shade
local P_kind = S.P_kind
local FIRE, LAVA, K_GAS = I.FIRE, I.LAVA, S.K_GAS
local random = math.random

local function renderGrid()
  local count = 0
  if heatView then
    for i = 0, N - 1 do
      local t = types[i]
      if t == 0 then pix[i] = BG
      else
        count = count + 1
        local k = floor((temps[i] + 100) * 0.25)
        if k < 0 then k = 0 elseif k > 1023 then k = 1023 end
        pix[i] = heatLUT[k]
      end
    end
  else
    for i = 0, N - 1 do
      local t = types[i]
      if t == 0 then pix[i] = BG
      else
        count = count + 1
        if t == FIRE then
          local l = lifes[i]; if l > 127 then l = 127 end
          pix[i] = fireLUT[l]
        elseif t == LAVA then
          pix[i] = pal[t * 8 + random(2, 7)]          -- shimmer
        else
          local T = temps[i]
          if T > 525 and P_kind[t] ~= K_GAS then        -- incandescent glow
            local c = pal[t * 8 + shades[i]]
            local a = (T - 525) * 0.0012; if a > 0.85 then a = 0.85 end
            local r, g, b = band(c, 255), band(rshift(c, 8), 255), band(rshift(c, 16), 255)
            r = floor(r + (255 - r) * a); g = floor(g + (110 - g) * a); b = floor(b * (1 - a))
            pix[i] = bor(ALPHA, lshift(b, 16), lshift(g, 8), r)
          else
            pix[i] = pal[t * 8 + shades[i]]
          end
        end
      end
    end
  end
  partCount = count
  img:replacePixels(imgData)
end

---------------------------------------------------------------------------
-- Drawing tools
---------------------------------------------------------------------------
local function applyAt(x, y, item)
  local tl = item.tool
  if tl == nil then S.place(x, y, item.id)
  elseif tl == "erase" then S.erase(x, y)
  elseif tl == "heat" then S.heat(x, y, 8)
  elseif tl == "cool" then S.heat(x, y, -8) end
end

local function stamp(cx, cy, item)
  local r = brush
  local rr = r * r + r
  for dy = -r, r do
    local y = cy + dy
    if y >= 0 and y < H then
      for dx = -r, r do
        local x = cx + dx
        if x >= 0 and x < W and (brushSquare or dx * dx + dy * dy <= rr) then applyAt(x, y, item) end
      end
    end
  end
end

local function stampLine(x0, y0, x1, y1, item)
  local dx, dy = x1 - x0, y1 - y0
  local steps = max(math.abs(dx), math.abs(dy))
  if steps == 0 then stamp(x0, y0, item); return end
  -- with big brushes, we don't need to stamp every single cell along the line
  local stride = max(1, floor(brush / 2))
  for s = 0, steps, stride do
    stamp(floor(x0 + dx * s / steps + 0.5), floor(y0 + dy * s / steps + 0.5), item)
  end
  stamp(x1, y1, item)
end

local function fillRect(x0, y0, x1, y1, item)
  if x0 > x1 then x0, x1 = x1, x0 end
  if y0 > y1 then y0, y1 = y1, y0 end
  x0, y0 = max(0, x0), max(0, y0); x1, y1 = min(W - 1, x1), min(H - 1, y1)
  for y = y0, y1 do for x = x0, x1 do applyAt(x, y, item) end end
end

local function mouseCell()
  local mx, my = love.mouse.getPosition()
  local cx, cy = floor(mx / CELL), floor(my / CELL)
  return max(0, min(W - 1, cx)), max(0, min(H - 1, cy)), mx < SIM_W and my < SIM_H
end

---------------------------------------------------------------------------
-- Actions (shared by keyboard and buttons)
---------------------------------------------------------------------------
local function doSave()
  local ok = love.filesystem.write("quicksave.grnl", S.serialize())
  toastMsg(ok and "Saved (F9 to load)" or "Save failed")
end
local function doLoad()
  local data = love.filesystem.read("quicksave.grnl")
  if data and S.deserialize(data) then toastMsg("Loaded quicksave") else toastMsg("No quicksave found") end
end
local function doClear() S.snapshot(); S.clear(); toastMsg("Cleared (Ctrl+Z to undo)") end

local buttons = {
  { label=function() return paused and "Resume" or "Pause" end, key="Space", fn=function() paused = not paused end, on=function() return paused end },
  { label=function() return "Step" end, key="F", fn=function() paused = true; stepOnce = true end },
  { label=function() return "Heat view" end, key="V", fn=function() heatView = not heatView end, on=function() return heatView end },
  { label=function() return brushSquare and "Brush: Square" or "Brush: Circle" end, key="Tab", fn=function() brushSquare = not brushSquare end },
  { label=function() return "Undo" end, key="Ctrl+Z", fn=function() if S.undo() then toastMsg("Undo") end end },
  { label=function() return "Clear" end, key="Del", fn=doClear },
  { label=function() return "Save" end, key="F5", fn=doSave },
  { label=function() return "Load" end, key="F9", fn=doLoad },
  { label=function() return "Help" end, key="F1", fn=function() showHelp = not showHelp end, on=function() return showHelp end },
}

---------------------------------------------------------------------------
-- Layout helpers / hit testing
---------------------------------------------------------------------------
local function catRect(k)
  local col, row = (k - 1) % 2, floor((k - 1) / 2)
  return SIM_W + 6 + col * 75, 30 + row * 24, 72, 21
end
local function itemRect(k) return SIM_W + 6, 108 + (k - 1) * 27, SIDE_W - 12, 24 end
local function buttonRects()
  local rects, x = {}, 6
  for k, b in ipairs(buttons) do
    local w = fonts.ui:getWidth(b.label()) + 14
    rects[k] = { x, SIM_H + 4, w, BAR_H - 8 }
    x = x + w + 4
  end
  return rects
end
local function inside(px, py, x, y, w, h) return px >= x and px < x + w and py >= y and py < y + h end

---------------------------------------------------------------------------
-- LÖVE callbacks
---------------------------------------------------------------------------
function love.load()
  if not love.image.newImageData(1, 1).getFFIPointer then
    error("Granule needs LOVE 11.3 or newer (ImageData:getFFIPointer missing).")
  end
  if jit then jit.on() end
  love.graphics.setDefaultFilter("nearest", "nearest")
  love.keyboard.setKeyRepeat(true)
  fonts.ui = love.graphics.newFont(12)
  fonts.small = love.graphics.newFont(11)
  fonts.title = love.graphics.newFont(16)
  imgData = love.image.newImageData(W, H, "rgba8")
  img = love.graphics.newImage(imgData)
  img:setFilter("nearest", "nearest")
  pix = ffi.cast("int32_t*", imgData:getFFIPointer())
  buildPalettes()
  primary, secondary = S.elements[I.SAND], tools[1]

  -- a small starter scene so the window isn't empty
  for x = 0, W - 1 do S.place(x, H - 1, I.WALL); S.place(x, H - 2, I.WALL) end
  for y = 200, H - 3 do S.place(60, y, I.WALL); S.place(61, y, I.WALL) end
  for y = 180, H - 3 do S.place(320, y, I.WALL); S.place(321, y, I.WALL) end
  for y = 240, H - 3 do for x = 62, 140 do S.place(x, y, I.WATR) end end
  for y = 230, H - 3 do for x = 250, 319 do S.place(x, y, (y < 250) and I.WOOD or I.OIL) end end
end

function love.update(dt)
  -- continuous drawing while a button is held
  if mode == "draw" then
    local cx, cy = mouseCell()
    local item = (modeBtn == 1) and primary or secondary
    stampLine(lastX, lastY, cx, cy, item)
    lastX, lastY = cx, cy
  end

  if not paused or stepOnce then
    local t0 = love.timer.getTime()
    S.step()
    simMs = simMs * 0.9 + (love.timer.getTime() - t0) * 1000 * 0.1
    stepOnce = false
  end

  if toastTime > 0 then toastTime = toastTime - dt end
end

local function drawPanel(x, y, w, h, hot, on)
  if on then love.graphics.setColor(0.25, 0.42, 0.75)
  elseif hot then love.graphics.setColor(0.24, 0.24, 0.29)
  else love.graphics.setColor(0.16, 0.16, 0.19) end
  love.graphics.rectangle("fill", x, y, w, h, 3, 3)
end

function love.draw()
  local t0 = love.timer.getTime()
  renderGrid()
  local g = love.graphics
  g.setColor(1, 1, 1)
  g.draw(img, 0, 0, 0, CELL, CELL)

  local mx, my = love.mouse.getPosition()
  local cx, cy, overSim = mouseCell()
  hoverText = nil

  -- brush / shape previews
  g.setLineWidth(1)
  if mode == "line" then
    g.setColor(1, 1, 1, 0.7)
    g.line((startX + 0.5) * CELL, (startY + 0.5) * CELL, (cx + 0.5) * CELL, (cy + 0.5) * CELL)
  elseif mode == "rect" then
    g.setColor(1, 1, 1, 0.7)
    local x0, y0 = min(startX, cx), min(startY, cy)
    g.rectangle("line", x0 * CELL, y0 * CELL, (math.abs(cx - startX) + 1) * CELL, (math.abs(cy - startY) + 1) * CELL)
  end
  if overSim and mode ~= "rect" then
    g.setColor(1, 1, 1, 0.45)
    local px, py = (cx + 0.5) * CELL, (cy + 0.5) * CELL
    if brushSquare then
      g.rectangle("line", (cx - brush) * CELL, (cy - brush) * CELL, (2 * brush + 1) * CELL, (2 * brush + 1) * CELL)
    else
      g.circle("line", px, py, (brush + 0.5) * CELL, 32)
    end
  end

  -- sidebar
  g.setColor(0.09, 0.09, 0.11)
  g.rectangle("fill", SIM_W, 0, SIDE_W, WIN_H)
  g.setColor(0.3, 0.3, 0.36)
  g.line(SIM_W + 0.5, 0, SIM_W + 0.5, WIN_H)
  g.setFont(fonts.title); g.setColor(1, 0.85, 0.5)
  g.print("GRANULE", SIM_W + 8, 6)
  g.setFont(fonts.small)
  for k, c in ipairs(categories) do
    local x, y, w, h = catRect(k)
    local hot = inside(mx, my, x, y, w, h)
    drawPanel(x, y, w, h, hot, k == category)
    g.setColor(1, 1, 1)
    g.printf(c.name, x, y + 4, w, "center")
  end
  local items = categories[category].items
  for k, it in ipairs(items) do
    local x, y, w, h = itemRect(k)
    local hot = inside(mx, my, x, y, w, h)
    drawPanel(x, y, w, h, hot, false)
    g.setColor(it.color[1] / 255, it.color[2] / 255, it.color[3] / 255)
    g.rectangle("fill", x + 4, y + 4, 26, h - 8, 2, 2)
    if it == primary then g.setColor(1, 0.3, 0.3); g.setLineWidth(2); g.rectangle("line", x + 1, y + 1, w - 2, h - 2, 3, 3); g.setLineWidth(1) end
    if it == secondary then g.setColor(0.3, 0.6, 1); g.rectangle("line", x + 3, y + 3, w - 6, h - 6, 3, 3) end
    g.setColor(1, 1, 1)
    g.print(it.name, x + 38, y + 5)
    g.setColor(0.6, 0.6, 0.65)
    g.print(k <= 10 and tostring(k % 10) or "", x + w - 14, y + 5)
    if hot then hoverText = it.name .. ": " .. it.desc end
  end
  -- selection summary
  local sy = SIM_H - 70
  g.setColor(0.6, 0.6, 0.65); g.print("Left / Right mouse:", SIM_W + 8, sy)
  g.setColor(1, 0.45, 0.45); g.print("L: " .. primary.name, SIM_W + 8, sy + 16)
  g.setColor(0.45, 0.7, 1);  g.print("R: " .. secondary.name, SIM_W + 80, sy + 16)
  g.setColor(0.6, 0.6, 0.65)
  g.print(string.format("Brush %d  (%s)", brush, brushSquare and "square" or "circle"), SIM_W + 8, sy + 34)

  -- bottom bar
  g.setColor(0.09, 0.09, 0.11)
  g.rectangle("fill", 0, SIM_H, SIM_W, BAR_H)
  g.setColor(0.3, 0.3, 0.36)
  g.line(0, SIM_H + 0.5, SIM_W, SIM_H + 0.5)
  g.setFont(fonts.ui)
  local rects = buttonRects()
  for k, b in ipairs(buttons) do
    local r = rects[k]
    local hot = inside(mx, my, r[1], r[2], r[3], r[4])
    drawPanel(r[1], r[2], r[3], r[4], hot, b.on and b.on())
    g.setColor(1, 1, 1)
    g.print(b.label(), r[1] + 7, r[2] + 3)
    if hot then hoverText = b.label() .. "  [" .. b.key .. "]" end
  end

  -- status line (top-left overlay)
  local active, total = S.activeChunks()
  local status = string.format("FPS %d  |  sim %.2f ms  |  draw %.2f ms  |  parts %d  |  chunks %d/%d%s",
    love.timer.getFPS(), simMs, renderMs, partCount, active, total, paused and "  |  PAUSED" or "")
  g.setFont(fonts.small)
  g.setColor(0, 0, 0, 0.55); g.rectangle("fill", 0, 0, fonts.small:getWidth(status) + 12, 18)
  g.setColor(paused and 1 or 0.85, paused and 0.6 or 0.85, paused and 0.4 or 0.9)
  g.print(status, 6, 3)

  -- hover info line
  local info = hoverText
  if not info and overSim then
    local t, T = S.get(cx, cy)
    info = string.format("%s   %.1f C   (%d, %d)", t == 0 and "EMPTY" or S.elements[t].name, t == 0 and S.AMBIENT or T, cx, cy)
  end
  if info then
    local w = fonts.small:getWidth(info) + 12
    g.setColor(0, 0, 0, 0.55); g.rectangle("fill", 0, SIM_H - 18, w, 18)
    g.setColor(1, 1, 1); g.print(info, 6, SIM_H - 15)
  end

  if toast and toastTime > 0 then
    g.setFont(fonts.ui)
    local w = fonts.ui:getWidth(toast) + 20
    g.setColor(0, 0, 0, 0.7); g.rectangle("fill", (SIM_W - w) / 2, 24, w, 24, 4, 4)
    g.setColor(1, 1, 0.7, min(1, toastTime * 2)); g.printf(toast, (SIM_W - w) / 2, 29, w, "center")
  end

  if showHelp then
    local lines = {
      { "CONTROLS" }, {},
      { "Left / Right mouse", "draw with primary / secondary" },
      { "Middle click, Alt+click", "pick element under cursor" },
      { "Shift + drag", "draw a line" },
      { "Ctrl + drag", "fill a box" },
      { "Wheel  or  [ ]", "brush size (hold Shift for x5)" },
      { "Tab", "circle / square brush" }, {},
      { "Space", "pause / resume" },
      { "F", "step one frame (pauses)" },
      { "V", "toggle heat view" },
      { "1-9, 0", "select item in current category" },
      { "Up/Down  or  Q/E", "previous / next category" },
      { "Ctrl+Z", "undo (press again = redo)" },
      { "Delete / Backspace", "clear everything" },
      { "F5 / F9", "quicksave / quickload" },
      { "F1  or  H", "toggle this help" },
      { "Esc", "quit" }, {},
      { "Sidebar: left-click = primary, right-click = secondary." },
    }
    g.setFont(fonts.ui)
    local w, h = 440, #lines * 16 + 24
    local x, y = (SIM_W - w) / 2, (SIM_H - h) / 2
    g.setColor(0.05, 0.05, 0.07, 0.93); g.rectangle("fill", x, y, w, h, 6, 6)
    g.setColor(0.4, 0.4, 0.5); g.rectangle("line", x, y, w, h, 6, 6)
    for k, l in ipairs(lines) do
      local ly = y + 12 + (k - 1) * 16
      if k == 1 then g.setColor(1, 0.85, 0.5) else g.setColor(0.65, 0.8, 1) end
      if l[1] then g.print(l[1], x + 16, ly) end
      if l[2] then g.setColor(0.9, 0.9, 0.92); g.print(l[2], x + 190, ly) end
    end
  end

  renderMs = renderMs * 0.9 + (love.timer.getTime() - t0) * 1000 * 0.1
end

local function selectItem(it, btn)
  if btn == 2 then secondary = it else primary = it end
end

function love.mousepressed(x, y, btn)
  if x < SIM_W and y < SIM_H then
    local cx, cy = floor(x / CELL), floor(y / CELL)
    local alt = love.keyboard.isDown("lalt", "ralt")
    if btn == 3 or (btn == 1 and alt) then             -- eyedropper
      local t = S.get(cx, cy)
      if t ~= 0 then
        primary = S.elements[t]
        for k, c in ipairs(categories) do if c.name == primary.cat then category = k end end
      end
      return
    end
    if btn ~= 1 and btn ~= 2 then return end
    if mode then return end
    S.snapshot()
    modeBtn = btn
    startX, startY, lastX, lastY = cx, cy, cx, cy
    if love.keyboard.isDown("lshift", "rshift") then mode = "line"
    elseif love.keyboard.isDown("lctrl", "rctrl") then mode = "rect"
    else mode = "draw"; stamp(cx, cy, btn == 1 and primary or secondary) end
    return
  end
  if x >= SIM_W then
    for k = 1, #categories do
      if inside(x, y, catRect(k)) then category = k; return end
    end
    for k, it in ipairs(categories[category].items) do
      if inside(x, y, itemRect(k)) then selectItem(it, btn); return end
    end
  elseif y >= SIM_H and btn == 1 then
    for k, r in ipairs(buttonRects()) do
      if inside(x, y, r[1], r[2], r[3], r[4]) then buttons[k].fn(); return end
    end
  end
end

function love.mousereleased(x, y, btn)
  if btn ~= modeBtn or not mode then return end
  local cx, cy = mouseCell()
  local item = (btn == 1) and primary or secondary
  if mode == "line" then stampLine(startX, startY, cx, cy, item)
  elseif mode == "rect" then fillRect(startX, startY, cx, cy, item) end
  mode, modeBtn = nil, nil
end

function love.wheelmoved(_, dy)
  local step = love.keyboard.isDown("lshift", "rshift") and 5 or 1
  brush = max(0, min(60, brush + (dy > 0 and step or (dy < 0 and -step or 0))))
end

function love.keypressed(key)
  local ctrl = love.keyboard.isDown("lctrl", "rctrl")
  if key == "escape" then
    if showHelp then showHelp = false else love.event.quit() end
  elseif key == "space" then paused = not paused
  elseif key == "f" then paused = true; stepOnce = true
  elseif key == "v" then heatView = not heatView
  elseif key == "tab" then brushSquare = not brushSquare
  elseif key == "[" then brush = max(0, brush - (love.keyboard.isDown("lshift", "rshift") and 5 or 1))
  elseif key == "]" then brush = min(60, brush + (love.keyboard.isDown("lshift", "rshift") and 5 or 1))
  elseif key == "z" and ctrl then if S.undo() then toastMsg("Undo") end
  elseif key == "delete" or key == "backspace" then doClear()
  elseif key == "f5" then doSave()
  elseif key == "f9" then doLoad()
  elseif key == "f1" or key == "h" then showHelp = not showHelp
  elseif key == "up" or key == "q" then category = (category - 2) % #categories + 1
  elseif key == "down" or key == "e" then category = category % #categories + 1
  elseif key:match("^%d$") then
    local n = tonumber(key); if n == 0 then n = 10 end
    local it = categories[category].items[n]
    if it then primary = it end
  end
end

---------------------------------------------------------------------------
-- Custom main loop: exactly one simulation tick + one frame, hard-capped at 60.
-- Sleeps most of the remaining frame time, then spins the last ~1.5 ms for
-- precise pacing (OS sleep granularity is coarse, especially on Windows).
---------------------------------------------------------------------------
function love.run()
  if love.load then love.load(love.arg.parseGameArguments(arg), arg) end
  if love.timer then love.timer.step() end
  local nextTime = love.timer.getTime()

  return function()
    if love.event then
      love.event.pump()
      for name, a, b, c, d, e, f in love.event.poll() do
        if name == "quit" then
          if not love.quit or not love.quit() then return a or 0 end
        end
        love.handlers[name](a, b, c, d, e, f)
      end
    end

    local dt = love.timer.step()
    love.update(math.min(dt, 0.1))

    if love.graphics and love.graphics.isActive() then
      love.graphics.origin()
      love.graphics.clear(0.05, 0.05, 0.06)
      love.draw()
      love.graphics.present()
    end

    nextTime = nextTime + TICK
    local now = love.timer.getTime()
    if nextTime <= now then
      nextTime = now                          -- running behind: don't try to "catch up"
    else
      local wait = nextTime - now
      if wait > 0.002 then love.timer.sleep(wait - 0.0015) end
      while love.timer.getTime() < nextTime do end
    end
  end
end
