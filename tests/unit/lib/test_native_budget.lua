-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local module = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/native_budget.lua"))()

do
    -- EdgeTX raises "CPU limit" from its count hook after 100 hooks of 200
    -- instructions, and an xpcall message handler runs with hooks disabled.
    local function limit()
        local hooks = 0
        debug.sethook(function()
            hooks = hooks + 1
            if hooks > 100 then
                error("CPU limit")
            end
        end, "", 200)
    end
    local function heavy()
        local total = 0
        for index = 1, 60000 do
            total = total + index % 7
        end
        return total
    end
    limit()
    local ok, result = module.cross(function()
        return heavy()
    end)
    debug.sethook()
    assert(ok and result ~= nil, "the work ran past the limit")

    local finished
    limit()
    ok = module.cross(function()
        finished = heavy()
    end)
    debug.sethook()
    assert(ok and finished ~= nil, "work after the limit completes without being cut off")

    -- Without a limit the burn finishes and the work runs directly.
    local ran = false
    assert(module.cross(function()
        ran = true
    end))
    assert(ran)

    -- A failing job reports its error and the callback survives.
    limit()
    ok, result = module.cross(function()
        error("job failed", 0)
    end)
    debug.sethook()
    assert(not ok and result == "job failed")
end

print("Native budget crossing runs work past the limit and reports failures")
