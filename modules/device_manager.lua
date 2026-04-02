local device_manager = {}

local devices = {}

function device_manager.registry(name, device)
    if devices[name] then
        error(string.format("device \"%s\" arleady exists", name))
    end

    devices[name] = device
end

function device_manager.unregistry(name)
    devices[name] = nil
end

function device_manager.create(name, ...)
    local path = devices[name]

    if not path then
        error(string.format("device \"%s\" not exists", name))
    end

    return require(path).new(...)
end

return device_manager
