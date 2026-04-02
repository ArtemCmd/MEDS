-- =====================================================================================================================================================================
-- POST Diagnostic Card emulation.
-- =====================================================================================================================================================================

local logger = require("dave_logger:logger")("MEDS")

local postcard = {}

local function postcard_out(_, cpu, port, val)
    logger:debug("POST: 0x%02X", val)
end

function postcard.new(cpu, base_port)
    cpu:get_io():set_port_out(base_port, postcard_out)
end

return postcard
