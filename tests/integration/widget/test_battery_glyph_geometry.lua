-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local edgetx = fixture.edgetx
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

local function testBatteryGlyphFillsFromTheVoltage()
    resetRadio()
    -- Without `getGeneralSettings` the only range is the one a layout states,
    -- which is what makes the `unranged` panel below genuinely unranged. With
    -- it present every panel inherits the radio's 6.4 to 8.4 and the case that
    -- matters here cannot be reached at all.
    local realSettings = getGeneralSettings
    getGeneralSettings = nil

    local widgetPath = makeWidget(
        "glyph",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: healthy
    type: tx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      packEmpty: 6.6
      packFull: 8.4
      showPercent: true
  - id: alarmed
    type: tx-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      packEmpty: 6.6
      packFull: 8.4
      critical: 8.0
      showPercent: true
  - id: unranged
    type: tx-battery
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 1
    config:
      label: NO RANGE
  - id: tiny
    type: tx-battery
    col: 2
    row: 2
    colSpan: 1
    rowSpan: 1
    config:
      label: TINY
      packEmpty: 6.6
      packFull: 8.4
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 30)

    local healthy = entryById(context, "healthy").instance
    local alarmed = entryById(context, "alarmed").instance
    local unranged = entryById(context, "unranged").instance
    local tiny = entryById(context, "tiny").instance

    -- The fixture transmitter reads 7.9 V against 6.6 to 8.4, so 1.3 of 1.8.
    local fraction = (7.9 - 6.6) / (8.4 - 6.6)
    local glyph = healthy.glyph
    assert(glyph, "a two by two panel drew no battery")
    assertEqual(healthy.glyphShown, true)

    -- The cell stands upright, so the level is a **height** and it grows from
    -- the bottom, because a cell drains downward.
    local expected = math.floor(glyph.interiorHeight * fraction + 0.5)
    assertEqual(glyph.fill.properties.h, expected, "the level is not the voltage's share of the battery's interior")
    assertEqual(
        glyph.fill.properties.y,
        glyph.interiorY + glyph.interiorHeight - expected,
        "the level grows from the top, so a full cell would drain upward"
    )

    -- And the number is a real proportion rather than either extreme, which is
    -- what makes the assertion above worth making.
    assert(
        expected > 0 and expected < glyph.interiorHeight,
        "the fixture voltage produced a full or empty battery, so a level stuck"
            .. " at one end would satisfy this test"
    )

    -- The level stays inside the outline it is drawn in, on every side.
    assert(glyph.fill.properties.y >= glyph.bodyY + glyph.border, "the level starts on or above the outline")
    assert(
        glyph.fill.properties.y + glyph.fill.properties.h <= glyph.bodyY + glyph.bodyHeight - glyph.border,
        "a full level would paint over the outline's bottom edge"
    )
    assert(glyph.fill.properties.w < glyph.width, "the level is as wide as the outline, so it covers the sides")

    -- The outline is drawn as an outline, at the weight it asked for. A filled
    -- rectangle here would be a solid block with nothing visible inside it.
    assertEqual(glyph.shell.properties.filled, false)
    assertEqual(
        glyph.shell.painted.borderWidth,
        glyph.border,
        "the outline reached LVGL at a different weight from the one asked for"
    )
    assert(glyph.border >= 2, "the outline is a hairline rather than the drawn cell the mock shows")

    -- The terminal sits on top, centred, and is a contact rather than a second
    -- cell.
    assertEqual(glyph.nub.properties.filled, true)
    assertEqual(glyph.nub.properties.y, glyph.y)
    assert(glyph.nub.properties.y + glyph.nub.properties.h <= glyph.bodyY, "the terminal overlaps the body it sits on")
    assert(glyph.nub.properties.w < glyph.width, "the terminal is as wide as the battery, so it reads as a cap")

    -- State reaches the whole cell, which is what the user asked for: a
    -- critical pack is red throughout rather than red inside a grey box.
    assertEqual(alarmed.stateName, "critical")
    for name, part in pairs({
        outline = alarmed.glyph.shell,
        terminal = alarmed.glyph.nub,
        level = alarmed.glyph.fill,
    }) do
        assertEqual(
            part.properties.color,
            context.theme.color.critical,
            "a critical pack's " .. name .. " did not go red"
        )
    end
    assert(
        healthy.glyph.fill.properties.color ~= alarmed.glyph.fill.properties.color,
        "both panels fill the same colour, so the state is not reaching the cell"
    )

    -- The empty part of the cell is the panel showing through, so a red cell on
    -- a red-tinted panel is what has to be checked. In 24 bits, because
    -- `contrast` is arithmetic on colour channels and `theme.color` holds
    -- `LcdFlags` words.
    assert(
        themeModule.contrast(context.theme.rgb.critical, context.theme.alertRgb.critical) >= 3,
        "a critical cell is indistinguishable from the panel it stands on"
    )

    -- A panel with no range has nothing to fill from, and an empty outline is a
    -- claim that the pack is flat. All four parts go, not just the level.
    --
    -- This is a weak assertion on its own and it is worth saying why: the glyph
    -- is *built* hidden, so a reconcile that forgot to hide one of its parts
    -- would satisfy every line below. The shed on reflow is where the hiding
    -- actually happens, and that is covered separately.
    assertEqual(unranged.glyphShown, false)
    assertEqual(unranged.glyph.shell.hidden, true)
    assertEqual(unranged.glyph.nub.hidden, true)
    assertEqual(unranged.glyph.fill.hidden, true)

    -- The three parts move together when the glyph is revealed, which is the
    -- direction this build does exercise: `healthy` was built hidden and shown
    -- once the range arrived.
    for name, part in pairs({ shell = glyph.shell, nub = glyph.nub, fill = glyph.fill }) do
        assertEqual(part.hidden, false, "the battery was revealed and its " .. name .. " was left hidden")
    end

    -- The header clearance shortens the glyph enough to retain the reading.
    assertEqual(tiny.glyphShown, true)
    assertEqual(tiny.value.hidden, false)
    assertEqual(tiny.unit.hidden, false)
    assertEqual(tiny.glyph.fill.properties.h, math.floor(tiny.glyph.interiorHeight * fraction + 0.5))

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    getGeneralSettings = realSettings
end

