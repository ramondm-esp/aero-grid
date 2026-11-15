-- SPDX-License-Identifier: GPL-2.0-only

--- Slot scheduler: shares a callback's slots among tasks in fair round-robin.
--- It knows nothing about panels, services or EdgeTX; the host wraps its work
--- as tasks. One slot is a nominal 2000 Lua instructions.
---
---@class AeroGridTask
---@field name string Label used in error reports.
---@field step fun(task: AeroGridTask, now: integer, slots: integer, context: any): integer?, boolean? Returns slots used and whether more work is ready now.
--- A fixed-cost step that returns no consumption used its whole grant; a
--- variable-cost step must report it. No continuation means none is wanted.
---@field cost? integer|"variable" Slots one step needs, 0 to 8. Defaults to 1. Read before every step.
---@field minCost? integer Minimum grant for a variable-cost step, 1 to 8.
---@field due? integer Tick from which the task is eligible. Ignored while pending.
---@field ready? fun(task: AeroGridTask, now: integer, context: any): boolean Extra gate.
---@field failed? boolean Set by the host before a run, or by the scheduler after a failure.
---@field error? string Set by the scheduler with `failed`.
---
--- The scheduler keeps its bookkeeping off the task; `state(task)` reads it.
---@class AeroGridTaskState
---@field pending? boolean The last step asked for another.
---@field spent integer Slots charged so far.
---@field refused? integer Callback in which the task was denied slots or spun on free turns.
---@field denied? integer Segment in which the task did not fit its grant.
---@field spun? integer Callback in which the task was stopped after repeated free turns.

local MAX_TASK_SLOTS = 8
--- `SLOTS` caps one turn; `CAPACITY` is the default allowance of one callback segment.
local scheduler = { RUNTIME_API = 1, SLOTS = MAX_TASK_SLOTS, CAPACITY = MAX_TASK_SLOTS, INSTRUCTIONS_PER_SLOT = 2000 }

--- Slots a task is granted, zero when it does not fit, or nil when its cost is invalid.
---@param cost any
---@param minCost any
---@param allowance integer Slots still available to charged work.
---@return integer?
local function grant(cost, minCost, allowance)
    if cost == "variable" then
        if type(minCost) ~= "number" or minCost < 1 or minCost > MAX_TASK_SLOTS or minCost % 1 ~= 0 then
            return nil
        end
        if allowance < minCost then
            return 0
        end
        return math.min(allowance, MAX_TASK_SLOTS)
    end
    if type(cost) ~= "number" or cost < 0 or cost > MAX_TASK_SLOTS or cost % 1 ~= 0 then
        return nil
    end
    return cost <= allowance and cost or 0
end

