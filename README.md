
Granule
A falling-sand sandbox written from scratch in Lua. It runs on LÖVE 11.x, which ships with LuaJIT. The simulation and frame rate are both hard-capped at 60.

Run it
Platform	How
Windows	Double-click run-windows.bat. If LÖVE isn't installed, the script downloads a portable copy (about 10 MB) into runtime\ the first time.
Linux	chmod +x run-linux.sh && ./run-linux.sh. LÖVE is installed through apt/dnf/pacman/zypper, or the script falls back to a portable AppImage.
ChromeOS	Turn on Settings → About ChromeOS → Developers → Linux development environment. Copy this folder into Linux files, then run bash ~/granule/run-chromeos.sh in Terminal. The first run installs LÖVE and adds a Granule icon to the launcher.
Extras:

run-windows.bat build makes a standalone dist\Granule\Granule.exe that you can zip up and share.
./run-linux.sh build makes dist/granule.love, which runs anywhere LÖVE is installed.
--software (Linux/ChromeOS) forces software OpenGL. Use it if the window is black.
Elements
Solids	Powders	Liquids	Gases	Tools
WALL, WOOD, ICE, PLNT	SAND, STNE, GUNP	WATR, OIL, ACID, LAVA	FIRE, SMKE, STEM	ERASE, HEAT, COOL
Every particle has a temperature, and heat conducts between neighbours. These reactions come out of that:

Water boils into steam at 100 °C and freezes into ice at 0 °C. Steam condenses back into water.
Lava (1400 °C) cools into stone, and stone melts back into lava.
Wood, oil and plants ignite when hot and burn at different speeds. Gunpowder explodes and sets off a chain reaction.
Plants grow by drinking water, and acid dissolves anything except walls.
Liquids settle by density, so oil floats on water.
Controls
Input	Action
Left / Right mouse	Draw with the primary / secondary item
Middle click, Alt+click	Pick the element under the cursor
Shift+drag / Ctrl+drag	Draw a line / fill a box
Wheel or [ ] (Shift = ×5)	Brush size
Tab	Switch between circle and square brush
Space / F	Pause / step one frame
V	Heat view
1–9, 0	Select an item in the current category
Up/Down or Q/E	Change category
Ctrl+Z	Undo (press again to redo)
Delete / Backspace	Clear
F5 / F9	Quicksave / quickload
F1 or H	Help overlay
Esc	Quit
Performance design
FFI arrays everywhere. All cell state (type, temperature, life, colour variation) lives in flat C arrays, and element properties are C lookup tables. The hot loop never touches a Lua table.
Sleeping chunks. The 384×288 grid is split into 16×16 chunks, and only chunks where something changed get simulated. A settled pile of sand costs close to nothing.
Branch-free hot paths. Chunk waking uses precomputed edge-offset tables, and density checks are a single 64 KB lookup (FALL[a*256+b]). Fewer branches means fewer LuaJIT side traces.
Tuned JIT. The trace and side-trace limits are raised so LuaJIT keeps the cellular automaton compiled instead of falling back to the interpreter. This alone made the worst-case benchmark about 3× faster.
Zero-copy rendering. Pixels are written straight into ImageData memory through getFFIPointer() with precomputed packed-colour palettes, then uploaded once per frame and scaled up with nearest-neighbour filtering.
Exact 60 FPS pacing. A custom love.run does one tick and one frame, sleeps most of the remaining time and spins the last ~1.5 ms so frame timing stays precise. Vsync is off so the cap doesn't depend on the monitor.
Unused LÖVE modules (audio, physics, video, joystick) are disabled for faster startup.
Benchmark (headless, one core): a full-screen stress scene with about 65,000 moving particles takes about 5 ms per tick. Normal scenes take 1–2 ms.

Code layout
game/conf.lua   window and module config
game/sim.lua    simulation core (pure LuaJIT, no LÖVE dependency, so you can benchmark it headless)
game/main.lua   rendering, sidebar/UI, input, 60 Hz main loop
To add an element, add an id and a def(...) entry in sim.lua. Kind, density, conductivity, phase-change temperatures and burn rate are all data. Put any special behaviour in section 4 of update().

