-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))().new()
local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
fixture.reset()
fixture.radio.rssi = 0
local context = fixture.createLoaded(nil, { Layout = "Default", Theme = "modern-dark" })
fixture.pump(context, 40)
assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
local timer = fixture.instanceOf(context, "flight-clock")
local previous = timer.text
fixture.radio.timers[0].value = 120
fixture.pump(context, 40)
assert(timer.text ~= previous, "timer must advance without receiver telemetry")
assertions.assertEqual(fixture.instanceOf(context, "transmitter-battery").stateName, "normal")