local function testBatteryStrokeFollowsTheReading()
    resetRadio()
    local widgetPath = makeWidget(
        "glyph-stroke",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: small
    type: tx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      label: SMALL
      packEmpty: 6.6
      packFull: 8.4
  - id: large
    type: tx-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: LARGE
      packEmpty: 6.6
      packFull: 8.4
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 30)

    local small = entryById(context, "small").instance
    local large = entryById(context, "large").instance

    -- Read off the label rather than out of the panel's own bookkeeping,
    -- so this is the font the panel is drawing in rather than the one it
    -- believes it chose.
    local smallFont = small.value.properties.font()
    local largeFont = large.value.properties.font()

    -- The precondition: two different fonts. Two panels can no longer be made
    -- to differ in font while holding their cells the same size, because both
    -- now come from the same body band and move together -- so the width is
    -- held still in the second assertion below instead of in the layout.
    assert(
        themeModule.fontHeight(smallFont) < themeModule.fontHeight(largeFont),
        "both panels resolved the same reading font, so nothing below can tell a"
            .. " font-derived stroke from a constant one"
    )

    -- Width held constant, font varied, which is the isolation the old layout
    -- used to provide. Without this, everything below is also satisfied by a
    -- stroke derived purely from the cell's width.
    local held = large.glyph.width
    assert(
        primitivesModule.batteryStroke(themeModule, smallFont, held)
            < primitivesModule.batteryStroke(themeModule, largeFont, held),
        "at one cell width the two fonts produced the same stroke, so the"
            .. " thickness does not follow the reading at all"
    )

    assert(
        small.glyph.border < large.glyph.border,
        "the same stroke ("
            .. small.glyph.border
            .. ") was drawn beside a "
            .. edgetx.fontName(smallFont)
            .. " reading and a "
            .. edgetx.fontName(largeFont)
            .. " one"
    )

    -- And what LVGL was actually given, rather than what the geometry says.
    -- A border width only reaches the firmware at build, so the painted value
    -- is the one on screen.
    assertEqual(small.glyph.shell.painted.borderWidth, small.glyph.border)
    assertEqual(large.glyph.shell.painted.borderWidth, large.glyph.border)
    assert(
        small.glyph.shell.painted.borderWidth < large.glyph.shell.painted.borderWidth,
        "the geometry disagrees about the stroke but the screen does not"
    )

    -- Thinning the outline is only worth anything if the interior grows with
    -- it, because the interior is what shows the charge. Asked of the geometry
    -- at one width, since the two cells are no longer the same size.
    local lightInterior = held - 2 * primitivesModule.batteryStroke(themeModule, smallFont, held)
    local heavyInterior = held - 2 * primitivesModule.batteryStroke(themeModule, largeFont, held)
    assert(lightInterior > heavyInterior, "the lighter outline bought the level no room")

    -- And the level is still a proportion rather than a line: the fixture
    -- reads 7.9 V of 6.6 to 8.4, so neither end.
    for id, panel in pairs({ small = small, large = large }) do
        local level = panel.glyph.fill.properties.h
        assert(
            level > 0 and level < panel.glyph.interiorHeight,
            id .. " draws a full or empty cell, so its level says nothing"
        )
        assert(
            panel.glyph.interiorWidth >= 4,
            id .. " has a " .. panel.glyph.interiorWidth .. " pixel interior, which is a line rather than a level"
        )
    end

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testBatteryStrokeSurvivesReflow()
    resetRadio()
    local widgetPath = makeWidget(
        "glyph-stale",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: pack
    type: tx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: TX
      packEmpty: 6.6
      packFull: 8.4
]]
    )

    -- **Both zones are chosen so the cell comes out the same size**, which is
    -- what isolates the stroke: the font moves and the cell does not, so a
    -- stroke that followed the cell rather than the reading would pass every
    -- assertion below. The cell is capped at 50 px tall and therefore 25 wide
    -- across a range of panel heights, while the reading's budget keeps
    -- growing -- so a 480 x 220 zone reads at XXLSIZE and a 480 x 219 zone at
    -- DBLSIZE, both with a 25 px cell.
    --
    -- **Re-swept twice, and the pair moves every time the budget does.** It
    -- was 224 and 172 under the rule that redistributed an absent part's
    -- quarter, 240 and 232 under fixed quarter/half/quarter bands, 240 and 239
    -- when the reading moved to the panel's centre, and 244 and 243 now that
    -- pinning the supporting row moved the cap the reading is sized against.
    -- This panel draws no row at these heights, so what moved it is the cap
    -- rather than the row. Each time
    -- the previous pair stopped straddling a step and read at one size on
    -- both, which is a test that covers nothing and does not fail -- so the
    -- assertion above the reflow is the guard that makes it fail instead.
    local zone = { x = 0, y = 0, w = 480, h = 244 }
    local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 60)

    local pack = entryById(context, "pack").instance
    local glyph = pack.glyph
    assert(glyph, "the panel drew no battery")

    local builtStroke = glyph.border
    local builtFont = pack.value.properties.font()
    local painted = glyph.shell.painted.borderWidth
    assertEqual(painted, builtStroke)

    local function reflow(width, height)
        zone.w, zone.h = width, height
        local passes = 0
        repeat
            definition.refresh(context)
            passes = passes + 1
            assert(passes < 100, "reflow never finished")
        until reflowDone(context)
        settle(context, 60)
    end

    -- Shorter, which takes the reading from XXLSIZE down to DBLSIZE while the
    -- cell stays 25 px wide. Both zones were found by sweeping rather than
    -- chosen: the budget and the cell both derive from the panel's height, so
    -- the pairs where one moves and the other does not are narrow -- one pixel
    -- of zone, here -- and are not where anybody would look first.
    reflow(480, 243)

    assert(
        themeModule.fontHeight(pack.value.properties.font()) < themeModule.fontHeight(builtFont),
        "the reading did not change size, so this reflow is not the case this"
            .. " test exists for and the assertions below prove nothing"
    )
    assertEqual(glyph.width, 25, "the cell changed size, so the stroke would have been free to change")

    -- The limitation, stated.
    assertEqual(
        glyph.border,
        builtStroke,
        "the stroke changed on a reflow, which a radio cannot do; if the outline"
            .. " is now drawn as filled rectangles rather than a border, delete"
            .. " this test"
    )
    assertEqual(
        glyph.shell.painted.borderWidth,
        builtStroke,
        "the mock let a border width through after build, which the firmware" .. " does not"
    )

    -- And the thing that must stay true: the interior is measured from the
    -- stroke that is on screen, so the level sits inside the outline rather
    -- than floating away from it.
    assertEqual(
        glyph.inset,
        builtStroke + primitivesModule.GLYPH_GAP,
        "the interior was inset against a stroke the screen does not have"
    )
    assertEqual(glyph.fill.properties.x, glyph.interiorX)
    assert(
        glyph.fill.properties.x >= glyph.x + glyph.shell.painted.borderWidth,
        "the level overlaps the outline it is drawn inside"
    )

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testBatteryGlyphShedsWhole()
    resetRadio()
    local widgetPath = makeWidget(
        "glyph-shed",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: pack
    type: tx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      label: TX
      packEmpty: 6.6
      packFull: 8.4
      showPercent: true
]]
    )

    local zone = { x = 0, y = 0, w = 480, h = 272 }
    local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 60)

    local pack = entryById(context, "pack").instance
    local glyph = pack.glyph
    assert(glyph, "the panel drew no battery to shed")

    -- The precondition. Without a battery on screen the shed below is not a
    -- shed, and every assertion after it would pass on a panel that never had
    -- one.
    assertEqual(pack.glyphShown, true, "the battery was not showing to start")
    assertEqual(glyph.shell.hidden, false)
    assertEqual(glyph.nub.hidden, false)
    assertEqual(glyph.fill.hidden, false)
    local shownWidth = glyph.fill.properties.h
    assert(shownWidth > 0, "the battery was showing an empty cell")

    local function reflow(width, height)
        zone.w, zone.h = width, height
        local passes = 0
        repeat
            definition.refresh(context)
            passes = passes + 1
            assert(passes < 100, "reflow never finished")
        until reflowDone(context)
        settle(context, 60)
    end

    -- A compact panel keeps the battery and sheds the voltage instead.
    reflow(140, 140)
    assertEqual(pack.glyphShown, true)
    assertEqual(pack.value.hidden, true)
    assertEqual(pack.unit.hidden, true)

    -- Only a rectangle too small for the glyph itself sheds it.
    reflow(60, 60)
    assertEqual(pack.glyphShown, false, "a panel with no room for a battery kept drawing one")
    for name, part in pairs({ shell = glyph.shell, nub = glyph.nub, fill = glyph.fill }) do
        assertEqual(part.hidden, true, "the battery was shed and its " .. name .. " stayed on screen")
    end

    -- And it comes back whole, in the right place, rather than coming back as
    -- whichever parts happened to be hidden.
    reflow(480, 272)
    assertEqual(pack.glyphShown, true, "the battery never came back")
    assertEqual(pack.value.hidden, false, "the voltage never came back")
    for name, part in pairs({ shell = glyph.shell, nub = glyph.nub, fill = glyph.fill }) do
        assertEqual(part.hidden, false, "the battery came back and its " .. name .. " stayed hidden")
    end
    assertEqual(
        glyph.fill.properties.h,
        shownWidth,
        "the battery came back with a different level from the one it left with"
    )
    assertEqual(glyph.nub.properties.y, glyph.y, "the terminal came back detached from the body")

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testBatteryGlyphLeavesTheReadingRoom()
    resetRadio()
    local lines = { "version: 1", "grid:", "  columns: 4", "  rows: 4", "panels:" }
    local spans = { { 2, 1, 0, 0 }, { 2, 1, 2, 0 }, { 1, 2, 0, 1 }, { 2, 2, 1, 1 } }
    for index, span in ipairs(spans) do
        lines[#lines + 1] = "  - id: p" .. index
        lines[#lines + 1] = "    type: tx-battery"
        lines[#lines + 1] = "    col: " .. span[3]
        lines[#lines + 1] = "    row: " .. span[4]
        lines[#lines + 1] = "    colSpan: " .. span[1]
        lines[#lines + 1] = "    rowSpan: " .. span[2]
        lines[#lines + 1] = "    config:"
        lines[#lines + 1] = "      packEmpty: 6.6"
        lines[#lines + 1] = "      packFull: 8.4"
    end

    local widgetPath = makeWidget("glyph-room", table.concat(lines, "\n"))
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 30)

    for index = 1, #spans do
        local panel = entryById(context, "p" .. index).instance
        local glyph = panel.glyph
        local span = spans[index][1] .. "x" .. spans[index][2]

        assert(glyph, "panel " .. index .. " (" .. span .. ") drew no battery")
        if span == "1x2" then
            assertEqual(panel.value.hidden, true, span .. " must prioritize the glyph")
            assertEqual(panel.unit.hidden, true)
        else
            assertEqual(panel.value.hidden, false)
            local reading = panel.value.properties
            local right = reading.x + reading.w
            assert(
                glyph.x >= right,
                "panel "
                    .. index
                    .. " puts its battery at "
                    .. glyph.x
                    .. ", inside a reading column that ends at "
                    .. right
            )
        end

        -- And the reading stays on one line, which is the wrap a narrowed column
        -- would cause if the label kept the panel's full width.
        assertEqual(
            panel.value.lines,
            1,
            "panel " .. index .. " wrapped its reading into " .. tostring(panel.value.lines) .. " lines"
        )
    end

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

testBatteryGlyphFillsFromTheVoltage()
testBatteryStrokeFollowsTheReading()
testBatteryStrokeSurvivesReflow()
testBatteryGlyphShedsWhole()
testBatteryGlyphLeavesTheReadingRoom()
