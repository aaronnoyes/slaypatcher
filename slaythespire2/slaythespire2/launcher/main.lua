-- SPDX-License-Identifier: MIT
-- Slay the Spire 2 port: settings menu shown before the game starts.
--
-- Writes settings.cfg (simple key=value lines) into the LÖVE save directory. The launcher script
-- reads it, turns it into SLAY_* / SLAYPERF_* settings and starts the game. perf.env still applies
-- on top, for experiments.
--
-- Exit status: 0 = launch the game, 1 = back out to the frontend.

local SETTINGS_FILE = "settings.cfg"

local lowresAvailable = os.getenv("SLAY_LOWRES_AVAILABLE") == "1"

-- Each row: key, label, list of {value, text}, help per value. Help text quotes what was measured
-- on an H700 (973 MB RAM). See PERF_NOTES.md.
local rows = {
    { key = "lowres", label = "Low-res textures",
      choices = { { "1", "On" }, { "0", "Off" } },
      help = {
          ["1"] = "Half-size textures. Needed on 1 GB devices: combat went from ~0.1 to 30 FPS.",
          ["0"] = "Full-size textures. On 1 GB devices the game runs out of memory in combat.",
      } },
    { key = "spine_hz", label = "Animation rate",
      choices = { { "0", "Every frame" }, { "20", "20 Hz" }, { "15", "15 Hz" }, { "10", "10 Hz" } },
      help = {
          ["0"] = "Characters animate every frame. Smoothest, but caused 17-18 FPS dips in combat.",
          ["20"] = "Character animations update 20 times a second. Animations keep their length.",
          ["15"] = "Recommended. Removed the 17-18 FPS combat dips; animations keep their length.",
          ["10"] = "Cheapest. Animation looks choppier.",
      } },
    { key = "particles", label = "Particles",
      choices = { { "on", "Full" }, { "half", "Half" }, { "off", "Off" } },
      help = {
          ["on"] = "All particle effects.",
          ["half"] = "Half as many particles per effect. Not yet measured on device.",
          ["off"] = "No particle effects. Effects still finish on time, they're just invisible.",
      } },
    { key = "gc", label = "Fewer GC pauses",
      choices = { { "1", "On" }, { "0", "Off" } },
      help = {
          ["1"] = "Tunes .NET garbage collection: ~170 collections per session down to ~10.",
          ["0"] = ".NET defaults: more frequent small hitches.",
      } },
    { key = "cpu_max", label = "CPU at full speed",
      choices = { { "1", "On" }, { "0", "Off" } },
      help = {
          ["1"] = "Locks the CPU at full clock while playing (restored on exit). Smoother, warmer.",
          ["0"] = "Normal power management. Cooler and better battery, more stutter.",
      } },
    { key = "hud", label = "Performance overlay",
      choices = { { "0", "Off" }, { "1", "On" } },
      help = {
          ["0"] = "No overlay. Performance is still logged to mods/slayperf/logs.",
          ["1"] = "Shows FPS, memory and CPU stats on screen.",
      } },
}

local presets = {
    { name = "Recommended", values = { lowres = "1", spine_hz = "15", particles = "on", gc = "1", cpu_max = "1", hud = "0" },
      help = "Best measured balance on an H700: steady 30 FPS in combat." },
    { name = "Battery", values = { lowres = "1", spine_hz = "15", particles = "half", gc = "1", cpu_max = "0", hud = "0" },
      help = "Like Recommended, but normal CPU power management and fewer particles." },
    { name = "Quality", values = { lowres = "0", spine_hz = "0", particles = "on", gc = "1", cpu_max = "1", hud = "0" },
      help = "Full textures and animation. Only for devices with more than 1 GB of RAM." },
}

local values = {}
local selected = 1 -- 1 = Launch button, 2 = preset row, 3.. = setting rows
local message = nil

local fonts = {}

local function rowIndexOf(key)
    for i, r in ipairs(rows) do
        if r.key == key then return i end
    end
end

local function choiceIndex(row)
    for i, c in ipairs(row.choices) do
        if c[1] == values[row.key] then return i end
    end
    return 1
end

local function currentPreset()
    for i, p in ipairs(presets) do
        local match = true
        for k, v in pairs(p.values) do
            if k == "lowres" and not lowresAvailable then
                -- ignore: can't be turned on anyway
            elseif values[k] ~= v then
                match = false
                break
            end
        end
        if match then return i end
    end
    return nil -- custom
end

local function applyPreset(i)
    for k, v in pairs(presets[i].values) do values[k] = v end
    if not lowresAvailable then values.lowres = "0" end
end

local function loadSettings()
    applyPreset(1)
    local contents = love.filesystem.getInfo(SETTINGS_FILE) and love.filesystem.read(SETTINGS_FILE)
    if contents then
        for line in contents:gmatch("[^\n]+") do
            local k, v = line:match("^([%w_]+)=([%w_]+)$")
            if k and v and rowIndexOf(k) then values[k] = v end
        end
    end
    if not lowresAvailable then values.lowres = "0" end
end

