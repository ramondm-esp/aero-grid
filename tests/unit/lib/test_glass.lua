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
            return {
                size = images[path].size or 100,
                time = not images[path].noTime
                        and { year = 2026, mon = 11, day = 17, hour = 20, min = 0, sec = images[path].modified or 1 }
                    or nil,
            }
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
local function analyze(cache, persistent)
    local work = glass.new(builder, yaml, cache or {}, persistent, env)
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
equal(white.theme.mode, "modern-light")
equal(white.opacity, builder.glassOpacity(white.theme, 0xFFFFFF))
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
equal(black.theme.mode, "modern-dark")
equal(black.filename, "/THEMES/Ocean/background_480x272.png", "screen-specific backgrounds take precedence")
for _, brightness in ipairs({ 0, 85, 127, 128, 170, 255 }) do
    images["/THEMES/Ocean/background_480x272.png"].mask = mask(brightness)
    local automatic = analyze()
    equal(automatic.theme.mode, brightness < 128 and "modern-dark" or "modern-light")
    equal(automatic.opacity, builder.glassOpacity(automatic.theme, automatic.average))
end

images["/THEMES/Ocean/background_480x272.png"].mask = string.char(16, 0, 16, 0) .. string.rep(string.char(0, 255), 128)
local cache = {}
local mixed = analyze(cache)
equal(mixed.average, 0x808080, "average must include all samples, not a single pixel")
local decodes = calls.decode
equal(analyze(cache).opacity, builder.glassOpacity(light, 0x808080))
equal(calls.decode, decodes, "dashboard reloads reuse the sampled image")
images["/THEMES/Ocean/background_480x272.png"].modified = 2
analyze(cache)
equal(calls.decode, decodes + 1, "changed background files must be sampled again")

images["/THEMES/Ocean/background_480x272.png"].invalid = true
local invalid = analyze()
equal(invalid.opacity, 204)
equal(invalid.theme.mode, "modern-dark")
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
local unsupported = analyze()
equal(unsupported.opacity, 204, "firmware without bitmap analysis must use the fallback")
equal(unsupported.theme.mode, "modern-dark")
env.bitmap = bitmapApi

local cacheModule = loadModule("lib/background_cache.lua")
local writer = loadModule("lib/verified_file.lua")
local disk, operations = assert(loadfile(root .. "/tests/support/memory_files.lua"))()()
local cachePath = "/AEROGRID/cache/backgrounds.yml"
local function persistent()
    return cacheModule.new(yaml, writer, cachePath, operations)
end
files["/RADIO/radio.yml"] = 'selectedTheme: "Ocean # Blue"\n'
local image = images["/THEMES/Ocean/background_480x272.png"]
image.mask, image.modified = mask(136), 10
decodes = calls.decode
local cold = analyze({}, persistent())
equal(cold.average, 0x888888)
equal(cold.cacheReason, nil)
equal(calls.decode, decodes + 1)
assert(disk[cachePath], "sampling must persist brightness outside the widget")
local warm = analyze({}, persistent())
equal(warm.average, cold.average)
equal(calls.decode, decodes + 1, "new widget lifetimes must not decode unchanged images")
local resizes, masks = calls.resize, calls.mask
env.bitmap = nil
equal(analyze({}, persistent()).average, cold.average, "cached brightness must not require bitmap APIs")
equal(calls.resize, resizes)
equal(calls.mask, masks)
env.bitmap = bitmapApi
image.mask, image.modified = mask(85), 11
equal(analyze({}, persistent()).theme.mode, "modern-dark")
equal(calls.decode, decodes + 2, "modification time changes must resample")
image.mask, image.size = mask(170), 101
equal(analyze({}, persistent()).theme.mode, "modern-light")
equal(calls.decode, decodes + 3, "size changes must resample even if the timestamp is preserved")

files["/RADIO/radio.yml"] = "battWarn: 66\n"
images["/THEMES/EdgeTX/background.png"] = { mask = mask(0) }
equal(analyze({}, persistent()).average, 0)
equal(calls.decode, decodes + 4)
files["/RADIO/radio.yml"] = 'selectedTheme: "Ocean # Blue"\n'
equal(analyze({}, persistent()).average, 0xAAAAAA)
equal(calls.decode, decodes + 4, "switching back to a previously sampled image must reuse its stored result")

disk[cachePath] = "broken"
local recovered = analyze({}, persistent())
equal(recovered.average, 0xAAAAAA)
assert(recovered.cacheReason, "corrupt caches must report a diagnostic")
equal(calls.decode, decodes + 5)
equal(analyze({}, persistent()).cacheReason, nil)
equal(calls.decode, decodes + 5, "a repaired cache must be reusable")
local inMemory = {}
analyze(inMemory, persistent())
disk[cachePath] = nil
equal(analyze(inMemory, persistent()).average, 0xAAAAAA)
assert(disk[cachePath], "deleting the disk cache must recreate it using the in-memory sample")
equal(calls.decode, decodes + 5, "recreating a missing cache must not resample a known image")

image.modified = 12
operations.inject("write")
local failed = analyze({}, persistent())
equal(failed.average, 0xAAAAAA, "cache write failures must not discard a valid image sample")
assert(failed.cacheReason, "cache write failures must be reported for diagnostics")
equal(failed.reason, nil, "cache write failures must not force 80% image fallback")
image.noTime = true
local before = calls.decode
local unverified = analyze({}, persistent())
equal(unverified.average, 0xAAAAAA)
assert(unverified.cacheReason, "unavailable timestamps must be reported")
analyze({}, persistent())
equal(calls.decode, before + 2, "unverifiable image metadata must not reuse potentially stale samples")
assert(worst < 12000, "background analysis must stay within a loader callback")
print("Glass image averaging, automatic palette and opacity passed; worst step " .. worst .. " Lua instructions")
