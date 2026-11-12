-- sim.lua : the particle simulation core.
-- Pure LuaJIT (ffi + bit), no LÖVE dependency, so it can be benchmarked headless.
--
-- Performance notes:
--  * All per-cell state lives in flat FFI arrays (no Lua tables in the hot loop).
--  * Element properties are FFI lookup tables indexed by element id.
--  * The grid is split into 16x16 chunks; only chunks that changed recently are
--    simulated ("sleeping" regions cost ~nothing).
--  * A per-cell frame stamp prevents a particle from being moved twice per tick.
--  * Scan direction alternates per row/frame to remove left/right bias.

local ffi = require("ffi")
local bit = require("bit")
local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift
local random = math.random

local S = {}

-- Give the JIT more room: cellular automata are branchy, and the default limits
-- make LuaJIT give up and fall back to the interpreter.
if jit and jit.opt then
  pcall(jit.opt.start, "maxtrace=4000", "maxrecord=16000", "maxside=500",
        "maxsnap=2000", "maxmcode=65536", "hotexit=20", "maxirconst=2000")
end

local W, H = 384, 288          -- must be multiples of 16
local N = W * H
local CW, CH = W / 16, H / 16  -- chunk grid
local AMBIENT = 22.0
S.W, S.H, S.N, S.AMBIENT = W, H, N, AMBIENT

---------------------------------------------------------------------------
-- Element kinds and ids
---------------------------------------------------------------------------
local K_SOLID, K_POWDER, K_LIQUID, K_GAS = 1, 2, 3, 4
S.K_SOLID, S.K_POWDER, S.K_LIQUID, S.K_GAS = K_SOLID, K_POWDER, K_LIQUID, K_GAS

local NONE, WALL, WOOD, ICE, PLNT, SAND, STNE, GUNP,
      WATR, OIL, ACID, LAVA, FIRE, SMKE, STEM =
      0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
local EXPLODE = 255
S.ids = { NONE=NONE, WALL=WALL, WOOD=WOOD, ICE=ICE, PLNT=PLNT, SAND=SAND, STNE=STNE,
          GUNP=GUNP, WATR=WATR, OIL=OIL, ACID=ACID, LAVA=LAVA, FIRE=FIRE, SMKE=SMKE, STEM=STEM }

-- property tables (FFI so the JIT can turn them into plain loads)
local P_kind   = ffi.new("uint8_t[256]")
local P_dens   = ffi.new("float[256]")
local P_cond   = ffi.new("float[256]")
local P_amb    = ffi.new("float[256]")
local P_hiT    = ffi.new("float[256]")
local P_hiTo   = ffi.new("uint8_t[256]")
local P_loT    = ffi.new("float[256]")
local P_loTo   = ffi.new("uint8_t[256]")
local P_spawnT = ffi.new("float[256]")
local P_life0  = ffi.new("int16_t[256]")
local P_lifeR  = ffi.new("int16_t[256]")
local P_disp   = ffi.new("uint8_t[256]")
local P_burn   = ffi.new("float[256]")
S.P_kind = P_kind

local elements = {}
S.elements = elements

local function def(id, e)
  e.id = id
  elements[id] = e
  P_kind[id]   = e.kind
  P_dens[id]   = e.dens or 1
  P_cond[id]   = e.cond or 0
  P_amb[id]    = e.amb or 0
  P_hiT[id]    = e.hiT or 1e9
  P_hiTo[id]   = e.hiTo or id
  P_loT[id]    = e.loT or -1e9
  P_loTo[id]   = e.loTo or id
  P_spawnT[id] = e.temp or AMBIENT
  P_life0[id]  = e.life or 0
  P_lifeR[id]  = e.lifeR or 0
  P_disp[id]   = e.disp or 0
  P_burn[id]   = e.burn or 0
end

--   name/desc/cat/color are for the UI; everything else drives the physics.
def(WALL, { name="WALL",  cat="Solids",  color={112,112,124}, kind=K_SOLID, dens=1000,
  desc="Indestructible wall. Blocks everything, does not conduct heat." })
def(WOOD, { name="WOOD",  cat="Solids",  color={128,84,44},  kind=K_SOLID, dens=1000, cond=0.12,
  hiT=300, hiTo=FIRE, burn=0.015, desc="Solid. Burns slowly once above 300C." })
def(ICE,  { name="ICE",   cat="Solids",  color={170,215,255}, kind=K_SOLID, dens=1000, cond=0.45,
  temp=-30, hiT=1, hiTo=WATR, desc="Frozen water, spawns at -30C. Melts above 0C, freezes water it touches." })
