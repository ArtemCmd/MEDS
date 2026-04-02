local logger = require("dave_logger:logger")("MEDS")

local config = {}

local function error_handler(message)
    logger:error("Config: Failed to load config file: %s\n%s", message, debug.traceback())
end

local function merge(table1, table2)
    for key, val in pairs(table2) do
        if type(val) == "table" then
            if table1[key] == nil then
                table1[key] = {}
            end

            merge(table1[key], val)
        elseif table1[key] == nil then
            table1[key] = val
        end
    end
end

function config.initialize()
    local data = {}
    local default = file.read("emulator:default.toml")
    local default_data = toml.parse(default)

    logger:info("Config: Loading...")

    local start = os.clock()

    xpcall(function()
        local global_path = pack.shared_file("emulator", "config.toml")
        local local_path = pack.data_file("emulator", "config.toml")

        if file.exists(local_path) then
            data = toml.parse(file.read(local_path))
        elseif file.exists(global_path) then
            data = toml.parse(file.read(global_path))
        else
            file.write(global_path, default)
        end
    end, error_handler)

    logger:info("Config: Loaded in %d milliseconds", (os.clock() - start) * 1000)

    merge(data, default_data)
    table.merge(config, data)
end

return config
