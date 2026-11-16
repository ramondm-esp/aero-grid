-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."
local gesture = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/lib/gesture.lua"))()
EVT_TOUCH_FIRST, EVT_TOUCH_BREAK, EVT_TOUCH_TAP, EVT_TOUCH_SLIDE, EVT_TOUCH_LONG = 9101, 9102, 9103, 9104, 9105

local function run(events)
    local press, taps = nil, {}
    for _, step in ipairs(events) do
        local tap
        press, tap = gesture.track(press, step[1], step[2])
        if tap then
            taps[#taps + 1] = { x = tap.x, y = tap.y }
        end
    end
    return taps, press
end

local at = { x = 100, y = 50 }
local origin = { x = 0, y = 0 }

local taps = run({ { EVT_TOUCH_FIRST, at }, { EVT_TOUCH_TAP, at }, { EVT_TOUCH_BREAK, origin } })
assert(#taps == 1 and taps[1].x == 100, "a short tap and its release tap once")

taps = run({ { EVT_TOUCH_FIRST, at }, { EVT_TOUCH_BREAK, origin }, { EVT_TOUCH_TAP, at } })
assert(#taps == 1 and taps[1].x == 100 and taps[1].y == 50, "a release taps at the press, not at (0, 0)")

taps = run({ { EVT_TOUCH_FIRST, at }, { EVT_TOUCH_SLIDE, { x = 110, y = 40 } }, { EVT_TOUCH_BREAK, origin } })
assert(#taps == 1, "jitter within ten pixels still taps")

for _, moved in ipairs({ { x = 111, y = 50 }, { x = 100, y = 39 } }) do
    taps = run({ { EVT_TOUCH_FIRST, at }, { EVT_TOUCH_SLIDE, moved }, { EVT_TOUCH_SLIDE, at }, { EVT_TOUCH_BREAK } })
    assert(#taps == 0, "moving more than ten pixels cancels the tap, even after returning")
end

taps = run({ { EVT_TOUCH_FIRST, at }, { EVT_TOUCH_LONG, at }, { EVT_TOUCH_BREAK, origin } })
assert(#taps == 0, "a long press does not tap")

taps = run({ { EVT_TOUCH_TAP, at }, { EVT_TOUCH_TAP, at } })
assert(#taps == 1, "a TAP without FIRST taps once")

taps = run({ { EVT_TOUCH_FIRST }, { EVT_TOUCH_BREAK, origin } })
assert(#taps == 0, "a release without a captured point does not tap")

local press = gesture.track(nil, EVT_TOUCH_FIRST, at)
press = gesture.cancel(press)
local _, tap = gesture.track(press, EVT_TOUCH_BREAK, origin)
assert(not tap, "a cancelled press does not tap")
assert(gesture.cancel(nil).done, "cancel ignores the rest of a gesture that began elsewhere")

assert(gesture.touch(EVT_TOUCH_SLIDE) and not gesture.touch(1), "only touch events are gestures")
print("Gesture tests passed")