def(PLNT, { name="PLNT",  cat="Solids",  color={40,170,55},  kind=K_SOLID, dens=1000, cond=0.25,
  hiT=200, hiTo=FIRE, burn=0.05, desc="Plant. Grows by drinking adjacent water. Flammable." })
def(SAND, { name="SAND",  cat="Powders", color={222,196,122}, kind=K_POWDER, dens=3, cond=0.3,
  desc="Powder. Piles up and sinks through liquids." })
def(STNE, { name="STNE",  cat="Powders", color={132,126,120}, kind=K_POWDER, dens=5, cond=0.4,
  hiT=1100, hiTo=LAVA, desc="Heavy rubble. Melts into lava above 1100C." })
def(GUNP, { name="GUNP",  cat="Powders", color={72,72,62},   kind=K_POWDER, dens=2.5, cond=0.4,
  hiT=170, hiTo=EXPLODE, desc="Gunpowder. Explodes above 170C, chain-reacts." })
def(WATR, { name="WATR",  cat="Liquids", color={40,92,232},  kind=K_LIQUID, dens=1.0, cond=0.6, disp=6,
  hiT=100, hiTo=STEM, loT=0, loTo=ICE, desc="Water. Boils at 100C, freezes at 0C." })
def(OIL,  { name="OIL",   cat="Liquids", color={96,64,22},   kind=K_LIQUID, dens=0.8, cond=0.3, disp=4,
  hiT=250, hiTo=FIRE, burn=0.12, desc="Oil. Floats on water, very flammable." })
def(ACID, { name="ACID",  cat="Liquids", color={150,255,40},  kind=K_LIQUID, dens=1.1, cond=0.4, disp=4,
  desc="Acid. Dissolves almost anything except walls." })
def(LAVA, { name="LAVA",  cat="Liquids", color={255,96,18},  kind=K_LIQUID, dens=4, cond=0.3, disp=2,
  temp=1400, amb=0.0004, loT=850, loTo=STNE, desc="Molten rock at 1400C. Solidifies to stone below 850C." })
def(FIRE, { name="FIRE",  cat="Gases",   color={255,140,20},  kind=K_GAS, dens=0.01, cond=0.5,
  temp=900, amb=0.02, life=25, lifeR=45, loT=250, loTo=SMKE, desc="Fire. Very hot, ignites flammables." })
def(SMKE, { name="SMKE",  cat="Gases",   color={70,70,72},   kind=K_GAS, dens=0.02, cond=0.1,
  temp=150, amb=0.02, life=60, lifeR=120, desc="Smoke. Rises and fades away." })
def(STEM, { name="STEM",  cat="Gases",   color={200,200,222}, kind=K_GAS, dens=0.03, cond=0.3,
  temp=120, amb=0.0008, loT=95, loTo=WATR, desc="Steam. Condenses back to water below 95C." })

S.NUM_ELEMENTS = 14

---------------------------------------------------------------------------
-- Grid state
---------------------------------------------------------------------------
local types = ffi.new("uint8_t[?]", N)
local temp  = ffi.new("float[?]", N)
local life  = ffi.new("int16_t[?]", N)
local shade = ffi.new("uint8_t[?]", N)   -- per-particle colour variation 0..7
local stamp = ffi.new("uint8_t[?]", N)   -- last tick this cell was processed/moved
local cur   = ffi.new("uint8_t[?]", CW * CH) -- chunks simulated this tick
local nxt   = ffi.new("uint8_t[?]", CW * CH) -- chunks woken for next tick
S.types, S.temp, S.life, S.shade = types, temp, life, shade

local st, frame = 1, 0

-- Branch-free chunk waking: per-row/column offset tables say whether a cell sits
-- on a chunk edge, so we always do 9 byte stores instead of branching (branches
-- here cause LuaJIT side-trace explosions because wake() is called constantly).
local XL = ffi.new("int32_t[?]", W)
local XR = ffi.new("int32_t[?]", W)
local YU = ffi.new("int32_t[?]", H)
local YD = ffi.new("int32_t[?]", H)
local CX = ffi.new("int32_t[?]", W)
local CY = ffi.new("int32_t[?]", H)
for x = 0, W - 1 do
  CX[x] = rshift(x, 4)
  XL[x] = (band(x, 15) == 0 and x > 0) and -1 or 0
  XR[x] = (band(x, 15) == 15 and x < W - 1) and 1 or 0
end
for y = 0, H - 1 do
  CY[y] = rshift(y, 4) * CW
  YU[y] = (band(y, 15) == 0 and y > 0) and -CW or 0
  YD[y] = (band(y, 15) == 15 and y < H - 1) and CW or 0
