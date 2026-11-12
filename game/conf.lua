function love.conf(t)
  t.identity = "granule"          -- save folder name
  t.version = "11.4"              -- works on LÖVE 11.3, 11.4, 11.5
  t.console = false
  t.window.title = "Granule - falling sand sandbox"
  t.window.width = 928
  t.window.height = 604
  t.window.vsync = 0              -- we pace frames ourselves (hard 60 FPS cap)
  t.window.resizable = false
  t.window.msaa = 0
  t.window.highdpi = false
  -- unused modules off = faster startup, less memory
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.video = false
  t.modules.audio = false
  t.modules.sound = false
  t.modules.touch = false
end
