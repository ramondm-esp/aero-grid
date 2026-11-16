-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local resetRadio = fixture.reset
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local themeModule = fixture.module("lib/theme.lua")
local primitivesModule = fixture.module("lib/primitives.lua")
assert(
    themeModule.setCatalog(
        assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
    )
)

local function testReconcileBar()
    resetRadio()
    local theme = themeModule.build("modern-dark")
    local root = lvgl.box({ x = 0, y = 0, w = 200, h = 100 })
    local bar = primitivesModule.bar(root, theme, {
        x = 0,
        y = 0,
        w = 100,
        fraction = 0,
        color = theme.color.cyan,
        marker = 0.5,
    })
    assert(bar.marker, "this test needs a bar that carries a marker")

    -- Shown: positioned, and every object told, the marker included.
    primitivesModule.reconcileBar(bar, true, 10, 20, 100, 0.25)
    assertEqual(bar.track.hidden, false)
    assertEqual(bar.fill.hidden, false)
    assertEqual(
        bar.marker.hidden,
        false,
        "a bar's marker was left behind, which is what reconciling its two" .. " other objects separately does"
    )
    assertEqual(bar.track.properties.x, 10)

    -- Hidden: every object told, and nothing positioned, because moving an
    -- object nobody can see is the invisible work this exists to stop.
    local writes = bar.track.writes
    primitivesModule.reconcileBar(bar, false, 99, 99, 40, 1)
    assertEqual(bar.track.hidden, true)
    assertEqual(bar.fill.hidden, true)
    assertEqual(bar.marker.hidden, true)
    assertEqual(bar.track.writes, writes, "a hidden bar was repositioned")
    assertEqual(bar.track.properties.x, 10, "a hidden bar moved")

    -- Settled: positioned, and told nothing it already is.
    primitivesModule.reconcileBar(bar, true, 30, 40, 80, 0.5)
    local calls = bar.track.visibilityCalls
    local markerCalls = bar.marker.visibilityCalls
    primitivesModule.reconcileBar(bar, true, 50, 40, 80, 0.5, true)
    assertEqual(bar.track.properties.x, 50, "a settled bar was not repositioned")
    assertEqual(bar.track.visibilityCalls, calls, "a bar whose visibility had not moved was told what it already was")
    assertEqual(bar.marker.visibilityCalls, markerCalls)

    -- Settled and hidden: nothing at all.
    primitivesModule.reconcileBar(bar, false, 1, 2, 3, 0)
    writes = bar.track.writes
    calls = bar.track.visibilityCalls
    primitivesModule.reconcileBar(bar, false, 7, 8, 9, 1, true)
    assertEqual(bar.track.writes, writes)
    assertEqual(bar.track.visibilityCalls, calls)

    -- A panel with no bar passes nil, and that is not an error.
    primitivesModule.reconcileBar(nil, true, 0, 0, 10, 1)
    root:clear()
end

local function testUnitNeedsAValueToQualify()
    resetRadio()
    local theme = themeModule.build("modern-dark")
    local root = lvgl.box({ x = 0, y = 0, w = 200, h = 100 })
    local context = {
        value = primitivesModule.value(root, theme, { x = 0, y = 0, w = 100, font = DBLSIZE, text = "--" }),
        unit = primitivesModule.unit(root, theme, { x = 0, y = 0, font = TINSIZE, text = "V" }),
        showUnit = true,
        unitText = "V",
    }
    local area = { valueCentre = 100, valueY = 20, unitFont = TINSIZE }

    local function place(text)
        primitivesModule.centreReading(context, themeModule, area, DBLSIZE, text)
    end

    -- A reading, so the unit has something to qualify.
    place("7.9")
    assertEqual(context.unit.hidden, false, "a unit was withheld from a reading")
    local readingX = context.value.properties.x
    local pairWidth = context.value.properties.w

    -- A missing value has no unit.
    place("--")
    assertEqual(context.unit.hidden, true, "a unit was drawn beside `--`")

    -- `N/A` is the other spelling of absence, and `link-status` prints it for a
    -- source the protocol does not publish at all.
    place("N/A")
    assertEqual(context.unit.hidden, true, "a unit was drawn beside `N/A`")

    -- Zero is a measurement, not an absence.
    place("0.0")
    assertEqual(
        context.unit.hidden,
        false,
        "a reading of zero lost its unit, so the rule read availability rather" .. " than what the panel draws"
    )

    -- Both the pair and a bare number are centered on the same slot.
    place("7.9")
    assertEqual(context.value.properties.x, readingX)
    assertEqual(context.value.properties.w, pairWidth)
    local bare = {
        value = primitivesModule.value(root, theme, { x = 0, y = 0, w = 100, font = DBLSIZE, text = "--" }),
        showUnit = false,
    }
    primitivesModule.centreReading(bare, themeModule, area, DBLSIZE, "7.9")
    assertEqual(
        bare.value.properties.x,
        area.valueCentre - math.floor(bare.value.properties.w / 2),
        "a bare reading must be centered without reserving room for a unit"
    )
    assertEqual(readingX, area.valueCentre - math.floor(pairWidth / 2))
    assert(bare.value.properties.w < pairWidth, "the drawn box did not shrink, so the unit's width is still reserved")

    -- A hidden unit is not repositioned. Placing something nobody can see is
    -- the invisible work this project has twice paid to remove, and it is
    -- invisible to assertions as well as to eyes.
    place("--")
    local writes = context.unit.writes
    place("N/A")
    assertEqual(context.unit.writes, writes, "a hidden unit was re-placed against a reading nobody can see it beside")

    root:clear()