end

local function wake(x, y)
  local ci = CY[y] + CX[x]
  local l, r, u, d = XL[x], XR[x], YU[y], YD[y]
  nxt[ci] = 1; nxt[ci+l] = 1; nxt[ci+r] = 1
  nxt[ci+u] = 1; nxt[ci+u+l] = 1; nxt[ci+u+r] = 1
  nxt[ci+d] = 1; nxt[ci+d+l] = 1; nxt[ci+d+r] = 1
end
S.wake = wake

local function swap(i, j, x, y, xj, yj)
  local t = types[i]; types[i] = types[j]; types[j] = t
  local tt = temp[i]; temp[i] = temp[j]; temp[j] = tt
  local l = life[i];  life[i] = life[j];   life[j] = l
  local s = shade[i]; shade[i] = shade[j]; shade[j] = s
  stamp[i] = st; stamp[j] = st
  wake(x, y); wake(xj, yj)
end

local function initLife(t)
  local l0 = P_life0[t]
  if l0 > 0 then return l0 + random(0, P_lifeR[t]) end
  return 0
end

local function create(i, x, y, t)
  types[i] = t
  temp[i] = P_spawnT[t]
  life[i] = initLife(t)
  shade[i] = random(0, 7)
  stamp[i] = st
  wake(x, y)
end

-- change element but keep temperature / colour variation
local function transform(i, x, y, t)
  types[i] = t
  life[i] = initLife(t)
  if t == FIRE and temp[i] < P_spawnT[FIRE] then temp[i] = P_spawnT[FIRE] end
  stamp[i] = st
  wake(x, y)
end

local function remove(i, x, y)
  types[i] = 0
  life[i] = 0
  wake(x, y)
end

local function explode(x, y)
  local r = 5
  for dy = -r, r do
    local yy = y + dy
    if yy >= 0 and yy < H then
      for dx = -r, r do
        local xx = x + dx
        if xx >= 0 and xx < W and dx*dx + dy*dy <= r*r then
          local j = yy * W + xx
          local tj = types[j]
          if tj == GUNP then
            temp[j] = 2000; wake(xx, yy)            -- chain reaction next tick
          elseif tj ~= WALL then
            if tj == 0 or P_kind[tj] == K_GAS or random() < 0.3 then
              create(j, xx, yy, FIRE)
              temp[j] = 1600
              life[j] = random(8, 25)
            else
              temp[j] = temp[j] + 400; wake(xx, yy)
            end
          end
        end
      end
    end
  end
end

-- FALL[t*256+tj] == 1 if a falling particle t may move into a cell holding tj
-- (empty, or a lighter liquid/gas). SIDE[tj] == 1 if a liquid may flow sideways into it.
local FALL = ffi.new("uint8_t[65536]")
local SIDE = ffi.new("uint8_t[256]")
for t = 0, 255 do
  SIDE[t] = (t == 0 or P_kind[t] == K_GAS) and 1 or 0
  for tj = 0, 255 do
    FALL[t * 256 + tj] = (tj == 0 or (P_kind[tj] >= K_LIQUID and P_dens[tj] < P_dens[t])) and 1 or 0
  end
end

local function acidAt(j, xj, yj)
  local tj = types[j]
  if tj ~= 0 and tj ~= WALL and tj ~= ACID then
    if random() < 0.05 then remove(j, xj, yj); return 2 end
    return 1
  end
  return 0
end

-- fire radiates heat into every neighbour (not just the right/down conduction pair)
local function fireHeat(j, xj, yj, ti)
  local tj = types[j]
  if tj ~= 0 and tj ~= FIRE and P_cond[tj] > 0 then
    local d = (ti - temp[j]) * 0.25
    if d > 0 then
      temp[j] = temp[j] + d
      wake(xj, yj)
      return ti - d * 0.4      -- combustion: the flame loses less than it gives
    end
  end
  return ti
end

