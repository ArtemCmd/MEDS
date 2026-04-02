local filesystem = {}

function filesystem.open(path, mode)
    return require("emulator:io/file_stream").new(path, mode)
end

return filesystem
