-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local firmware = fixture.firmware
local resetRadio = fixture.reset
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local makeWidget = fixture.makeWidget
local themeModule = fixture.module("lib/theme.lua")
local primitivesModule = fixture.module("lib/primitives.lua")
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local settle = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end
assert(
    themeModule.setCatalog(
        assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
    )
)

local reflowDone = fixture.reflowDone

local function testHeadingNeverWraps()
    resetRadio()

    -- First, that the harness can see the thing at all. Every assertion below
    -- is of the form "one line", which a mock that always answered one line
    -- would satisfy without checking anything. So an unfitted label is built
    -- directly and held to wrapping, which is what the firmware does and what
    -- the panels must therefore avoid.
    local box = lvgl.box({ x = 0, y = 0, w = 120, h = 60 })
    local overflowing = primitivesModule.label(box, themeModule.build("modern-dark"), {
        x = 0,
        y = 0,
        w = 40,
        text = "A HEADING FAR TOO LONG FOR FORTY PIXELS",
        font = firmware.SMLSIZE,
    })
    assert(
        overflowing.lines > 1,
        "the harness does not model LVGL's wrapping, so every assertion below"
            .. " that a heading takes one line would pass without checking"
    )
    assert(
        overflowing.drawnHeight > themeModule.fontHeight(firmware.SMLSIZE),
        "a wrapped label did not grow, so the growth this exists to prevent" .. " cannot be seen either"
    )
    box:clear()

    local widgetPath = makeWidget(
        "heading",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: short
    type: tx-battery
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      label: TX
      warning: 9.0
  - id: long
    type: tx-battery
    col: 1
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      label: BATTERY
      warning: 9.0
  - id: huge
    type: tx-battery
    col: 2
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      label: TRANSMITTER BATTERY PACK
      warning: 9.0
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 30)

    local short = entryById(context, "short").instance
    local long = entryById(context, "long").instance
    local huge = entryById(context, "huge").instance

    -- The badge is showing, so the heading column is the narrow one. Without
    -- this the panels are not the case being tested.
    for _, panel in ipairs({ short, long, huge }) do
        assertEqual(panel.stateName, "warning")
        assertEqual(
            panel.badge.properties.text,
            "WARN",
            "the badge is not showing, so the heading column is not the narrow one"
        )
    end

    local column = short.label.properties.w
    assert(column > 0 and column < 80, "a single cell's heading column should be narrow: " .. column)
    assertEqual(column, short.badge.properties.x - short.label.properties.x - 4)

    -- One line each, which is the whole point. `TRANSMITTER` used to take
    -- three lines and 51 pixels of a 65 pixel panel.
    for id, panel in pairs({ short = short, long = long, huge = huge }) do
        assertEqual(
            panel.label.lines,
            1,
            id .. "'s heading wrapped onto " .. tostring(panel.label.lines) .. " lines and grew down over the reading"
        )
        assert(
            panel.label.drawnHeight <= themeModule.fontHeight(panel.fonts.label),
            id .. "'s heading is taller than one row of its own font"
        )
    end

    -- A heading that fits is left exactly as the author wrote it, at the font
    -- the panel would have used anyway. Stepping a short heading down would be
    -- a cost paid for nothing.
    assertEqual(short.label.properties.text, "TX")
    assertEqual(short.label.properties.font(), short.fonts.label)

    assertEqual(long.label.properties.text, "BATTERY", "a heading that fits beside WARN was shortened")
    assertEqual(long.label.properties.font(), long.fonts.badge, "a heading became smaller than its badge")

    -- One that does not fit even at the smallest font is quietly cut rather
    -- than wrapped.
    assert(
        #huge.label.properties.text < #"TRANSMITTER BATTERY PACK",
        "a heading nothing could fit was drawn whole, so it must have wrapped"
    )

    local function noticedHeading(id)
        for _, notice in ipairs(context.notices) do
            if string.find(notice.text, "heading", 1, true) and string.find(notice.text, id .. ":", 1, true) then
                return notice.text
            end
        end
        return nil
    end

    assertEqual(noticedHeading("short"), nil, "a heading that fitted was reported as cut")
    assertEqual(noticedHeading("long"), nil, "a heading carried whole by a smaller font was reported as cut")

    assertEqual(noticedHeading("huge"), nil, "a truncated heading must not produce a fit warning")
end

local function testHeadingRefitsOnReflow()
    resetRadio()
    local widgetPath = makeWidget(
        "heading-reflow",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: panel
    type: tx-battery
    col: 0
    row: 0
    colSpan: 4
    rowSpan: 2
    config:
      label: TRANSMITTER
]]
    )

    local zone = { x = 0, y = 0, w = 480, h = 272 }
    local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 20)

    local panel = entryById(context, "panel").instance
    -- Four cells wide: the whole heading fits at the panel's own font.
    assertEqual(panel.label.properties.text, "TRANSMITTER")
    assertEqual(panel.label.properties.font(), panel.fonts.label)
    assertEqual(panel.label.lines, 1)

    zone.w = 80
    local passes = 0
    repeat
        definition.refresh(context)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    until reflowDone(context)
    settle(context, 20)

    assertEqual(panel.label.lines, 1, "the heading wrapped after a reflow narrowed its column")
    assertEqual(panel.label.properties.font(), panel.fonts.badge, "a reflow shrank the heading below its badge")
    assert(#panel.label.properties.text < #"TRANSMITTER", "a narrow reflow did not shorten the heading")
end

testHeadingNeverWraps()
testHeadingRefitsOnReflow()