---------------------------------------------------------------------------
-- Per-cell update
---------------------------------------------------------------------------
local function update(x, y)
  local i = y * W + x
  local t = types[i]
  if t == 0 or stamp[i] == st then return end
  stamp[i] = st
  local awake = false

  -- 1) heat conduction (right & down pairs; every pair is visited once)
  local c = P_cond[t]
  if c > 0 then
    local ti = temp[i]
    if x < W - 1 then
      local j = i + 1
      local c2 = P_cond[types[j]]
      if c2 > 0 then
        local d = (temp[j] - ti) * (c < c2 and c or c2) * 0.5
        if d > 0.02 or d < -0.02 then ti = ti + d; temp[j] = temp[j] - d; awake = true end
      end
    end
    if y < H - 1 then
      local j = i + W
      local c2 = P_cond[types[j]]
      if c2 > 0 then
        local d = (temp[j] - ti) * (c < c2 and c or c2) * 0.5
        if d > 0.02 or d < -0.02 then ti = ti + d; temp[j] = temp[j] - d; awake = true end
      end
    end
    local a = P_amb[t]
    if a > 0 then
      local d = (AMBIENT - ti) * a
      ti = ti + d
      if d > 0.01 or d < -0.01 then awake = true end
    end
    temp[i] = ti

    -- 2) phase changes / burning
    if ti > P_hiT[t] then
      local nt = P_hiTo[t]
      if nt == EXPLODE then remove(i, x, y); explode(x, y); return end
      local b = P_burn[t]
      if b > 0 then
        temp[i] = ti + 3                         -- burning releases heat
        if random() < b then transform(i, x, y, FIRE); return end
        if y > 0 and types[i - W] == 0 and random() < 0.2 then create(i - W, x, y - 1, FIRE) end
        awake = true
      else
        transform(i, x, y, nt); return
      end
    elseif ti < P_loT[t] then
      transform(i, x, y, P_loTo[t]); return
    end
  end

  -- 3) limited lifetime
  if P_life0[t] > 0 then
    local l = life[i] - 1
    life[i] = l
    if l <= 0 then
      if t == FIRE and random() < 0.25 then transform(i, x, y, SMKE) else remove(i, x, y) end
      return
    end
    awake = true
  end

  -- 4) element specific behaviour
  if t == FIRE then
    local ti = temp[i]
    if x > 0     then ti = fireHeat(i - 1, x - 1, y, ti) end
    if x < W - 1 then ti = fireHeat(i + 1, x + 1, y, ti) end
    if y > 0     then ti = fireHeat(i - W, x, y - 1, ti) end
    if y < H - 1 then ti = fireHeat(i + W, x, y + 1, ti) end
    temp[i] = ti
    if random() < 0.35 then wake(x, y); return end   -- flames linger/flicker instead of shooting up
  elseif t == ACID then
    local hit = 0
    if x > 0     then hit = hit + acidAt(i - 1, x - 1, y) end
    if x < W - 1 then hit = hit + acidAt(i + 1, x + 1, y) end
    if y > 0     then hit = hit + acidAt(i - W, x, y - 1) end
    if y < H - 1 then hit = hit + acidAt(i + W, x, y + 1) end
    if hit > 0 then
      awake = true
      if hit >= 2 and random() < 0.3 then remove(i, x, y); return end
    end
  elseif t == PLNT then
    local d = random(0, 3)
    local j, xj, yj = -1, x, y
    if d == 0 and x > 0 then j, xj = i - 1, x - 1
    elseif d == 1 and x < W - 1 then j, xj = i + 1, x + 1
    elseif d == 2 and y > 0 then j, yj = i - W, y - 1
    elseif d == 3 and y < H - 1 then j, yj = i + W, y + 1 end
    if j >= 0 and types[j] == WATR then
      if random() < 0.15 then transform(j, xj, yj, PLNT) end
    end
    -- stay awake while any water touches us
    if (x > 0 and types[i-1] == WATR) or (x < W-1 and types[i+1] == WATR) or
       (y > 0 and types[i-W] == WATR) or (y < H-1 and types[i+W] == WATR) then
      awake = true
    end
  end

  -- 5) movement
  local k = P_kind[t]
  if k == K_POWDER or k == K_LIQUID then
    if t == LAVA and random() > 0.4 then wake(x, y); return end   -- viscous
    if y < H - 1 then
      local j = i + W
      local ft = lshift(t, 8)
      if FALL[ft + types[j]] ~= 0 then swap(i, j, x, y, x, y + 1); return end
      local d = random(0, 1) * 2 - 1
      local nx = x + d
      if nx >= 0 and nx < W and FALL[ft + types[j + d]] ~= 0 then swap(i, j + d, x, y, nx, y + 1); return end
      nx = x - d
      if nx >= 0 and nx < W and FALL[ft + types[j - d]] ~= 0 then swap(i, j - d, x, y, nx, y + 1); return end
    end
    if k == K_LIQUID then
      local disp = P_disp[t]
      local d = random(0, 1) * 2 - 1
      for _ = 1, 2 do
        local best = 0
        for s = 1, disp do
          local nx = x + d * s
          if nx < 0 or nx >= W then break end
          local j = i + d * s
          if SIDE[types[j]] ~= 0 then
            best = s
            if y < H - 1 and types[j + W] == 0 then break end  -- found a drop, go there
          else
            break
          end
        end
        if best > 0 then swap(i, i + d * best, x, y, x + d * best, y); return end
        d = -d
      end
    end
  elseif k == K_GAS then
    awake = true
    local d = random(-1, 1)
    local nx = x + d
    if y > 0 and nx >= 0 and nx < W and types[i - W + d] == 0 then
      swap(i, i - W + d, x, y, nx, y - 1); return
    end
    d = random(0, 1) * 2 - 1
    nx = x + d
    if nx >= 0 and nx < W and types[i + d] == 0 then swap(i, i + d, x, y, nx, y); return end
  end

  if awake then wake(x, y) end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
