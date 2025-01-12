local LOGLEVEL = "debug"
local TIMEOUT = module:get_option_number("role_timeout", 120)

local is_admin = require "core.usermanager".is_admin
local is_healthcheck_room = module:require "util".is_healthcheck_room
local it = require "util.iterators"
local timer = require "util.timer"
module:log("info", "loaded")

local function _is_admin(jid)
    return is_admin(jid, module.host)
end

local function terminator(room)
    if is_healthcheck_room(room.jid) then
        return
    end

    -- decrease the terminator counter
    room._data.terminator_count = room._data.terminator_count - 1

    -- stop this terminator if there is another active one
    -- always the last terminator destroys the room
    if room._data.terminator_count > 0 then
        return
    end

    -- last check before destroying the room
    module:log(LOGLEVEL, "last check before destroying the room")
    for _, o in room:each_occupant() do
        if not _is_admin(o.jid) then
            if room:get_affiliation(o.jid) == "owner" then
                module:log(
                    LOGLEVEL,
                    "there is an owner, terminator is stopped, %s",
                    room.jid
                )
                return
            end
        end
    end

    -- terminate the meeting
    room:destroy(nil, "The meeting has been terminated")
    module:log(LOGLEVEL, "the meeting has been terminated")
end

local function trigger_terminator(room)
    module:log(LOGLEVEL, "terminator request is received")

    -- check if there is an owner in the room
    -- do nothing if there is one
    for _, o in room:each_occupant() do
        if not _is_admin(o.jid) then
            if room:get_affiliation(o.jid) == "owner" then
                module:log(
                    LOGLEVEL,
                    "there is an owner, terminator is not triggered, %s",
                    room.jid
                )
                return
            end
        end
    end

    -- increase the terminator counter before triggering a new one
    if not room._data.terminator_count then
        room._data.terminator_count = 1
    else
        room._data.terminator_count = room._data.terminator_count + 1
    end

    -- since there is no owner in the room, destroy the room after TIMEOUT secs
    timer.add_task(TIMEOUT, function()
        terminator(room)
    end)
    module:log(LOGLEVEL, "terminator is triggered")
end

module:hook("muc-occupant-joined", function (event)
    local room, occupant = event.room, event.occupant

    if is_healthcheck_room(room.jid) or _is_admin(occupant.jid) then
        return
    end

    -- do nothing if this is not the first participant (after focus)
    local occupant_count = it.count(room:each_occupant())
    if occupant_count > 2 then
        return
    end
    module:log(LOGLEVEL, "the first participant joined the room, %s", room.jid)

    -- the first participant joined the room, call terminator
    trigger_terminator(room)
end)

module:hook("muc-occupant-left", function (event)
    local room, occupant = event.room, event.occupant

    if is_healthcheck_room(room.jid) or _is_admin(occupant.jid) then
        return
    end

    -- do nothing if her role is not owner
    if room:get_affiliation(occupant.jid) ~= "owner" then
        return
    end
    module:log(LOGLEVEL, "an owner left, %s", occupant.jid)

    -- an owner left the room, call terminator
    trigger_terminator(room)
end)
