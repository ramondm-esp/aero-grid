-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local WidgetFixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))()

local function testRepresentativeDashboardBuilds()
    local fixture = WidgetFixture.new()
    local context = fixture.createLoaded()

    assertions.assertEqual(context.stage, nil, "staged loading should finish")
    assert(#context.panels > 0, "builder did not create any dashboard panels")
    assertions.assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))

    for _, entry in ipairs(context.panels) do
        assert(entry.container, "panel is missing its host container")
        assert(entry.instance, "panel is missing its instance")
        local bounds = entry.container.properties
        assert(bounds.w > 0 and bounds.h > 0, "builder created an empty panel")
    end
    fixture.assertNoOverlap(context)
end

local function testThemeFallback()
    local fixture = WidgetFixture.new()
    local context = fixture.createLoaded(nil, { Layout = "main", Theme = "not-a-theme" })
    assertions.assertEqual(context.theme.mode, "modern-dark")
end

local function testMissingWidgetPathFailsExplicitly()
    local fixture = WidgetFixture.new()
    local context = fixture.createLoaded(nil, { Layout = "main", Theme = "modern-dark" }, "/path/does/not/exist/")
    assert(#context.errors > 0, "missing widget modules should be reported as errors")
    assertions.assertEqual(#context.panels, 0)
end

local function run()
    testRepresentativeDashboardBuilds()
    testThemeFallback()
    testMissingWidgetPathFailsExplicitly()
end

run()