local NCH = CW * CH

function S.step()
  frame = frame + 1
  st = frame % 255 + 1
  ffi.copy(cur, nxt, NCH)
  ffi.fill(nxt, NCH, 0)
  for y = H - 1, 0, -1 do
    local row = rshift(y, 4) * CW
    if band(y + frame, 1) == 0 then
      for cx = 0, CW - 1 do
        if cur[row + cx] ~= 0 then
          local x0 = lshift(cx, 4)
          for x = x0, x0 + 15 do update(x, y) end
        end
      end
    else
      for cx = CW - 1, 0, -1 do
        if cur[row + cx] ~= 0 then
          local x0 = lshift(cx, 4)
          for x = x0 + 15, x0, -1 do update(x, y) end
        end
      end
    end
  end
end

function S.activeChunks()
  local n = 0
  for c = 0, NCH - 1 do if cur[c] ~= 0 then n = n + 1 end end
  return n, NCH
end

function S.wakeAll() ffi.fill(nxt, NCH, 1); ffi.fill(cur, NCH, 1) end

function S.inBounds(x, y) return x >= 0 and x < W and y >= 0 and y < H end

function S.get(x, y)
  if x < 0 or x >= W or y < 0 or y >= H then return 0, 0 end
  local i = y * W + x
  return types[i], temp[i]
end

function S.place(x, y, t, replace)
  local i = y * W + x
  if types[i] ~= 0 and not replace then return end
  create(i, x, y, t)
  stamp[i] = 0 -- let it act on the next tick
end

function S.erase(x, y)
  local i = y * W + x
  if types[i] ~= 0 then remove(i, x, y) end
end

function S.heat(x, y, amount)
  local i = y * W + x
  if types[i] ~= 0 and P_cond[types[i]] > 0 then
    local v = temp[i] + amount
    if v < -273 then v = -273 elseif v > 9999 then v = 9999 end
    temp[i] = v
    wake(x, y)
  end
end

function S.clear()
  ffi.fill(types, N, 0); ffi.fill(life, N * 2, 0)
  for i = 0, N - 1 do temp[i] = AMBIENT end
  S.wakeAll()
end

-- one-level undo (pressing undo twice = redo)
local u_types = ffi.new("uint8_t[?]", N)
local u_temp  = ffi.new("float[?]", N)
local u_life  = ffi.new("int16_t[?]", N)
local u_shade = ffi.new("uint8_t[?]", N)
local hasUndo = false
local tmp = ffi.new("uint8_t[?]", N * 4)
local function swapBuf(a, b, bytes) ffi.copy(tmp, a, bytes); ffi.copy(a, b, bytes); ffi.copy(b, tmp, bytes) end

function S.snapshot()
  ffi.copy(u_types, types, N); ffi.copy(u_temp, temp, N * 4)
  ffi.copy(u_life, life, N * 2); ffi.copy(u_shade, shade, N)
  hasUndo = true
end

function S.undo()
  if not hasUndo then return false end
  swapBuf(types, u_types, N); swapBuf(temp, u_temp, N * 4)
  swapBuf(life, u_life, N * 2); swapBuf(shade, u_shade, N)
  S.wakeAll()
  return true
end

local MAGIC = "GRNL1"
function S.serialize()
  return MAGIC .. ffi.string(types, N) .. ffi.string(temp, N * 4)
       .. ffi.string(life, N * 2) .. ffi.string(shade, N)
end

function S.deserialize(s)
  if type(s) ~= "string" or #s ~= #MAGIC + N * 8 or s:sub(1, #MAGIC) ~= MAGIC then return false end
  local o = #MAGIC
  local p = ffi.cast("const uint8_t*", s)
  ffi.copy(types, p + o, N);          o = o + N
  ffi.copy(temp,  p + o, N * 4);      o = o + N * 4
  ffi.copy(life,  p + o, N * 2);      o = o + N * 2
  ffi.copy(shade, p + o, N)
  S.wakeAll()
  return true
end

S.clear()
return S
