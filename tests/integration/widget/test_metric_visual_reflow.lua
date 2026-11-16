-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local radio = fixture.radio
local resetRadio = fixture.reset
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local makeWidget = fixture.makeWidget
local DEFAULT_OPTIONS = { Layout = "main", Theme = "modern-dark" }
local entryById = fixture.entryById
local pump = fixture.pump
local settle = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end
local geometry = assert(loadfile(root .. "/tests/support/widget_geometry.lua"))(fixture)
local arcSquareOf = geometry.arcSquareOf

local reflowDone = fixture.reflowDone

local boundsOf = fixture.boundsOf

local hostTurn = fixture.hostTurn

local function testRadialReflow()
    local widgetPath = makeWidget(
        "radial",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: dial
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          label: Dial
          rangeMin: 0
          rangeMax: 100
      visual: radial
]]
    )

    local zone = { x = 0, y = 0, w = 480, h = 272 }
    local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
    local dial = entryById(context, "dial")
    assert(dial.instance.radial, "radial visualization was not created")

    -- EdgeTX positions an arc by its centre: LvglWidgetArc::build calls setPos,
    -- and LvglWidgetRoundObject::setPos stores x - radius. A test that read x
    -- as a corner would pass while the arc was drawn a radius off the panel.
    --
    -- Measured from the object the mock actually drew rather than recomputed
    -- from what Lua passed. Recomputing is how the widget came to carry an
    -- `arcBounds` helper that no panel called and that put the outer edge
    -- half a stroke too far out: the only thing checking it was a test that
    -- used the same arithmetic.
    local arc = dial.instance.radial.arc
    local bounds = boundsOf(dial)
    local firstRadius = arc.properties.radius
    local box = arcSquareOf(arc)
    assert(box.x >= 0 and box.y >= 0, "radial was drawn off its own panel")
    assert(box.x + box.w <= bounds.w, "radial overflows its panel")
    assert(box.y + box.h <= bounds.h, "radial overflows its panel")

    -- The value must not sit underneath the arc.
    local value = dial.instance.value.properties
    assert(value.x + value.w <= box.x, "value overlaps the radial")

    zone.w = 240
    zone.h = 160
    hostTurn(context)

    local resized = dial.instance.radial.arc
    local newBounds = boundsOf(dial)
    local newBox = arcSquareOf(resized)
    assert(resized.properties.radius < firstRadius, "radial did not shrink with the panel")
    assert(newBox.x >= 0 and newBox.y >= 0, "radial left its panel after reflow")
    assert(newBox.x + newBox.w <= newBounds.w, "radial overflowed after reflow")
    assert(newBox.y + newBox.h <= newBounds.h, "radial overflowed after reflow")
end

local function testRadialDoesNotDrift()
    resetRadio()
    local widgetPath = makeWidget(
        "radial-drift",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: dial
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 1
    config:
      metrics:
        - source: Curr
          label: Current
          rangeMin: 0
          rangeMax: 120
      visual: radial
]]
    )

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, DEFAULT_OPTIONS, widgetPath)
    pump(context, 60)

    local dial = entryById(context, "dial").instance
    -- The precondition, and it is the whole reason this moved: an arc nobody
    -- draws cannot drift.
    assertEqual(dial.showVisual, true, "the panel shed its dial, so a drift test proves nothing")
    assertEqual(dial.radial.arc.hidden, false, "the dial was not on screen")
    -- 10 of 0..120 is a small part of a 270 degree sweep, drawn from 135.
    assertEqual(dial.radial.arc.properties.endAngle, 135 + 23)

    local arc = dial.radial.arc
    local expectedX = dial.radial.centreX - dial.radial.radius
    local expectedY = dial.radial.centreY - dial.radial.radius
    assertEqual(arc.round.drawn.x, expectedX, "an arc was not built at its centre")
    assertEqual(arc.round.drawn.y, expectedY, "an arc was not built at its centre")
    for reading = 1, 8 do
        radio.values[103] = 10 + reading * 5
        pump(context, 12)
    end
    -- The dial has to have actually moved, and the sweep is pinned rather than
    -- merely required to differ: 50 of 0 to 120 is 113 degrees of 270, drawn
    -- from 135. A sweep that changed for the wrong reason would satisfy "it is
    -- no longer 158".
    assertEqual(arc.properties.endAngle, 248, "the dial never moved, so a drift test proves nothing")
    assertEqual(arc.round.drawn.x, expectedX, "the dial drifted horizontally")
    assertEqual(arc.round.drawn.y, expectedY, "the dial drifted vertically")
    resetRadio()
