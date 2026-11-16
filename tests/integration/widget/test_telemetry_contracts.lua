-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local radioMock = fixture.radioMock
local radio = fixture.radio
local resetRadio = fixture.reset
local tick = fixture.tick
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
local REFERENCE_LAYOUT = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))().REFERENCE_LAYOUT
local TELEMETRY_LAYOUT = assert(loadfile(root .. "/tests/support/layout_fixtures.lua"))().TELEMETRY_LAYOUT
local referencePath = makeWidget("reference", REFERENCE_LAYOUT)
assert(
    themeModule.setCatalog(
        assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
    )
)

local reflowDone = fixture.reflowDone

local function testTelemetryDrivesPanels()
    resetRadio()
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, referencePath)
    local pack = entryById(context, "pack").instance
    local current = entryById(context, "current").instance

    assert(pack.feed, "the metric never subscribed to a source")
    assertEqual(pack.feed.name, "RxBt")

    --- Advance far enough for the services and the panel to both fall due.
    local function settle()
        for _ = 1, 8 do
            tick(20)
            definition.refresh(context)
        end
    end

    settle()
    assertEqual(pack.stateName, "normal")
    assertEqual(pack.value.properties.text, "24.0")
    assertEqual(pack.badge.properties.text, "")

    assertEqual(current.showUnit, true, "the sensor unit fits beside the reading")
    assertEqual(current.unit.properties.text, "A")
    assert(not current.unit.hidden, "the sensor unit was left hidden")
    -- Without a configured precision, the sensor's precision. This is the
    -- dominant reading, which every span draws.
    assertEqual(current.text, "10.0", "the sensor precision was ignored")

    radio.values[100] = 20.5
    settle()
    assertEqual(pack.stateName, "warning")
    assertEqual(pack.badge.properties.text, "WARN")

    radio.values[100] = 19.0
    settle()
    assertEqual(pack.stateName, "critical")
    assertEqual(pack.badge.properties.text, "CRIT")

    -- Losing the link must keep the last reading and mark it stale, never
    -- replace it with the zero EdgeTX reports for a dead telemetry source.
    radio.values[100] = 24.0
    settle()
    assertEqual(pack.stateName, "normal")
    radio.rssi = 0
    settle()
    assertEqual(pack.stateName, "stale")
    assertEqual(pack.badge.properties.text, "STALE")
    assertEqual(pack.value.properties.text, "24.0", "a stale poll overwrote the value")

    -- With the link back, a zero really is a reading and must be shown as one.
    radio.rssi = 80
    radio.values[100] = 0
    settle()
    assertEqual(pack.value.properties.text, "0.0", "a valid zero was not shown")
    assertEqual(pack.stateName, "critical")

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testOnlyReferencedSourcesArePolled()
    resetRadio()
    local read = {}
    local realGetValue = getValue
    getValue = function(source)
        read[tostring(source)] = true
        return realGetValue(source)
    end

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, referencePath)
    for _ = 1, 40 do
        tick(20)
        definition.refresh(context)
    end
    getValue = realGetValue

    assert(read["100"], "a referenced source was never polled")
    assert(not read["109"], "an unreferenced GPS source was polled")
    assert(not read["310"], "an unreferenced trim source was polled")
    assert(not read["tx-voltage"], "an unreferenced radio source was polled")

    -- Services nothing subscribed to must stay idle rather than being scheduled.
    local byId = context.serviceRuntime.byId
    assert(byId.telemetry.revision > 0, "the telemetry service never ran")
    assertEqual(byId.navigation.revision, 0, "an idle service was scheduled")
    assertEqual(byId.control.revision, 0, "an idle service was scheduled")
    assertEqual(byId.model.revision, 0, "an idle service was scheduled")
end

