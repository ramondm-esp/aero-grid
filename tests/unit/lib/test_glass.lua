-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local loadModule = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local edgetx = assert(loadfile(root .. "/tests/support/edgetx.lua"))()
edgetx.constants()
lcd = {
    RGB = function(value)
        return value
    end,
}
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local yaml = loadModule("lib/yaml.lua")
local builder = loadModule("lib/theme.lua")
assert(builder.setCatalog(assert(loadfile(root .. "/tests/support/theme_catalog.lua"))()(root, yaml)))
local glass = loadModule("lib/glass.lua")
local dark, light = builder.build("modern-dark"), builder.build("modern-light")
local function blend(surface, background, opacity)
    local result = 0
    for _, shift in ipairs({ 65536, 256, 1 }) do
        local foreground = math.floor(surface / shift) % 256
        local behind = math.floor(background / shift) % 256
        result = result + math.floor((foreground * opacity + behind * (255 - opacity)) / 255 + 0.5) * shift
    end
    return result
end
for _, resolved in ipairs({ dark, light }) do
    for _, background in ipairs({ 0, 0x444444, 0x888888, 0xCCCCCC, 0xFFFFFF }) do
        local opacity = builder.glassOpacity(resolved, background)
        assert(opacity >= 128 and opacity <= 255)
        local function readable(alpha)
            local mixed = blend(resolved.rgb.surface, background, alpha)
            for name, minimum in pairs({ text = 4.5, textMuted = 3, textFaint = 1.8 }) do
                local target = math.min(minimum, builder.contrast(resolved.rgb.surface, resolved.rgb[name]))
                if builder.contrast(mixed, resolved.rgb[name]) + 0.00001 < target then
                    return false
                end
            end
            return true
        end
        assert(readable(opacity), "automatic opacity must meet text contrast targets")
        assert(
            opacity == 128 or not readable(opacity - 1),
            "automatic opacity must not hide more background than needed"
        )
    end
end
local files, images, opened, folders = {}, {}, {}, { "readme.txt", "Broken", "Ocean" }
local calls = { decode = 0, resize = 0, mask = 0, close = 0 }
local env = {
    width = 480,
    height = 272,
    stat = function(path)
        if files[path] then
            return { size = #files[path] }
        end
        if images[path] then
            return { size = 100, sec = images[path].modified or 1 }
        end
    end,
    dir = function(path)
        equal(path, "/THEMES")
        local index = 0
        return function()
            index = index + 1
            return folders[index]
        end
    end,
    io = {
        open = function(path)
            assert(files[path])
            opened[path] = true
            return { path = path }
        end,
        read = function(handle, size)
            equal(size, #files[handle.path])
            return files[handle.path]
        end,
        close = function(handle)
            assert(opened[handle.path])
            opened[handle.path] = nil
            calls.close = calls.close + 1
        end,
    },
    bitmap = {
        open = function(path)
            calls.decode = calls.decode + 1
            return assert(images[path])
        end,
        getSize = function(image)
            return image.invalid and 0 or (image.width or 480), image.invalid and 0 or (image.height or 272)
        end,
        resize = function(image, width, height)
            calls.resize = calls.resize + 1
            equal(width, 16)
            equal(height, 16)
            return image
        end,
        toMask = function(image)
            calls.mask = calls.mask + 1
            return image.mask
        end,
    },
}
local function mask(brightness)
    return string.char(16, 0, 16, 0) .. string.rep(string.char(255 - brightness), 256)
end
local worst = 0
local function analyze(resolved, cache)
    local work = glass.new(builder, resolved or dark, yaml, cache or {}, env)
    for _ = 1, 100 do
        local counted = 0
        debug.sethook(function()
            counted = counted + 1
        end, "", 1)
        local done = work:step()
        debug.sethook()
        worst = math.max(worst, counted)
        assert(next(opened) == nil, "metadata files must close in the same step")
        if done then
            return work
        end
    end
    error("background analysis did not finish")
end

files["/RADIO/radio.yml"] = 'selectedTheme: "Ocean # Blue"\n'
files["/THEMES/Broken/theme.yml"] = "summary:\n  name: [invalid]\n"
files["/THEMES/Ocean/theme.yml"] = 'summary:\n  name: "Ocean # Blue"\n'
images["/THEMES/Ocean/background.png"] = { mask = mask(255) }
local white = analyze()
equal(white.average, 0xFFFFFF)
equal(white.opacity, builder.glassOpacity(dark, 0xFFFFFF))
equal(white.reason, nil)
equal(white.filename, "/THEMES/Ocean/background.png")
images["/THEMES/Ocean/background.png"].mask = string.char(16, 0, 16, 0)
    .. string.rep(string.char(255), 3 * 16)
    .. string.rep(string.char(0), 9 * 16)
    .. string.rep(string.char(255), 4 * 16)
equal(analyze().average, 0xFFFFFF, "aspect-preserving resize padding must not darken the average")

images["/THEMES/Ocean/background_480x272.png"] = { mask = mask(0) }
local black = analyze()
equal(black.average, 0)
equal(black.filename, "/THEMES/Ocean/background_480x272.png", "screen-specific backgrounds take precedence")
assert(white.opacity > black.opacity, "dark panels on bright images need more opacity")
assert(builder.glassOpacity(light, 0) > builder.glassOpacity(light, 0xFFFFFF))

images["/THEMES/Ocean/background_480x272.png"].mask = string.char(16, 0, 16, 0) .. string.rep(string.char(0, 255), 128)
local cache = {}
local mixed = analyze(dark, cache)
equal(mixed.average, 0x808080, "average must include all samples, not a single pixel")
local decodes = calls.decode
equal(analyze(light, cache).opacity, builder.glassOpacity(light, 0x808080))
equal(calls.decode, decodes, "palette changes reuse the sampled image")
images["/THEMES/Ocean/background_480x272.png"].modified = 2
analyze(dark, cache)
equal(calls.decode, decodes + 1, "changed background files must be sampled again")

images["/THEMES/Ocean/background_480x272.png"].invalid = true
local invalid = analyze()
equal(invalid.opacity, 204)
assert(invalid.reason)
images["/THEMES/Ocean/background_480x272.png"].invalid = nil
images["/THEMES/Ocean/background_480x272.png"].width = 1
images["/THEMES/Ocean/background_480x272.png"].height = 10000
equal(analyze().opacity, 204, "images too narrow to resize must use the fallback")
images["/THEMES/Ocean/background_480x272.png"].width = nil
images["/THEMES/Ocean/background_480x272.png"].height = nil
images["/THEMES/Ocean/background_480x272.png"].mask = "bad"
equal(analyze().opacity, 204, "invalid samples must use the fallback")

files["/RADIO/radio.yml"] = "battWarn: 66\n"
images["/THEMES/EdgeTX/background.png"] = { mask = mask(136) }
local default = analyze()
equal(default.filename, "/THEMES/EdgeTX/background.png")
equal(default.average, 0x888888)
images["/THEMES/EdgeTX/background.png"] = nil
equal(analyze().opacity, 204, "firmware-only backgrounds must use the fallback")
files["/RADIO/radio.yml"] = "selectedTheme: Missing\n"
equal(analyze().opacity, 204)
files["/RADIO/radio.yml"] = nil
equal(analyze().opacity, 204)
local bitmapApi = env.bitmap
env.bitmap = nil
equal(analyze().opacity, 204, "firmware without bitmap analysis must use the fallback")
env.bitmap = bitmapApi
assert(worst < 12000, "background analysis must stay within a loader callback")
print("Glass image averaging and automatic opacity passed; worst step " .. worst .. " Lua instructions")
