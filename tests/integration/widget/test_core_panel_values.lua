-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local sourcePath = root .. "/src/WIDGETS/AeroGrid/"
local edgetx = fixture.edgetx
local radio = fixture.radio
local resetRadio = fixture.reset
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local makeWidget = fixture.makeWidget
local themeModule = fixture.module("lib/theme.lua")
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local settle = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end
local CORE_LAYOUT = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))().CORE_LAYOUT
assert(
    themeModule.setCatalog(
        assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
    )
)

local assertFont = fixture.assertFont

local reflowDone = fixture.reflowDone

local function testFlightModeIndexRow()
    resetRadio()
    local widgetPath = makeWidget(
        "fm-index",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: tall
    type: flight-mode
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      showIndex: true
  - id: quiet
    type: flight-mode
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 20)

    -- The fixture's active mode is 1, named Sport.
    local tall = entryById(context, "tall").instance
    assertEqual(tall.showDetail, true, "a two-row panel shed its supporting row")
    assertEqual(
        tall.detailLabel.properties.text,
        "#1",
        "the mode number is not drawn, or still repeats the header's word"
    )
    assertEqual(tall.detailLabel.hidden, false)

    -- The same span without the setting draws no row at all -- and now builds
    -- no label for one either, where it used to build one and write an empty
    -- string into it. That object cost a reserved quarter of the panel as well
    -- as itself: the band was cut for a row that could never be filled, which
    -- took a font size off the name above it.
    local quiet = entryById(context, "quiet").instance
    assertEqual(quiet.rendered.detail, nil, "a panel that never asked for the mode number computed one")
    assertEqual(quiet.detailLabel, nil, "a panel that never asked for the mode number built a label for it")
    assertEqual(quiet.showDetail, false, "a panel with no mode number to show reserved a row for one")

    -- The reading fits: the fixture model's widest mode name is ten characters
    -- and this is the span that used to lose nearly half of it.
    --
    -- Asked of the panel's own room rather than of the label's box. The name
    -- is centred on a slot now, so its box is exactly as wide as the string it
    -- draws -- and comparing the widest possible name against a box sized for
    -- the current one asks whether `Normal` is as wide as `LongRange7`, which
    -- is not the question.
    local widest = "LongRange7"
    local font = tall.value.properties.font()
    -- Measured, because being drawn past the panel is a fact about advances
    -- rather than about the estimate of them, and the fitting that chose this
    -- font measured too. Asserting the estimate here would demand the panel
    -- hold about half again as much as it draws.
    assert(
        themeModule.measureText(font, widest) <= tall.area.valueBudget,
        "the widest mode name is drawn past the panel: needs "
            .. themeModule.measureText(font, widest)
            .. " of "
            .. tall.area.valueBudget
    )

    -- Shrink until the ladder takes the row away. The setting is still stated,
    -- and the panel must stop declaring and painting the row rather than
    -- writing into a hidden label, which is what it used to do.
    local zone = context.zone
    zone.h = 150
    local passes = 0
    repeat
        definition.refresh(context)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    until reflowDone(context)
    settle(context, 20)

    assertEqual(tall.showDetail, false, "a shortened panel kept a supporting row it has no space for")
    assertEqual(tall.rendered.detail, nil, "a shed mode number was still being formatted every frame")
    assert(tall.detailLabel.hidden, "a shed row was left on screen")

    -- Not formatted, and not written either. Writing an empty string into a
    -- hidden label leaves no trace on screen, so nothing about what is drawn
    -- can see it; the harness counts writes for exactly this.
    local writes = tall.detailLabel.writes
    radio.flightMode = 2
    settle(context, 20)
    assertEqual(tall.detailLabel.writes, writes, "a shed row was painted while the mode changed underneath it")

    -- And the row comes back with the right number rather than whatever it
    -- held when it was shed.
    radio.flightMode = 3
    settle(context, 20)
    zone.h = 272
    passes = 0
    repeat
        definition.refresh(context)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    until reflowDone(context)
    settle(context, 20)

    assertEqual(tall.showDetail, true, "the supporting row never came back")
    assertEqual(
        tall.detailLabel.properties.text,
        "#3",
        "a revealed mode number still reports the mode it was shed with"
    )
    resetRadio()
end

