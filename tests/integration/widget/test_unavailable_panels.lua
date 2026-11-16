-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local radio = fixture.radio
local resetRadio = fixture.reset
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local makeWidget = fixture.makeWidget
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local settle = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end

local function testPanelsDegrade()
    resetRadio()
    -- A timer the radio has and the model has not set up. `luaModelGetTimer`
    -- answers nothing for an unconfigured slot the same way it does for one
    -- out of range, so this is the shape a panel must survive.
    radio.timers[2] = nil
    local widgetPath = makeWidget(
        "degrade",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: timer
    type: flight-timer
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      timer: 2
  - id: gv
    type: metric
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      metrics:
        - source: NoSuchSensor
  - id: trims
    type: trim-panel
    col: 0
    row: 1
    colSpan: 2
    rowSpan: 1
    config:
      trim1: not-a-trim
      trim2: also-not-a-trim
      trim4: another-missing-trim
  - id: identity
    type: model-identity
    col: 2
    row: 1
    colSpan: 2
    rowSpan: 2
    config:
      presentation: both
  - id: mode
    type: flight-mode
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 1
  - id: battery
    type: tx-battery
    col: 0
    row: 3
    colSpan: 2
    rowSpan: 1
]]
    )

    -- A firmware without a flight mode API, and a model with no bitmap.
    local realFlightMode = getFlightMode
    local realGetInfo = model.getInfo
    getFlightMode = nil
    model.getInfo = function()
        return { filename = radio.modelFilename, name = "No Picture", bitmap = "gone.png" }
    end

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    local ok, err = pcall(settle, context)
    getFlightMode = realFlightMode
    model.getInfo = realGetInfo
    assert(ok, "a panel raised inside a callback: " .. tostring(err))

    local function assertUnavailable(id)
        local instance = entryById(context, id).instance
        assertEqual(instance.stateName, "unavailable", id .. " hid a missing source")
        assertEqual(instance.badge.properties.text, "N/A", id .. " reported its state by colour alone")
    end

    assertUnavailable("timer")
    assertUnavailable("gv")
    assertUnavailable("trims")
    assertUnavailable("mode")

    -- The dominant reading, which every span draws. This panel is one row
    -- tall and sheds its caption, so the caption is checked where it is shown.
    assertEqual(entryById(context, "timer").instance.text, "--:--")
    assertEqual(entryById(context, "trims").instance.indicators[1].valueText, "-- A")

    -- A bitmap the card does not have falls back to the model name rather than
    -- leaving an empty hole where the picture would be.
    local identity = entryById(context, "identity").instance
    assert(identity.area.showImage, "the degradation test must run on a panel that could show an image")
    assertEqual(identity.text, "No Picture")
    assertEqual(identity.image, nil, "a missing bitmap was still opened")
    assertEqual(identity.value.hidden, false, "the name fallback was hidden")

    -- The transmitter voltage does not depend on any of that, so it stays live.
    assertEqual(entryById(context, "battery").instance.stateName, "normal")
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

testPanelsDegrade()