local function save()
    local lines = {}
    for _, r in ipairs(rows) do
        lines[#lines + 1] = r.key .. "=" .. values[r.key]
    end
    love.filesystem.write(SETTINGS_FILE, table.concat(lines, "\n") .. "\n")
end

local function step(dir)
    if selected == 2 then
        local p = currentPreset() or 0
        local n = #presets
        p = ((p - 1 + dir) % n) + 1
        if dir < 0 and currentPreset() == nil then p = n end
        applyPreset(p)
    elseif selected >= 3 then
        local row = rows[selected - 2]
        if row.key == "lowres" and not lowresAvailable then
            message = "Low-res textures aren't installed (tools/make-lowres.sh)."
            return
        end
        local i = choiceIndex(row)
        i = ((i - 1 + dir) % #row.choices) + 1
        values[row.key] = row.choices[i][1]
    end
    message = nil
    save()
end

-- PortMaster's quit hotkey sends SIGTERM: back out to the frontend instead of launching.
local receivedSigterm = false

function love.load()
    local h = love.graphics.getHeight()
    local s = h / 480
    fonts.title = love.graphics.newFont(math.floor(28 * s))
    fonts.row = love.graphics.newFont(math.floor(20 * s))
    fonts.help = love.graphics.newFont(math.floor(14 * s))
    loadSettings()

    if pcall(require, "ffi") then
        local ffi = require("ffi")
        ffi.cdef [[
            typedef void (*sighandler_t)(int);
            sighandler_t signal(int signum, sighandler_t handler);
        ]]
        -- Only set a flag here: calling into LÖVE from a signal handler isn't safe.
        local handler = ffi.cast("sighandler_t", function() receivedSigterm = true end)
        ffi.C.signal(15, handler)
    end
end

function love.update()
    if receivedSigterm then love.event.quit(1) end
end

local function launch()
    save()
    love.event.quit(0)
end

function love.keypressed(key)
    local total = #rows + 2
    if key == "up" then
        selected = selected > 1 and selected - 1 or total
    elseif key == "down" then
        selected = selected < total and selected + 1 or 1
    elseif key == "left" then
        step(-1)
    elseif key == "right" then
        step(1)
    elseif key == "space" then
        if selected == 1 then launch() else step(1) end
    elseif key == "return" then
        launch()
    elseif key == "escape" then
        save()
        love.event.quit(1)
    end
end

local function drawRow(y, w, rowH, isSelected, label, valueText, dim)
    if isSelected then
        love.graphics.setColor(0.35, 0.35, 0.35, 0.6)
        love.graphics.rectangle("fill", w * 0.08, y - 4, w * 0.84, rowH, 6, 6)
    end
    love.graphics.setColor(dim and 0.5 or 1, dim and 0.5 or 1, dim and 0.5 or 1)
    love.graphics.print(label, w * 0.11, y)
    local text = "<  " .. valueText .. "  >"
    love.graphics.printf(text, 0, y, w * 0.89, "right")
end

function love.draw()
    local w, h = love.graphics.getDimensions()
    local s = h / 480
    love.graphics.clear(0.08, 0.07, 0.09)

    love.graphics.setFont(fonts.title)
    love.graphics.setColor(0.95, 0.85, 0.6)
    love.graphics.printf("Slay the Spire 2", 0, 10 * s, w, "center")

    -- Launch button
    local btnW, btnH = 260 * s, 40 * s
    local btnX, btnY = (w - btnW) / 2, 52 * s
    love.graphics.setColor(selected == 1 and 0.75 or 0.45, selected == 1 and 0.3 or 0.18, 0.15)
    love.graphics.rectangle("fill", btnX, btnY, btnW, btnH, 8, 8)
    love.graphics.setFont(fonts.row)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("Launch Game", btnX, btnY + (btnH - fonts.row:getHeight()) / 2, btnW, "center")

    -- Preset + setting rows
    local rowH = 34 * s
    local y = btnY + btnH + 18 * s
    local p = currentPreset()
    drawRow(y, w, rowH, selected == 2, "Preset", p and presets[p].name or "Custom", false)
    y = y + rowH + 6 * s
    for i, r in ipairs(rows) do
        local unavailable = r.key == "lowres" and not lowresAvailable
        local text = unavailable and "Not installed" or r.choices[choiceIndex(r)][2]
        drawRow(y, w, rowH, selected == i + 2, r.label, text, unavailable)
        y = y + rowH
    end

    -- Help line
    local help
    if message then
        help = message
    elseif selected == 1 then
        help = "A / Start: launch.  B: back to menu.  Left/Right: change setting."
    elseif selected == 2 then
        help = p and presets[p].help or "Custom settings. Pick a preset to reset all rows."
    else
        local r = rows[selected - 2]
        help = r.help[values[r.key]] or ""
    end
    love.graphics.setFont(fonts.help)
    love.graphics.setColor(0.85, 0.85, 0.85)
    love.graphics.printf(help, w * 0.05, h - 44 * s, w * 0.9, "center")
end

function love.quit()
    save()
    if receivedSigterm then os.exit(1) end
end
