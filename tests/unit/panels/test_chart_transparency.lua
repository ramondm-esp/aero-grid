-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local chart = fixture.module("panels/chart.lua")
assert(loadfile(root .. "/tests/support/chart_turns.lua"))().install(chart)
local view = assert(loadfile(root .. "/tests/support/chart_assertions.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local host = fixture.createLoaded(nil, { Layout = "Empty", Theme = 3 })
local services = host.dashboardLoader.buildServices(host, { col = 0, row = 0, colSpan = 2, rowSpan = 2 })
local session = {
    configured = true,
    available = true,
    recording = true,
    elapsed = 1500,
    flightFirst = 1,
    flightLast = 1,
    flightRevision = 1,
    flightActive = false,
    resumeFirst = 1,
    resumeLast = 2,
    resumeRevision = 1,
}
local breaks = { 300, 700 }
local history = { FLIGHT_CAPACITY = 64 }
function history:session()
    return session
end
function history:subscribe()
    return { available = false, revision = 0, plotRevision = 0, count = 0 }
end
function history:flight(_, index)
    if index == 1 and session.flightLast == 1 then
        return 100, session.flightActive and session.elapsed or 1200
    end
end
function history:recordingBreak(_, index)
    return breaks[index]
end
services.history = history
local panel = chart.create(
    host.page,
    { x = 0, y = 0, w = 238, h = 134 },
    { duration = 1, metrics = { { source = "V" } } },
    services
)
local function settle()
    for _ = 1, 2000 do
        local _, pending = chart.refresh(panel)
        if
            not pending
            and view.finished(panel)
            and panel.flightDrawnRevision == session.flightRevision
            and panel.flightDrawnResumeRevision == session.resumeRevision
            and panel.flightDrawnElapsed == (session.flightActive and session.elapsed or 0)
        then
            return
        end
    end
    error("translucent chart did not finish")
end
local function assertSurfaces(opacity)
    equal(panel.panel.background.properties.opacity, opacity)
    equal(panel.durationBackground.properties.opacity, opacity < 255 and 0 or 255)
    if opacity < 255 then
        assert(panel.area.y + panel.area.h < panel.durationTop, "plot must leave the duration text unobstructed")
    end
    equal(panel.duration.properties.opacity, nil, "duration text must stay opaque")
    local band = assert(panel.flightBands[1])
    equal(band.kind, "rectangle", "each flight must use a single continuous rectangle")
    assert(not band.hidden)
    equal(band.properties.opacity, 24, "flight shading must stay subtle at either panel opacity")
    local finish = session.flightActive and session.elapsed or 1200
    local right =
        math.min(panel.area.x + panel.area.w, panel.area.x + math.floor(panel.axis.map:pixel(finish, true) + 0.5))
    equal(band.properties.x + band.properties.w, right, "flight shading must include recording interruptions")
    equal(#panel.flightRoot.children, 1, "recording breaks must not allocate extra flight objects")
    equal(panel.gapRoot, nil, "recording breaks must not allocate an erasing layer")
    for _, at in ipairs(breaks) do
        local left = panel.area.x + panel.axis.map:pixel(at, true)
        local gapRight = panel.area.x + panel.axis.map:pixel(at)
        assert(gapRight > left, "recording breaks must still separate telemetry")
        assert(band.properties.x < left and band.properties.x + band.properties.w > gapRight)
    end
end
settle()
assertSurfaces(204)
session.flightActive, session.flightRevision = true, 2
settle()
local width = panel.flightBands[1].properties.w
session.elapsed = 2000
settle()
assert(panel.flightBands[1].properties.w > width, "open flight shading must still grow")
assertSurfaces(204)
breaks[3], session.resumeLast, session.resumeRevision = 900, 3, 2
settle()
assertSurfaces(204)
chart.update(panel, { x = 0, y = 0, w = 480, h = 272 })
settle()
assertSurfaces(204)
host.theme.panelOpacity = 255
chart.destroy(panel)
panel = chart.create(
    host.page,
    { x = 0, y = 0, w = 238, h = 134 },
    { duration = 1, metrics = { { source = "V" } } },
    services
)
settle()
assertSurfaces(255)
session.flightLast, session.flightActive, session.flightRevision = 0, false, 3
for _ = 1, 100 do
    local _, pending = chart.resetSession(panel)
    if not pending then
        break
    end
end
assert(panel.flightBands[1].hidden, "reset must retire the continuous flight band")
