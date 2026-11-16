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

local reflowDone = fixture.reflowDone

local function assertDeclaresWhatItDraws(cells, link, alt, nav, when)
    local function check(panel, what, shown, key)
        local declared = panel.rendered[key] ~= nil
        assertEqual(
            declared,
            shown,
            when
                .. ": "
                .. what
                .. (shown and " is drawn but declares no " or " declares a ")
                .. key
                .. (shown and " key" or " key it does not draw")
        )
    end

    check(cells, "the cell count", cells.showDetail, "count")
    check(cells, "the pack row", cells.showDetail, "pack")
    check(link, "the link detail row", link.showDetail, "detail")
    check(link, "the link row", link.showDetail, "link")
    check(alt, "the metric's range row", alt.showRange, "range")
    check(alt, "the metric's secondary", alt.showSecondary, "secondary")
    check(nav, "the bearing row", nav.showDetail, "detail")
    check(nav, "the origin row", nav.showDetail, "origin")
    check(nav, "the coordinate row", nav.showCoordinates, "coordinates")
end

local function testShedRowsComeBackCurrent()
    resetRadio()
    local widgetPath = makeWidget(
        "reveal",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: cells
    type: rx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: Cels
      visual: bar
      showCount: true
      showPack: true
  - id: link
    type: link-status
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      rssiSource: RSSI
      qualitySource: RQly
      reading: quality
  - id: alt
    type: metric
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          label: Alt
          unit: m
          precision: 0
        - source: Alt+
          label: MAX
          unit: m
          precision: 0
        - source: VSpd
          label: VS
  - id: nav
    type: navigation
    col: 2
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      source: GPS
      presentation: bearing
      showCoordinates: true
]]
    )

    local zone = { x = 0, y = 0, w = 480, h = 272 }
    local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

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
    settle(context, 60)

    local cells = entryById(context, "cells").instance
    local link = entryById(context, "link").instance
    local alt = entryById(context, "alt").instance
    local nav = entryById(context, "nav").instance

    -- The precondition: every row under test is on screen at this span. Without
    -- this the shed below is not a shed and the reveal is not a reveal.
    assertEqual(cells.showDetail, true, "the cell panel shed its rows too early")
    assertEqual(link.showDetail, true, "the link panel shed its rows too early")
    assertEqual(alt.showRange, true, "the metric shed its range row too early")
    assertEqual(alt.showSecondary, true, "the metric shed its secondary too early")
    assertEqual(nav.showDetail, true, "the nav panel shed its rows too early")
    -- **One supporting row at this span, not two.** A `2 x 2` panel's tertiary
    -- quarter is 31 px and this panel's two-row group is 32 px of ink, so
    -- the coordinates are shed by the band that would have to hold them. The
    -- row that sheds and returns here is therefore the bearing, which is what
    -- the assertions below follow. Two rows at a three-row span are covered by
    -- testTwoRowFooterClearsTheReading.
    assertEqual(nav.showCoordinates, true, "compact footer must retain coordinates at 2 x 2")

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

    reflow(240, 140)

    assertEqual(cells.showDetail, false, "the cell panel kept rows it cannot fit")
    assertEqual(link.showDetail, false, "the link panel kept rows it cannot fit")
    assertEqual(alt.showRange, false, "the metric kept a range row it cannot fit")
    assertEqual(alt.showSecondary, false, "the metric kept a row it cannot fit")
    assertEqual(nav.showDetail, false, "the nav panel kept rows it cannot fit")

    assertDeclaresWhatItDraws(cells, link, alt, nav, "shed")

    -- Everything moves here, while the rows are hidden and nothing is drawing
    -- them, and nothing moves after this point.
    radio.values[130] = { 4.11, 4.09, 4.12, 4.10, 4.08 }
    radio.values[140] = -95
    radio.values[141] = 42
    radio.values[120] = -3.5
    radio.values[109] = {
        lat = 47.4000,
        lon = 8.6000,
        ["pilot-lat"] = 47.3700,
        ["pilot-lon"] = 8.5400,
    }
    settle(context, 60)

    reflow(480, 272)

    assertDeclaresWhatItDraws(cells, link, alt, nav, "revealed")
    assertEqual(cells.showDetail, true, "the cell rows never came back")
    assertEqual(link.showDetail, true, "the link rows never came back")
    assertEqual(alt.showSecondary, true, "the metric's secondary never came back")
    assertEqual(nav.showDetail, true, "the nav rows never came back")

    -- Five cells now, not three. A stale row would still say 3S.
    assertEqual(cells.countLabel.properties.text, "5S", "a revealed cell count still reports the pack it was shed with")
    -- With quality leading, the supporting row names RSSI, which fell from
    -- -70 to -95 while the row was not on screen.
    assert(
        string.find(link.linkLabel.properties.text, "-95", 1, true),
        "a revealed link row still reports the RSSI it was shed with: " .. tostring(link.linkLabel.properties.text)
    )
    -- The vertical speed reversed while the row was not on screen.
    assert(
        string.find(alt.secondary.properties.text, "-3", 1, true),
        "a revealed secondary row still reports the value it was shed with: " .. tostring(alt.secondary.properties.text)
    )
    -- The model moved while the row was hidden, so the bearing measured from
    -- home moved with it: 009 degrees before, 054 after. Pinned rather than
    -- merely required to differ, because "not 009" is satisfied by every wrong
    -- answer as well as the right one.
    assertEqual(
        nav.detailLabel.properties.text,
        "BRG 054 NE",
        "a revealed bearing row still reports the bearing it was shed with: "
            .. tostring(nav.detailLabel.properties.text)
    )
    assertEqual(
        nav.detailLabel.properties.text,
        nav.detail,
        "a revealed bearing row disagrees with what the panel last declared"
    )
    assertEqual(
        cells.countLabel.properties.text,
        cells.countText,
        "a revealed cell count disagrees with what the panel last declared"
    )

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testTrimPanelShedsText()
    resetRadio()
    local layout = [==[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: trims
    type: trim-panel
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      readout: raw
  - id: tight
    type: metric
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          label: Alt
          unit: m
          precision: 0
]==]
    local widget = makeWidget("trim-shed", layout)
    -- The normal simulator-sized 2 x 2 square sheds captions. Use a larger
    -- virtual zone first to test visible captions and their later reflow.
    local zone = { x = 0, y = 0, w = 800, h = 480 }
    local context = createLoaded(zone, DEFAULT_OPTIONS, widget)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    settle(context)

    local trims = entryById(context, "trims").instance
    assertEqual(#trims.indicators, 3)

    -- The shared reconcile is what keeps every panel off its hidden rows.
    -- It is proved on a metric rather than on the trim panel, which guards the
    -- call itself and so never reaches reconcile with a row staying shed. The
    -- metric is built at a span that has a unit and then narrowed until it
    -- does not, which is the state reconcile is being asked about.
    local tight = entryById(context, "tight").instance
    assert(tight.unit, "the metric never built a unit to shed")
    assertEqual(tight.unit.hidden, false, "a 2 x 2 metric shed its unit")

    -- At this zone size, the 2 x 2 square has room for all three parts.
    assertEqual(trims.showCaption, true, "a 2 x 2 trim panel shed its captions")
    assertEqual(trims.showValue, true, "a 2 x 2 trim panel shed its readouts")
    assertEqual(trims.indicators[1].caption.properties.text, "AIL")
    assertEqual(trims.indicators[1].caption.hidden, false)
    assertEqual(trims.indicators[1].valueText, "+30 A", "240 raw is 30 trim units")

    -- Shrinking the host zone narrows every cell past what text needs, and
    -- shortens the metric beside it past the row its unit needs.
    zone.w = 240
    zone.h = 100
    local passes = 0
    repeat
        definition.refresh(context)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    until reflowDone(context)
    settle(context)

    assertEqual(trims.showCaption, false, "a narrowed trim panel kept captions it has no room for")
    assertEqual(trims.showValue, false, "a narrowed trim panel kept readouts it has no room for")
    assert(trims.indicators[1].caption.hidden, "a shed caption stayed on screen")
    assert(trims.indicators[1].value.hidden, "a shed readout stayed on screen")

    -- Hidden is not the point. The declaration is what the panel draws, so a
    -- readout it has shed must not be in it: nothing formats a string for a
    -- label that is not on screen.
    assertEqual(trims.rendered.text1, nil, "a shed readout was still being formatted every frame")
    assertEqual(
        trims.rendered.fraction1 ~= nil,
        true,
        "the bar stopped being declared, which is the part that is still drawn"
    )
    assertEqual(trims.indicators[1].valueText, "", "a shed readout left its last wording behind as if still current")

    -- Invisible work leaves no trace on screen, so nothing else in this suite
    -- can see it. The harness counts writes into LVGL for exactly this: a row
    -- the panel has shed must cost nothing to keep shed, however many reflows
    -- pass over it.
    local captionWrites = trims.indicators[1].caption.writes
    local valueWrites = trims.indicators[1].value.writes
    local captionCalls = trims.indicators[1].caption.visibilityCalls
    local valueCalls = trims.indicators[1].value.visibilityCalls
    local unitWrites = tight.unit.writes
    zone.w = 236
    passes = 0
    repeat
        definition.refresh(context)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    until reflowDone(context)
    settle(context)

    assertEqual(
        trims.indicators[1].caption.writes,
        captionWrites,
        "a reflow repositioned a caption the panel had already shed"
    )
    assertEqual(
        trims.indicators[1].value.writes,
        valueWrites,
        "a reflow repositioned a readout the panel had already shed"
    )
    assertEqual(
        trims.indicators[1].caption.visibilityCalls,
        captionCalls,
        "a reflow hid a caption that was already hidden"
    )
    assertEqual(trims.indicators[1].value.visibilityCalls, valueCalls, "a reflow hid a readout that was already hidden")
    -- The metric's unit used to be shed here, and it is not any more: it rides
    -- beside the reading instead of taking a row, so a narrower panel keeps it
    -- until the pair genuinely will not fit, and at 116 pixels an `m` beside a
    -- DBLSIZE `100` still does. What replaces that assertion is the invariant
    -- the unit brought with it -- a rider that is drawn is repositioned only
    -- when the reading's own width changed -- because a unit that rewrites its
    -- position every frame is exactly the invisible work this test exists for.
    assert(
        not tight.unit.hidden,
        "the metric shed a unit it has room for, so the line below is measuring" .. " a hidden object"
    )
    assertEqual(
        tight.unit.writes,
        unitWrites + 1,
        "a reflow moved the unit more than once, or not at all: it moved "
            .. (tight.unit.writes - unitWrites)
            .. " times"
    )
    zone.w = 240
    passes = 0
    repeat
        definition.refresh(context)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    until reflowDone(context)

    -- Widening again must bring the text back with its wording, not with
    -- whatever it held when it was shed.
    zone.w = 800
    zone.h = 480
    passes = 0
    repeat
        definition.refresh(context)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    until reflowDone(context)
    settle(context)

    assertEqual(trims.showCaption, true, "captions never came back")
    assertEqual(trims.indicators[1].caption.properties.text, "AIL", "a revealed caption came back blank")
    assertEqual(trims.indicators[1].caption.hidden, false)
    assertEqual(
        trims.indicators[1].value.properties.text,
        "+30 A",
        "a revealed readout came back with what it held when it was shed"
    )

    -- A reflow that changes nothing about visibility still has to move the
    -- rows, or a panel that merely narrows leaves its text where it was.
    local captionBefore = trims.indicators[2].caption.properties.x
    zone.w = 720
    passes = 0
    repeat
        definition.refresh(context)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    until reflowDone(context)
    settle(context)

    assertEqual(trims.showCaption, true, "a mild narrowing shed captions that still fit")
    assert(
        trims.indicators[2].caption.properties.x < captionBefore,
        "a narrowed panel left its captions at their old positions"
    )
    assertEqual(
        trims.indicators[2].caption.hidden,
        false,
        "a caption that never changed visibility was hidden by the reflow"
    )
    assertEqual(
        trims.indicators[1].caption.properties.text,
        "AIL",
        "a reflow that kept the captions rewrote one of them blank"
    )

    -- A panel built small has never had a caption to write, so revealing one
    -- has to write it rather than reveal whatever creation happened to leave.
    -- This is the case the first reveal above cannot prove: that panel was
    -- built wide, so its captions already said the right thing.
    resetRadio()
    local narrowZone = { x = 0, y = 0, w = 240, h = 240 }
    local narrow = createLoaded(narrowZone, DEFAULT_OPTIONS, makeWidget("trim-shed-narrow", layout))
    assertEqual(#narrow.errors, 0, table.concat(narrow.errors, "\n"))
    settle(narrow)

    local born = entryById(narrow, "trims").instance
    assertEqual(born.showCaption, false, "a 240 px panel found room for captions")
    assertEqual(
        born.indicators[1].caption.properties.text,
        "",
        "a panel built without room wrote captions nobody could read"
    )

    narrowZone.w = 800
    narrowZone.h = 480
    passes = 0
    repeat
        definition.refresh(narrow)
        passes = passes + 1
        assert(passes < 100, "reflow never finished")
    until reflowDone(narrow)
    settle(narrow)

    assertEqual(born.showCaption, true, "a widened panel never found room")
    assertEqual(
        born.indicators[1].caption.properties.text,
        "AIL",
        "a caption revealed for the first time came back blank"
    )
    assertEqual(born.indicators[1].caption.hidden, false)
end

testShedRowsComeBackCurrent()
testTrimPanelShedsText()
