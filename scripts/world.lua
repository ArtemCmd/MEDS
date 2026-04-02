local config = require("emulator:config")
local device_manager = require("emulator:device_manager")
local network = require("emulator:network/network")

function on_world_open()
    config.initialize()
    network.initialize()

    -- CPU
    device_manager.registry("6502", "emulator:hardware/cpu/6502/6502")
    device_manager.registry("i8080", "emulator:hardware/cpu/i8080/i8080")
    device_manager.registry("i8088", "emulator:hardware/cpu/i8088/i8088")

    -- HDC
    device_manager.registry("st506", "emulator:hardware/disk/st506")

    -- FDC
    device_manager.registry("fdc", "emulator:hardware/floppy/fdc")

    -- Keyboard
    device_manager.registry("keyboard_xt", "emulator:hardware/keyboard/keyboard_xt")
    device_manager.registry("keyboard_okean", "emulator:hardware/keyboard/keyboard_okean")

    -- Mouse
    device_manager.registry("mouse_bus", "emulator:hardware/mouse/mouse_bus")

    -- Sound
    device_manager.registry("pc_speaker", "emulator:hardware/sound/pc_speaker")

    -- Video
    device_manager.registry("mda", "emulator:hardware/video/mda")
    device_manager.registry("cga", "emulator:hardware/video/cga")
    device_manager.registry("ega", "emulator:hardware/video/ega")
    device_manager.registry("okean", "emulator:hardware/video/okean")

    -- Misc
    device_manager.registry("i8237", "emulator:hardware/i8237")
    device_manager.registry("i8253", "emulator:hardware/i8253")
    device_manager.registry("i8255", "emulator:hardware/i8255")
    device_manager.registry("i8259", "emulator:hardware/i8259")
    device_manager.registry("lpt", "emulator:hardware/lpt")
    device_manager.registry("serial", "emulator:hardware/serial")
    device_manager.registry("postcard", "emulator:hardware/postcard")
    device_manager.registry("memory", "emulator:hardware/memory")
    device_manager.registry("screen", "emulator:screen")
    device_manager.registry("wd8003", "emulator:hardware/network/wd8003")
end

function on_world_close()
    network.close()
end
