-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local base = root .. "/src/WIDGETS/AeroGrid/lib/"
local counter = assert(loadfile(base .. "flight_count.lua"))()
local memory = assert(loadfile(root .. "/tests/support/memory_files.lua"))()
local values = { [8] = 123, [7] = 4 }
local precision = {}
local env = {
    charUp = "^",
    charDown = "v",
    getSwitchIndex = function(name)
        return name == "SFv" and 7 or 0
    end,
    getGlobalVariable = function(index, mode)
        assert(mode == 0)
        return values[index]
    end,
    getGlobalVariableDetails = function(index)
        return { prec = precision[index] or 0 }
    end,
}

assert(counter.external(env, false) == 123)
assert(counter.external(env, true) == 4123)
values[8] = 123.0
assert(tostring(counter.external(env, false)) == "123", "integer-valued floats display without decimals")
for _, bad in ipairs({ -1, 1000, 0.1, math.huge, 0 / 0 }) do
    values[8] = bad
    assert(not pcall(counter.external, env, false))
end
values[8] = 123
precision[7] = 1
assert(counter.external(env, false) == 123, "GV9-only mode must not inspect GV8")
assert(not pcall(counter.external, env, true))
precision[7] = nil
assert(counter.valid(0) and counter.valid(999999) and counter.valid(counter.MAX))
assert(not counter.valid(counter.MAX + 1) and not counter.valid(-1) and not counter.valid(1.5))

local function widget(modern, combined, trigger)
    if not modern then
        return [[
       widgetName: Flights
       widgetData:
          options:
             0:
                type: Source
                value:
                   source: SF
             1:
                type: Source
                value:
                   source: CH3
             2:
                type: Signed
                value:
                   signedValue: 30
]]
    end
    return [[
       widgetName: Flights
       widgetData:
          options:
             0:
                type: Unsigned
                value:
                   unsignedValue: ]] .. tostring(trigger or 1) .. [[

             1:
                type: Signed
                value:
                   signedValue: 7
             2:
                type: Source
                value:
                   source: CH5
             4:
                type: Signed
                value:
                   signedValue: 12
]] .. (combined == nil and "" or [[
             7:
                type: Bool
                value:
                   boolValue: ]] .. tostring(combined) .. "\n")
end

local function import(text, legacy, change)
    local files, ops = memory()
    files["/MODELS/test.yml"] = text
    if change then
        change(ops)
    end
    local job = counter.begin(ops, "test.yml", legacy, env)
    for _ = 1, 300 do
        local done, result = counter.step(job)
        if done then
            assert(not job.handle, "migration must close the model file")
            return result
        end
    end
    error("import did not finish")
end

local top = "topbarData:\n   zones:\n    0:\n"
local screens = "screenData:\n   0:\n    layoutData:\n"
local result = import(top .. widget(true, true))
assert(result.count == 4123 and result.armed == "SFv")
assert(result.flight.motorSource == "ch5" and result.flight.minFlightDuration == 12)
assert(result.flight.requireReceiver and result.notice)
result = import(screens .. widget(true, false, 2))
assert(result.count == 123 and result.flight.requireReceiver == false)
result = import(top .. widget(true, nil))
assert(result.count == 123, "standard versions without GV8 support use GV9")
result = import(top .. widget(false))
assert(result.count == 123 and result.armed == "SF^" and result.flight.motorSource == "ch3")
result = import(top .. widget(true, true, 3))
assert(result.count == 4123 and not result.flight and result.notice, "unsupported detection still imports count")
result = import(top .. widget(true, true), true)
assert(result.count == 4123 and not result.flight and not result.armed, "existing AeroGrid settings win")
assert(import("header:\n   name: Model\n", false).count == 0)
assert(import(nil, false).count == 0, "missing model file is not proof of a configured counter")
assert(import(nil, true).count == 123, "existing AeroGrid models retain their old GV9 total")
assert(import("header:\n   name: Flights\n", false).count == 0, "widget names elsewhere do not match")
assert(import(top .. widget(true, true) .. "    1:\n" .. widget(true, true)).count == 4123)
assert(not pcall(import, top .. widget(true, false) .. "    1:\n" .. widget(true, true)))
assert(not pcall(import, top .. string.gsub(widget(true, false), "Unsigned", "String")))
assert(not pcall(import, "", false), "an empty existing model is not silently treated as a fresh model")
assert(not pcall(import, "not a model file\n", false), "unrecognized model content must not silently initialize zero")
assert(not pcall(import, top .. widget(true, true), false, function(ops)
    ops.read = function()
        return ""
    end
end))
local long = string.rep("   unrelated: value\n", 600) .. top .. widget(true, true)
assert(import("header:\n" .. long).count == 4123, "large models are scanned in bounded chunks")

print("Flight count sources and one-time import variants passed")
