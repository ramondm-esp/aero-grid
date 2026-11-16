-- SPDX-License-Identifier: GPL-2.0-only

local fixture = ...
local edgetx = fixture.edgetx
local themeModule = fixture.module("lib/theme.lua")

local function boundsOf(entry)
    return entry.container.properties
end

local function arcSquareOf(arc)
    local radius = arc.round.radius()
    return {
        x = arc.round.drawn.x,
        y = arc.round.drawn.y,
        w = radius * 2,
        h = radius * 2,
    }
end

local function drawnBoxes(entry)
    local found = {}
    local root = entry.instance.panel and entry.instance.panel.root
    local compassFurniture = {}
    local backgrounds = {}
    local tape = entry.instance.tape
    if tape then
        for _, object in ipairs(tape.shading) do
            backgrounds[object] = true
        end
    end
    if entry.instance.durationBackground then
        backgrounds[entry.instance.durationBackground] = true
    end
    local compass = entry.instance.compass
    if compass then
        for _, object in ipairs(compass.labels) do
            compassFurniture[object] = true
        end
        for _, object in ipairs(compass.rings) do
            compassFurniture[object] = true
        end
    end

    --- Clip a box to its container, or drop it if nothing is left.
    ---
    --- **A container is not decoration here.** The panel's accent stripe is
    --- two quarter-circle arcs inside a box one accent-width wide: unclipped
    --- each arc reaches a full diameter across the panel and appears to lie
    --- over the heading, and the container is the whole reason it does not.
    --- Walking the tree without honouring it reports eleven collisions that
    --- are not on the screen.
    local function clipTo(box, clip)
        if not clip then
            return box
        end
        local x = math.max(box.x, clip.x)
        local y = math.max(box.y, clip.y)
        local right = math.min(box.x + box.w, clip.x + clip.w)
        local bottom = math.min(box.y + box.h, clip.y + clip.h)
        if right <= x or bottom <= y then
            return nil
        end
        box.x, box.y, box.w, box.h = x, y, right - x, bottom - y
        return box
    end

    local function walk(object, offsetX, offsetY, clip)
        for _, child in ipairs(object.children) do
            local x = offsetX + (child.properties.x or 0)
            local y = offsetY + (child.properties.y or 0)
            local inner = clip
            if child.properties.w and child.properties.h then
                inner = clipTo({ x = x, y = y, w = child.properties.w, h = child.properties.h }, clip)
            end
            if not child.hidden then
                local text = tostring(child.properties.text or "")
                if child.kind == "label" and text ~= "" then
                    local font = child.properties.font
                    local size = type(font) == "function" and font() or font
                    found[#found + 1] = clipTo({
                        label = true,
                        compassFurniture = compassFurniture[child],
                        what = '"' .. text .. '"',
                        x = x,
                        y = y,
                        -- Measured the way the radio draws it, not estimated.
                        -- `theme.textWidth` is deliberately generous so text shrinks
                        -- rather than clips, and a check fed the generous number
                        -- reports a reading lying across its own unit on every panel
                        -- that has one. Generosity belongs in deciding whether
                        -- something fits, never in deciding where it is.
                        --
                        -- And never past its own column. A Lua label's long mode is
                        -- LVGL's default wrap, so text too wide for the width it was
                        -- given comes back down the panel rather than out across it.
                        -- Sideways is the one direction it cannot go, and reporting it
                        -- there would be reporting a collision the screen does not
                        -- have. The downward growth is a real defect and is what the
                        -- `lines` assertions elsewhere exist for.
                        w = math.min(themeModule.measureText(size, text), child.properties.w or math.huge),
                        -- Ink, plus whatever this particular string reaches below its
                        -- baseline. Almost always the ink alone, because a reading is
                        -- digits, a minus, a point or a colon -- but a `g` or a `p`
                        -- does reach into the space the band rule leaves unreserved,
                        -- and a check that measured every label by its ascent could
                        -- not see it. See testReadingsDoNotDescendOverAnything, which
                        -- constructs the strings that can.
                        h = themeModule.fontAscent(size) + edgetx.textDescent(size, text),
                    }, clip)
                elseif child.kind == "arc" then
                    local drawn = child.round.drawn
                    local diameter = child.round.radius() * 2
                    found[#found + 1] = clipTo({
                        what = "a dial",
                        compassFurniture = compassFurniture[child],
                        x = offsetX + drawn.x,
                        y = offsetY + drawn.y,
                        w = diameter,
                        h = diameter,
                    }, clip)
                elseif child.kind == "rectangle" or child.kind == "image" then
                    found[#found + 1] = clipTo({
                        what = "a " .. child.kind,
                        background = backgrounds[child],
                        x = x,
                        y = y,
                        w = child.properties.w or 0,
                        h = child.properties.h or 0,
                    }, clip)
                end
            end
            walk(child, x, y, inner)
        end
    end

    if root then
        walk(root, 0, 0, nil)
    end
    return found
