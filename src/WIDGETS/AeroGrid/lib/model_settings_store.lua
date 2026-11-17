-- SPDX-License-Identifier: GPL-2.0-only

local storeModule = { RUNTIME_API = 1, VERSION = 1 }

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, entry in pairs(value) do
        result[key] = copy(entry)
    end
    return result
end

local function validIdentity(filename)
    return type(filename) == "string" and string.find(filename, "%S") ~= nil and not string.find(filename, "%z")
end

function storeModule.path(widgetPath, modelFilename)
    if not validIdentity(modelFilename) then
        return nil, "Model filename unavailable; reload the model before saving settings"
    end
    local base = string.sub(widgetPath, -1) == "/" and widgetPath or widgetPath .. "/"
    local root = string.match(base, "^(.*/)WIDGETS/[^/]+/$") or base
    local encoded = string.gsub(modelFilename, ".", function(character)
        return string.format("%02x", string.byte(character))
    end)
    return root .. "AEROGRID/models/" .. encoded .. ".yaml"
end

local function dependency(path, name)
    local filename = path .. (string.sub(path, -1) == "/" and "" or "/") .. "lib/" .. name .. ".lua"
    return assert((loadScript or loadfile)(filename))()
end

function storeModule.new(widgetPath, yaml, env, fileOps)
    env = env or {}
    local writer = env.verifiedFile or dependency(widgetPath, "verified_file")
    local config = env.flightConfig or dependency(widgetPath, "flight_config")
    local counter = env.flightCount or dependency(widgetPath, "flight_count")
    local flightDefaults = config.defaults()
    local armed = env.armedConfig or dependency(widgetPath, "armed_service")
    local operations = writer.operations(fileOps)
    local instance = { counter = counter, operations = operations }
    local function identity(filename)
        local current
        if env.modelFilename then
            current = env.modelFilename()
        elseif model and type(model.getInfo) == "function" then
            local info = model.getInfo()
            current = type(info) == "table" and info.filename
        end
        if not validIdentity(filename) or current ~= filename then
            return false, "Model changed or filename unavailable; reload Model settings"
        end
        return true
    end
    local function validate(document, filename)
        if type(document) ~= "table" or document.version ~= storeModule.VERSION then
            return nil, "Unsupported model settings schema; expected version 1"
        end
        if document.modelFilename ~= filename then
            return nil, "Model settings filename identity mismatch"
        end
        local revision = document.revision
        if type(revision) ~= "number" or revision < 0 or revision % 1 ~= 0 or revision > 2147483646 then
            return nil, "Invalid model settings revision"
        end
        for key in pairs(document) do
            if
                key ~= "version"
                and key ~= "modelFilename"
                and key ~= "revision"
                and key ~= "flight"
                and key ~= "armed"
                and key ~= "sessionReset"
                and key ~= "flightCount"
            then
                return nil, "Unknown model settings field: " .. tostring(key)
            end
        end
        if document.flightCount ~= nil and not counter.valid(document.flightCount) then
            return nil, "Flight count must be an integer in 0.." .. counter.MAX
        end
        if document.flightCount ~= nil then
            document.flightCount = math.floor(document.flightCount)
        end
        if document.armed ~= nil and not armed.valid(document.armed) then
            return nil, "Armed must be blank, a physical switch position, or a logical switch (L01-L64)"
        end
        if document.sessionReset ~= nil and not armed.valid(document.sessionReset) then
            return nil, "Session reset must be blank, a physical switch position, or a logical switch (L01-L64)"
        end
        if document.flight ~= nil then
            if type(document.flight) ~= "table" then
                return nil, "flight must be a configuration table"
            end
            document.flight.announcements = nil
            document.flight.history = nil
            for key in pairs(document.flight) do
                if flightDefaults[key] == nil then
                    return nil, "Unknown flight setting: " .. tostring(key)
                end
            end
            local resolved = config.resolve(document.flight)
            local errors = config.validate(resolved)
            if #errors > 0 then
                return nil, table.concat(errors, "; ")
            end
            document.flight = resolved
            if
                document.sessionReset ~= nil
                and document.sessionReset ~= ""
                and resolved.flightSwitch ~= ""
                and string.gsub(document.sessionReset or "", "^!", "") == resolved.flightSwitch
            then
                return nil, "Flight status switch cannot be the Session reset input"
            end
        end
        return copy(document)
    end
    local function loadDocument(filename)
        local path, pathError = storeModule.path(widgetPath, filename)
        if not path then
            return nil, pathError
        end
        local errors, found = {}, false
        for _, suffix in ipairs({ "", ".bak" }) do
            if operations.stat(path .. suffix) then
                found = true
                local content, readError = writer.read(path .. suffix, operations)
                local document, parseError
                if content then
                    document, parseError = yaml.parse(content)
                end
                local normalized, validationError
                if document then
                    normalized, validationError = validate(document, filename)
                end
                if normalized then
                    local recovered = suffix ~= ""
                    return normalized,
                        {
                            filename = path .. suffix,
                            recovered = recovered,
                            notice = recovered and "Recovered previous model settings from backup; review and Save"
                                or nil,
                        }
                end
                errors[#errors + 1] = tostring(validationError or parseError or readError)
            end
        end
        if found then
            return nil, "Cannot load model settings: " .. table.concat(errors, "; ")
        end
        return { version = 1, modelFilename = filename, revision = 0 }, { filename = path, missing = true }
    end
    function instance:load(filename)
        local ok, document, info = pcall(loadDocument, filename)
        if not ok then
            return nil, "Cannot load model settings: " .. tostring(document)
        end
        return document, info
    end
    local function prepare(self, filename, baseRevision, flight, armedCondition, sessionReset)
        local matches, identityError = identity(filename)
        if not matches then
            return false, identityError
        end
        if type(flight) ~= "table" then
            return false, "Choose flight settings before saving"
        end
        local previous, info = self:load(filename)
        if not previous then
            return false, info
        end
        if previous.revision ~= baseRevision then
            return false, "Model settings changed in another dashboard; close and reopen Model settings"
        end
        local document, validationError = validate({
            version = 1,
            modelFilename = filename,
            revision = baseRevision + 1,
            flight = copy(flight),
            armed = armedCondition == nil and previous.armed or armedCondition,
            sessionReset = sessionReset == nil and previous.sessionReset or sessionReset,
            flightCount = previous.flightCount,
        }, filename)
        if not document then
            return false, validationError
        end
        local serialized, serializeError = yaml.serialize(document)
        if not serialized then
            return false, serializeError
        end
        local parsed, parseError = yaml.parse(serialized)
        if not parsed then
            return false, parseError
        end
        local checked, checkError = validate(parsed, filename)
        if not checked then
            return false, checkError
        end
        return true,
            {
                filename = filename,
                baseRevision = baseRevision,
                serialized = serialized,
                document = checked,
                recovered = info and info.recovered,
            }
    end
    -- The write guard rechecks identity and the live revision, so a commit may follow its prepare in a later callback.
    local function commit(self, prepared)
        local filename, baseRevision = prepared.filename, prepared.baseRevision
        local function guard(afterRotation)
            local current, currentError = identity(filename)
            if not current then
                return false, currentError
            end
            if afterRotation then
                if operations.stat(assert(storeModule.path(widgetPath, filename))) then
                    return false, "Model settings changed during save; cancel and reload"
                end
                return true
            end
            local live, loadError = self:load(filename)
            if not live then
                return false, loadError
            end
            if live.revision ~= baseRevision then
                return false, "Model settings changed during save; cancel and reload"
            end
            if live.flightCount ~= prepared.baseCount then
                return false, "Flight count changed during save; retry the setting"
            end
            return true
        end
        local saved, saveError = writer.write(
            assert(storeModule.path(widgetPath, filename)),
            prepared.serialized,
            operations,
            guard,
            prepared.recovered
        )
        if not saved then
            return false, saveError
        end
        local matches, identityError = identity(filename)
        if not matches then
            return false, identityError
        end
        return true, copy(prepared.document)
    end
    local function protected(step, ...)
        local ok, saved, result = pcall(step, ...)
        if not ok then
            return false, "Cannot save model settings: " .. tostring(saved)
        end
        return saved, result
    end
    --- Validates and serializes a save; returns `true, prepared` or `false, message`.
    function instance:prepare(filename, baseRevision, flight, armedCondition, sessionReset)
        local ok, prepared = protected(prepare, self, filename, baseRevision, flight, armedCondition, sessionReset)
        if ok then
            prepared.baseCount = prepared.document.flightCount
        end
        return ok, prepared
    end
    --- Writes a prepared save; returns `true, document` or `false, message`.
    function instance:commit(prepared)
        return protected(commit, self, prepared)
    end
    function instance:save(filename, baseRevision, flight, armedCondition, sessionReset)
        local prepared, result = self:prepare(filename, baseRevision, flight, armedCondition, sessionReset)
        if not prepared then
            return false, result
        end
        return self:commit(result)
    end
    function instance:prepareCount(filename, expected, value, imported)
        return protected(function()
            local matches, message = identity(filename)
            if not matches then
                return false, message
            end
            local previous, info = self:load(filename)
            if not previous then
                return false, info
            end
            if previous.flightCount ~= expected then
                return false, "Flight count changed before save; reload the model"
            end
            previous.flightCount = value
            if imported and previous.flight == nil and imported.flight then
                previous.flight = imported.flight
            end
            if imported and previous.armed == nil then
                previous.armed = imported.armed
            end
            local document, validationError = validate(previous, filename)
            if not document then
                return false, validationError
            end
            local serialized, serializeError = yaml.serialize(document)
            if not serialized then
                return false, serializeError
            end
            return true,
                {
                    filename = filename,
                    baseRevision = document.revision,
                    baseCount = expected,
                    document = document,
                    serialized = serialized,
                    recovered = info and info.recovered,
                }
        end)
    end
    return instance
end

return storeModule