--- Create one scheduler.
--- `fail(task, message)` reports a failed task once. `charge(task, spent)`
--- observes every non-zero charge.
---@param dependencies? table
---@return table scheduler
function scheduler.new(dependencies)
    dependencies = dependencies or {}
    local fail, charge = dependencies.fail, dependencies.charge
    local capacity = dependencies.capacity == nil and scheduler.CAPACITY or dependencies.capacity
    assert(
        type(capacity) == "number" and capacity > 0 and capacity < math.huge and capacity % 1 == 0,
        "capacity must be a positive whole number"
    )
    local self = {
        -- Read-only description of the callback budget, shared with panels.
        budget = {
            capacity = capacity,
            slots = math.min(capacity, MAX_TASK_SLOTS),
            instructionsPerSlot = scheduler.INSTRUCTIONS_PER_SLOT,
        },
        tasks = {},
        count = 0,
        cursor = 1,
        callbacks = 0,
        segments = 0,
    }
    -- Weak keys: a retired task is collectable once its owner drops it.
    local records = setmetatable({}, { __mode = "k" })

    local function record(task)
        local state = records[task]
        if not state then
            state = { spent = 0 }
            records[task] = state
        end
        return state
    end

    --- The scheduler's bookkeeping for a task, for diagnostics and tests. Read only.
    ---@param task AeroGridTask
    ---@return AeroGridTaskState
    function self.state(task)
        return record(task)
    end

    --- Enrol one task for the coming run.
    function self.add(task)
        local count = self.count + 1
        self.tasks[count] = task
        self.count = count
    end

    --- Release every task. The scheduler keeps nothing between callbacks, so a
    --- retired panel is collectable as soon as its owner drops it; only the
    --- cursor, an index, persists.
    function self.clear()
        local tasks = self.tasks
        for index = self.count, 1, -1 do
            tasks[index] = nil
        end
        self.count = 0
    end

    local function failTask(task, state, message)
        task.failed, task.error, state.pending = true, message, false
        if fail then
            fail(task, message)
        end
    end

    --- Run one segment of a callback's work. A fresh callback starts with
    --- `run`; `resume` continues the same callback with new slots.
    --- Every eligible task takes a turn per pass, and a task that asks for
    --- another step runs again only after the rest of the ring has had its turn.
    --- The first task that does not fit keeps the next callback's first turn;
    --- nothing charged runs after it, though free tasks still do.
    --- Consecutive zero-charge turns are limited to at most eight per task
    --- per callback; unfinished work resumes on the next callback.
    local function execute(now, slots, context, resuming)
        local count, tasks, turnSlots = self.count, self.tasks, self.budget.slots
        if count == 0 then
            return 0, 0, 0
        end
        local callback, previous = self.callbacks, self.segments
        if not resuming then
            callback = callback + 1
            self.callbacks = callback
        end
        local segment = previous + 1
        self.segments = segment
        if resuming then
            -- Tasks that did not fit the last segment continue with the new
            -- allowance; tasks that spun on free turns wait for the next callback.
            for index = 1, count do
                local state = record(tasks[index])
                if state.denied == previous and state.spun ~= callback then
                    state.refused, state.pending = nil, true
                end
            end
        end
        local start = self.cursor
        if start > count then
            start = 1
        end
        local remaining, deferred, requested, denied = slots, nil, 0, 0

        local progressed
        repeat
            progressed = false
            local index = start
            for _ = 1, count do
                local position = index
                local task = tasks[position]
                local state = record(task)
                index = index % count + 1
                if
                    not task.failed
                    and state.refused ~= callback
                    and (state.pending or (state.ran ~= callback and now >= (task.due or 0)))
                    and (not task.ready or task.ready(task, now, context))
                then
                    local cost = task.cost
                    if cost == nil then
                        cost = 1
                    end
                    local granted = grant(cost, task.minCost, deferred and 0 or remaining)
                    if granted == nil then
                        failTask(task, state, cost == "variable" and "invalid minimum slot cost" or "invalid slot cost")
                    else
                        if cost ~= 0 then
                            requested = requested + 1
                        end
                        if granted == 0 and cost ~= 0 then
                            denied = denied + 1
                            state.refused, state.denied = callback, segment
                            deferred = deferred or position
                        else
                            local ok, used, again = pcall(task.step, task, now, granted, context)
                            local spent = granted
                            if used == nil and cost ~= "variable" then
                                used = granted
                            end
                            if again == nil then
                                again = false
                            end
                            if not ok then
                                failTask(task, state, tostring(used))
                            elseif type(used) == "number" and used >= 0 and used <= granted and used % 1 == 0 then
                                if type(again) ~= "boolean" then
                                    ok = false
                                    failTask(task, state, "continuation must be boolean")
                                else
                                    spent = used
                                end
                            else
                                ok = false
                                failTask(task, state, "consumption must be whole slots within the grant")
                            end
                            if spent == 0 then
                                state.zeroTurns = state.ran == callback and (state.zeroTurns or 0) + 1 or 1
                            else
                                state.zeroTurns = 0
                            end
                            state.ran = callback
                            state.spent = state.spent + spent
                            remaining = remaining - spent
                            if ok and again then
                                state.pending = true
                                progressed = true
                                if state.zeroTurns >= turnSlots then
                                    state.refused, state.spun = callback, callback
                                end
                            else
                                state.pending = false
                            end
                            if charge and spent > 0 then
                                charge(task, spent)
                            end
                        end
                    end
                end
            end
        until not progressed

        self.cursor = deferred or start
        return slots - remaining, requested, denied
    end

    --- Run one callback's worth of work.
    ---@param now integer
    ---@param slots integer Slots available to this callback.
    ---@param context any Passed through to `ready` and `step`.
    ---@return integer used
    ---@return integer requested Eligible tasks that asked for slots.
    ---@return integer denied Eligible tasks that did not fit.
    function self.run(now, slots, context)
        return execute(now, slots, context, false)
    end

    --- Continue the callback of the last `run` with a new allowance. Only tasks
    --- that asked for another step or did not fit the previous segment take a
    --- turn; a task that already ran does not run again just because it is due.
    ---@param now integer
    ---@param slots integer Slots available to this segment.
    ---@param context any Passed through to `ready` and `step`.
    ---@return integer used
    ---@return integer requested
    ---@return integer denied
    function self.resume(now, slots, context)
        return execute(now, slots, context, true)
    end

    --- Whether `resume` has work to do after the last segment.
    ---@param now integer
    ---@param context any Passed through to `ready`.
    ---@return boolean
    function self.more(now, context)
        local callback, segment, tasks = self.callbacks, self.segments, self.tasks
        for index = 1, self.count do
            local task = tasks[index]
            local state = record(task)
            if
                not task.failed
                and state.spun ~= callback
                and (state.pending and state.refused ~= callback or state.denied == segment)
                and (not task.ready or task.ready(task, now, context))
            then
                return true
            end
        end
        return false
    end

    return self
end

return scheduler