end

local function testHeaderUsesVisibleBadgeWidth()
    resetRadio()
    local builder, primitives = themeModule, primitivesModule
    local theme = builder.build("modern-dark")
    local fonts = builder.typography(1, 1)
    local frame = builder.frame(theme, { w = 117, h = 65 }, fonts)
    local parent = lvgl.box({ x = 0, y = 0, w = 238, h = 65 })
    local label, badge =
        primitives.header(parent, theme, frame, fonts, "TRANSMITTER", builder.state(theme, "normal"), builder)
    local context = {}
    assertEqual(label.properties.text, "TRANSMITTER", "an empty badge shortened a title that fits")
    assertEqual(label.properties.w, frame.content)
    local x, y = label.properties.x, label.properties.y

    for _, text in ipairs({ "N/A", "WARN", "CRIT", "STALE", "IN-FLIGHT", "" }) do
        primitives.setBadge(context, builder, badge, frame, fonts.badge, text, theme.color.amber)
        assertEqual(label.properties.x, x, "a badge moved the title horizontally")
        assertEqual(label.properties.y, y, "a badge moved the title vertically")
        assertEqual(label.properties.font(), fonts.badge, "a title became smaller than its badge")
        if not label.hidden then
            assertEqual(label.lines, 1)
            local right = text == "" and frame.width - frame.padRight or badge.properties.x - 4
            assertEqual(label.properties.x + label.properties.w, right)
            local shown = label.properties.text
            assert(builder.measureText(fonts.label, shown) <= label.properties.w)
            if shown ~= "TRANSMITTER" then
                assert(
                    builder.measureText(fonts.label, string.sub("TRANSMITTER", 1, #shown + 1)) > label.properties.w,
                    "the title was shortened more than necessary"
                )
            end
        end
    end
    assertEqual(label.properties.text, "TRANSMITTER", "clearing the badge did not restore the full title")

    primitives.setBadge(context, builder, badge, frame, fonts.badge, "STALE", theme.color.amber)
    primitives.setHeading(label, builder, frame, fonts, "BATTERY TIMER")
    local wide = builder.frame(theme, { w = 238, h = 65 }, fonts)
    primitives.placeHeader(label, badge, wide, builder, fonts)
    assertEqual(label.properties.text, "BATTERY TIMER", "a reflow forgot the original runtime title")
    primitives.placeHeader(label, badge, frame, builder, fonts)
    assertEqual(label.lines, 1)
    primitives.setBadge(context, builder, badge, frame, fonts.badge, "", theme.color.amber)
    assertEqual(label.properties.text, "BATTERY TIMER", "clearing a badge restored an obsolete title")

    local narrow = builder.frame(theme, { w = 80, h = 65 }, fonts)
    primitives.placeHeader(label, badge, narrow, builder, fonts, "BATTERY", "STALE")
    assertEqual(label.hidden, true, "a title without room beside its badge was drawn")
    primitives.setBadge(context, builder, badge, narrow, fonts.badge, "", theme.color.amber)
    assertEqual(label.hidden, false, "clearing the badge did not reveal the title")
    assertEqual(label.properties.text, "BATTERY")

    local wanted = "IIIIIIIIIIII"
    local width = builder.measureText(SMLSIZE, wanted)
    assert(builder.textWidth(SMLSIZE, wanted) > width, "the proportional-width test does not distinguish the estimate")
    local fitted, font, dropped = builder.fitHeading(wanted, width, SMLSIZE, SMLSIZE)
    assertEqual(fitted, wanted, "a title fitting at its measured width was shortened")
    assertEqual(font, SMLSIZE)
    assertEqual(dropped, nil)
    fitted, font = builder.fitHeading("MMMM", 1, SMLSIZE, SMLSIZE)
    assertEqual(fitted, "", "a glyph wider than the available space was kept")
    assertEqual(font, SMLSIZE)
    fitted, font = builder.fitHeading("TITLE", 200, TINSIZE, SMLSIZE)
    assertEqual(font, SMLSIZE, "a preferred font below the badge size was accepted")
    fitted, font = builder.fitHeading("TITLE", 0, SMLSIZE, SMLSIZE)
    assertEqual(fitted, "")
    assertEqual(font, SMLSIZE)
    parent:clear()
end

testReconcileBar()
testUnitNeedsAValueToQualify()
testHeaderUsesVisibleBadgeWidth()
