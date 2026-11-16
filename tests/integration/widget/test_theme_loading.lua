-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(..., "repository root argument is required")
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local assertEqual = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local makeWidget = fixture.makeWidget
local addTheme = fixture.addTheme
local themeModule = fixture.module("lib/theme.lua")
local pump = fixture.pump
local definition = fixture.module("main.lua")
local function createLoaded(zone, options, path)
    return fixture.createLoaded(zone, options, path, definition)
end
assert(
    themeModule.setCatalog(
        assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, fixture.module("lib/yaml.lua"))
    )
)

local function testLayoutSelectsLightTheme()
    local widgetPath = makeWidget(
        "light-theme",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: only
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          label: Light
]]
    )

    local context = createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "main", Theme = "modern-light" },
        widgetPath
    )

    assertEqual(context.theme.mode, "modern-light")
    assertEqual(#context.panels, 1)

    local tokens = context.theme.rgb
    assertEqual(tokens.canvas, 0xE5EAF0)
    assertEqual(tokens.surface, 0xFFFFFF)
    assert(themeModule.contrast(tokens.surface, tokens.text) >= 4.5)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testCustomTheme()
    local widgetPath = makeWidget(
        "custom-theme",
        [[
version: 1
grid:
  columns: 4
  rows: 4
panels:
  - id: only
    type: metric
    col: 0
    row: 0
    colSpan: 2
    rowSpan: 2
    config:
      metrics:
        - source: Alt
          label: Custom
]]
    )
    addTheme(widgetPath, "custom", {
        accent = "green",
        colors = { canvas = 0x000000, surface = 0x101010, border = 0xFF00FF },
    })

    local context = createLoaded({ x = 0, y = 0, w = 480, h = 272 }, { Layout = "main", Theme = "custom" }, widgetPath)

    assertEqual(context.theme.mode, "custom")
    assertEqual(context.theme.rgb.canvas, 0x000000)
    -- 0x101010 on a black canvas measures 1.11, and with no resting outline the
    -- fill is the only thing that makes a panel a panel, so the legibility pass
    -- lifts it exactly as it lifts a surface that would swallow text.
    assert(
        themeModule.contrast(context.theme.rgb.canvas, context.theme.rgb.surface) >= 1.30,
        "a named theme surface was left flat against its own canvas"
    )
    assertEqual(context.theme.accent, "green")
    assertEqual(context.theme.rgb.border, 0xFF00FF, "the full theme palette did not apply its border token")
    assert(
        themeModule.contrast(context.theme.rgb.surface, context.theme.rgb.border) >= 1.25,
        "the border vanished into the surface"
    )

    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testChangingToNewTheme()
    local widgetPath = makeWidget("theme-option-change")
    addTheme(widgetPath, "new-theme", {
        correctForContrast = false,
        colors = { canvas = 0x102030 },
    })
    local context = createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "Default", Theme = "modern-dark" },
        widgetPath
    )
    definition.update(context, { Layout = "Default", Theme = "new-theme" })
    pump(context, 100)
    assertEqual(context.theme.mode, "new-theme", "option changes load a previously unused theme")
    assertEqual(context.theme.rgb.canvas, 0x102030)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    definition.update(context, { Layout = "Default", Theme = "modern-light" })
    pump(context, 100)
    assertEqual(context.theme.mode, "modern-light", "theme changes also load the other built-in palette")
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

local function testUserThemeOverridesShippedTheme()
    local widgetPath = makeWidget("theme-override")
    addTheme(widgetPath, "modern-dark", {
        correctForContrast = false,
        colors = { canvas = 0x102030 },
    })
    local context = createLoaded(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "Default", Theme = "modern-dark" },
        widgetPath
    )
    assertEqual(context.theme.mode, "modern-dark")
    assertEqual(context.theme.rgb.canvas, 0x102030)
    assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
end

testLayoutSelectsLightTheme()
testCustomTheme()
testChangingToNewTheme()
testUserThemeOverridesShippedTheme()
