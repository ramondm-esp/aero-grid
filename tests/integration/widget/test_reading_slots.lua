-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local moduleLoader = fixture.module
local edgetx = fixture.edgetx
local appZone = fixture.lvglMock.appZone
local fullScreenZone = fixture.lvglMock.fullScreenZone
local resetRadio = fixture.reset
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local makeWidget = fixture.makeWidget
local themeModule = fixture.module("lib/theme.lua")
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local pump = fixture.pump
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

local assertFont = fixture.assertFont

local boundsOf = fixture.boundsOf

local function testTertiaryQuarterHoldsItsFurniture()
    --- Everything drawn that reaches into a panel's tertiary band.
    local function occupants(entry, bounds)
        local fonts = themeModule.typography(entry.placement.colSpan, entry.placement.rowSpan)
        local panel = { x = 0, y = 0, w = bounds.w, h = bounds.h }
        local band = themeModule.ladder(
            entry.instance.theme,
            panel,
            themeModule.frame(entry.instance.theme, panel, fonts)
        ).bands.tertiary

        local found = {}
        local function walk(object, offsetX, offsetY)
            for _, child in ipairs(object.children) do
                local x = offsetX + (child.properties.x or 0)
                local y = offsetY + (child.properties.y or 0)
                if not child.hidden then
                    local text = tostring(child.properties.text or "")
                    local height, what
                    if child.kind == "label" and text ~= "" then
                        local font = child.properties.font
                        if type(font) == "function" then
                            font = font()
                        end
                        height = themeModule.fontAscent(font)
                        what = '"' .. text .. '"'
                    elseif child.kind == "rectangle" or child.kind == "image" then
                        height = child.properties.h or 0
                        what = child.kind
                        -- The panel's own surface spans it and the accent stripe runs
                        -- its whole height inside the left padding. Both are under the
                        -- content by construction and belong to no band.
                        local spansPanel = (child.properties.w or 0) >= bounds.w - 2 and height >= bounds.h - 2
                        local inAccent = x + (child.properties.w or 0) <= 8
                        if spansPanel or inAccent then
                            what = nil
                        end
                    end
                    if what and height and y + height > band.y and y < band.y + band.h then
                        found[#found + 1] = { what = what, top = y, bottom = y + height }
                    end
                end
                walk(child, x, y)
            end
        end
        walk(entry.container, 0, 0)
        return found, band
    end

    -- Each case says whether the panel draws a supporting row, so the check
    -- knows which way the quarter should come out. A declaration that never
    -- builds the case is not coverage, so the bar variants carry the sources
    -- that make a second row real.
    local CASES = {
        { name = "flight-mode bare", type = "flight-mode", config = { "label: MODE" }, row = false, bar = false },
        {
            name = "tx-battery bare",
            type = "tx-battery",
            config = { "label: TX", "packEmpty: 6.6", "packFull: 8.4" },
            row = false,
            bar = false,
        },
        {
            name = "model-identity bare",
            type = "model-identity",
            config = { "presentation: name", "label: MODEL" },
            row = false,
            bar = false,
        },
        {
            name = "flight-mode row",
            type = "flight-mode",
            config = { "label: MODE", "showIndex: true" },
            row = true,
            bar = false,
        },
        {
            name = "tx-battery row",
            type = "tx-battery",
            config = { "label: TX", "packEmpty: 6.6", "packFull: 8.4", "showPercent: true" },
            row = true,
            bar = false,
        },
        {
            name = "metric bar",
            type = "metric",
            config = {
                "metrics:",
                "  - source: Alt",
                "    label: ALT",
                "    unit: m",
                "    rangeMin: 0",
                "    rangeMax: 400",
                "    precision: 0",
                "visual: bar",
            },
            row = true,
            bar = true,
        },
        {
            name = "rx-battery bar and row",
            type = "rx-battery",
            config = {
                "source: Cels",
                "label: PACK",
                "reading: cell",
                "visual: bar",
                "showPack: true",
                "showCount: true",
            },
            row = true,
            bar = true,
        },
    }

    local sawEmpty, sawOccupied, sawBarAndRow = 0, 0, 0

    for _, case in ipairs(CASES) do
        -- Two-row spans, because a one-row panel is granted no supporting row at
        -- all and would report an empty quarter whatever the panel asked
        -- for. Only three panels declare a three-row span, so a `2 x 3`
        -- sweep would be a sweep over a different set for every case.
        for _, span in ipairs({ { 2, 2 }, { 4, 2 } }) do
            for _, mode in ipairs({ { "full screen", fullScreenZone }, { "app mode", appZone } }) do
                resetRadio()
                local lines = {
                    "version: 1",
                    "grid:",
                    "  columns: 4",
                    "  rows: 4",
                    "panels:",
                    "  - id: subject",
                    "    type: " .. case.type,
                    -- Clear of the menu button, so the quarter is measured on a panel
                    -- nothing else is interfering with.
                    "    col: " .. (4 - span[1]),
                    "    row: " .. (4 - span[2]),
                    "    colSpan: " .. span[1],
                    "    rowSpan: " .. span[2],
                    "    config:",
                }
                for _, line in ipairs(case.config) do
                    lines[#lines + 1] = "      " .. line
                end
                local widget = makeWidget(
                    "quarter-"
                        .. string.gsub(case.name, " ", "")
                        .. "-"
                        .. span[1]
                        .. "x"
                        .. span[2]
                        .. "-"
                        .. string.gsub(mode[1], " ", ""),
                    table.concat(lines, "\n") .. "\n"
                )
                local context = createLoaded(mode[2](), DEFAULT_OPTIONS, widget)
                assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
                pump(context, 60)

                local entry = entryById(context, "subject")
                local bounds = boundsOf(entry)
                local inside, band = occupants(entry, bounds)
                local where = mode[1] .. " " .. case.name .. " " .. span[1] .. "x" .. span[2]

                if case.row then
                    assert(
                        #inside > 0,
                        where
                            .. ": the panel declares a supporting row and its tertiary"
                            .. " quarter is empty, so the row is somewhere else"
                    )
                    sawOccupied = sawOccupied + 1
                    -- Everything in it is inside it. A band that is always reserved is
                    -- only honest if what it holds actually fits.
                    for _, box in ipairs(inside) do
                        assert(
                            box.top >= band.y and box.bottom <= band.y + band.h,
                            where
                                .. ": "
                                .. box.what
                                .. " runs from "
                                .. box.top
                                .. " to "
                                .. box.bottom
                                .. ", outside its band at "
                                .. band.y
                                .. ".."
                                .. (band.y + band.h)
                        )
                    end
                    if case.bar then
                        local bars, labels = 0, 0
                        for _, box in ipairs(inside) do
                            if box.what == "rectangle" then
                                bars = bars + 1
                            else
                                labels = labels + 1
                            end
                        end
                        if bars > 0 and labels > 0 then
                            sawBarAndRow = sawBarAndRow + 1
                            -- The row sits above the bar rather than on it.
                            for _, box in ipairs(inside) do
                                if box.what ~= "rectangle" then
                                    for _, other in ipairs(inside) do
                                        if other.what == "rectangle" then
                                            assert(
                                                box.bottom <= other.top,
                                                where
                                                    .. ": a supporting row runs to "
                                                    .. box.bottom
                                                    .. " and the bar starts at "
                                                    .. other.top
                                            )
                                        end
                                    end
                                end
                            end
                        end
                    end
                else
                    assertEqual(
                        #inside,
                        0,
                        where
                            .. ": the panel draws no supporting row and its tertiary quarter"
                            .. " holds "
                            .. (inside[1] and inside[1].what or "")
                            .. " -- something grew"
                            .. " into a band that is supposed to stay empty"
                    )
                    sawEmpty = sawEmpty + 1
                end
            end
        end
    end

    -- None of the three sweeps may be vacuous.
    assert(sawEmpty > 0, "no panel with an empty quarter was ever built")
    assert(sawOccupied > 0, "no panel with an occupied quarter was ever built")
    assert(
        sawBarAndRow > 0,
        "no panel drawing a bar and a supporting row was ever built, so the"
            .. " case those two share a band was never constructed"
    )
    resetRadio()
end

local function testReadingsIgnoreTheRowBeneathThem()
    -- Each panel, the setting that turns its supporting row on, and how to
    -- read back whether the panel drew one. Declared rather than special-cased
    -- so a panel that gains an optional row is covered by adding a line.
    local OPTIONAL = {
        {
            type = "flight-mode",
            setting = "showIndex",
            config = { "label: MODE" },
            label = function(panel)
                return panel.detailLabel
            end,
            drew = function(panel)
                return panel.showDetail
            end,
        },
        {
            type = "model-identity",
            setting = "showLabels",
            config = { "label: MODEL" },
            label = function(panel)
                return panel.labelsLabel
            end,
            drew = function(panel)
                return panel.showLabels
            end,
        },
        {
            type = "tx-battery",
            setting = "showPercent",
            config = { "label: TX", "packEmpty: 6.6", "packFull: 8.4" },
            label = function(panel)
                return panel.detailLabel
            end,
            drew = function(panel)
                return panel.showDetail
            end,
        },
    }

    -- Two rows, because a single-row panel is granted no supporting row at all
    -- and would pass this check without exercising it.
    for _, subject in ipairs(OPTIONAL) do
        local fonts, tops = {}, {}
        for _, asked in ipairs({ false, true }) do
            resetRadio()
            local lines = {
                "version: 1",
                "grid:",
                "  columns: 4",
                "  rows: 4",
                "panels:",
                "  - id: panel",
                "    type: " .. subject.type,
                "    col: 0",
                "    row: 0",
                "    colSpan: 4",
                "    rowSpan: 2",
                "    config:",
            }
            for _, line in ipairs(subject.config) do
                lines[#lines + 1] = "      " .. line
            end
            if asked then
                lines[#lines + 1] = "      " .. subject.setting .. ": true"
            end

            local widgetPath =
                makeWidget("unused-" .. subject.type .. "-" .. tostring(asked), table.concat(lines, "\n") .. "\n")
            local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
            assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
            settle(context, 30)

            local panel = entryById(context, "panel").instance
            local where = subject.type .. " with " .. subject.setting .. " " .. tostring(asked)

            assertEqual(
                subject.drew(panel) == true,
                asked,
                where .. ": the panel disagrees with its own setting about whether it" .. " draws a supporting row"
            )

            -- No row means no object for one. An object built to be hidden is the
            -- invisible work the specification forbids, and it is what made this
            -- bug survive a sweep that was meant to end exactly that.
            if not asked then
                assertEqual(subject.label(panel), nil, where .. ": built a label for a row it will never fill")
            end

            local font = panel.value.properties.font
            fonts[asked] = type(font) == "function" and font() or font
            tops[asked] = panel.value.properties.y
        end

        -- **The reading lands on the same line either way.** Both panels have a
        -- label quarter, a body half and a tertiary quarter, and the tertiary
        -- quarter is reserved whether or not anything is drawn in it -- so the
        -- body band is the same band and the reading is centred in the same
        -- place. This is the property the user asked for, stated as the thing a
        -- pilot can see: two panels of one size, one with a row and one without,
        -- with their numbers on one line.
        assertEqual(
            tops[false],
            tops[true],
            subject.type
                .. ": a panel drawing no supporting row puts its reading at "
                .. tops[false]
                .. " and one that draws a row puts it at "
                .. tops[true]
                .. ", so the layout still depends on what is in the panel"
        )

        -- And at the same size, which follows from the same band but is worth
        -- pinning separately: a font is what a reader notices first, and an
        -- equal position with unequal fonts would mean the two were centred
        -- alike by coincidence rather than sized alike by rule.
        assertFont(
            fonts[false],
            fonts[true],
            subject.type .. ": a panel drawing no supporting row reads at a different size from" .. " one that does"
        )
    end
end

local function testReadingsSitInTheirSlots()
    --- What each panel slots, and how to build a layout that shows it.
    ---
    --- **Adding a panel here is a declaration, not new test code.** Nine
    --- more are due on the slots and the check below should cover each one the
    --- moment it arrives, rather than growing a ninth near-copy of itself.
    local SLOTTED = {
        {
            type = "flight-timer",
            config = { "label: FLIGHT", "timer: 0" },
            -- Its only visualization is a bar, which spans the panel and is
            -- exempt, so the clock never splits and centres across the whole box.
            variants = { {} },
            visual = function()
                return nil
            end,
            rows = function(panel)
                if not panel.showDetail then
                    return {}
                end
                return { { label = panel.detailLabel, slot = "whole" } }
            end,
        },
        {
            type = "flight-mode",
            config = { "label: MODE" },
            -- Draws no visualization at all: a flight mode is a name and there is
            -- nothing to gauge, so the reading never splits. The mode number is a
            -- supporting row the panel grants only on a two-row panel, so it
            -- cannot be asked for here without failing validation at every single
            -- row -- the spans this check walks include those.
            variants = { {}, { "showIndex: true", minRows = 2 } },
            visual = function()
                return nil
            end,
            rows = function(panel)
                if not panel.showDetail then
                    return {}
                end
                return { { label = panel.detailLabel, slot = "whole" } }
            end,
        },
        {
            type = "model-identity",
            config = { "label: MODEL" },
            -- Its picture spans the content box, so it is exempt the way a bar is
            -- and the name never splits. The second variant turns on the label row
            -- so the row case is actually constructed.
            variants = { {}, { "showLabels: true", minRows = 2 } },
            visual = function()
                return nil
            end,
            rows = function(panel)
                if not panel.showLabels then
                    return {}
                end
                return { { label = panel.labelsLabel, slot = "whole" } }
            end,
        },
        {
            type = "tx-battery",
            -- Battery glyph against bar: the two arrangements this panel
            -- offers, alike but for the visualization.
            sameReadingAcross = { 1, 2 },
            config = { "label: TX", "packEmpty: 6.6", "packFull: 8.4" },
            -- Both arrangements: a compact visual beside the reading, and a
            -- full-width bar that leaves the reading the whole box.
            variants = { { "visual: battery" }, { "visual: bar" } },
            -- What stands in the right slot when there is one.
            visual = function(panel)
                return panel.valueShown
                        and panel.glyphShown
                        and panel.glyph
                        and { x = panel.glyph.x, w = panel.glyph.width }
                    or nil
            end,
        },
        {
            type = "navigation",
            config = { "label: HOME", "source: GPS", "presentation: bearing" },
            variants = { {} },
            visual = function()
                return nil
            end,
            -- **Supporting rows are slotted too, so they are checked too.** A row
            -- of two takes the same two centres the reading and the visual use,
            -- and a row of one centres across the whole content box. Declared
            -- here, so a panel that slots a row says so rather than having a
            -- second test written for it.
            rows = function(panel)
                local found = {}
                if panel.showDetail then
                    found[#found + 1] = { label = panel.detailLabel, slot = panel.origin == "" and "whole" or "left" }
                    found[#found + 1] = { label = panel.originLabel, slot = "right" }
                end
                if panel.showCoordinates then
                    found[#found + 1] = { label = panel.coordinatesLabel, slot = "whole" }
                end
                return found
            end,
        },
        {
            type = "link-status",
            config = { "label: LINK", "rssiSource: RSSI", "qualitySource: RQly" },
            -- Its only visualization is a bar, which spans the panel by design and
            -- is exempt from the rule, so the reading never splits.
            variants = { { "visual: bar" }, { "visual: none" } },
            visual = function()
                return nil
            end,
            rows = function(panel)
                if not panel.showDetail then
                    return {}
                end
                return {
                    { label = panel.detailLabel, slot = "left" },
                    { label = panel.linkLabel, slot = "right" },
                }
            end,
        },
        {
            type = "metric",
            -- Radial against bar. The third variant adds a secondary source and
            -- so is not alike in every other respect, which is why the pair is
            -- named rather than assumed to be the first two of however many.
            sameReadingAcross = { 1, 2 },
            config = {
                "metrics:",
                "  - source: Alt",
                "    label: ALT",
                "    rangeMin: 0",
                "    rangeMax: 400",
                "    precision: 0",
            },
            -- A radial is a compact visual and takes the right slot; a bar spans
            -- the panel and is exempt, so the same panel splits under one
            -- setting and not the other. The third variant configures a secondary
            -- source, which is what turns the supporting row from one item into
            -- two -- without it the two-slot case is never exercised, and a defect
            -- in it passes unseen.
            variants = {
                { "visual: radial" },
                { "visual: bar" },
                { "  - source: VSpd", "    label: VS", "visual: bar" },
            },
            visual = function(panel)
                if not (panel.showVisual and panel.radial) then
                    return nil
                end
                -- A radial is one arc, where a compass is a ring and a pointer.
                local drawn = panel.radial.arc.round.drawn
                local diameter = panel.radial.arc.round.radius() * 2
                return { x = drawn.x, w = diameter }
            end,
            rows = function(panel)
                if not panel.showRange then
                    return {}
                end
                if panel.showSecondary then
                    return {
                        { label = panel.range, slot = "left" },
                        { label = panel.secondary, slot = "right" },
                    }
                end
                return { { label = panel.range, slot = "whole" } }
            end,
        },
        {
            type = "rx-battery",
            config = { "label: PACK", "source: Cels" },
            variants = { { "visual: bar" }, { "visual: none" } },
            visual = function()
                return nil
            end,
            rows = function(panel)
                if not panel.showDetail then
                    return {}
                end
                return {
                    { label = panel.countLabel, slot = "left" },
                    { label = panel.packLabel, slot = "right" },
                }
            end,
        },
    }

    -- Written out rather than read from `theme`, so a change to the rule has
    -- to be made here too, deliberately.
    local TIGHT_LEFT, TIGHT_RIGHT = 0.30, 0.70
    local STRICT_LEFT, STRICT_RIGHT = 0.25, 0.75
    local PAD, PAD_RIGHT = 8, 4

    local GUTTER, CELLS, WIDTH, HEIGHT = 4, 4, 480, 272
    local cellWidth = math.floor((WIDTH - GUTTER * (CELLS - 1)) / CELLS)
    local cellHeight = math.floor((HEIGHT - GUTTER * (CELLS - 1)) / CELLS)

    local panelHost = assert(loadfile(sourcePath .. "lib/panel_host.lua"))()
    for _, subject in ipairs(SLOTTED) do
        local module = moduleLoader("panels/" .. subject.type .. ".lua")
        local cases = {}
        local byVisual = {}
        for index, extra in ipairs(subject.variants) do
            for rows = 1, 4 do
                for columns = 1, 4 do
                    -- Restrict supporting-row variants to spans that can show them.
                    if
                        panelHost.supportsSpan(module, columns, rows)
                        and rows >= (type(extra) == "table" and extra.minRows or 1)
                    then
                        cases[#cases + 1] = {
                            span = panelHost.spanName(columns, rows),
                            extra = extra,
                            index = index,
                        }
                    end
                end
            end
        end

        for _, case in ipairs(cases) do
            local span, extra = case.span, case.extra
            local cols, rows = string.match(span, "(%d)x(%d)")
            cols, rows = tonumber(cols), tonumber(rows)

            resetRadio()
            local lines = {
                "version: 1",
                "grid:",
                "  columns: 4",
                "  rows: 4",
                "panels:",
                "  - id: pack",
                "    type: " .. subject.type,
                "    col: 0",
                "    row: 0",
                "    colSpan: " .. cols,
                "    rowSpan: " .. rows,
                "    config:",
            }
            for _, line in ipairs(subject.config) do
                lines[#lines + 1] = "      " .. line
            end
            for _, line in ipairs(extra) do
                lines[#lines + 1] = "      " .. line
            end
            local widgetPath = makeWidget(
                "slot-" .. subject.type .. "-" .. case.index .. "-" .. span,
                table.concat(lines, "\n") .. "\n"
            )

            local context = createLoaded({ x = 0, y = 0, w = WIDTH, h = HEIGHT }, DEFAULT_OPTIONS, widgetPath)
            assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
            settle(context, 30)

            local panel = entryById(context, "pack").instance
            local where = subject.type .. " " .. span .. (extra[1] and (" with " .. extra[1]) or "")

            local reading = panel.value.properties
            local text = tostring(reading.text)
            assert(text ~= "" and text ~= "--", where .. ": no reading was drawn, so there is nothing to place")

            local font = reading.font
            if type(font) == "function" then
                font = font()
            end

            -- Rebuilt from the panel, not read back from the panel.
            local panelWidth = cellWidth * cols + GUTTER * (cols - 1)
            local panelHeight = cellHeight * rows + GUTTER * (rows - 1)
            local content = panelWidth - PAD - PAD_RIGHT

            -- Measured the way the radio draws it, which is the whole point: the
            -- estimate is generous and half of its generosity lands in the left
            -- edge of anything centred with it.
            local drawn = lcd.sizeText(text, font)
            if panel.unitDrawn then
                drawn = drawn
                    + themeModule.unitGap(panel.area.unitFont)
                    + themeModule.measureText(panel.area.unitFont, panel.unitText)
            end
            local centre = reading.x + drawn / 2

            local expected, arrangement
            local glyph = subject.visual(panel)
            if glyph then
                -- Which slot set is in force, read off the glyph rather than
                -- recomputed. Its centre lands on one fraction or the other, and
                -- whichever it is, the reading has to agree with it.
                local glyphCentre = glyph.x + glyph.w / 2
                local tight = PAD + math.floor(content * TIGHT_RIGHT + 0.5)
                local strict = PAD + math.floor(content * STRICT_RIGHT + 0.5)
                if math.abs(glyphCentre - tight) <= 1 then
                    expected = PAD + math.floor(content * TIGHT_LEFT + 0.5)
                    arrangement = "tightened"
                elseif math.abs(glyphCentre - strict) <= 1 then
                    expected = PAD + math.floor(content * STRICT_LEFT + 0.5)
                    arrangement = "strict halves"
                else
                    assert(
                        false,
                        where
                            .. ": the visual is at "
                            .. glyphCentre
                            .. ", which is neither slot ("
                            .. tight
                            .. " or "
                            .. strict
                            .. ")"
                    )
                end
            elseif panel.area and panel.area.showSide then
                expected = panel.area.valueCentre
                arrangement = "supporting side stack"
            else
                -- One element does not split: it centres across the whole box.
                expected = PAD + content / 2
                arrangement = "unsplit"
            end

            assert(
                math.abs(centre - expected) <= 1,
                string.format(
                    "%s (%s) centres its reading %q at %.1f, %.1f px from the %.1f its"
                        .. " slot asks for -- %.1f%% of the panel against %.1f%%",
                    where,
                    arrangement,
                    text,
                    centre,
                    centre - expected,
                    expected,
                    100 * centre / panelWidth,
                    100 * expected / panelWidth
                )
            )

            -- Every slotted supporting row sits on the centre its slot names,
            -- measured the same way the reading is. A row of two takes the two
            -- slot centres and a row of one centres across the content box.
            for _, row in ipairs(subject.rows and subject.rows(panel) or {}) do
                local label = row.label
                if label and not label.hidden then
                    local rowText = tostring(label.properties.text or "")
                    if rowText ~= "" then
                        local rowFont = label.properties.font
                        if type(rowFont) == "function" then
                            rowFont = rowFont()
                        end
                        local rowCentre = label.properties.x + lcd.sizeText(rowText, rowFont) / 2
                        local want
                        if panel.area and panel.area.showSide then
                            want = panel.area.sideCentre
                        elseif row.slot == "left" then
                            want = PAD + math.floor(content * TIGHT_LEFT + 0.5)
                        elseif row.slot == "right" then
                            want = PAD + math.floor(content * TIGHT_RIGHT + 0.5)
                        else
                            want = PAD + content / 2
                        end
                        assert(
                            math.abs(rowCentre - want) <= 1,
                            string.format(
                                "%s centres its %s supporting item %q at %.1f, %.1f px from"
                                    .. " the %.1f its slot asks for",
                                where,
                                row.slot,
                                rowText,
                                rowCentre,
                                rowCentre - want,
                                want
                            )
                        )
                    end
                end
            end

            -- And the unit came with it. This is the defect shape that keeps
            -- reappearing, and moving the reading is exactly what perturbs it.
            if panel.unit and not panel.unit.hidden then
                local unitFont = panel.unit.properties.font
                if type(unitFont) == "function" then
                    unitFont = unitFont()
                end
                assertEqual(
                    panel.unit.properties.x,
                    reading.x + lcd.sizeText(text, font) + themeModule.unitGap(unitFont),
                    where .. ": the unit did not follow the reading to its slot"
                )
            end

            byVisual[span] = byVisual[span] or {}
            byVisual[span][case.index] = font
        end

        -- **A decoration does not cost the reading a size.** Declared as a pair
        -- of variant indices that differ only in which visualization is drawn,
        -- so the comparison is between two panels alike in every other respect
        -- and a difference can only have come from the visual.
        --
        -- The reading used to be fitted into half the panel wherever a compact
        -- visual might sit beside it, and shed the visual afterwards if that had
        -- still not been enough -- so a reading could pay a size for a dial it
        -- did not get. Which of the two the panel ends up drawing is not the
        -- claim here; the claim is that the number is the same size either way.
        if subject.sameReadingAcross then
            local a, b = subject.sameReadingAcross[1], subject.sameReadingAcross[2]
            local compared = 0
            for span, fonts in pairs(byVisual) do
                if fonts[a] and fonts[b] then
                    compared = compared + 1
                    assertEqual(
                        edgetx.fontName(fonts[a]),
                        edgetx.fontName(fonts[b]),
                        string.format(
                            "%s at %s reads %s with one visualization and %s with the"
                                .. " other, so the reading is paying for the decoration"
                                .. " beside it -- magnitude is the first thing a pilot reads"
                                .. " and it is not what a panel spends to keep a dial",
                            subject.type,
                            span,
                            edgetx.fontName(fonts[a]),
                            edgetx.fontName(fonts[b])
                        )
                    )
                end
            end
            assert(
                compared >= 4,
                subject.type
                    .. ": only "
                    .. compared
                    .. " spans compared the two"
                    .. " visualizations, so the pair is declared but barely built"
            )
        end
    end
end

testReadingsSitInTheirSlots()
testReadingsIgnoreTheRowBeneathThem()
testTertiaryQuarterHoldsItsFurniture()
