-- SPDX-License-Identifier: GPL-2.0-only

local root = assert(...)
local loadModule = assert(loadfile(root .. "/tests/support/module_loader.lua"))(root)
local yaml = loadModule("lib/yaml.lua")
local writer = loadModule("lib/verified_file.lua")
local module = loadModule("lib/background_cache.lua")
local memory = assert(loadfile(root .. "/tests/support/memory_files.lua"))()
local equal = assert(loadfile(root .. "/tests/support/assertions.lua"))().assertEqual
local filename = "/AEROGRID/cache/backgrounds.yml"
local first, second = "/THEMES/Ocean # Blue/background.png", "/THEMES/Other/background_480x272.png"
local worst = 0

local function step(work)
    local count = 0
    debug.sethook(function()
        count = count + 1
    end, "", 1)
    local done = work:step()
    debug.sethook()
    worst = math.max(worst, count)
    return done
end
local function run(work)
    for _ = 1, 2000 do
        if step(work) then
            return work
        end
    end
    error("background cache did not finish")
end
local function fixture()
    local files, ops = memory()
    local function lookup(file, key)
        local work = module.new(yaml, writer, filename, ops)
        work:lookup(file or first, key or "image:1")
        return run(work)
    end
    return files, ops, lookup
end

do
    local files, _, lookup = fixture()
    local cold = lookup()
    equal(cold.brightness, nil)
    equal(cold.reason, nil)
    assert(next(files) == nil, "a cache miss alone must not write")
    cold:save(0)
    run(cold)
    equal(cold.reason, nil)
    equal(lookup().brightness, 0, "fresh instances must preserve black samples")
    local content = files[filename]
    equal(lookup().brightness, 0)
    equal(files[filename], content, "cache hits must not rewrite the file")

    local other = lookup(second, "image:2")
    equal(other.brightness, nil)
    other:save(255)
    run(other)
    equal(lookup().brightness, 0, "saving another image must retain previous results")
    equal(lookup(second, "image:2").brightness, 255)
    local changed = lookup(first, "image:3")
    equal(changed.brightness, nil, "changed metadata must invalidate only that image")
    changed:save(85)
    run(changed)
    equal(lookup(first, "image:3").brightness, 85)
    equal(lookup(second, "image:2").brightness, 255)
    equal(#assert(yaml.parse(files[filename])).backgrounds, 2, "replace stale signatures instead of growing the cache")
end

for _, damaged in ipairs({
    "",
    "version: 1\n",
    "version: [broken\n",
    'version: 1\nbackgrounds:\n  - brightness: "bad"\n    file: image\n    key: stale\n',
    "version: 1\nbackgrounds:\n  - brightness: 256\n    file: image\n    key: stale\n",
    "version: 1\nbackgrounds:\n  - brightness: 1.5\n    file: image\n    key: stale\n",
    "version: 1\nbackgrounds:\n  - brightness: 5\n    file: image\n",
    "version: 1\nbackgrounds:\n  - brightness: 5\n    file: image\n    key: stale\n    extra: invalid\n",
    'version: 1\nbackgrounds:\n  - brightness: 5\n    file: "' .. string.rep("#", 60000) .. '"\n    key: stale\n',
    string.rep("x", 65537),
}) do
    local files, _, lookup = fixture()
    files[filename] = damaged
    local work = lookup()
    equal(work.brightness, nil)
    assert(work.reason, "damaged cache must report a diagnostic")
    work:save(136)
    run(work)
    equal(lookup().brightness, 136, "damaged derived data must be recoverable")
end

do
    local files, _, lookup = fixture()
    local file, key = "/THEMES/" .. string.rep("x#", 100) .. "/background.png", string.rep("x#", 120)
    files[filename] = "version: 1\n"
        .. assert(yaml.serialize({ backgrounds = { { file = file, key = key, brightness = 85 } } }))
    equal(lookup(file, key).brightness, 85, "long quoted filenames must remain within the callback budget")
end

do
    local files, _, lookup = fixture()
    files[filename] = "version: 2\nbackgrounds:\n  - brightness: 85\n    file: image\n    key: stale\n"
    local outdated = lookup()
    equal(outdated.brightness, nil, "sampling version changes must invalidate old results")
    outdated:save(170)
    run(outdated)
    equal(lookup().brightness, 170)
end

for _, fault in ipairs({ "open", "read", "write", "close", "rename" }) do
    local files, ops, lookup = fixture()
    local work = lookup()
    work:save(85)
    run(work)
    local content = files[filename]
    work = lookup(first, "changed")
    ops.inject(fault)
    work:save(170)
    run(work)
    assert(work.reason, fault .. " failures must report a diagnostic")
    equal(files[filename], content, fault .. " failures must preserve the previous cache")
end

do
    local _, _, lookup = fixture()
    local a, b = lookup(), lookup(second, "image:2")
    a:save(85)
    b:save(170)
    for _, work in ipairs({ a, b }) do
        while work.stage ~= "write" do
            assert(not step(work))
        end
    end
    run(a)
    run(b)
    equal(a.reason, nil)
    equal(b.reason, nil)
    equal(lookup().brightness, 85, "overlapping writers must merge rather than discard another sample")
    equal(lookup(second, "image:2").brightness, 170)
end

do
    local files, _, lookup = fixture()
    local entries = {}
    for index = 1, 160 do
        entries[index] = { file = "/THEMES/theme" .. index .. "/background.png", key = "metadata", brightness = index }
    end
    files[filename] = "version: 1\n" .. assert(yaml.serialize({ backgrounds = entries }))
    local work = lookup("/THEMES/theme160/background.png", "metadata")
    equal(work.brightness, 160)
    work:save(170)
    run(work)
    equal(lookup("/THEMES/theme1/background.png", "metadata").brightness, 1)
    equal(lookup("/THEMES/theme160/background.png", "metadata").brightness, 170)
end

assert(worst < 12000, "background cache steps must stay within the loader budget: " .. worst)
print("Persistent background cache, recovery and overlapping writes passed; worst step " .. worst .. " instructions")