end

local function assertNothingOverlaps(label, context)
    for _, entry in ipairs(context.panels) do
        local rect = boundsOf(entry)
        local boxes = drawnBoxes(entry)
        local where = label .. ": " .. entry.placement.id

        -- The panel's own furniture. A surface spans the panel and an accent
        -- stripe runs down its leading edge inside the padding, and both are
        -- under the content by design.
        -- The accent is a stripe one accent-width wide built from a straight
        -- run and two corner arcs, all of it inside the left padding, so the
        -- test is where it is rather than what it is called.
        local accentWidth = 6
        local surface = {}
        for index, box in ipairs(boxes) do
            if not box.label then
                local spansPanel = box.w >= rect.w - 2 and box.h >= rect.h - 2
                local inAccentColumn = box.x + box.w <= accentWidth + 2
                if spansPanel or inAccentColumn or box.background then
                    surface[index] = true
                end
            end
        end

        for first = 1, #boxes do
            for second = first + 1, #boxes do
                local a, b = boxes[first], boxes[second]
                -- One of the pair has to be text. Two shapes overlapping is a
                -- bar's fill inside its track or a level inside a cell, which is
                -- how those are built.
                if
                    (a.label or b.label)
                    and not surface[first]
                    and not surface[second]
                    and not (a.label and b.label and a.what == b.what)
                    and not (a.compassFurniture and b.compassFurniture)
                then
                    local overlapX = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
                    local overlapY = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
                    assert(
                        overlapX <= 0 or overlapY <= 0,
                        where
                            .. " draws "
                            .. a.what
                            .. " over "
                            .. b.what
                            .. ", "
                            .. overlapX
                            .. " by "
                            .. overlapY
                            .. " pixels at ("
                            .. math.max(a.x, b.x)
                            .. ","
                            .. math.max(a.y, b.y)
                            .. ")"
                    )
                end
            end
        end

        -- And nothing readable leaves the panel it belongs to.
        if rect then
            for _, box in ipairs(boxes) do
                if box.label then
                    assert(
                        box.y >= 0 and box.y + box.h <= rect.h,
                        where
                            .. " draws "
                            .. box.what
                            .. " off the panel vertically, "
                            .. box.y
                            .. " to "
                            .. (box.y + box.h)
                            .. " in "
                            .. rect.h
                    )
                end
            end
        end
    end
end

local function assertMenuClear(label, context)
    local reserved = assert(context.reserved, label .. ": nothing was reserved")
    local function walk(object, offsetX, offsetY)
        for _, child in ipairs(object.children) do
            local x = offsetX + (child.properties.x or 0)
            local y = offsetY + (child.properties.y or 0)
            local text = tostring(child.properties.text or "")
            if child.kind == "label" and not child.hidden and text ~= "" then
                local font = child.properties.font
                local size = type(font) == "function" and font() or font
                local width = themeModule.textWidth(size, text)
                local height = themeModule.fontHeight(size)
                assert(
                    x >= reserved.w or y >= reserved.h or x + width <= 0 or y + height <= 0,
                    label .. ' draws "' .. text .. '" under the EdgeTX menu button at ' .. x .. "," .. y
                )
            end
            walk(child, x, y)
        end
    end
    for _, entry in ipairs(context.panels) do
        local bounds = boundsOf(entry)
        walk(entry.container, bounds.x, bounds.y)
    end
end

local function assertReflowContained(context, label)
    for _, entry in ipairs(context.panels) do
        local bounds = boundsOf(entry)
        local panel = fixture.panelOf(entry)
        local where = label .. ": " .. entry.placement.id
        assert(panel.w == bounds.w and panel.h == bounds.h, where .. " did not follow its container")
        for _, object in ipairs(entry.instance.panel.root.children) do
            if not object.hidden then
                local properties = object.properties
                local right, bottom
                if object.kind == "arc" then
                    local drawn = object.round.drawn
                    local diameter = object.round.radius() * 2
                    assert(drawn.x >= -1 and drawn.y >= -1, where .. " drew an arc off its top or left edge")
                    right, bottom = drawn.x + diameter, drawn.y + diameter
                else
                    right = (properties.x or 0) + (properties.w or 0)
                    bottom = (properties.y or 0) + (properties.h or 0)
                end
                assert(right <= bounds.w + 1, where .. " drew past its right edge")
                assert(bottom <= bounds.h + 1, where .. " drew past its bottom edge")
            end
        end
    end
end

return {
    arcSquareOf = arcSquareOf,
    assertNothingOverlaps = assertNothingOverlaps,
    drawnBoxes = drawnBoxes,
    assertMenuClear = assertMenuClear,
    assertReflowContained = assertReflowContained,
}
