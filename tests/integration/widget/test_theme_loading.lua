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

local function testBackgroundAndPanelOpacity()
    local widgetPath = makeWidget(
        "panel-opacity",
        [[
version: 4
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
          label: Altitude
]]
    )
    local function appearance(context, canvasOpacity, panelOpacity)
        assertEqual(context.canvas.properties.opacity, canvasOpacity, "canvas opacity")
        assertEqual(context.theme.panelOpacity, panelOpacity, "resolved theme opacity")
        local instance = context.panels[1].instance
        local panel = instance.panel
        assertEqual(panel.background.properties.opacity, panelOpacity, "panel fill opacity")
        assertEqual(panel.root.properties.opacity, nil, "panel children must not be faded")
        assertEqual(instance.label.properties.opacity, nil, "heading must not be faded")
        assertEqual(panel.accent.properties.opacity, nil, "status accent must not be faded")
        assertEqual(#context.errors, 0, table.concat(context.errors, "\n"))
    end
    local selected = { Layout = "Default", Theme = "modern-dark", Backdrop = 2, PanelFill = 3 }
    local solid = createLoaded(nil, { Layout = "Default", Theme = "modern-dark", PanelFill = 1 }, widgetPath)
    appearance(solid, 255, 255)
    for _, sentinel in ipairs({ 0, -1, 999, 4294967295 }) do
        local defaults = createLoaded(
            nil,
            { Layout = "Default", Theme = "modern-dark", Backdrop = sentinel, PanelFill = sentinel },
            widgetPath
        )
        appearance(defaults, 255, 204)
        assertEqual(defaults.radioBackground, false, "missing background must select AeroGrid")
    end
    appearance(createLoaded(nil, { Layout = "Default", Theme = "modern-dark" }, widgetPath), 255, 204)
    assertEqual(definition.options[3][3], 1, "new widgets default to AeroGrid")
    assertEqual(definition.options[4][3], 4, "new widgets default to 80%")
    local context = definition.create(fixture.lvglMock.appZone(), selected, widgetPath)
    assertEqual(context.canvas.properties.opacity, 0, "startup must expose the radio background")
    pump(context, 100)
    appearance(context, 0, 217)
    appearance(solid, 255, 255)
    for _, state in ipairs({ "warning", "critical", "active", "normal" }) do
        local presentation = context.themeBuilder.state(context.theme, state)
        context.primitives.stylePanel(context.panels[1].instance.panel, presentation)
        appearance(context, 0, 217)
        assertEqual(
            context.panels[1].instance.panel.background.properties.color,
            presentation.surface or context.theme.color.surface,
            state .. " must retain its surface tint"
        )
    end
    definition.update(context, selected)
    assertEqual(context.optionsRequest, nil, "unchanged appearance must not reload")
    fixture.lvglMock.setFullScreen(true)
    pump(context, 60)
    appearance(context, 0, 217)
    fixture.lvglMock.setFullScreen(false)
    context.zone.w, context.zone.h = 320, 240
    pump(context, 60)
    appearance(context, 0, 217)
    assertEqual(context.canvas.properties.w, 320, "transparent canvas must reflow")

    local oldPage = context.page
    definition.update(context, { Layout = "Default", Theme = "modern-light", Backdrop = 2, PanelFill = 3 })
    pump(context, 100)
    assert(context.page ~= oldPage, "theme reload must replace the page")
    appearance(context, 0, 217)
    definition.update(context, { Layout = "Default", Theme = "modern-light", Backdrop = 1, PanelFill = 3 })
    assert(context.optionsRequest, "background-only changes must be scheduled")
    assertEqual(context.canvas.properties.opacity, 0, "update must not draw outside the scheduler")
    pump(context, 100)
    appearance(context, 255, 217)
    definition.update(context, { Layout = "Default", Theme = "modern-light", Backdrop = 1, PanelFill = 1 })
    assert(context.optionsRequest, "opacity-only changes must be scheduled")
    pump(context, 100)
    appearance(context, 255, 255)
    definition.update(context, { Layout = "Default", Theme = "modern-light", Backdrop = 0, PanelFill = 0 })
    pump(context, 100)
    appearance(context, 255, 204)
    definition.update(context, { Layout = "Default", Theme = "modern-light", Backdrop = -1, PanelFill = -1 })
    assertEqual(context.optionsRequest, nil, "equivalent missing-value sentinels must not keep reloading")
    fixture.lvglMock.setAppMode(false)
    assertEqual(definition.translate("Backdrop"), "Background")
    assertEqual(definition.translate("PanelFill"), "Panel opacity")
end

testLayoutSelectsLightTheme()
testCustomTheme()
testChangingToNewTheme()
testUserThemeOverridesShippedTheme()
testBackgroundAndPanelOpacity()
