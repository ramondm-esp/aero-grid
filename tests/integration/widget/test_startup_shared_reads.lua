-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local hostIo = io
local fixture = assert(loadfile(root .. "/tests/support/widget_fixture.lua"))(root).new()
local path = root .. "/build/test-widget-fixture/"
local filename = model.getInfo().filename
local yaml = fixture.module("lib/yaml.lua")
local modelPath = assert(fixture.module("lib/model_settings_store.lua").path(path, filename))
local themePath = path .. "themes/modern-dark.yml"
local originalIo = io
local reads = {}
io = {
    open = function(name, mode)
        if mode == "r" then
            reads[name] = (reads[name] or 0) + 1
        end
        return originalIo.open(name, mode)
    end,
    read = originalIo.read,
    write = originalIo.write,
    close = originalIo.close,
}

local function write(name, content)
    local file = assert(hostIo.open(name, "w"))
    file:write(content)
    file:close()
end
local function settings(name, revision)
    local location = assert(fixture.module("lib/model_settings_store.lua").path(path, name))
    write(
        location,
        assert(yaml.serialize({
            version = 1,
            revision = revision or 0,
            modelFilename = name,
            flightCount = 0,
            armed = "SFv",
            flight = fixture.module("lib/flight_config.lua").resolve({}),
        }))
    )
    return location
end
os.execute("mkdir -p '" .. path .. "AEROGRID/models'")
settings(filename)
local file = assert(hostIo.open(themePath, "r"))
local originalTheme = file:read("*a")
file:close()

fixture.reset()
local definition = fixture.module("main.lua")
reads = {}
local function create(theme)
    return definition.create(
        { x = 0, y = 0, w = 480, h = 272 },
        { Layout = "Default", Theme = theme or "modern-dark" },
        path
    )
end
local function pump(first, second)
    for _ = 1, 200 do
        fixture.tick(5)
        definition.refresh(first)
        if second then
            definition.background(second)
        end
        for _, context in ipairs(second and { first, second } or { first }) do
            assert(not context.runtimeFailed, table.concat(context.errors, "; "))
        end
        if
            not first.initializing
            and not first.stage
            and not first.optionsRequest
            and not first.reloadState
            and (not second or not second.initializing and not second.stage and not second.reloadState)
        then
            return
        end
    end
    error("shared startup reads did not settle")
end

local first, second = create(), create("modern-light")
-- Both have already requested model-settings staging before either document is read.
definition.refresh(first)
definition.background(second)
assert(first.stage == "model-settings" and second.stage == "model-settings")
pump(first, second)
assert(#first.errors == 0 and #second.errors == 0)
assert(reads[modelPath] == 1, "the same model document must be read only once during startup")
assert(reads[themePath] == 1, "the shared dark theme must be read and parsed only once")
assert(reads[path .. "themes/modern-light.yml"] == 1, "different selected themes still need their own definition")
assert(first.theme.label == "Modern Dark" and second.theme.label == "Modern Light")
assert(first.flightFactory.startupThemes == nil and not first.themeCache and not second.themeCache)

-- A layout reload must pick up theme edits instead of reusing the startup snapshot.
local changedTheme, replacements = string.gsub(originalTheme, "label: Modern Dark", "label: Changed Dark")
assert(replacements == 1)
write(themePath, changedTheme)
definition.update(first, { Layout = "Empty", Theme = "modern-dark" })
pump(first, second)
assert(reads[themePath] == 2 and first.theme.label == "Changed Dark")
assert(reads[modelPath] == 1, "a layout reload reuses the already-loaded model document")
local later = create()
pump(later)
assert(reads[themePath] == 3 and later.theme.label == "Changed Dark", "later widgets must read current themes")

-- The broker's loaded document must not suppress a different model's preload.
local originalFilename = fixture.radio.modelFilename
fixture.radio.modelFilename = "other-startup-model.yml"
local otherPath = settings("other-startup-model.yml", 7)
local other = create()
definition.refresh(other)
assert(other.stage == "model-settings", "shared settings must match the new model identity")
pump(other)
assert(reads[otherPath] == 1)
assert(other.flightFactory.broker.document.revision == 7)
assert(other.flightFactory.broker.document.modelFilename == "other-startup-model.yml")
fixture.radio.modelFilename = originalFilename

-- Failed palette validation must not leave a startup cache for widgets created after repair.
fixture.reset()
write(themePath, originalTheme)
definition = fixture.module("main.lua")
write(themePath, (string.gsub(originalTheme, "accent: cyan", "accent: invalid")))
local broken = create()
pump(broken)
assert(#broken.errors > 0 and not broken.stage)
assert(broken.flightFactory.startupThemes == nil)
write(themePath, originalTheme)
local repaired = create()
pump(repaired)
assert(#repaired.errors == 0 and repaired.theme.label == "Modern Dark")

io = originalIo
