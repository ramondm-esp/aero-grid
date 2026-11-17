-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local support = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/services.lua"))()
local control = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/control_service.lua"))()
local modelService = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/model_service.lua"))()
local equal = assertions.assertEqual
local stored = 39
local env = {
    getGlobalVariable = function(index, flightMode)
        equal(index, 8)
        equal(flightMode, 0)
        return stored
    end,
    setGlobalVariable = function()
        error("control subscriptions must remain read-only")
    end,
}
local service = control.new(env, support)
local feed = service:globalVariable(8, 0)
service:update(0)
equal(feed.raw, 39)
assert(service.incrementFlightCount == nil, "the control service must not write flight counts")
stored = 50
service:update(20)
equal(feed.raw, 50, "external count edits remain readable")

local selected, enabled = nil, false
local switches = control.new({
    charUp = string.char(192),
    charDown = string.char(193),
    getSwitchIndex = function(name)
        selected = name
        return name == "MISSING" and 0 or 7
    end,
    getSwitchValue = function(index)
        equal(index, 7)
        return enabled
    end,
}, support)
local function pollSwitches(now)
    local _, again
    repeat
        _, again = switches:update(now)
    until not again
end
for _, pair in ipairs({
    { "SF^", "SF" .. string.char(192) },
    { "SA-", "SA-" },
    { "SBv", "SB" .. string.char(193) },
    { "L01", "L01" },
}) do
    local arm = switches:switch(pair[1])
    pollSwitches(100)
    equal(selected, pair[2])
    enabled = true
    pollSwitches(100)
    equal(arm.value, true)
    equal(arm.updatedAt, 100)
    enabled = false
    for _, entry in ipairs(switches.entries) do
        entry.read(switches, entry, 120)
    end
    equal(arm.value, false)
    equal(arm.fresh, true)
end
local missing = switches:switch("MISSING")
pollSwitches(140)
assert(not missing.available and not missing.fresh, "unknown switch is unavailable, not disarmed")

local model = modelService.new({
    getInfo = function()
        return { name = "Model A", filename = "model1.yml" }
    end,
}, support)
assert(model.logFlight == nil and model.flightDate == nil, "model service must not expose CSV history")
assert(model.announceFlight == nil, "model service must not expose built-in flight announcements")
