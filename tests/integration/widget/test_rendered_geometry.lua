-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local developmentLayoutsPath = root .. "/tests/fixtures/layouts/development/"
local hostIo = fixture.hostIo
local edgetx = fixture.edgetx
local lvglMock = fixture.lvglMock
local appZone = fixture.lvglMock.appZone
local fullScreenZone = fixture.lvglMock.fullScreenZone
local radio = fixture.radio
local resetRadio = fixture.reset
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local writeFile = fixture.writeFile
local makeWidget = fixture.makeWidget
local themeModule = fixture.module("lib/theme.lua")
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local pump = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end
local geometry = assert(loadfile(root .. "/tests/support/widget_geometry.lua"))(fixture)
local assertNothingOverlaps = geometry.assertNothingOverlaps
local assertMenuClear = geometry.assertMenuClear
assert(
    themeModule.setCatalog(
        assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
    )
)

local boundsOf = fixture.boundsOf

local function testNothingIsDrawnOverAnythingElse()
    -- Every shipped layout, because the directory is the list. A layout is
    -- covered the moment it is added, exactly like the load coverage.
    local listingPath = root .. "/build/collide-layouts.txt"
    local names = {}

    -- **Both the shipped layouts and the retired galleries.** The four span
    -- galleries were taken off the radio because nobody paged to them, and
    -- they are still built here because of what they construct: eleven
    -- panels in one grid at one span, which is the densest arrangement
    -- this dashboard can be asked for and therefore where two things are
    -- likeliest to meet. Retiring a layout from a screen is a decision about
    -- the radio; deleting the cases it builds would have been a quiet
    -- reduction in what this check covers.
    local function collect(directory, prefix)
        os.execute("ls '" .. directory .. "' > '" .. listingPath .. "'")
        local listing = assert(hostIo.open(listingPath, "r"))
        for name in listing:lines() do
            local stem = string.match(name, "^(.+)%.yaml$")
            if stem then
                names[#names + 1] = { stem = stem, path = directory .. name, label = prefix .. stem }
            end
        end
        listing:close()
        os.remove(listingPath)
    end

    collect(sourcePath .. "layouts/", "")
    collect(root .. "/tests/fixtures/layouts/", "retired ")
    collect(developmentLayoutsPath, "development ")
    assert(#names > 1, "no layouts were found to check")

    local galleries = 0
    for _, entry in ipairs(names) do
        if string.match(entry.stem, "^span") then
            galleries = galleries + 1
        end
    end
    assertEqual(
        galleries,
        4,
        "the four retired span galleries are no longer being built, so the"
            .. " densest arrangement in the catalogue is not being checked for"
            .. " collisions by anything"
    )

    for index, entry in ipairs(names) do
        local source = assert(hostIo.open(entry.path, "r"))
        local yaml = source:read("a")
        source:close()
        local widget = makeWidget("catalog-" .. index, yaml)
        local declared = 0
        for _ in string.gmatch(yaml, "\n  %- id:") do
            declared = declared + 1
        end
        assert(declared > 0 or entry.stem == "Empty", entry.label .. ": no panels were declared")
        for _, mode in ipairs({ { "full screen", fullScreenZone }, { "app mode", appZone } }) do
            resetRadio()
            local context = createLoaded(mode[2](), DEFAULT_OPTIONS, widget)
            assertEqual(lvgl.isAppMode(), mode[1] == "app mode", entry.label .. ": wrong display mode")
            assertEqual(#context.panels, declared, entry.label .. ": declared panels did not load")
            pump(context, 60)
            assertEqual(#context.errors, 0, entry.label .. ": " .. table.concat(context.errors, "\n"))
            fixture.assertContained(context, entry.label)
            fixture.assertNoOverlap(context)
            assertNothingOverlaps(mode[1] .. " layout " .. entry.label, context)
            if lvgl.isAppMode() then
                assertMenuClear(entry.label, context)
            end
        end
    end
end

local function testAReadingAloneTakesTheWholePanel()
    local theme = themeModule

    local widgetPath = makeWidget(
        "alone",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: solo
    type: metric
    col: 1
    row: 1
    colSpan: 1
    rowSpan: 1
    config:
      metrics:
        - source: Alt
          label: ALT
          precision: 0
      visual: none
]]
    )

    resetRadio()
    local zone = fullScreenZone()
    zone.w, zone.h = 380, 188
    local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
    pump(context, 40)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

    local entry = assert(entryById(context, "solo"), "the panel was not built")
    local instance = entry.instance
    local area = instance.area
    local bounds = boundsOf(entry)

    -- **The premises, asserted rather than assumed.** If any stopped holding,
    -- the panel below would be an ordinary shared one and the branch this test
    -- exists for would go unvisited while every assertion passed.
    assertEqual(bounds.w, 92, "the cell is not the size this test was measured" .. " against")
    assertEqual(bounds.h, 44, "the cell is not the size this test was measured" .. " against")
    assert(area.frame.labelHidden, "this panel is wide enough for a heading, so it is not alone")
    assertEqual(instance.label.hidden, true, "a heading the frame dropped was drawn anyway")
    assertEqual(area.ladder.rows, 0, "this panel was granted a supporting row, so it is not alone")
    assertEqual(area.ladder.visual, false, "this panel was granted a visualization, so it is not alone")
    assertEqual(context.reserved, nil, "this panel sits under the menu button, so it is not alone")

    -- The budget is more than a half, which is the whole of the difference.
    assert(
        area.ladder.room > math.floor(bounds.h / 2),
        "a panel with nothing"
            .. " on it but its reading was still sized against a half: room "
            .. area.ladder.room
            .. " against "
            .. math.floor(bounds.h / 2)
    )

    -- And it buys a size, which is what makes the branch observable rather
    -- than merely taken: 24 px holds MIDSIZE at 23 px of ink, a half of 44 is
    -- 22 and holds SMLSIZE at 13.
    assertEqual(
        edgetx.fontName(area.value),
        "MIDSIZE",
        "the whole-panel budget bought no size, so it is indistinguishable from" .. " the half"
    )
    assertEqual(
        edgetx.fontName(theme.bandFont(math.floor(bounds.h / 2))),
        "SMLSIZE",
        "a half of this panel now holds the same font as the whole of it, so"
            .. " this panel no longer tells the two budgets apart"
    )

    -- Centred on the panel like every other reading, and inside it.
    local ink = theme.fontAscent(area.value)
    assert(math.abs((area.valueY + ink / 2) - bounds.h / 2) <= 1, "a reading alone on its panel is not centred on it")
    assert(
        area.valueY >= 0 and area.valueY + ink + theme.riderDepth() <= bounds.h,
        "a reading sized against the whole panel ran off it"
    )

    -- **And the same panel with a bar on it is not alone.** This is the half
    -- of the rule that was added on a measured collision and then very nearly
    -- removed as unprovable: with a row and a heading the only furniture, a
    -- panel too small for either but tall enough for a bar took its whole
    -- height. Measured here rather than argued: a 380 x 156 zone gives a
    -- `1 x 2` a 92 by 76 panel, whose heading is dropped at 95 px of width
    -- and whose supporting row is refused below 79 px of height -- but whose
    -- bar is granted at 48. Counting the bar leaves the reading at DBLSIZE
    -- ending at 53; not counting it gives XXLSIZE ending at 65, against a
    -- track that starts at 68 and a rider that reaches 71.
    local barPath = makeWidget(
        "alone-bar",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: barred
    type: metric
    col: 1
    row: 1
    colSpan: 1
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          label: ALT
          precision: 0
          rangeMin: 0
          rangeMax: 400
      visual: bar
]]
    )

    resetRadio()
    local barZone = fullScreenZone()
    barZone.w, barZone.h = 380, 156
    local barred = createLoaded(barZone, DEFAULT_OPTIONS, barPath)
    pump(barred, 40)
    assertEqual(#barred.errors, 0, table.concat(barred.errors, "\n"))

    local barEntry = assert(entryById(barred, "barred"), "the panel was not built")
    local barArea = barEntry.instance.area
    local barBounds = boundsOf(barEntry)
    assertEqual(barBounds.w, 92, "the bar panel is not the measured size")
    assertEqual(barBounds.h, 76, "the bar panel is not the measured size")
    assert(not barArea.frame.labelHidden, "the bar panel lost the heading its empty badge leaves room for")
    assertEqual(barArea.ladder.rows, 0, "the bar panel was granted a row")
    assertEqual(barArea.ladder.visual, true, "the bar panel was granted no bar")
    assertEqual(barEntry.instance.showVisual, true, "the bar was never drawn")

    assert(
        barArea.ladder.room <= math.floor(barBounds.h / 2),
        "a panel carrying a bar was sized as though nothing shared it: room "
            .. barArea.ladder.room
            .. " on a "
            .. barBounds.h
            .. " px panel"
    )
    local barInk = theme.fontAscent(barArea.value)
    assert(
        barArea.valueY + barInk + theme.riderDepth() <= barArea.barY,
        "the reading reaches "
            .. (barArea.valueY + barInk + theme.riderDepth())
            .. ", into a bar whose track starts at "
            .. barArea.barY
    )
    lvglMock.setAppMode(false)
end

local function testTheCornerFollowsEveryPanelInFullscreen()
    local widgetPath = makeWidget(
        "fullscreen-corner",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: corner
    type: metric
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      metrics:
        - source: Alt
          label: ALT
          precision: 0
      visual: none
  - id: clear
    type: metric
    col: 2
    row: 2
    colSpan: 1
    rowSpan: 1
    config:
      metrics:
        - source: Alt
          label: ALT
          precision: 0
      visual: none
]]
    )

    resetRadio()
    local zone = appZone()
    local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
    pump(context, 40)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

    local corner = entryById(context, "corner").instance
    local clear = entryById(context, "clear").instance

    -- The premise: while the button is drawn the two panels are the same size
    -- and lay out differently, which is the corner being a corner.
    assertEqual(
        boundsOf(entryById(context, "corner")).h,
        boundsOf(entryById(context, "clear")).h,
        "the two panels are not the same height, so nothing below compares them"
    )
    assert(context.reserved, "App mode reserved nothing for the menu button")
    assert(corner.area.content < clear.area.content, "the one-row corner panel was not reserving width for the button")
    local buttoned = corner.area.valueCentre

    -- Fullscreen. The zone is untouched -- deliberately, because that is what
    -- the firmware does -- so the only thing that changes is the flag.
    lvglMock.setFullScreen(true)

    -- Fullscreen replaces the native button with the same-sized AeroGrid button.
    definition.refresh(context)
    assert(context.reserved, "fullscreen must reserve the AeroGrid button footprint")

    local passes = 0
    while context.reflowIndex do
        definition.refresh(context)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    end
    pump(context, 10)
    assert(corner.area.content < clear.area.content, "fullscreen must retain the corner reservation")
    assertEqual(corner.area.valueCentre, buttoned, "fullscreen and native buttons must reserve the same width")

    -- And back, because a pilot leaves fullscreen as often as they enter it
    -- and the firmware raises nothing at all on the way out.
    lvglMock.setFullScreen(false)
    definition.refresh(context)
    assert(context.reserved, "one refresh after leaving fullscreen, the corner was not reserved again")
    passes = 0
    while context.reflowIndex do
        definition.refresh(context)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    end
    pump(context, 10)
    assertEqual(corner.area.valueCentre, buttoned, "the corner panel did not restore the left reservation")
    lvglMock.setAppMode(false)