local function testTelemetryPanels()
    resetRadio()
    local widgetPath = makeWidget("telemetry", TELEMETRY_LAYOUT)
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    assertEqual(#context.panels, 5)
    settle(context)

    -- The pack is judged by its worst cell, and the summed pack voltage is
    -- supporting detail rather than the headline.
    local pack = entryById(context, "pack").instance
    assertEqual(pack.text, "4.09")
    assertEqual(pack.countText, "4S")
    assertEqual(pack.packText, "16.4V")
    assertEqual(pack.stateName, "normal")
    assertEqual(pack.summary.count, 4)
    assertEqual(pack.summary.shape, "cells")

    -- One sagging cell must take the panel critical even though the pack sum
    -- barely moves: 15.6 V across four cells still looks healthy.
    radio.values[130] = { 4.11, 3.25, 4.09, 4.12 }
    radio.values[131] = 3.25
    settle(context, 12)
    assertEqual(pack.text, "3.25")
    assertEqual(pack.stateName, "critical")
    assertEqual(pack.badge.properties.text, "CRIT")

    -- The cells-monitor row always reports its measured count.
    radio.values[130] = { 4.11, 4.13, 4.09 }
    settle(context, 12)
    assertEqual(pack.countText, "3S", "the panel did not use the measured cell count")
    assertEqual(pack.stateName, "normal")

    -- Link quality leads under `auto`, because a percentage means the same
    -- thing on every protocol where RSSI does not.
    local link = entryById(context, "link").instance
    assertEqual(link.primaryName, "quality")
    assertEqual(link.text, "96")
    assertEqual(link.stateName, "normal")
    -- Both link panels are 2 x 1, which is 65 px tall, and shed their supporting
    -- rows to keep the reading large. What those rows say is covered at a span
    -- that shows them, below; asserting their text here described strings the
    -- panel does not draw.
    assertEqual(link.showDetail, false)

    radio.values[141] = 44
    settle(context, 12)
    assertEqual(link.stateName, "warning")
    assertEqual(link.badge.properties.text, "WARN")
    radio.values[141] = 22
    settle(context, 12)
    assertEqual(link.stateName, "critical")

    -- A dBm source keeps its own unit and its own thresholds; nothing converts
    -- one protocol's numbers into another's.
    local elrs = entryById(context, "elrs").instance
    assertEqual(elrs.primaryName, "rssi")
    assertEqual(elrs.text, "-72")
    assertEqual(elrs.unit.properties.text, "dBm", "the unit the source resolved to never reached the label beside it")
    assertEqual(elrs.stateName, "normal")
    radio.values[143] = -95
    settle(context, 12)
    assertEqual(elrs.stateName, "warning", "a dBm threshold must count downward")
    radio.values[143] = -72

    -- Navigation computes distance and bearing from the pilot position EdgeTX
    -- recorded, and says in words what the direction means.
    local nav = entryById(context, "nav").instance
    assertEqual(nav.text, "778")
    -- Fitted to the row rather than overrunning it. Whichever wording is chosen
    -- has to fit, which is the property that matters; pinning the string alone
    -- would pass on a helper that always returned the shortest one.
    assertEqual(nav.detail, nil, "tape replaces bearing text")
    assertEqual(nav.origin, "")
    assert(themeModule.textWidth(nav.fonts.label, nav.origin) <= nav.originWidth, "the origin caption overran its box")
    -- **No coordinates at this span**, and asserting their text here would be
    -- asserting a string nobody can see. A `2 x 2` panel's tertiary quarter is
    -- 31 px and two supporting rows are 32 px of ink, so this panel draws
    -- the bearing alone and the coordinates are shed by the band that would
    -- have had to hold them. They are checked at a three-row span, in
    -- testTwoRowFooterClearsTheReading.
    assertEqual(nav.showCoordinates, true, "compact footer must retain coordinates at 2 x 2")
    assert(nav.rendered.coordinates ~= nil)
    assertEqual(nav.stateName, "normal")
    assertEqual(nav.showTape, true, "legacy compass presentation must become a tape")
    assert(not nav.tape.root.hidden, "the requested tape was hidden")

    local shared = entryById(context, "native").instance
    assertEqual(shared.text, nav.text)
    assertEqual(shared.feed.distance, nav.feed.distance)
    assertEqual(shared.feed.pilotLatitude, nav.feed.pilotLatitude)
    assertEqual(shared.feed.pilotLongitude, nav.feed.pilotLongitude)

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testCompassShedsWhenThePanelNarrows()
    resetRadio()
    local widgetPath = makeWidget(
        "compass-shed",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: nav
    type: navigation
    col: 0
    row: 0
    colSpan: 3
    rowSpan: 2
    config:
      source: GPS
      label: Nav
      presentation: auto
]]
    )

    local zone = { x = 0, y = 0, w = 480, h = 272 }
    local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    pump(context, 60)

    local function drain()
        local passes = 0
        repeat
            definition.refresh(context)
            passes = passes + 1
            assert(passes < 200, "reflow never finished")
        until reflowDone(context)
    end

    local nav = entryById(context, "nav").instance
    assertEqual(nav.tape.root.hidden, false, "the tape was never shown")
    local firstWidth = nav.area.tapeWidth

    zone.w = 320
    drain()
    pump(context, 10)
    -- **Only the width changed.** A 320 px zone gives this panel a 224 px
    -- content box and leaves its 62 px body band alone, so the distance stays
    -- at XXLSIZE: `888.88km` is 195 px there, half of that is 98, and the
    -- tightened left slot has 67 px to its left. The reading's left edge would
    -- land at -23, and at strict halves at -34, so the dial goes rather than
    -- the distance shrinking.
    assertEqual(nav.tape.root.hidden, false, "tape must remain visible at standard narrower zone")

    zone.w = 480
    drain()
    pump(context, 10)
    assertEqual(nav.tape.root.hidden, false, "the tape was not restored")
    assertEqual(nav.area.tapeWidth, firstWidth, "the tape was not restored to its full size")

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testCompassPointsWhereTheFixIs()
    resetRadio()
    local widgetPath = makeWidget(
        "compass-pointer",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: nav
    type: navigation
    col: 0
    row: 0
    colSpan: 3
    rowSpan: 2
    config:
      source: GPS
      label: Nav
      presentation: detailed
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    pump(context, 60)

    local nav = entryById(context, "nav").instance
    -- The precondition. Without it every assertion below is about an object
    -- nobody draws and nothing writes to.
    assertEqual(nav.showTape, true, "the panel must show its tape")
    assertEqual(nav.tape.root.hidden, false, "the tape was not on screen")

    -- A real fix, 9 degrees from home. Three cells wide gives the row enough
    -- for the compass point as well as the number, which a `2 x 2` sheds.
    assertEqual(nav.detail, nil)
    assert(not nav.tape.pointer.hidden, "a known bearing must show a filled pointer")

    -- And nowhere when there is nowhere to point. Zero for both axes is what
    -- EdgeTX reports before it has a fix, and it is a real place off the coast
    -- of Africa, so it must never be drawn as one.
    radio.values[109].lat = 0
    radio.values[109].lon = 0
    pump(context, 40)
    assertEqual(nav.origin, "NO FIX")
    assertEqual(nav.tape.pointer.hidden, true, "an unknown bearing must hide the pointer")

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testTelemetryDegrades()
    resetRadio()
    local widgetPath = makeWidget("telemetry-degrade", TELEMETRY_LAYOUT)
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    settle(context)

    local pack = entryById(context, "pack").instance
    local link = entryById(context, "link").instance
    local nav = entryById(context, "nav").instance

    assertEqual(pack.stateName, "normal")
    assertEqual(nav.stateName, "normal")

    -- Disconnect. Every reading keeps its last value, marked, and the link
    -- panel says so in the one place a pilot will look.
    radio.rssi = 0
    pump(context, 40)

    assertEqual(pack.stateName, "stale", "a dropped link hid the last cells")
    assertEqual(pack.text, "4.09", "a stale poll overwrote the reading")
    assertEqual(pack.badge.properties.text, "STALE")

    assertEqual(link.stateName, "critical", "a dead link is the measurement")
    -- The badge carries the state. Which of the several ways a link can fail is
    -- carried by the supporting row, at a span that has one; this panel is
    -- 2 x 1 and sheds it.
    assertEqual(link.badge.properties.text, "CRIT")

    assertEqual(nav.stateName, "stale")
    assertEqual(nav.text, "778", "the last known position was discarded")
    assertEqual(nav.origin, "LAST KNOWN")

    -- Reconnect. Nothing may be left marked once readings arrive again.
    radio.rssi = 80
    pump(context, 40)
    assertEqual(pack.stateName, "normal")
    assertEqual(link.stateName, "normal")
    assertEqual(link.badge.properties.text, "")
    assertEqual(nav.stateName, "normal")
    assertEqual(nav.origin, "")

    -- A fix EdgeTX has not acquired reports zero for both axes, which is a real
    -- place off the coast of Africa and must never be shown as one.
    radio.values[109].lat = 0
    radio.values[109].lon = 0
    pump(context, 40)
    assertEqual(nav.stateName, "unavailable")
    assertEqual(nav.badge.properties.text, "N/A")
    assertEqual(nav.origin, "NO FIX")
    assertEqual(nav.text, "--", "a missing fix was shown as a distance")
    -- The coordinates row is shed at this span, so what it would have said is
    -- not on screen and is not asserted. The state, the badge and the origin
    -- caption are what this panel actually reports a lost fix with.
    -- The dial must not point anywhere when there is nowhere to point.
    assertEqual(nav.tape.pointer.hidden, true, "an unknown bearing must hide the pointer")

    -- A fix without a home position: the position is perfectly good, but a
    -- distance and a bearing would be measured from nowhere.
    radio.values[109].lat = 47.3769
    radio.values[109].lon = 8.5417
    radio.values[109]["pilot-lat"] = 0
    radio.values[109]["pilot-lon"] = 0
    pump(context, 40)
    assertEqual(nav.stateName, "normal", "a missing home is not a broken fix")
    -- A missing home position leaves the fix good, so the panel is not badged
    -- at all and only the caption changes.
    assertEqual(nav.badge.properties.text, "")
    assert(string.match(nav.origin, "^NO HOME"), nav.origin)
    assertEqual(nav.text, "--")
    assertEqual(nav.detail, nil, "tape must not invent a bearing text row")
    assertEqual(nav.origin, "NO HOME POSITION")
    -- **That the position itself is still known is asserted at a span that
    -- draws it.** The specification's promise is that a missing home withholds
    -- only the two values measured from home and leaves the coordinates
    -- visible; this panel is `2 x 2` and sheds its coordinate row to the
    -- tertiary quarter, so the promise is checked in
    -- testTwoRowFooterClearsTheReading, on a three-row panel that draws both
    -- supporting rows. Asserting the string here would assert something no
    -- screen shows.
    assertEqual(nav.showCoordinates, true)

    -- A table whose entries cannot be cell voltages. The count row says the
    -- table is gone, and the cells table remains the sole headline source.
    -- **A pack not yet detected and a source answering wrongly still
    -- read differently**, because one means wait and the other means go and
    -- fix something; which *kind* of wrong is not a difference the row spends
    -- a word on.
    radio.values[130] = { 0, -1, 99 }
    pump(context, 40)
    assertEqual(pack.summary.shape, "invalid")
    assertEqual(pack.text, "--")
    assertEqual(pack.badge.properties.text, "N/A")
    assertEqual(pack.countText, "CELLS ERR")
    assert(
        themeModule.measureText(pack.fonts.label, pack.countText) <= pack.detailWidth,
        "the cell-count row overran its box"
    )
    assertEqual(pack.packText, "", "a pack sum was computed from nonsense")

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testCellSourceShapes()
    resetRadio()
    radio.values[100] = 16.4
    local widgetPath = makeWidget(
        "cell-shapes",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: extreme
    type: rx-battery
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: Cels-
      label: Wrong
      visual: bar
  - id: voltage
    type: rx-battery
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: RxBt
      label: Pack voltage
      visual: bar
  - id: absent
    type: rx-battery
    col: 0
    row: 2
    colSpan: 2
    rowSpan: 2
    config:
      source: NoSuchSensor
      label: Missing
      visual: bar
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    pump(context, 40)

    for _, id in ipairs({ "extreme", "voltage" }) do
        local instance = entryById(context, id).instance
        assertEqual(instance.summary.shape, "pack", id .. " must interpret numeric telemetry as pack voltage")
        assertEqual(instance.stateName, "normal")
        assertEqual(instance.countText, id == "extreme" and "1S EST" or "4S EST")
        assertEqual(
            instance.text,
            id == "extreme" and "4.09" or "4.10",
            "numeric pack voltage uses average cell voltage"
        )
        assertEqual(instance.summary.lowest, nil, "numeric sources must not imply measured individual cells")
    end

    -- A sensor the radio has never heard of is a different problem again, and
    -- keeps the ordinary wording.
    local absent = entryById(context, "absent").instance
    assertEqual(absent.summary.shape, "none")
    assertEqual(absent.stateName, "unavailable")
    assertEqual(absent.badge.properties.text, "N/A")

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testRefreshSeesEverythingItDraws()
    resetRadio()
    local widgetPath = makeWidget("stale-rows", TELEMETRY_LAYOUT)
    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    settle(context)

    -- Three of four cells sagging moves the pack sum by 0.6 V without moving
    -- the lowest cell, which is the reading the panel leads with.
    local pack = entryById(context, "pack").instance
    radio.values[130] = { 3.80, 4.10, 4.10, 4.10 }
    radio.values[131] = 3.80
    settle(context, 20)
    assertEqual(pack.text, "3.80")
    assertEqual(pack.packText, "16.1V")

    radio.values[130] = { 3.80, 3.90, 3.90, 3.90 }
    settle(context, 20)
    assertEqual(pack.text, "3.80", "the lowest cell should not have moved")
    assertEqual(pack.packText, "15.5V", "the pack row froze on an old sum")

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testNavigationSeesItsSensorAppear()
    resetRadio()
    local widgetPath = makeWidget(
        "late-gps",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: nav
    type: navigation
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      source: LateGps
      presentation: detailed
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    settle(context, 20)

    local nav = entryById(context, "nav").instance
    assertEqual(nav.stateName, "unavailable")
    assertEqual(nav.badge.properties.text, "N/A")
    assertEqual(nav.origin, "NO GPS SOURCE")

    -- The sensor arrives, but without a position yet: this is the cold start,
    -- and it is a different message from a layout naming a sensor that is not
    -- there. Nothing else in the snapshot moves, so only `known` says so.
    radio.fields.LateGps = { id = 150, name = "LateGps", desc = "Late GPS", unit = 40 }
    radio.values[150] = { lat = 0, lon = 0, ["pilot-lat"] = 0, ["pilot-lon"] = 0 }
    radioMock.indexFields()
    settle(context, 60)

    assertEqual(nav.stateName, "unavailable")
    assertEqual(nav.badge.properties.text, "N/A", "a sensor that appeared was still reported as a missing source")
    assertEqual(nav.origin, "NO FIX")

    -- And then a real position.
    radio.values[150] = {
        lat = 47.3769,
        lon = 8.5417,
        ["pilot-lat"] = 47.3700,
        ["pilot-lon"] = 8.5400,
    }
    settle(context, 60)
    assertEqual(nav.stateName, "normal")
    assertEqual(nav.text, "778")

    radio.fields.LateGps = nil
    radio.values[150] = nil
    radioMock.indexFields()
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    resetRadio()
end

local function testProtocolWithoutRssi()
    resetRadio()
    local widgetPath = makeWidget(
        "no-rssi",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: link
    type: link-status
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      rssiSource: RSSI
      qualitySource: RQly
      # `auto` is the subject here, so it carries no thresholds: their unit
      # is exactly what `auto` leaves undecided.
      reading: auto
  - id: rssionly
    type: link-status
    col: 2
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      rssiSource: RSSI
      reading: rssi
]]
    )

    -- A live link whose protocol has no RSSI sensor: values keep arriving while
    -- the indicator reads zero, and no RSSI sensor exists to be resolved.
    local realRssi = radio.fields.RSSI
    radio.rssi = 0
    radio.rssiAbsent = true
    radio.fields.RSSI = nil
    radioMock.indexFields()

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    settle(context, 60)

    local link = entryById(context, "link").instance
    assertEqual(link.primaryName, "quality", "auto must fall back to the source the protocol actually has")
    assertEqual(link.text, "96", "a live reading was discarded as a dead link")
    assertEqual(link.stateName, "normal")
    assertEqual(link.badge.properties.text, "")

    -- A panel configured for RSSI alone on such a protocol has nothing to show,
    -- and must say the sensor is missing rather than report zero or claim the
    -- link is down.
    local rssiOnly = entryById(context, "rssionly").instance
    assertEqual(rssiOnly.stateName, "unavailable")
    assertEqual(rssiOnly.badge.properties.text, "N/A")
    assertEqual(rssiOnly.text, "N/A", "an absent sensor was reported as zero")

    radio.fields.RSSI = realRssi
    resetRadio()
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testMetricSupportingDetail()
    resetRadio()
    local widgetPath = makeWidget(
        "metric-detail",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: altitude
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          label: ALT
          rangeMin: 0
          rangeMax: 400
        - source: Alt+
          label: MAX
        - source: VSpd
          label: VS
      accent: green
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    settle(context)

    local altitude = entryById(context, "altitude").instance
    assertEqual(altitude.detailFeed.name, "Alt+", "the metric lost its maximum source")
    assertEqual(altitude.range.properties.text, "MAX 180 m")
    assertEqual(altitude.secondary.properties.text, "VS 2.5 m/s")
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

testTelemetryDrivesPanels()
testOnlyReferencedSourcesArePolled()
testTelemetryPanels()
testCompassPointsWhereTheFixIs()
testCompassShedsWhenThePanelNarrows()
testTelemetryDegrades()
testCellSourceShapes()
testRefreshSeesEverythingItDraws()
testNavigationSeesItsSensorAppear()
testProtocolWithoutRssi()
testMetricSupportingDetail()
