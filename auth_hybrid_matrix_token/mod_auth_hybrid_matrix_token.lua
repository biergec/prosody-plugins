-- Hybrid Matrix-Token authentication
local async = require "util.async"
local basexx = require 'basexx'
local cjson_safe  = require 'cjson.safe'
local formdecode = require "util.http".formdecode
local generate_uuid = require "util.uuid".generate
local http = require "net.http"
local json = require "util.json"
local new_sasl = require "util.sasl".new
local sasl = require "util.sasl"
local sessions = prosody.full_sessions
local token_util = module:require "token/util".new(module)

-- no token configuration
if token_util == nil then
    return
end

module:depends("jitsi_session")

local uvsIssuer = {"*"}
local issuer = module:get_option("uvs_issuer", nil)
if issuer then
    uvsIssuer = { string.format("%s", issuer) }
end

local uvsUrl = module:get_option("uvs_base_url", nil)
if uvsUrl == nil then
    module:log("warn", "Missing 'uvs_base_url' config")
end

local uvsAuthToken = module:get_option("uvs_auth_token", nil)
if uvsAuthToken == nil then
    module:log(
        "info",
        "No uvs_auth_token supplied, not sending authentication headers"
    )
end

-- define auth provider
local provider = {}

local host = module.host

-- Extract 'token' and 'room' params from URL when session is created
function init_session(event)
    local session, request = event.session, event.request
    local query = request.url.query

    if query ~= nil then
        local params = formdecode(query)

        session.auth_token = params and params.token or nil
        session.jitsi_room = params and params.room or nil
    end
end

module:hook_global("bosh-session", init_session)
module:hook_global("websocket-session", init_session)

function provider.test_password(_username, _password)
    return nil, "Password based auth not supported"
end

function provider.get_password(_username)
    return nil
end

function provider.set_password(_username, _password)
    return nil, "Set password not supported"
end

function provider.user_exists(_username)
    return nil
end

function provider.create_user(_username, _password)
    return nil
end

function provider.delete_user(_username)
    return nil
end

local function split_token(token)
    local segments = {}
    for seg in string.gmatch(token, "([^.]+)") do
        table.insert(segments, seg)
    end

    return segments
end

local function parse_token(token)
    if type(token) ~= "string" then return nil, nil, nil end

    local segments = split_token(token)
    if #segments ~= 3 then return nil, nil, nil end

    local header, err1 = cjson_safe.decode(basexx.from_url64(segments[1]))
    if err1 then return nil, nil, nil end

    local payload, err2 = cjson_safe.decode(basexx.from_url64(segments[2]))
    if err2 then return nil, nil, nil end

    local sign, err3 = basexx.from_url64(segments[3])
    if err3 then return nil, nil, nil end

    return header, payload, sign
end

local function get_options(matrixPayload)
    local options = {}

    options.method = "POST"

    options.headers = {
        ["Content-Type"] = "application/json",
        ["User-Agent"] = string.format("Prosody (%s)", prosody.version)
    }
    if uvsAuthToken ~= nil then
        options.headers["Authorization"] = string.format(
            "Bearer %s", uvsAuthToken
        )
    end

    local body = {
        ["token"] = matrixPayload["token"],
        ["room_id"] = matrixPayload["room_id"]
    }
    if matrixPayload.server_name then
        body["matrix_server_name"] = matrixPayload.server_name
    end
    options.body = json.encode(body)

    return options
end

local function is_user_in_room(session, matrixPayload)
    local url = string.format("%s/verify/user_in_room", uvsUrl)
    local options = get_options(matrixPayload)
    local wait, done = async.waiter()
    local httpRes

    local function cb(resBody, resCode, _req, _res)
        if resCode == 200 then
            httpRes = json.decode(resBody)
        end

        done()
    end

    http.request(url, options, cb)
    wait()

    -- no result
    if not (httpRes and httpRes.results) then
        return false
    end

    -- not a member of Matrix room
    if not (httpRes.results.user and httpRes.results.room_membership) then
        return false
    end

    -- set affiliation as session value according to their power level
    session.matrix_affiliation = "member"
    session.auth_matrix_user_verification_is_owner = false
    if
        httpRes.power_levels and httpRes.power_levels.user and
        httpRes.power_levels.room and httpRes.power_levels.room.state_default and
        httpRes.power_levels.user >= httpRes.power_levels.room.state_default
    then
        session.matrix_affiliation = "owner"
        session.auth_matrix_user_verification_is_owner = true
    end

    return true
