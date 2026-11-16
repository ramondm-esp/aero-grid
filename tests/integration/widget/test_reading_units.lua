-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local hostIo = fixture.hostIo
local moduleLoader = fixture.module
local edgetx = fixture.edgetx
local radio = fixture.radio
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

local function testUnitFollowsTheReadingWidth()
    resetRadio()
    local widgetPath = makeWidget(
        "unit-follow",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: tx
    type: tx-battery
    col: 0
    row: 0
    colSpan: 3
    rowSpan: 2
    config:
      label: TX
      packEmpty: 6.6
      packFull: 8.4
      # The estimate, which gives this panel a supporting row and therefore
      # a half-height body band. Without it the band is three quarters and
      # the reading reaches XXLSIZE either way; with it the band is 62 px,
      # which holds XXLSIZE by ink where it held DBLSIZE by line height.
      showPercent: true
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 30)

    local tx = entryById(context, "tx").instance
    assert(tx.unit and not tx.unit.hidden, "the panel drew no unit to follow")

    --- Where the reading actually ends, asked of the same measurement the
    --- radio would use rather than of the estimate. Measuring the gap with
    --- `textWidth` here is what let the old one pass: the estimate is 58%
    --- generous, so it put the reading's right edge well beyond where it is
    --- drawn and made a 48 pixel gap look like a small one.
    local function unitGap()
        local reading = tx.value.properties
        local right = reading.x + lcd.sizeText(reading.text, reading.font())
        return tx.unit.properties.x - right
    end

    -- The fixture reads 7.9 V: three characters.
    assertEqual(tx.text, "7.9")
    local narrowGap = unitGap()
    local narrowX = tx.unit.properties.x
    assertEqual(
        narrowGap,
        themeModule.unitGap(tx.unit.properties.font()),
        "the unit does not begin where the reading ends plus the stated gap"
    )
    assert(
        narrowGap <= 3,
        "the unit sits " .. narrowGap .. " pixels from the number, which is a gap rather than a rider"
    )

    -- Four characters. The reading grows and the unit has to grow with it.
    radio.values[320] = 10.0
    settle(context, 30)
    assertEqual(tx.text, "10.0", "the reading did not change length, so this test proves nothing")
    assert(
        tx.unit.properties.x > narrowX,
        "the reading grew a character and"
            .. " the unit stayed at "
            .. tx.unit.properties.x
            .. ", which leaves it sitting inside the number"
    )
    assertEqual(unitGap(), narrowGap, "the unit followed the reading but not by the width it gained")

    -- And back, because a unit that only ever moves right would pass the line
    -- above and then overlap a reading that shortened.
    radio.values[320] = 7.9
    settle(context, 30)
    assertEqual(tx.text, "7.9")
    assertEqual(
        tx.unit.properties.x,
        narrowX,
        "the reading shrank and the unit stayed out at " .. tx.unit.properties.x .. ", leaving a gap"
    )

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testUnitsRideBesideEveryReading()
    resetRadio()
    radio.values[130] = { 4.11, 4.09, 4.12 }
    radio.values[140] = -70
    radio.values[141] = 88
    radio.values[106] = 120
    radio.values[120] = 2.5
    radio.values[109] = {
        lat = 47.3769,
        lon = 8.5417,
        ["pilot-lat"] = 47.3700,
        ["pilot-lon"] = 8.5400,
    }

    -- Six panels of the span under test in a 4 x 4 grid, which is the only
    -- shape the schema allows. Three fit at 2 x 2, so the six are split across
    -- two layouts rather than crammed into one.
    local function layoutAt(colSpan, rowSpan, from, count)
        local lines = { "version: 1", "grid:", "  columns: 4", "  rows: 4", "panels:" }
        local panels = {
            {
                id = "alt",
                type = "metric",
                config = "      metrics:\n        - source: Alt\n          unit: m\n          precision: 0\n",
            },
            { id = "cells", type = "rx-battery", config = "      source: Cels\n      reading: cell\n" },
            {
                id = "link",
                type = "link-status",
                config = "      rssiSource: 1RSS\n      qualitySource: RQly\n" .. "      reading: rssi\n",
            },
            { id = "nav", type = "navigation", config = "      source: GPS\n      presentation: distance\n" },
            { id = "tx", type = "tx-battery", config = "      packEmpty: 6.6\n      packFull: 8.4\n" },
            {
                id = "gv",
                type = "metric",
                config = "      metrics:\n        - source: Curr\n          rangeMin: 0\n          rangeMax: 120\n",
            },
        }
        local chosen = {}
        for index = from, math.min(from + count - 1, #panels) do
            chosen[#chosen + 1] = panels[index]
        end

        local col, row = 0, 0
        for _, panel in ipairs(chosen) do
            if col + colSpan > 4 then
                col, row = 0, row + rowSpan
            end
            lines[#lines + 1] = "  - id: " .. panel.id
            lines[#lines + 1] = "    type: " .. panel.type
            lines[#lines + 1] = "    col: " .. col
            lines[#lines + 1] = "    row: " .. row
            lines[#lines + 1] = "    colSpan: " .. colSpan
            lines[#lines + 1] = "    rowSpan: " .. rowSpan
            lines[#lines + 1] = "    config:"
            lines[#lines + 1] = string.gsub(panel.config, "\n$", "")
            col = col + colSpan
        end
        return table.concat(lines, "\n"), chosen
    end

    local seenFonts = {}
    local checked = 0

    for _, span in ipairs({ { 2, 2, 1 }, { 2, 2, 4 }, { 2, 1, 1 }, { 2, 1, 4 } }) do
        local text, panels = layoutAt(span[1], span[2], span[3], 3)
        local widgetPath = makeWidget("units-" .. span[1] .. "x" .. span[2] .. "-" .. span[3], text)
        local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
        settle(context, 60)

        for _, panel in ipairs(panels) do
            local instance = entryById(context, panel.id).instance
            local where = panel.type .. " at " .. span[1] .. "x" .. span[2]

            -- Its own object. A panel that glued the unit back onto the
            -- reading would have no unit label at all.
            assert(instance.unit, where .. " draws no separate unit")

            local readingLabel = instance.value
            local reading = readingLabel.properties.text
            local unit = instance.unit.properties.text

            if not instance.unit.hidden and unit ~= "" then
                checked = checked + 1
                local readingFont = readingLabel.properties.font()
                local unitFont = instance.unit.properties.font()
                seenFonts[edgetx.fontName(readingFont)] = true

                assert(
                    themeModule.fontHeight(unitFont) < themeModule.fontHeight(readingFont),
                    where
                        .. " draws its unit at "
                        .. edgetx.fontName(unitFont)
                        .. ", which is not smaller than the reading's "
                        .. edgetx.fontName(readingFont)
                )

                -- The reading is digits alone. If the unit were still glued on, the
                -- panel would be printing it twice.
                assert(
                    not string.find(reading, unit, 1, true),
                    where .. " prints its unit inside the reading (" .. reading .. ") as well as beside it"
                )

                -- And the pair fits the column, measured together. Measuring the
                -- number alone is what let a 116 pixel string into a 105 pixel
                -- column for three milestones.
                --
                -- Measured rather than estimated, because the column is now measured
                -- too: a label is sized to the string it actually draws, and LVGL
                -- wraps against the same real advances. Asking the estimate here
                -- would compare a generous number against an exact one and report
                -- overflow on panels that have none.
                local pairWidth = themeModule.measureText(readingFont, reading)
                    + themeModule.unitGap(unitFont)
                    + themeModule.measureText(unitFont, unit)
                local column = readingLabel.properties.w
                assert(
                    pairWidth <= column,
                    where
                        .. " draws "
                        .. reading
                        .. " "
                        .. unit
                        .. " needing "
                        .. pairWidth
                        .. " in a column of "
                        .. column
                )

                -- Neither label wraps, which is the failure no assertion about text
                -- content can see.
                assertEqual(readingLabel.lines, 1, where .. " wrapped its reading")
                assertEqual(instance.unit.lines, 1, where .. " wrapped its unit")

                -- The baseline, which is the whole point of the arrangement.
                assertEqual(
                    instance.unit.properties.y + themeModule.fontAscent(unitFont),
                    readingLabel.properties.y + themeModule.fontAscent(readingFont),
                    where .. " does not sit its unit on the reading's baseline"
                )

                -- And the horizontal placement, held to the same standard: the unit
                -- begins where the reading *ends*, measured the way the radio
                -- measures, plus the stated gap and nothing else.
                --
                -- Asserting that the unit is merely to the right of the reading is
                -- what the 48 pixel gap satisfied, so this pins the distance instead.
                local drawnRight = readingLabel.properties.x + lcd.sizeText(reading, readingFont)
                assertEqual(
                    instance.unit.properties.x - drawnRight,
                    themeModule.unitGap(unitFont),
                    where .. " places its unit against an estimate rather than against" .. " where the reading is drawn"
                )
            end
        end
    end

    -- The two spans really did produce different reading sizes, or the whole
    -- exercise collapsed into one case.
    local sizes = 0
    for _ in pairs(seenFonts) do
        sizes = sizes + 1
    end
    assert(
        sizes >= 2,
        "every panel resolved the same reading font, so this" .. " test says nothing about a rule that varies with size"
    )
    assert(checked >= 8, "only " .. checked .. " panels actually drew a unit to check")
end

local function testUnitsAreNotDrawnBesideAnAbsentReading()
    local panelHost = assert(loadfile(sourcePath .. "lib/panel_host.lua"))()

    -- Live enough to resolve a unit, absent enough to have no value.
    local UNIT_CONFIG = {
        ["state"] = "      entries:\n        - label: MODE\n          states:\n"
            .. "            - switch: SA^\n              text: LOW\n            - switch: SAv\n              text: HIGH\n",
        ["link-status"] = "      reading: rssi\n      rssiSource: RSSI\n",
        ["metric"] = "      metrics:\n        - source: VSpd\n          unit: m/s\n",
    }

    local listingPath = root .. "/build/unit-panels.txt"
    os.execute("ls '" .. sourcePath .. "panels' > '" .. listingPath .. "'")
    local listing = assert(hostIo.open(listingPath, "r"))
    local stems = {}
    for name in listing:lines() do
        local stem = string.match(name, "^(.+)%.lua$")
        if stem then
            stems[#stems + 1] = stem
        end
    end
    listing:close()
    os.remove(listingPath)
    assert(#stems > 0, "no panels were found to sweep")

    local constructed = {}
    local built = 0
    for _, stem in ipairs(stems) do
        local module = moduleLoader("panels/" .. stem .. ".lua")
        for colSpan = 1, 4 do
            for rowSpan = 1, 4 do
                if panelHost.supportsSpan(module, colSpan, rowSpan) then
                    resetRadio()
                    -- Every sensor resolves through getFieldInfo and none of them
                    -- delivers, because EdgeTX reports integer zero for a telemetry
                    -- source while telemetry is not streaming and the service withholds
                    -- exactly that. The transmitter's own voltage is radio-local rather
                    -- than link-dependent, so it is taken away separately.
                    radio.rssi = 0
                    radio.values[radio.fields["tx-voltage"].id] = nil

                    local widgetPath = makeWidget(
                        "unit-sweep",
                        table.concat({
                            "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n",
                            "  - id: probe\n    type: ",
                            stem,
                            "\n    col: 0\n    row: 0\n    colSpan: ",
                            tostring(colSpan),
                            "\n    rowSpan: ",
                            tostring(rowSpan),
                            "\n    config:\n",
                            UNIT_CONFIG[stem] or "",
                        })
                    )
                    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
                    settle(context, 40)

                    local entry = entryById(context, "probe")
                    if entry then
                        built = built + 1
                        local instance = entry.instance
                        local unit = instance.unit
                        local where = stem .. " " .. colSpan .. "x" .. rowSpan
                        if unit and (instance.unitText or "") ~= "" then
                            -- The unit is known and the value is not, which is the state
                            -- the defect lived in. Without this the sweep could run
                            -- entirely over panels that never learned a unit.
                            assert(
                                primitivesModule.SENTINELS[instance.text],
                                where
                                    .. " prints `"
                                    .. tostring(instance.text)
                                    .. "` for a"
                                    .. " value it does not have, which is not one of the"
                                    .. " sentinels the rule knows, so its unit is drawn beside"
                                    .. " an absent reading"
                            )
                            constructed[stem] = true
                            assertEqual(
                                unit.hidden,
                                true,
                                where
                                    .. " drew `"
                                    .. tostring(instance.text)
                                    .. " "
                                    .. tostring(instance.unitText)
                                    .. "`, and a unit with no"
                                    .. " value to qualify is a label for nothing"
                            )
                        end
                    end
                end
            end
        end
    end

    assert(built >= 40, "only " .. built .. " panels were swept")

    -- **A sweep that constructed no unit at all would satisfy every assertion
    -- above.** These four are the panels measured to have drawn one beside
    -- a sentinel before the fix; naming them is what stops the test passing
    -- because a panel stopped learning its unit rather than because it stopped
    -- drawing it.
    for _, stem in ipairs({ "tx-battery", "rx-battery", "link-status", "metric" }) do
        assert(
            constructed[stem],
            stem
                .. " never reached a panel that knew its"
                .. " unit and had no value, so this swept past the case it exists for"
        )
    end
end

local function testAReflowDoesNotRestoreAnOrphanedUnit()
    resetRadio()
    -- A cells sensor the radio knows and has never delivered, which is the
    -- state that pairs a unit with no value: `rx-battery`'s unit is a
    -- constant -- a cell is measured in volts whatever the sensor says -- so
    -- the panel knows it is drawing volts before it has any.
    radio.values[130] = nil
    local widgetPath = makeWidget(
        "orphan-unit",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: pack
    type: rx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: Cels
]]
    )

    local zone = { x = 0, y = 0, w = 480, h = 272 }
    local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
    settle(context, 20)
    local instance = entryById(context, "pack").instance

    local function reflow()
        local passes = 0
        repeat
            definition.refresh(context)
            passes = passes + 1
            assert(passes < 100, "reflow never finished")
        until reflowDone(context)
    end

    assert(instance.unit, "this test needs a panel that built a unit")
    assertEqual(instance.unitText, "V", "this test needs a panel that knows its unit without being told")
    assertEqual(instance.text, "--", "this test needs a panel with no reading")
    assertEqual(instance.unit.hidden, true, "a unit was drawn beside `--`")

    -- Keep unit permission through a resize, including the rx-battery's
    -- 30% whitespace requirement, to exercise the reflow short-circuit.
    zone.w = 400
    zone.h = 200
    definition.update(context, DEFAULT_OPTIONS)
    reflow()
    assert(
        instance.area.showUnit,
        "this step must keep the unit permitted, or it is not testing the" .. " short-circuit it was written for"
    )
    assertEqual(instance.unit.hidden, true, "a reflow put the unit back beside a reading that still has no value")

    -- **And one that does move it.** Measured: the same panel at 240 x 272 is
    -- too narrow for the pair, so the permission is genuinely withdrawn and
    -- genuinely returns, which is the other branch.
    zone.w = 240
    zone.h = 272
    definition.update(context, DEFAULT_OPTIONS)
    reflow()
    assertEqual(
        instance.area.showUnit,
        false,
        "this step must withdraw the unit's permission, or the widening below" .. " restores nothing and proves nothing"
    )
    assertEqual(instance.unit.hidden, true)

    zone.w = 480
    zone.h = 272
    definition.update(context, DEFAULT_OPTIONS)
    reflow()
    assert(instance.area.showUnit, "the permission never came back")
    assertEqual(instance.unit.hidden, true, "growing the panel restored a unit to a reading that still has no value")

    -- And the panel is not merely stuck hidden: a reading arriving brings the
    -- unit back. Without this the assertions above are satisfied by a unit
    -- that never shows at all, which is the other way to be wrong.
    radio.values[130] = { 4.11, 4.13, 4.09, 4.12 }
    settle(context, 60)
    assertEqual(instance.text, "4.09", "the pack never delivered a reading")
    assertEqual(instance.unit.hidden, false, "a reading arrived and its unit stayed away")
end

testUnitFollowsTheReadingWidth()
testUnitsRideBesideEveryReading()
testUnitsAreNotDrawnBesideAnAbsentReading()
testAReflowDoesNotRestoreAnOrphanedUnit()
