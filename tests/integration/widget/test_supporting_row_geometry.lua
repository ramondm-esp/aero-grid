-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local developmentLayoutsPath = root .. "/tests/fixtures/layouts/development/"
local hostIo = fixture.hostIo
local moduleLoader = fixture.module
local appZone = fixture.lvglMock.appZone
local fullScreenZone = fixture.lvglMock.fullScreenZone
local radio = fixture.radio
local resetRadio = fixture.reset
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
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
assert(
    themeModule.setCatalog(
        assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
    )
)

local reflowDone = fixture.reflowDone

local boundsOf = fixture.boundsOf

local function testSupportingWordingsStayDistinct()
    --- Every panel that words a state, and the states it words.
    ---
    --- **A declaration, like the positional check.** A panel whose
    --- supporting row names more than one failure adds itself here; nine are
    --- still to convert and each should be covered the moment it arrives.
    local WORDED = {
        {
            -- **One form per state here, and the check is the same check.** Every
            -- wording this panel offers fits every panel that draws a row, so
            -- its "shortest" form is its only form -- which is exactly when two
            -- states are likeliest to be collapsed into one word by someone
            -- shortening for width.
            type = "flight-timer",
            variantsFor = function(module, state)
                return module.detailVariants(state[1], tostring)
            end,
            states = {
                { "no timer configured", { nil, nil } },
                {
                    "a countdown run past zero",
                    {
                        {
                            available = true,
                            countdown = true,
                            start = 300,
                            remaining = -15,
                            elapsed = 315,
                            expired = true,
                        },
                        nil,
                    },
                },
                {
                    "a timer counting up",
                    { { available = true, countdown = false, elapsed = 64, value = 64, start = 0 }, nil },
                },
            },
        },
        {
            type = "navigation",
            -- How to ask this panel for one state's wordings. Declared,
            -- because a panel's own signature is its own business: this one
            -- takes a view table and `rx-battery` takes a summary and settings.
            variantsFor = function(module, state)
                return module.originVariants(state)
            end,
            states = {
                { "no GPS sensor configured at all", { known = false, fix = false, home = false } },
                { "sensor present, no satellite fix", { known = true, fix = false, home = false } },
                { "fix acquired, home not yet set", { known = true, fix = true, home = false } },
                {
                    "position known but telemetry gone quiet",
                    { known = true, fix = true, home = true, state = "stale" },
                },
            },
        },
        {
            -- Invalid cells and no detected cells imply different actions.
            type = "rx-battery",
            variantsFor = function(module, state)
                return module.countVariants({ shape = state }, { showCount = true })
            end,
            states = {
                { "a source answering with something wrong", "invalid" },
                { "a source answering with no cells at all", "empty" },
            },
        },
    }

    for _, subject in ipairs(WORDED) do
        local module = moduleLoader("panels/" .. subject.type .. ".lua")
        local seen = {}
        for _, entry in ipairs(subject.states) do
            local variants = subject.variantsFor(module, entry[2])
            local shortest = variants[#variants]

            assert(
                type(shortest) == "string" and shortest ~= "",
                subject.type .. ": " .. entry[1] .. " has no wording at all"
            )

            local owner = seen[shortest]
            assert(
                owner == nil,
                string.format(
                    "%s: %q is the narrowest wording for two different states -- %s and"
                        .. " %s -- so a panel too narrow for the longer forms cannot say"
                        .. " which happened, and the row stops carrying the distinction"
                        .. " the badge above it deliberately does not",
                    subject.type,
                    shortest,
                    owner or "",
                    entry[1]
                )
            )
            seen[shortest] = entry[1]
        end
    end

    -- And the narrowest row in the catalogue really does reach the shortest
    -- forms, or the assertions above are about strings nothing prints.
    local navigationModule = moduleLoader("panels/navigation.lua")
    local GUTTER, CELLS, WIDTH, HEIGHT = 4, 4, 480, 272
    local cellWidth = math.floor((WIDTH - GUTTER * (CELLS - 1)) / CELLS)
    local cellHeight = math.floor((HEIGHT - GUTTER * (CELLS - 1)) / CELLS)
    local rect = { x = 0, y = 0, w = cellWidth * 2 + GUTTER, h = cellHeight * 2 + GUTTER }
    local fonts = themeModule.typography(2, 2)
    local area = navigationModule.regionsFor(
        themeModule.build("modern-dark"),
        themeModule,
        rect,
        { showTape = false, showCoordinates = true },
        fonts,
        { digits = navigationModule.DIGITS, unit = navigationModule.UNIT }
    )

    local shortened = 0
    local navigation
    for _, subject in ipairs(WORDED) do
        if subject.type == "navigation" then
            navigation = subject
        end
    end
    for _, entry in ipairs(assert(navigation).states) do
        local full = navigationModule.originVariants(entry[2])[1]
        local drawn = navigationModule.originText(entry[2], themeModule, fonts.label, area.originWidth)
        if drawn ~= full then
            shortened = shortened + 1
        end
    end
    assert(
        shortened > 0,
        "no state was shortened at the narrowest row, so the"
            .. " distinctness check above is not exercising the case it exists for"
    )

    local link = moduleLoader("panels/link-status.lua")
    local minimum = math.max(themeModule.textWidth(fonts.label, "DOWN"), themeModule.textWidth(fonts.label, "NO RSS"))
    for _, width in ipairs({ minimum, minimum + 20, 200, 400 }) do
        local context = {
            settings = { protocol = "generic" },
            themeBuilder = themeModule,
            fonts = fonts,
            rowRightWidth = width,
        }
        local down = link.linkText(context, { linkDown = true })
        local absent = link.linkText(context, { rssiState = "absent" })
        assert(down ~= "" and absent ~= "" and down ~= absent, "link failure causes must remain distinct")
        assert(themeModule.textWidth(fonts.label, down) <= width, "link-down wording exceeds its row")
        assert(themeModule.textWidth(fonts.label, absent) <= width, "missing-RSSI wording exceeds its row")
    end
end

local function testTwoRowFooterClearsTheReading()
    for _, place in ipairs({ { "the menu button's corner", 0, 0 }, { "a clear cell", 2, 1 } }) do
        resetRadio()
        local widget = makeWidget(
            "two-row-footer-" .. place[2] .. place[3],
            table.concat({
                "version: 1\ngrid:\n  columns: 4\n  rows: 4\npanels:\n",
                "  - id: nav\n    type: navigation\n",
                "    col: ",
                tostring(place[2]),
                "\n",
                "    row: ",
                tostring(place[3]),
                "\n",
                "    colSpan: 2\n    rowSpan: 3\n",
                "    config:\n      label: HOME\n      source: GPS\n",
                "      presentation: bearing\n      showCoordinates: true\n",
            })
        )
        local context = createLoaded(appZone(), DEFAULT_OPTIONS, widget)
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
        pump(context, 60)

        local nav = entryById(context, "nav").instance
        local where = "navigation 2 x 3 in " .. place[1]
        -- The preconditions. Without both of these the assertions below are
        -- about a panel that draws one row, or none, and cannot fail.
        assertEqual(nav.showDetail, true, where .. " drew no supporting row")
        assertEqual(nav.showCoordinates, true, where .. " drew one supporting row, not two")

        local font = nav.value.properties.font
        font = type(font) == "function" and font() or font
        local bottom = nav.value.properties.y + themeModule.fontAscent(font)
        local rowTop = nav.detailLabel.properties.y
        assert(
            bottom <= rowTop,
            where .. ": the distance ends at " .. bottom .. " and the bearing row starts at " .. rowTop
        )
        -- And the rows clear each other, which is what the band has to be tall
        -- enough for in the first place.
        assert(
            rowTop < nav.coordinatesLabel.properties.y,
            where .. ": the coordinates do not sit below the bearing row"
        )
        -- Both rows inside the quarter they were granted, which is the property
        -- the fixed-bands rule turns on: a band that is always reserved is only
        -- honest if what it holds actually fits it.
        local band = nav.area.bands.tertiary
        assert(
            rowTop >= band.y,
            where .. ": the bearing row starts at " .. rowTop .. ", above its own band at " .. band.y
        )
        local lastRow = nav.coordinatesLabel.properties.y + themeModule.fontAscent(nav.area.rowFont)
        assert(
            lastRow <= band.y + band.h,
            where .. ": the coordinate row ends at " .. lastRow .. ", below its own band at " .. (band.y + band.h)
        )
        assertNothingOverlaps(where, context)

        -- **A missing home withholds what is measured from home and nothing
        -- else.** The fix is perfectly good, so the coordinates stay on screen.
        radio.values[109]["pilot-lat"] = 0
        radio.values[109]["pilot-lon"] = 0
        pump(context, 40)
        assert(string.match(nav.origin, "^NO HOME"))
        assertEqual(nav.text, "--", "a distance was measured from nowhere")
        assertEqual(nav.detail, "BRG --", "a bearing was invented without a home")
        assertEqual(nav.coordinates, "47.37690 8.54170", where .. ": the position itself is still known")
        assertEqual(
            nav.coordinatesLabel.properties.text,
            "47.37690 8.54170",
            where .. ": the coordinates were computed and not drawn"
        )
    end
    resetRadio()
end

local function testSupportingRowsFitTheirBox()
    --- Each panel that draws a supporting row, configured so it draws one,
    --- and how to drive it into the state that words the most.
    ---
    --- **A declaration, and it names the state as well as the panel.** A
    --- declaration that does not construct the case is not coverage: listing
    --- `flight-timer` without expiring its countdown would check `OF 5:00`,
    --- which fits everywhere, and report the panel covered.
    local ROWED = {
        {
            name = "flight-timer, countdown running",
            type = "flight-timer",
            config = { "timer: 0", "label: TIMER" },
        },
        {
            name = "flight-timer, elapsed past zero",
            type = "flight-timer",
            config = { "timer: 0", "label: TIMER" },
            drive = function()
                radio.timers[0].value = -15
            end,
        },
        { name = "flight-timer, counting up", type = "flight-timer", config = { "timer: 1", "label: TIMER" } },
        {
            name = "flight-timer, no timer",
            type = "flight-timer",
            config = { "timer: 2", "label: TIMER" },
            drive = function()
                radio.timers[2] = nil
            end,
        },
        { name = "flight-mode, mode number", type = "flight-mode", config = { "label: MODE", "showIndex: true" } },
        {
            name = "rx-battery, pack and count",
            type = "rx-battery",
            config = { "source: Cels", "label: PACK", "showPack: true", "showCount: true" },
        },
        {
            name = "rx-battery, nonsense cells",
            type = "rx-battery",
            config = { "source: Cels", "label: PACK", "showPack: true", "showCount: true" },
            drive = function()
                radio.values[130] = { 0, -1, 99 }
            end,
        },
        {
            name = "link-status, link down",
            type = "link-status",
            config = { "label: LINK", "rssiSource: 1RSS", "qualitySource: RQly", "reading: rssi" },
            drive = function()
                radio.rssi = 0
            end,
        },
        {
            name = "metric, range and secondary",
            type = "metric",
            config = {
                "metrics:",
                "  - source: Alt",
                "    label: ALT",
                "    unit: m",
                "    rangeMin: 0",
                "    rangeMax: 400",
                "    precision: 0",
                "  - source: Curr",
                "    label: CUR",
                "visual: bar",
            },
        },
        {
            name = "navigation, no home position",
            type = "navigation",
            config = { "label: HOME", "source: GPS", "presentation: detailed" },
            drive = function()
                radio.values[109]["pilot-lat"] = 0
                radio.values[109]["pilot-lon"] = 0
            end,
        },
        {
            name = "tx-battery, percentage",
            type = "tx-battery",
            config = { "label: TX", "packEmpty: 6.6", "packFull: 8.4", "showPercent: true" },
        },
    }

    local checked, narrowest = 0, 0

    for _, subject in ipairs(ROWED) do
        -- Every span that grants a supporting row. One-row panels are granted
        -- none at any width, so they would report an empty sweep rather than a
        -- fitting one.
        for _, span in ipairs({ { 1, 2 }, { 2, 2 }, { 4, 2 } }) do
            for _, mode in ipairs({ { "full screen", fullScreenZone }, { "app mode", appZone } }) do
                resetRadio()
                if subject.drive then
                    subject.drive()
                end

                local lines = {
                    "version: 1",
                    "grid:",
                    "  columns: 4",
                    "  rows: 4",
                    "panels:",
                    "  - id: subject",
                    "    type: " .. subject.type,
                    -- Clear of the menu button, so the row is measured against a
                    -- content box nothing else has narrowed.
                    "    col: " .. (4 - span[1]),
                    "    row: " .. (4 - span[2]),
                    "    colSpan: " .. span[1],
                    "    rowSpan: " .. span[2],
                    "    config:",
                }
                for _, line in ipairs(subject.config) do
                    lines[#lines + 1] = "      " .. line
                end

                local widget = makeWidget(
                    "rowfit-"
                        .. string.gsub(subject.name, "[^%w]", "")
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
                local frame = themeModule.frame(
                    entry.instance.theme,
                    { x = 0, y = 0, w = bounds.w, h = bounds.h },
                    themeModule.typography(span[1], span[2])
                )
                local where = mode[1] .. " " .. subject.name .. " " .. span[1] .. "x" .. span[2]

                -- Every visible label in the panel's lower half is a supporting row.
                -- Read off the drawing rather than from a field each panel names
                -- differently -- `detail`, `range`, `secondary`, `countText`.
                local function walk(object, offsetX, offsetY)
                    for _, child in ipairs(object.children) do
                        local x = offsetX + (child.properties.x or 0)
                        local y = offsetY + (child.properties.y or 0)
                        local text = tostring(child.properties.text or "")
                        if child.kind == "label" and not child.hidden and text ~= "" and y > bounds.h / 2 then
                            local font = child.properties.font
                            font = type(font) == "function" and font() or font
                            local width = themeModule.measureText(font, text)

                            assert(
                                width <= frame.content,
                                where
                                    .. ': draws "'
                                    .. text
                                    .. '" at '
                                    .. width
                                    .. " px into a content box of "
                                    .. frame.content
                                    .. " -- a row cannot shrink its font, so a"
                                    .. " row this wide is centred on a box wider than the panel"
                                    .. " and runs off both edges"
                            )

                            -- And it is on the panel, which is the same fact stated
                            -- against the edge rather than against the box.
                            assert(
                                x >= 0 and x + width <= bounds.w,
                                where
                                    .. ': draws "'
                                    .. text
                                    .. '" from '
                                    .. x
                                    .. " to "
                                    .. (x + width)
                                    .. " on a panel "
                                    .. bounds.w
                                    .. " px wide"
                            )

                            checked = checked + 1
                            if span[1] == 1 and span[2] == 2 then
                                narrowest = narrowest + 1
                            end
                        end
                        walk(child, x, y)
                    end
                end
                walk(entry.container, 0, 0)
            end
        end
    end

    -- Not vacuous: rows were actually drawn, and the narrowest span really was
    -- reached. Without this a sweep that shed every row would pass.
    assert(checked >= 60, "only " .. checked .. " supporting rows were drawn, so most of this swept nothing")
    assert(narrowest > 0, "the narrowest span drew no supporting rows")
    resetRadio()
end

local function testBadgesEndFlushWithTheirPanel()
    local theme = themeModule
    local source = assert(hostIo.open(developmentLayoutsPath .. "states.yaml", "r"))
    local yaml = source:read("a")
    source:close()

    -- The vocabulary, read off the theme rather than typed, so a word added to
    -- it is covered the moment it is added.
    local vocabulary = {}
    for _, name in ipairs({ "warning", "critical", "stale", "unavailable", "selected", "editing" }) do
        local state = theme.state(theme.build("modern-dark"), name)
        if state and type(state.badge) == "string" and state.badge ~= "" then
            vocabulary[state.badge] = true
        end
    end
    assert(next(vocabulary), "the badge vocabulary came out empty")

    local seen, checked = {}, 0

    local function inspect(where, context)
        for _, entry in ipairs(context.panels) do
            local instance = entry.instance
            local badge = instance and instance.badge
            if badge and not badge.hidden then
                local word = tostring(badge.properties.text or "")
                if word ~= "" then
                    local bounds = boundsOf(entry)
                    local font = badge.properties.font
                    font = type(font) == "function" and font() or font

                    -- **The assertion.** The badge's ink ends where the panel's right
                    -- padding says it ends, which is exactly where `theme.frame` puts
                    -- the column's own right edge. Pinned against the panel rather
                    -- than against the column, because the column was always right
                    -- and the text inside it was not.
                    local inkEnd = badge.properties.x + theme.measureText(font, word)
                    local frame = theme.frame(
                        instance.theme,
                        { x = 0, y = 0, w = bounds.w, h = bounds.h },
                        theme.typography(entry.placement.colSpan, entry.placement.rowSpan)
                    )
                    local columnEnd = frame.badgeX + frame.badgeWidth

                    assertEqual(
                        inkEnd,
                        columnEnd,
                        where
                            .. ": "
                            .. entry.placement.id
                            .. ' draws "'
                            .. word
                            .. '" ending at '
                            .. inkEnd
                            .. ", where its column ends at "
                            .. columnEnd
                            .. " -- the text is left-aligned inside its box again"
                    )

                    -- And the box never starts left of the column, which is what
                    -- protects the heading beside it.
                    assert(
                        badge.properties.x >= frame.badgeX,
                        where
                            .. ": "
                            .. entry.placement.id
                            .. " placed its badge at "
                            .. badge.properties.x
                            .. ", left of the column at "
                            .. frame.badgeX
                            .. ", where the heading is"
                    )

                    seen[word] = true
                    checked = checked + 1
                end
            end
        end
    end

    for _, mode in ipairs({ { "full screen", fullScreenZone }, { "app mode", appZone } }) do
        resetRadio()
        local widget = makeWidget("badge-flush-" .. string.gsub(mode[1], " ", ""), yaml)
        -- The very table the host holds, because a reflow is driven by mutating
        -- it. Building a second one and resizing that reflows nothing, and the
        -- check then watches a panel that never moved while reporting that it
        -- did -- which is how the first version of this test passed with the
        -- reflow path deliberately broken.
        local zone = mode[2]()
        local context = createLoaded(zone, DEFAULT_OPTIONS, widget)
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
        pump(context, 60)
        inspect(mode[1] .. " resting", context)

        -- A dead link badges the telemetry panels stale and then unavailable,
        -- which is how the two remaining words are reached.
        radio.rssi = 0
        pump(context, 80)
        inspect(mode[1] .. " link down", context)

        local widthBefore = {}
        for _, entry in ipairs(context.panels) do
            widthBefore[entry.placement.id] = boundsOf(entry).w
        end

        -- **And then the panel moves.** A badge's right edge is its panel's, so
        -- every reflow changes it -- and the badge is placed from its own
        -- measured text, which a reflow does not re-measure unless something
        -- makes it. Restating the box and leaving the word where the previous
        -- width put it is the defect shape this project has paid for eight
        -- times: a position derived from a size, carried as an offset.
        zone.w, zone.h = 360, 200
        local passes = 0
        repeat
            definition.refresh(context)
            passes = passes + 1
            assert(passes < 200, "reflow never finished")
        until reflowDone(context)
        pump(context, 40)
        local moved = false
        for _, entry in ipairs(context.panels) do
            if boundsOf(entry).w ~= widthBefore[entry.placement.id] then
                moved = true
            end
        end
        assert(
            moved,
            mode[1] .. ": no panel changed width, so the reflow below" .. " is not a reflow and proves nothing"
        )
        inspect(mode[1] .. " reflowed", context)
        resetRadio()
    end

    -- Non-vacuous in two directions: something was actually badged, and the
    -- words reached were words the vocabulary declares rather than whatever
    -- happened to be on screen.
    assert(checked >= 8, "only " .. checked .. " badged panels were found, so this proves very little")
    local reached = 0
    for word in pairs(seen) do
        assert(vocabulary[word], 'a panel drew "' .. word .. '", which is not in the badge vocabulary')
        reached = reached + 1
    end
    assert(reached >= 3, "only " .. reached .. " of the vocabulary was reached, so the narrow words may be untested")
end

testSupportingWordingsStayDistinct()
testSupportingRowsFitTheirBox()
testBadgesEndFlushWithTheirPanel()
testTwoRowFooterClearsTheReading()
