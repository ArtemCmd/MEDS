local device_manager = require("emulator:device_manager")
local event = require("emulator:events")
local io_ports = require("emulator:io_ports")
local hdf = require("emulator:hardware/disk/hdd_hdf")

local api = {
    device_manager = {
        create = device_manager.create
    },
    events = {
        new = event.new,
    },
    io_ports = {
        new = io_ports.new
    },
    file_formats = {
        hdf = {
            create = hdf.create
        }
    }
}

return api