end

local function testReadingsAreCentredOnTheirPanel()
    testAReadingAloneTakesTheWholePanel()
    testTheCornerFollowsEveryPanelInFullscreen()
    local theme = themeModule

    --- Every panel, configured so it actually builds a reading. Read from
    --- the panel directory rather than listed, so a panel added to the
    --- catalogue is covered from the moment it exists.
    local CONFIG = {
        ["state"] = {
            "      entries:",
            "        - label: MODE",
            "          states:",
            "            - switch: SA^",
            "              text: LOW",
            "            - switch: SA-",
            "              text: MID",
            "            - switch: SAv",
            "              text: HIGH",
        },
        ["metric"] = { "      metrics:", "        - source: Alt", "          label: ALT", "          unit: m" },
        ["flight-timer"] = { "      label: TIMER", "      timer: 0" },
        ["flight-mode"] = { "      label: MODE" },
        ["flight-counter"] = { "      label: FLT" },
        ["tx-battery"] = { "      label: TX" },
        ["trim-panel"] = { "      label: TRIM", "      trim1: trim-ail" },
        ["model-identity"] = { "      label: MODEL" },
        ["rx-battery"] = { "      label: PACK", "      source: Cels" },
        ["link-status"] = { "      label: LINK", "      rssiSource: RSSI", "      qualitySource: RQly" },
        ["navigation"] = { "      label: HOME", "      source: GPS" },
        ["host-diagnostics"] = { "      label: HOST" },
        ["service-probe"] = { "      label: PROBE", "      service: telemetry" },
        ["heartbeat"] = { "      label: BEAT" },
        ["placeholder"] = { "      label: HOLD" },
        ["theme-showcase"] = {},
    }

    local types = {}
    for _, directory in ipairs({ sourcePath .. "panels", root .. "/tests/fixtures/panels" }) do
        local listingPath = root .. "/build/centre-types.txt"
        os.execute("ls '" .. directory .. "' > '" .. listingPath .. "'")
        local listing = assert(hostIo.open(listingPath, "r"))
        for name in listing:lines() do
            local stem = string.match(name, "^(.+)%.lua$")
            if stem then
                types[#types + 1] = stem
            end
        end
        listing:close()
        os.remove(listingPath)
    end
    assert(#types >= 13, "only " .. #types .. " panel types were found")

    local widgetPath = makeWidget("centred")
    -- Both placements. The top-left cell is the one EdgeTX paints its button
    -- over and is a different panel; every other cell is clear of it, and a
    -- sweep that only ever builds one of the two measures one case.
    local PLACES = { { "clear", 4, 4 }, { "corner", 0, 0 } }
    local ZONES = {
        {
            "app mode",
            function()
                return appZone()
            end,
        },
        {
            "full screen",
            function()
                return fullScreenZone()
            end,
        },
    }

    local centred, clamped, cleared, sideReserved = 0, 0, 0, 0

    for _, kind in ipairs(types) do
        for _, span in ipairs({ { 1, 1 }, { 2, 1 }, { 2, 2 }, { 3, 2 }, { 4, 2 }, { 2, 3 }, { 4, 4 } }) do
            for _, place in ipairs(PLACES) do
                for _, zone in ipairs(ZONES) do
                    local col = math.max(0, place[2] - span[1])
                    local row = math.max(0, place[3] - span[2])
                    writeFile(
                        widgetPath .. "layouts/Default.yaml",
                        table.concat({
                            "version: 1",
                            "grid:",
                            "  columns: 4",
                            "  rows: 4",
                            "panels:",
                            "  - id: subject",
                            "    type: " .. kind,
                            "    col: " .. col,
                            "    row: " .. row,
                            "    colSpan: " .. span[1],
                            "    rowSpan: " .. span[2],
                            "    config:",
                            table.concat(CONFIG[kind] or { "      label: Probe" }, "\n"),
                            "",
                        }, "\n")
                    )

                    resetRadio()
                    local context = createLoaded(zone[2](), DEFAULT_OPTIONS, widgetPath)
                    pump(context, 40)
                    local entry = context.panels[1]
                    local where = kind .. " " .. span[1] .. "x" .. span[2] .. " " .. place[1] .. " " .. zone[1]
                    -- A span a panel declines is a refusal, not a defect, and the
                    -- host says so through the error channel. Nothing was built, so
                    -- there is nothing to measure.
                    if entry then
                        assertEqual(#context.errors, 0, where .. ": " .. table.concat(context.errors, "\n"))
                    end

                    local instance = entry and entry.instance
                    local area = instance and instance.area
                    if area and area.ladder and area.value and area.valueY then
                        local bounds = boundsOf(entry)
                        local ink = theme.fontAscent(area.value)
                        local top = area.valueY
                        local reserved = place[1] == "corner" and context.reserved or nil

                        if area.frame.reserved and area.frame.reserved.side then
                            sideReserved = sideReserved + 1
                            assert(area.pad >= area.frame.reserved.w, where .. ": left reservation was lost")
                        end
                        if reserved and not area.frame.reserved.side and top == reserved.h then
                            -- The one panel the widget does not own outright. The button
                            -- is painted over anything drawn beneath it, so the reading
                            -- starts at the button's own bottom edge instead -- and its
                            -- room was capped to match, so it still ends inside the panel.
                            clamped = clamped + 1
                            assert(
                                top + ink <= bounds.h,
                                where
                                    .. ": a reading pushed below the menu button ran off the"
                                    .. " panel, "
                                    .. (top + ink)
                                    .. " in "
                                    .. bounds.h
                            )
                        elseif
                            area.visualSize
                            and area.showUnit
                            and top == area.frame.labelY + area.frame.labelHeight
                        then
                            clamped = clamped + 1
                            assert(top + ink <= bounds.h, where .. ": header clearance pushed the reading off-panel")
                        else
                            -- **Pinned against the panel, not against a band.** One pixel
                            -- of tolerance is the floor of an odd height, and nothing
                            -- else: a reading centred in the old body band sits 3 to 5 px
                            -- low on an unobstructed panel and 19 px low in the corner,
                            -- so this goes red on either.
                            local offset = (top + ink / 2) - bounds.h / 2
                            centred = centred + 1
                            assert(
                                math.abs(offset) <= 1,
                                where
                                    .. ": the reading's ink is centred at "
                                    .. (top + ink / 2)
                                    .. " on a panel whose centre is "
                                    .. (bounds.h / 2)
                                    .. ", "
                                    .. offset
                                    .. " px out"
                            )
                        end

                        -- **And it is alone there.** The heading is pinned to the top
                        -- of the panel and a supporting row sits in the bottom quarter;
                        -- neither is derived from the reading's position any more, so
                        -- the clearance is asserted rather than assumed. A rider's
                        -- descent counts against the reading, because it is drawn on
                        -- the reading's own baseline.
                        local heading = instance.label
                        if heading and not heading.hidden and tostring(heading.properties.text or "") ~= "" then
                            local font = heading.properties.font
                            if type(font) == "function" then
                                font = font()
                            end
                            local bottom = (heading.properties.y or 0) + theme.fontAscent(font)
                            cleared = cleared + 1
                            assert(
                                top >= bottom,
                                where
                                    .. ": the reading starts at "
                                    .. top
                                    .. ", inside a heading that ends at "
                                    .. bottom
                            )
                        end

                        local rowY = area.detailY
                        if instance.showDetail and rowY then
                            local depth = area.showUnit and theme.riderDepth() or 0
                            cleared = cleared + 1
                            assert(
                                top + ink + depth <= rowY,
                                where
                                    .. ": the reading reaches "
                                    .. (top + ink + depth)
                                    .. ", into a supporting row that starts at "
                                    .. rowY
                            )
                        end
                    end
                end
            end
        end
    end

    -- Per property, so a sweep that stopped building panels cannot pass by
    -- checking nothing -- which is how this suite's own apparatus has failed
    -- seven times.
    assert(centred >= 80, "only " .. centred .. " panels had their reading's centre checked")
    assert(clamped >= 14, "only " .. clamped .. " taller panels exercised the menu button's vertical clamp")
    assert(sideReserved >= 10, "only " .. sideReserved .. " one-row panels reserved width for the button")
    assert(cleared >= 139, "only " .. cleared .. " clearances were checked")
    lvglMock.setAppMode(false)
end

local function testReadingsDoNotDescendOverAnything()
    testReadingsAreCentredOnTheirPanel()
    -- **The instrument first.** A check that cannot report a descender would
    -- agree with everything below while proving nothing, which is the failure
    -- mode this suite keeps finding in its own apparatus. So it is made to
    -- disagree on purpose before it is trusted when it agrees.
    assert(edgetx.textDescent(XXLSIZE, "rpm") > 0, "the fixture cannot see a descender, so nothing below is a check")
    assert(edgetx.textDescent(XXLSIZE, "km/h") > 0, "the fixture cannot see a solidus descend")
    for _, safe in ipairs({ "-888.88", "1:04:12", "120.0", "%", "V", "dBm" }) do
        assertEqual(
            edgetx.textDescent(XXLSIZE, safe),
            0,
            "the fixture reports a descender in " .. safe .. ", so it would report one anywhere"
        )
    end

    -- Every unit the dashboard can render that reaches below the baseline,
    -- taken from `telemetry_service`'s own table rather than invented. Each is
    -- given to a `metric` through its `unit` setting, which is the same string
    -- a resolved sensor would have produced.
    local DESCENDING_UNITS = { "rpm", "mph", "deg", "g", "km/h", "m/s", "ml/m" }

    -- A span that draws a bar **and** a supporting row, so there is something
    -- in the strip below the baseline for a descender to land on. A one-row
    -- panel sheds the row; this is the case where the reading has least air
    -- beneath it.
    local SPANS = { { 2, 1 }, { 4, 1 }, { 2, 2 }, { 4, 2 } }
    -- Built rather than stored, because a zone carries the App mode flag as
    -- well as a rectangle and constructing both up front leaves the second
    -- one's flag in force for the first.
    local ZONES = { { "full screen", fullScreenZone }, { "app mode", appZone } }

    local drewAUnit, drewAName = 0, 0

    for _, unit in ipairs(DESCENDING_UNITS) do
        for _, span in ipairs(SPANS) do
            for _, mode in ipairs(ZONES) do
                resetRadio()
                local widget = makeWidget(
                    "descend-"
                        .. string.gsub(unit, "/", "-")
                        .. "-"
                        .. span[1]
                        .. "x"
                        .. span[2]
                        .. "-"
                        .. string.gsub(mode[1], " ", ""),
                    table.concat({
                        "version: 1\n",
                        "grid:\n  columns: 4\n  rows: 4\n",
                        "panels:\n",
                        "  - id: subject\n    type: metric\n",
                        "    col: 0\n    row: 0\n",
                        "    colSpan: ",
                        tostring(span[1]),
                        "\n",
                        "    rowSpan: ",
                        tostring(span[2]),
                        "\n",
                        "    config:\n",
                        "      metrics:\n        - source: Alt\n          label: RATE\n",
                        '          unit: "',
                        unit,
                        '"\n',
                        "          rangeMin: 0\n          rangeMax: 400\n",
                        "          precision: 0\n",
                        "        - source: Curr\n          label: CUR\n      visual: bar\n",
                    })
                )
                local context = createLoaded(mode[2](), DEFAULT_OPTIONS, widget)
                pump(context, 60)
                assertEqual(#context.errors, 0, unit .. ": " .. table.concat(context.errors, "\n"))

                local panel = entryById(context, "subject").instance
                if panel.showUnit then
                    assertEqual(
                        panel.unit.properties.text,
                        unit,
                        "the unit the layout asked for never reached the label"
                    )
                    drewAUnit = drewAUnit + 1
                end
                assertNothingOverlaps(mode[1] .. " " .. unit .. " " .. span[1] .. "x" .. span[2], context)
            end
        end
    end

    -- And the one reading that is free text. `model-identity` is the only
    -- panel whose reading is a name rather than a number, and a name is the
    -- one string on this dashboard nobody here chooses.
    for _, name in ipairs({ "Puppy", "Gypsy Moth", "jjjj", "Q_[g]" }) do
        for _, span in ipairs({ { 2, 2 }, { 4, 2 }, { 4, 4 } }) do
            for _, mode in ipairs(ZONES) do
                resetRadio()
                radio.modelName = name
                local widget = makeWidget(
                    "descend-name-"
                        .. string.gsub(name, "[^%w]", "")
                        .. "-"
                        .. span[1]
                        .. "x"
                        .. span[2]
                        .. "-"
                        .. string.gsub(mode[1], " ", ""),
                    table.concat({
                        "version: 1\n",
                        "grid:\n  columns: 4\n  rows: 4\n",
                        "panels:\n",
                        "  - id: subject\n    type: model-identity\n",
                        "    col: 0\n    row: 0\n",
                        "    colSpan: ",
                        tostring(span[1]),
                        "\n",
                        "    rowSpan: ",
                        tostring(span[2]),
                        "\n",
                        "    config:\n",
                        "      presentation: name\n",
                        "      label: MODEL\n",
                        "      showLabels: true\n",
                    })
                )
                local context = createLoaded(mode[2](), DEFAULT_OPTIONS, widget)
                pump(context, 60)
                assertEqual(#context.errors, 0, name .. ": " .. table.concat(context.errors, "\n"))

                local panel = entryById(context, "subject").instance
                assertEqual(panel.text, name, "the hostile model name never reached the panel")
                drewAName = drewAName + 1
                assertNothingOverlaps(mode[1] .. " name " .. name .. " " .. span[1] .. "x" .. span[2], context)
            end
        end
    end

    -- Neither sweep may be vacuous. A panel that shed every unit, or a name
    -- that never reached a label, would take this whole check with it.
    assert(drewAUnit > 0, "every panel shed its unit, so no descending unit was ever drawn")
    assert(drewAName > 0, "no model name was ever drawn")
    resetRadio()
end

local function testNothingReadableUnderTheMenuButton()
    -- The worst case the grid permits: a single cell in the corner, where the
    -- button covers 40% of the width and 69% of the height. The reading has to
    -- survive even though the label cannot.
    local cramped = makeWidget(
        "appmode-cramped",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: tight
    type: metric
    col: 0
    row: 0
    colSpan: 1
    rowSpan: 1
    config:
      metrics:
        - source: RxBt
          label: Pack
          precision: 1
]]
    )
    resetRadio()
    local context = createLoaded(appZone(), DEFAULT_OPTIONS, cramped)
    pump(context, 60)
    assertMenuClear("1 x 1 corner", context)

    local tight = entryById(context, "tight").instance
    assertEqual(tight.value.properties.text, "24.0", "the reading was lost rather than moved")
    assertEqual(tight.badge.properties.text, "")
    assertEqual(tight.label.hidden, false, "the empty badge still hides a title that fits beside the button")
    assertEqual(tight.label.properties.text, "PACK")

    -- Every catalogue panel, at every span the grid allows, in the corner.
    -- Eight of the ten pull their reading back up when a panel is too short to
    -- hold it below the header, which could slide it under the button again.
    -- The cell heights that would do that are one pixel away from the ones the
    -- grid actually produces, so this is measured rather than reasoned about.
    local sweepPath = makeWidget("appmode-sweep")
    --- What each panel needs to draw something real during the sweep.
    local SWEEP_CONFIG = {
        ["state"] = {
            "      entries:",
            "        - label: MODE",
            "          states:",
            "            - switch: SA^",
            "              text: LOW",
            "            - switch: SA-",
            "              text: MID",
            "            - switch: SAv",
            "              text: HIGH",
        },
        ["metric"] = { "      metrics:", "        - source: RxBt", "          label: Probe" },
        ["flight-timer"] = { "      label: Probe", "      timer: 0" },
        ["flight-mode"] = { "      label: Probe" },
        ["flight-counter"] = { "      label: FLT" },
        ["tx-battery"] = { "      label: Probe" },
        ["trim-panel"] = { "      label: Probe", "      trim1: trim-ail" },
        ["model-identity"] = { "      label: Probe" },
        ["rx-battery"] = { "      label: Probe", "      source: Cels" },
        ["link-status"] = { "      label: Probe", "      rssiSource: RSSI", "      qualitySource: RQly" },
        ["navigation"] = { "      label: Probe", "      source: GPS" },
        ["heartbeat"] = { "      label: Probe" },
        ["placeholder"] = { "      label: Probe" },
        ["theme-showcase"] = {},
    }

    -- Read from both panel directories rather than listed here. A hand-kept
    -- list cannot drift out of step with itself, which is why the guard below
    -- could never be shown to do anything: it was checking the list against the
    -- list. Reading the directories means a panel added to either one is
    -- swept from the moment it exists, and one that disappears is noticed.
    --
    -- Both directories, because `heartbeat` and `placeholder` are fixtures now
    -- and the host must still treat a layout that places one exactly like any
    -- other panel. Both drew at a raw (8, 6) until they were routed through
    -- the shared frame, which is the kind of thing this sweep is for.
    local sweepTypes = {}
    for _, directory in ipairs({ sourcePath .. "panels", root .. "/tests/fixtures/panels" }) do
        local listingPath = root .. "/build/sweep-types.txt"
        os.execute("ls '" .. directory .. "' > '" .. listingPath .. "'")
        local listing = assert(hostIo.open(listingPath, "r"))
        for name in listing:lines() do
            local stem = string.match(name, "^(.+)%.lua$")
            if stem then
                sweepTypes[#sweepTypes + 1] = stem
            end
        end
        listing:close()
        os.remove(listingPath)
    end
    assert(#sweepTypes >= 13, "only " .. #sweepTypes .. " panel types were found to sweep")

    local checked = {}

    for _, kind in ipairs(sweepTypes) do
        checked[kind] = 0
        for colSpan = 1, 4 do
            for rowSpan = 1, 4 do
                resetRadio()
                writeFile(
                    sweepPath .. "layouts/Default.yaml",
                    table.concat({
                        "version: 1",
                        "grid:",
                        "  columns: 4",
                        "  rows: 4",
                        "panels:",
                        "  - id: probe",
                        "    type: " .. kind,
                        "    col: 0",
                        "    row: 0",
                        "    colSpan: " .. colSpan,
                        "    rowSpan: " .. rowSpan,
                        "    config:",
                        -- Each kind gets only the keys it declares. Handing every key to
                        -- every panel was a shortcut, and it stopped being a harmless
                        -- one when an undeclared key became something the host reports.
                        table.concat(SWEEP_CONFIG[kind] or { "      label: Probe" }, "\n"),
                        "",
                    }, "\n")
                )

                local swept = createLoaded(appZone(), DEFAULT_OPTIONS, sweepPath)
                pump(swept, 20)

                -- A span the panel refuses is a refusal, not a defect.
                local refused = #swept.panels == 0
                if not refused then
                    assertEqual(
                        #swept.errors,
                        0,
                        kind .. " " .. colSpan .. "x" .. rowSpan .. ": " .. table.concat(swept.errors, "\n")
                    )
                    assertMenuClear(kind .. " " .. colSpan .. "x" .. rowSpan, swept)
                    checked[kind] = checked[kind] + 1
                end
            end
        end
    end

    -- Per type, so a name the loader rejects cannot quietly drop one from the
    -- sweep and leave it looking as though it passed.
    for _, kind in ipairs(sweepTypes) do
        assert(checked[kind] > 0, kind .. " was never built at any span")
    end

    -- Outside App mode nothing is taken away, so the same layout keeps the
    -- geometry it has always had.
    local plain = createLoaded(fullScreenZone(), DEFAULT_OPTIONS, cramped)
    pump(plain, 60)
    local plainLabel = entryById(plain, "tight").instance.label
    local plainSpacing = themeModule.build("modern-dark").spacing
    assertEqual(plainLabel.hidden, false, "a Full screen panel lost its label")
    -- An unobstructed label starts where the content does, which is clear of
    -- the accent stripe rather than hard against it.
    assertEqual(
        plainLabel.properties.x,
        plainSpacing.accentWidth + plainSpacing.accentGap,
        "a Full screen panel moved its label"
    )
    lvglMock.setAppMode(false)
end

testNothingIsDrawnOverAnythingElse()
testReadingsDoNotDescendOverAnything()
testNothingReadableUnderTheMenuButton()