local function testFlightModeSizesFromTheModel()
    local layout = [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: mode
    type: flight-mode
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
]]

    local function fontFor(names)
        resetRadio()
        radio.flightModeNames = names
        local context =
            createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, makeWidget("fm-sizing", layout))
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
        settle(context, 20)
        local panel = entryById(context, "mode").instance
        return panel.value.properties.font(), panel.widest
    end

    local shortFont, shortWidest = fontFor({ [0] = "Up", [1] = "Down" })
    local longFont, longWidest = fontFor({ [0] = "Up", [4] = "LongRange7" })

    assertEqual(shortWidest, "Down", "the panel did not take its widest name from the model")
    assertEqual(longWidest, "LongRange7")
    assert(
        themeModule.fontHeight(shortFont) > themeModule.fontHeight(longFont),
        "a model whose mode names are short gained nothing: both readings are " .. edgetx.fontName(shortFont)
    )
    resetRadio()
end

local function testTxBatteryRangeComesFromTheRadio()
    resetRadio()
    local widgetPath = makeWidget(
        "tx-range",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: stated
    type: tx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      packEmpty: 6.6
      packFull: 8.4
      visual: bar
      showPercent: true
  - id: quiet
    type: tx-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      visual: bar
      showPercent: true
  - id: inverted
    type: tx-battery
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      packEmpty: 8.4
      packFull: 6.6
      visual: bar
      showPercent: true
  - id: half
    type: tx-battery
    col: 2
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      packEmpty: 6.6
      visual: bar
      showPercent: true
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 30)

    local stated = entryById(context, "stated").instance
    local quiet = entryById(context, "quiet").instance
    local inverted = entryById(context, "inverted").instance
    local half = entryById(context, "half").instance

    -- The voltage is authoritative and is shown by all of them. The fixture
    -- transmitter reads 7.9 V, and the unit rides beside the digits.
    for _, panel in ipairs({ stated, quiet, inverted, half }) do
        assertEqual(panel.text, "7.9")
        assertEqual(panel.unit.properties.text, "V")
    end

    -- Stated: the layout's 6.6 to 8.4, so 7.9 is 1.3 of 1.8, which is 72.
    assertEqual(stated.detailLabel.properties.text, "72% EST")
    assertEqual(stated.barShown, true)

    -- Stated nothing: the radio's own 6.4 to 8.4, so 7.9 is 1.5 of 2.0, which
    -- is 75. A different number from the layout's, which is what proves it came
    -- from the radio rather than from a default that happens to match.
    assertEqual(
        quiet.detailLabel.properties.text,
        "75% EST",
        "a panel that stated no range did not fall back to the radio's"
    )
    assertEqual(
        quiet.barShown,
        true,
        "a panel that stated no range drew no bar, which is what this change" .. " exists to stop being the normal case"
    )

    -- Half a range is not a range, and must not be mixed with the radio's
    -- other end: that would measure against two different packs.
    assertEqual(half.detailLabel.properties.text, "75% EST", "a stated empty was mixed with the radio's full")

    -- An inverted range is not a range either, and falls back rather than
    -- producing a backwards fill.
    assertEqual(inverted.detailLabel.properties.text, "75% EST", "an inverted range was treated as usable")

    -- And the pilot changing it in radio settings is seen, because the range is
    -- subscribed rather than read once. Nothing rebuilds a widget for that.
    radio.battMin, radio.battMax = 5.4, 8.4
    settle(context, 60)
    assertEqual(
        quiet.detailLabel.properties.text,
        "83% EST",
        "the radio's range was read once and went stale when the pilot changed it"
    )
    assertEqual(
        stated.detailLabel.properties.text,
        "72% EST",
        "a layout that states its own range was moved by a radio setting"
    )

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testTxBatteryWithoutAnyRange()
    resetRadio()
    local real = getGeneralSettings
    getGeneralSettings = nil

    local widgetPath = makeWidget(
        "tx-norange",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: quiet
    type: tx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      visual: bar
      showPercent: true
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    local ok, err = pcall(settle, context, 30)
    getGeneralSettings = real
    assert(ok, "a panel raised without getGeneralSettings: " .. tostring(err))

    local quiet = entryById(context, "quiet").instance
    assertEqual(quiet.text, "7.9", "the voltage it does know was lost")
    assertEqual(quiet.barShown, false, "a bar was drawn with nothing to measure it against")
    assertEqual(quiet.detailLabel.properties.text, "", "a percentage was estimated from nothing")
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testFlightTimerShedsItsDetail()
    resetRadio()
    local widgetPath = makeWidget(
        "timer-detail",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: tall
    type: flight-timer
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      timer: 0
  - id: flat
    type: flight-timer
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      timer: 0
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 30)

    local tall = entryById(context, "tall").instance
    local flat = entryById(context, "flat").instance

    -- Two rows: the caption is drawn, and says what the countdown is out of.
    assertEqual(tall.showDetail, true, "a two-row timer shed its caption")
    assertEqual(
        tall.detailLabel.properties.text,
        "OF 5:00",
        "the caption does not state the total the timer counts down from"
    )
    assertEqual(tall.detailLabel.hidden, false)

    -- One row: not drawn, and not made either.
    assertEqual(flat.showDetail, false, "a one-row timer kept its caption")
    assertEqual(flat.rendered.detail, nil, "a shed caption was still being formatted every frame")
    assert(flat.detailLabel.hidden, "a shed caption was left on screen")

    -- An expired countdown says so, where it can.
    radio.timers[0].value = -15
    settle(context, 20)
    assertEqual(tall.detailLabel.properties.text, "EXPIRED")
    assertEqual(tall.stateName, "critical")

    -- And a shed caption costs nothing to keep shed while the timer moves
    -- underneath it. Writing into a hidden label leaves no trace on screen, so
    -- only the harness's write counter can see this.
    local writes = flat.detailLabel.writes
    radio.timers[0].value = 42
    settle(context, 20)
    assertEqual(flat.detailLabel.writes, writes, "a shed caption was written while the timer changed underneath it")
    resetRadio()
end

local function testClockKeepsItsWidth()
    resetRadio()
    local widgetPath = makeWidget(
        "timer-width",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: clock
    type: flight-timer
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      timer: 0
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context, 30)

    local clock = entryById(context, "clock").instance
    local timerModule = assert(loadfile(sourcePath .. "panels/flight-timer.lua"))()
    local font = clock.value.properties.font
    font = type(font) == "function" and font() or font
    local budget = clock.area.valueBudget

    -- The precondition: the font really was chosen from the form, so the
    -- assertions below are about the string that decided it.
    assertFont(font, XXLSIZE, "a 2 x 2 clock")
    local formWidth = themeModule.measureText(font, timerModule.FORMS[1])
    assert(
        formWidth <= budget,
        "the form itself does not fit the panel it" .. " sized: " .. formWidth .. " in " .. budget
    )

    local TIMER_MAX = math.floor(0xffffff / 2)
    local cases = {
        { 90, "1:30", "an ordinary countdown" },
        { -15, "-0:15", "a countdown fifteen seconds past zero" },
        { 3599, "59:59", "one second under an hour" },
        -- **The shape does not change here**, which is the whole point: the
        -- shared formatter answers `1:00:00` for this and would widen the
        -- reading by two characters while a pilot is watching it.
        { 3600, "60:00", "exactly one hour" },
        { 5999, "99:59", "the clamp itself" },
        { 6000, "99:59", "one second past the clamp" },
        { TIMER_MAX, "99:59", "the largest value the firmware holds" },
        { -TIMER_MAX - 1, "-99:59", "the smallest value the firmware holds" },
    }

    local widest = 0
    for _, case in ipairs(cases) do
        radio.timers[0].value = case[1]
        -- A countdown's start has to clear the value, or the service reads it
        -- as a count-up timer and the sign never arrives.
        radio.timers[0].start = case[1] > 0 and (case[1] + 60) or 300
        settle(context, 20)

        assertEqual(clock.text, case[2], case[3] .. " drew the wrong clock")
        assertEqual(clock.value.properties.text, case[2], case[3] .. ": what was computed is not what was drawn")

        -- The font never moves, because it was chosen once from the form.
        local now = clock.value.properties.font
        now = type(now) == "function" and now() or now
        assertFont(now, font, case[3] .. " resized the clock")

        local width = themeModule.measureText(font, clock.text)
        assert(
            width <= formWidth,
            case[3] .. " drew " .. width .. " px, wider than the " .. formWidth .. " px form its font came from"
        )
        assert(width <= budget, case[3] .. " drew past its own box")
        if width > widest then
            widest = width
        end
    end

    -- And the sweep is not vacuous: something in it actually reached the form.
    assertEqual(
        widest,
        formWidth,
        "no reading in the sweep was as wide as the form, so this proves only" .. " that narrow strings fit"
    )

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testCorePanels()
    resetRadio()
    local widgetPath = makeWidget("core", CORE_LAYOUT)
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    assertEqual(#context.panels, 9)
    settle(context)

    -- A countdown shows what EdgeTX's timer says, takes its name from the
    -- model, and states the total it is counting down from.
    local countdown = entryById(context, "countdown").instance
    assertEqual(countdown.text, "1:30")
    assertEqual(countdown.labelValue, "FLIGHT", "the timer's own name was ignored")
    -- Both timers here are one row tall, which sheds the supporting row, so
    -- the total and the counting-up caption are not on screen and asserting
    -- their text would assert something nobody can see. The wording is checked
    -- at a span that keeps it, in testFlightTimerShedsItsDetail.
    assertEqual(countdown.showDetail, false, "a one-row timer found space for a supporting row")
    assert(countdown.detailLabel.hidden, "a shed row was left on screen")
    assertEqual(countdown.stateName, "warning", "90s left is inside the warning")
    assertEqual(countdown.badge.properties.text, "WARN")

    -- A count-up timer has no total and therefore no progress to draw.
    local countup = entryById(context, "countup").instance
    assertEqual(countup.text, "1:04")
    assertEqual(countup.showDetail, false)
    assert(countup.detailLabel.hidden, "a shed row was left on screen")
    assertEqual(countup.stateName, "normal")

    -- An expired countdown must never read like a healthy timer.
    radio.timers[0].value = -15
    settle(context, 12)
    assertEqual(countdown.text, "-0:15", "an expired countdown lost its sign")
    assertEqual(countdown.rendered.detail, nil, "a shed caption was still being formatted every frame")
    assertEqual(countdown.stateName, "critical")
    radio.timers[0].value = 90

    -- EdgeTX lets a countdown be shown as time used rather than time left, and
    -- says so with showElapsed. The fixture omitted the field entirely, so this
    -- branch was permanently false and no panel ever reached it: the same
    -- 300 second timer with 90 seconds left must read 3:30 used, not 1:30 left,
    -- and it is no longer a countdown to warn about.
    radio.timers[0].showElapsed = true
    settle(context, 12)
    assertEqual(countdown.text, "3:30", "showElapsed did not flip the timer")
    radio.timers[0].showElapsed = false
    settle(context, 12)
    assertEqual(countdown.text, "1:30", "the timer did not flip back")

    local mode = entryById(context, "mode").instance
    assertEqual(mode.text, "Sport")
    -- Declared only where it is drawn. This panel sheds the row, so the key is
    -- absent rather than computed and written into a hidden label.
    assertEqual(mode.rendered.detail, nil, "a shed mode number was still being formatted every frame")
    -- A single cell has no supporting row, so there is no mode number here and
    -- asserting its text would assert something nobody can see. This used to
    -- read `MODE 1` on a panel that draws no such row.
    assertEqual(mode.showDetail, false, "a single-cell flight mode found room for a supporting row")
    -- **No label at all, rather than a hidden one.** This panel did not ask
    -- for the mode number, so there is nothing for a row to hold at any span,
    -- and building an object to hide it is the invisible work the
    -- specification forbids.
    assertEqual(mode.detailLabel, nil, "a panel that never asked for the mode number built a label for it")

    -- The transmitter pack: voltage is authoritative, the percentage is an
    -- estimate and says so.
    local battery = entryById(context, "battery").instance
    assertEqual(battery.text, "7.9")
    -- A single cell sheds the supporting row, so the percentage is not on
    -- screen here; its wording is checked at a span that shows it, in
    -- testTxBatteryRangeGatesTheEstimate.
    assertEqual(battery.showDetail, false, "a single-cell battery found room for a percentage")
    assertEqual(battery.rendered.detail, nil, "a shed percentage was still being formatted every frame")
    assertEqual(battery.stateName, "normal")
    radio.values[320] = 6.7
    settle(context, 12)
    assertEqual(battery.stateName, "critical")
    assertEqual(battery.badge.properties.text, "CRIT")
    radio.values[320] = 7.9

    -- A GV is read through the ordinary source path; display settings are explicit.
    local gv = entryById(context, "gv").instance
    assertEqual(gv.text, "10")
    assertEqual(gv.settings.label, "GV2")
    assertEqual(gv.showRange, false)

    -- A global variable holds a separate value per flight mode, so switching
    -- mode has to re-read it. This previously asserted that the value did NOT
    -- move, reasoning about EdgeTX's inheritance, and it could not have failed
    -- either way: the mock ignored the flight mode argument entirely and
    -- answered the same number for every mode. It was asserting the fixture's
    -- limitation and calling it firmware behaviour.
    radio.flightMode, radio.flightModeName = 2, "Land"
    settle(context, 12)
    assertEqual(gv.text, "60", "the value stored for the new flight mode was not read")

    -- A mode with no value of its own does inherit, and that is a different
    -- observation from never having looked.
    radio.flightMode, radio.flightModeName = 3, "Cruise"
    settle(context, 12)
    assertEqual(gv.text, "10", "an inherited value was not inherited")

    radio.flightMode, radio.flightModeName = 1, "Sport"
    settle(context, 12)
    assertEqual(gv.text, "10")
    assertEqual(gv.unitText, "", "GV metadata is not supplied by the ordinary source interface")

    -- The same panel bound to a telemetry source instead.
    local dial = entryById(context, "dial").instance
    assertEqual(dial.text, "10.0")
    -- A single-cell metric intentionally omits its unit.
    assertEqual(dial.unit, nil)
    assertEqual(dial.showVisual, false, "a single-cell metric must keep its minimal presentation")
    assert(not dial.showUnit, "a single-cell metric does not create a unit label")
    assertEqual(dial.radial, nil)

    -- Trims are read through EdgeTX's own sources, in stored trim units.
    local trims = entryById(context, "trims").instance
    assertEqual(#trims.indicators, 3)
    assertEqual(trims.indicators[1].valueText, "+30 A", "240 raw is 30 trim units")
    assertEqual(trims.indicators[2].valueText, "-15 E")
    assertEqual(trims.indicators[3].valueText, "0 R")
    -- This panel is one row tall, which is not enough for a caption above a
    -- bar, so it sheds them. Asserting the caption's text here would assert
    -- something nobody can see; that it is hidden is the fact on screen. The
    -- text is checked at a span that keeps it, in testTrimPanelShedsText.
    assertEqual(trims.showCaption, false, "a one-row trim panel found room for captions")
    assert(trims.indicators[1].caption.hidden, "a shed caption was left on screen")
    -- A positive trim fills rightward from the centre of its own bar.
    local fill = trims.indicators[1].bar.fill.properties
    assert(
        fill.x >= trims.indicators[1].bar.x + math.floor(trims.indicators[1].bar.w / 2),
        "a positive trim filled the wrong side of centre"
    )

    local identity = entryById(context, "identity").instance
    assertEqual(identity.text, "Test Model")
    assertEqual(identity.labelsText, "fpv")
    assert(identity.image, "a model bitmap that exists was not shown")
    assertEqual(identity.image.properties.file, "/IMAGES/plane.png")

    -- **Contained, not cropped.** `fill` is the only thing that decides this
    -- and it reaches EdgeTX as `StaticImage`'s `fillFrame`, where `setZoom`
    -- computes `z = fillFrame ? max(zw, zh) : min(zw, zh)`
    -- (`gui/colorlcd/libui/static.cpp`). The larger zoom covers the frame and
    -- cuts off whatever does not fit; a model image is 192 x 114 and every
    -- frame this panel produces is wider in proportion, so covering cut
    -- the aircraft's top and bottom off -- a tenth of its height survived at
    -- four cells by two. Nothing else observable changes when this flips,
    -- which is why it is asserted here rather than inferred from a position.
    assertEqual(
        identity.image.properties.fill,
        false,
        "the model picture is cropped to fill its frame instead of fitted" .. " inside it"
    )

    -- And the name is the heading, because a picture is drawn. The configured
    -- label has nowhere to go on such a panel and the layout validator refuses
    -- one; this is the other half of that rule, observed rather than assumed.
    assertEqual(
        identity.label.properties.text,
        "TEST MODEL",
        "a panel drawing the model picture did not put the model name in its" .. " heading"
    )

    -- A metric bar measures the source against its explicit range.
    local swing = entryById(context, "swing").instance
    assertEqual(swing.text, "4.5")
    assertEqual(swing.bar, nil, "single-cell metrics omit visualization")

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

testCorePanels()
testFlightModeIndexRow()
testFlightModeSizesFromTheModel()
testTxBatteryRangeComesFromTheRadio()
testTxBatteryWithoutAnyRange()
testFlightTimerShedsItsDetail()
testClockKeepsItsWidth()
