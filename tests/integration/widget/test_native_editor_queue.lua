-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local noGrant = assert(loadfile(root .. "/tests/support/no_grant.lua"))()
fixture.reset()
getSourceIndex = function(name)
    local info = getFieldInfo(name)
    return info and info.id or 0
end
getSourceName = function(value)
    return getSourceIndex("GPS") == value and "GPS" or ""
end
fixture.lvglMock.setFullScreen(true)
EVT_VIRTUAL_ENTER = 9601
local definition = fixture.module("main.lua")
local context = fixture.createLoaded(nil, { Layout = "Empty", Theme = "modern-dark" })
fixture.pump(context, 30)
local maxRowsPerCallback = 0
local function untilState(predicate)
    for callback = 1, 200 do
        if predicate() then
            return callback - 1
        end
        local state = context.editorUi
        local view = state and state.drawerView
        local rows = view and #view.controls or 0
        definition.refresh(context)
        state = context.editorUi
        local nextView = state and state.drawerView
        if nextView and nextView == view then
            maxRowsPerCallback = math.max(maxRowsPerCallback, #view.controls - rows)
        elseif nextView and nextView.build then
            assert(#nextView.controls == 0, "opening or replacing a native dialog must retain its callback boundary")
        end
    end
    error("native editor work did not complete")
end
definition.refresh(context, EVT_VIRTUAL_ENTER)
untilState(function()
    return context.editorUi and not context.editorUi.buildStage
end)
definition.refresh(context, EVT_VIRTUAL_ENTER)
untilState(function()
    return fixture.lvglMock.menu() ~= nil
end)
local state, menu = context.editorUi, fixture.lvglMock.menu()
local index
for position, item in ipairs(state.handlers.editor.CATALOG) do
    if item.type == "navigation" then
        index = position
    end
end
menu.set(assert(index))
assert(state.nativeInput and not state.drawerPending and #state.session.draft.panels == 0)
definition.background(context)
assert(state.nativeInput and #state.session.draft.panels == 0, "hidden callbacks cannot apply native editor commands")
local openingCallbacks = untilState(function()
    return #state.session.draft.panels == 1 and not state.drawerBuild
end)
assert(not state.nativeInput and state.mode == "configure")
assert(openingCallbacks <= 5, "Navigation opening must not regress to one callback per row")
assert(
    maxRowsPerCallback > 1,
    "panel construction must batch rows like Model settings instead of yielding after each row"
)
local function nativeCalls()
    local calls = {}
    for _, row in ipairs(state.drawerControls) do
        for _, object in ipairs({ row.row, row.object, row.errorLabel }) do
            calls[object] = object.writes + object.visibilityCalls
        end
    end
    return calls
end
local function assertUnchanged(calls, edited)
    for object, before in pairs(calls) do
        if object ~= edited then
            assert(object.writes + object.visibilityCalls == before, "an edit must not refresh unchanged drawer rows")
        end
    end
end
local function assertActive()
    for _, row in ipairs(state.drawerControls) do
        if row.object.properties.active then
            assert(row.object.properties.active(), "queued value edits must not disable every drawer control")
        end
    end
end
local function settleEdit()
    untilState(function()
        assertActive()
        return not state.nativeInput and not state.drawerPending
    end)
end
local numeric
for _, row in ipairs(state.drawerControls) do
    if row.kind == "numberEdit" then
        numeric = row
        break
    end
end
assert(numeric)
for _ = 1, 3 do
    local calls = nativeCalls()
    local nextValue = numeric.object.properties.get() + 1
    numeric.object.properties.set(nextValue)
    settleEdit()
    assert(numeric.object.properties.get() == nextValue, "consecutive numeric edits must retain their values")
    assert(state.session.draft.panels[1].config[numeric.field.key] == nextValue)
    assertUnchanged(calls)
end
for _, edit in ipairs({
    { key = "accent", value = 2, expected = "green" },
    { key = "showCoordinates", value = 1, expected = true },
    { key = "label", value = "Edited navigation", expected = "Edited navigation" },
}) do
    local control
    for _, row in ipairs(state.drawerControls) do
        if row.field.key == edit.key then
            control = row.object
            break
        end
    end
    assert(control)
    local calls = nativeCalls()
    control.properties.set(edit.value)
    settleEdit()
    assert(state.session.draft.panels[1].config[edit.key] == edit.expected)
    assertUnchanged(calls, control)
end
local source
for _, row in ipairs(state.drawerControls) do
    if row.kind == "source" then
        source = row.object
        break
    end
end
assert(source)
local originalFieldInfo, lookups = getFieldInfo, 0
getFieldInfo = function(value)
    lookups = lookups + 1
    return originalFieldInfo(value)
end
local value = getSourceIndex("GPS")
local before = lookups
local sourceCalls = nativeCalls()
source.properties.set(value)
assert(lookups == before and state.nativeInput, "native setters cannot resolve sources before a grant")
assertActive()
source.properties.get()
assert(lookups == before, "native getters return cached values")
noGrant(context, fixture.lvglMock.objects, function()
    definition.refresh(context)
    definition.background(context)
    assert(state.nativeInput and lookups == before, "accepted source edits must wait for a grant")
end)
settleEdit()
assert(lookups > before, "source resolution must run in a granted editor task")
assertUnchanged(sourceCalls)
getFieldInfo = originalFieldInfo
local toggle
for _, row in ipairs(state.drawerControls) do
    if row.field.key == "showTape" then
        toggle = row
    end
end
assert(toggle)
local properties = toggle.object.properties
local toggleCalls = nativeCalls()
assert(properties.get() == 0)
properties.set(1)
assert(state.nativeInput and properties.get() == 1, "panel toggles must acknowledge accepted input immediately")
properties.set(0)
assert(properties.get() == 1, "blocked repeated input must not bounce the native toggle")
untilState(function()
    return not state.nativeInput and not state.drawerPending
end)
assert(state.session.draft.panels[1].config.showTape and properties.get() == 1)
for _, row in ipairs(state.drawerControls) do
    assert(row.row.hidden == (row.field.key == "bearingFormat"), "toggle edits must still update dependent visibility")
    if row.field.key == "showTape" then
        assert(row.row.writes + row.row.visibilityCalls == toggleCalls[row.row])
    end
end
local steadyToggleCalls = nativeCalls()
properties.set(1)
untilState(function()
    return not state.nativeInput and not state.drawerPending
end)
assertUnchanged(steadyToggleCalls)
local write, log = state.handlers.editor.setValue, state.handlers.logError
local failure
state.handlers.editor.setValue = function()
    return false, "rejected toggle"
end
state.handlers.logError = function(_, message)
    failure = message
end
properties.set(0)
assert(properties.get() == 0 and state.nativeInput)
untilState(function()
    return not state.nativeInput and not state.drawerPending
end)
assert(failure == "rejected toggle" and toggle.errorLabel.properties.text == failure)
assert(properties.get() == 1, "a rejected panel edit must restore the committed toggle value")
state.handlers.editor.setValue, state.handlers.logError = write, log
local setter = source.properties.set
context.editorUiModule.close(context, true)
setter(value)
assert(not state.nativeInput, "callbacks from a closed editor cannot retain or apply commands")