end

local function matrix_handler(session, payload)
    if uvsUrl == nil then
        module:log("warn", "Missing 'uvs_base_url' config")
        session.auth_token = nil
        return false, "access-denied", "missing Matrix UVS address"
    end

    session.public_key = "notused"
    local res, error, reason = token_util:process_and_verify_token(
        session,
        uvsIssuer
    )
    if res == false then
        module:log(
            "warn",
            "Error verifying token err:%s, reason:%s", error, reason
        )
        session.auth_token = nil
        return res, error, reason
    end

    if payload.context.matrix.room_id == nil then
        module:log("warn", "Missing Matrix room_id in token")
        session.auth_token = nil
        return false, "bad-request", "Matrix room ID must be given"
    end

    local decodedRoomId = basexx.from_base32(session.jitsi_room)
    if decodedRoomId ~= payload.context.matrix.room_id then
        module:log("warn", "Jitsi and Matrix rooms don't match")
        session.auth_token = nil
        return false, "access-denied", "Jitsi room does not match Matrix room"
    end

    if not is_user_in_room(session, payload.context.matrix) then
        module:log("warn", "Matrix token is invalid or user does not in room")
        session.auth_token = nil
        return false, "access-denied", "Matrix token invalid or not in room"
    end

    session.jitsi_meet_context_matrix = payload.context.matrix

    return true, nil, nil
end

local function token_handler(session)
    -- retrieve custom public key from server and save it on the session
    local preEvent = prosody.events.fire_event(
        "pre-jitsi-authentication-fetch-key",
        session
    )
    if preEvent ~= nil and preEvent.res == false then
        module:log(
            "warn",
            "Error verifying token on pre authentication stage:%s, reason:%s",
                preEvent.error,
                preEvent.reason
        )
        session.auth_token = nil
        return preEvent.res, preEvent.error, preEvent.reason
    end

    local res, error, reason = token_util:process_and_verify_token(session)
    if res == false then
        module:log(
            "warn",
            "Error verifying token err:%s, reason:%s", error, reason
        )
        session.auth_token = nil
        return res, error, reason
    end

    return true, nil, nil
end

local function common_handler(self, session, message)
    local shouldAllow = prosody.events.fire_event(
        "jitsi-access-ban-check",
        session
    )
    if shouldAllow == false then
        module:log("warn", "user is banned")
        return false, "not-allowed", "user is banned"
    end

    local customUsername = prosody.events.fire_event(
        "pre-jitsi-authentication",
        session
    )

    if (customUsername) then
        self.username = customUsername
    elseif (session.previd ~= nil) then
        for _, s in pairs(sessions) do
            if (s.resumption_token == session.previd) then
                self.username = s.username
                break
            end
        end
    else
        self.username = message
    end

    local postEvent = prosody.events.fire_event(
        "post-jitsi-authentication",
        session
    )
    if postEvent ~= nil and postEvent.res == false then
        module:log(
            "warn",
            "Error verifying token on post authentication :%s, reason:%s",
            postEvent.error,
            postEvent.reason
        )
        session.auth_token = nil
        return postEvent.res, postEvent.error, postEvent.reason
    end

    return true, nil, nil
end

function provider.get_sasl_handler(session)
    local function handler(self, message)
        local payload
        if session.auth_token then
            _, payload, _ = parse_token(session.auth_token)
        end

        if payload and payload.context and payload.context.matrix then
            module:log("info", "Matrix authentication handler is selected")

            local res, error, reason = matrix_handler(session, payload)
            if res == false then
                return res, error, reason
            end
        else
            module:log("info", "Token authentication handler is selected")

            local res, error, reason = token_handler(session)
            if res == false then
                return res, error, reason
            end
        end

        local res, error, reason = common_handler(self, session, message)
        if res == false then
            return res, error, reason
        end

        return true
    end

    return new_sasl(host, { anonymous = handler })
end

module:provides("auth", provider)

local function anonymous(self, message)
    module:log("debug", "Message in anonymous: %s", message)

    local username = generate_uuid()

    -- This calls the handler created in 'provider.get_sasl_handler(session)'
    local result, err, msg = self.profile.anonymous(self, username, self.realm)

    if result == true then
        if (self.username == nil) then
            self.username = username
        end
        return "success"
    else
        return "failure", err, msg
    end
end

sasl.registerMechanism("ANONYMOUS", {"anonymous"}, anonymous)