end

local function testMetricReconcilesOnResize()
    -- **A live source, because this test is about width and not about having a
    -- reading at all.** It named no source until a unit stopped being drawn
    -- beside an absent value, and every assertion below then described a panel
    -- printing `-- V`: the unit it asserted survived a height loss was a unit
    -- with no number to qualify. The shed-and-restore behaviour it exists to
    -- pin is unchanged, because `metric` sheds on the widest form it can print
    -- rather than on the one on screen; what changes is that the panel now has
    -- one.
    local widgetPath = makeWidget(
        "reconcile",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: big
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: S1
          label: Pack
          unit: V
          precision: 1
          rangeMin: 18
          rangeMax: 25
        - source: S2
          label: AUXILIARY VOLTAGE
          unit: V
          precision: 1
      visual: bar
]]
    )

    local zone = { x = 0, y = 0, w = 480, h = 272 }
    local context = createLoaded(zone, DEFAULT_OPTIONS, widgetPath)
    -- Let the telemetry service resolve and deliver, so the panel is drawing a
    -- number before anything here asks what happens to the unit beside it.
    pump(context, 20)
    local instance = entryById(context, "big").instance

    assertEqual(instance.text, "3.0", "this test needs a panel with a reading, not a sentinel")
    assert(instance.unit, "unit was never created")
    assert(instance.range, "range was never created")
    assertEqual(instance.unit.hidden, false)
    assertEqual(instance.range.hidden, false)

    --- Drain a batched reflow.
    local function settle()
        local passes = 0
        repeat
            definition.refresh(context)
            passes = passes + 1
            assert(passes < 100, "reflow never finished")
        until reflowDone(context)
    end

    -- Shrink until the panel can no longer afford the optional rows.
    zone.w = 320
    zone.h = 140
    settle()

    local bounds = boundsOf(entryById(context, "big"))
    assertEqual(instance.range.hidden, true, "shed range was left visible")

    -- The unit survives this, and that is the change rather than a slip. It
    -- rides beside the reading now instead of taking a row beneath it, so a
    -- panel losing height loses rows and keeps the unit. What it costs is
    -- width, and width is what takes it away.
    assertEqual(
        instance.unit.hidden,
        false,
        "the unit was shed by a panel that only lost height, which it no longer" .. " pays for"
    )

    for _, object in ipairs({ instance.label, instance.value, instance.badge }) do
        assert(object.properties.y < bounds.h, "visible content escaped the panel")
    end

    -- Narrow enough that the number and its unit no longer fit side by side.
    -- Measured rather than estimated, now that the pair is: the reading's
    -- column comes out at 36 px, a SMLSIZE `25.0` is 25 of those and the same
    -- reading with a TINSIZE `V` beside it is 32. The number keeps its size;
    -- the unit goes, because the heading names what is being measured and the
    -- digits are the reading.
    --
    -- It used to be 180, which the estimate called too narrow and a radio does
    -- not: measured, the pair still fits at 120. And then 100, for the same
    -- reason once more -- fitting itself now measures, so the reading no
    -- longer steps down at a width where the font had room all along, and the
    -- pair survives further than it did.
    zone.w = 90
    zone.h = 272
    settle()
    assertEqual(instance.unit.hidden, true, "a panel too narrow for the pair kept its unit")
    assert(instance.value.lines == 1, "the reading wrapped, so the unit was shed and bought nothing")

    -- Growing again must restore what was shed rather than leave it hidden.
    zone.w = 480
    zone.h = 272
    settle()
    assertEqual(instance.unit.hidden, false, "unit was not restored")
    assertEqual(instance.range.hidden, false, "range was not restored")
end

testRadialReflow()
testRadialDoesNotDrift()
testMetricReconcilesOnResize()
