-- SPDX-License-Identifier: MIT
-- Settings menu shown before Slay the Spire 2 starts. Pattern borrowed from the PortMaster
-- "The Binding of Isaac: Rebirth" port's LÖVE launcher.
function love.conf(t)
    t.identity = "sts2launcher" -- settings live in $XDG_DATA_HOME/love/sts2launcher/
    t.window.title = "Slay the Spire 2"
    t.window.fullscreen = true
    t.modules.audio = false
    t.modules.sound = false
    t.modules.physics = false
    t.modules.joystick = false -- gptokeyb maps the pad to keys
end
