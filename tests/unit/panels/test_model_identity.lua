-- SPDX-License-Identifier: GPL-2.0-only

local root = (... and ... ~= "" and ...) or "."

local assertions = assert(loadfile(root .. "/tests/support/assertions.lua"))()
local identity = assert(loadfile(root .. "/src/WIDGETS/AeroGrid/panels/model-identity.lua"))()

local function run()
    for _, presentation in ipairs({ "image", "both" }) do
        local config = { presentation = presentation, label = "MODEL" }
        assertions.assertEqual(#identity.validateSettings(config, { rowSpan = 1 }, config), 0)
        config.label = "CUSTOM"
        local errors = identity.validateSettings(config, { rowSpan = 1 }, config)
        assertions.assertEqual(#errors, 1)
        assertions.assertContains(errors[1], "label is not drawn")
        config.label = nil
        assertions.assertEqual(#identity.validateSettings(config, { rowSpan = 1 }, config), 0)
    end
end

run()
