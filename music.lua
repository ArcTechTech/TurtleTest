-- HUD-only music speaker agent for CC: Tweaked (>= 1.100).
--
-- Install:   wget <server>/music.lua?token=<token> startup   + reboot
--
-- There is NO in-game interface: the program never reads keys, mouse or
-- shell input. Playback is driven entirely by the turtle-hud server,
-- which is fed by the web dashboard (youtube urls / uploaded files,
-- converted server-side to DFPWM). The player loop is the proven
-- terreng/computercraft-streaming-music pattern: pull DFPWM chunks over
-- http, decode with cc.audio.dfpwm, feed speaker.playAudio paced by the
-- speaker_audio_empty event.
local WS_URL = "wss://interference-quebec-hormone-considering.trycloudflare.com/music"
local TOKEN = "447004d3aa68ca41"

local args = { ... }
local CID = os.getComputerID()
local NAME = args[1] or os.getComputerLabel() or ("music-" .. tostring(CID))

-- http origin for chunk pulls (the ws endpoint's http origin); recomputed
-- when the endpoint self-heals after a tunnel rotation
local BASE = ""
local function deriveBase()
    BASE = WS_URL:gsub("^wss://", "http://"):gsub("^ws://", "http://")
                   :gsub("/music$", "")
end
deriveBase()

-- --------------------------------------------------------------- speakers --
local speakers = {}
local function rescanSpeakers()
    speakers = { peripheral.find("speaker") }
end
rescanSpeakers()

local decoder = require "cc.audio.dfpwm".make_decoder()

-- ------------------------------------------------------------ play state --
local playing = false
local curGen = nil            -- track generation the player is on
local vol = 1.0
local stream = nil            -- open http handle for the current track
local offset = 0              -- dfpwm bytes fed to the decoder
local tlen = 0                -- track length in bytes
local tname = ""              -- track name (display only)
local dirtyState = true
local ws = nil                -- active websocket (set per session)
local gotWelcome = false      -- set once the server welcomes a session

local outbox = {}
local function push(o)
    outbox[#outbox + 1] = o
    os.queueEvent("music_flush")
end

local logs = {}
local function log(msg, level)
    logs[#logs + 1] = tostring(msg)
    if #logs > 30 then table.remove(logs, 1) end
    push({ t = "log", msg = tostring(msg), level = level or "info" })
end

local function pushState()
    push({
        t = "state", name = NAME, label = os.getComputerLabel(),
        kind = "music", playing = playing, gen = curGen,
        offset = offset, len = tlen, track = tname, vol = vol,
        speakers = #speakers,
    })
    dirtyState = false
end

local function flushOutbox()
    if not ws then return true end
    while #outbox > 0 do
        local m = table.remove(outbox, 1)
        local ok = pcall(ws.send, textutils.serializeJSON(m))
        if not ok then
            table.insert(outbox, 1, m)
            return false
        end
    end
    return true
end

-- ----------------------------------------------------------- transport ----
local function closeStream()
    if stream then
        pcall(stream.close)
        stream = nil
    end
end

local function openStream(from)
    closeStream()
    local url = BASE .. "/music/stream?token=" ..
        textutils.urlEncode(TOKEN) .. "&from=" .. tostring(from)
    local h = http.get(url)
    if not h then return nil, "stream fetch failed" end
    stream = h
    return true
end

--- Silence everything and wake a player stuck waiting on a speaker.
local function haltPlayback()
    playing = false
    closeStream()
    for _, sp in ipairs(speakers) do pcall(sp.stop) end
    os.queueEvent("music_wake")
end

-- ---------------------------------------------------------- player loop --
-- Pull -> decode -> playAudio, paced per speaker on speaker_audio_empty.
-- A music_wake event (issued by pause/stop/new track) breaks the wait, so
-- transport is always instant.
local function playChunk(thisGen)
    if not stream then
        playing = false
        return
    end
    local chunk = stream.read(16384)
    if not chunk then
        -- track finished cleanly
        playing = false
        closeStream()
        dirtyState = true
        return
    end
    offset = offset + #chunk
    local pcm = decoder(chunk)
    for _, sp in ipairs(speakers) do
        local spName = peripheral.getName(sp)
        while not sp.playAudio(pcm, vol) do
            parallel.waitForAny(
                function()
                    repeat until
                        select(2, os.pullEvent("speaker_audio_empty")) == spName
                end,
                function() os.pullEvent("music_wake") end)
            if not playing or curGen ~= thisGen then return end
        end
        if not playing or curGen ~= thisGen then return end
    end
end

local function player()
    while true do
        if playing and stream then
            playChunk(curGen)
        else
            os.pullEvent("music_wake")
        end
    end
end

-- ----------------------------------------------------------- commands ----
local function handleCmd(cmd, a)
    a = a or {}
    if cmd == "music_sync" then
        -- a (new) track is ready: full resync from the start
        haltPlayback()
        decoder = require "cc.audio.dfpwm".make_decoder()
        curGen = tonumber(a.gen) or os.clock()
        tlen = tonumber(a.len) or 0
        tname = tostring(a.name or "")
        vol = tonumber(a.vol) or vol
        offset = 0
        local ok, err = openStream(0)
        if not ok then return false, err end
        if #speakers == 0 then
            rescanSpeakers()
            if #speakers == 0 then
                haltPlayback()
                return false, "no speakers attached"
            end
        end
        playing = true
        dirtyState = true
        os.queueEvent("music_wake")
        return true, "playing " .. tname
    elseif cmd == "music_pause" then
        -- keep the decoder + offset: resume continues mid-track
        haltPlayback()
        return true, "paused at byte " .. tostring(offset)
    elseif cmd == "music_resume" then
        if tlen == 0 then return false, "no track loaded" end
        if playing then return true, "already playing" end
        if offset >= tlen then
            -- at (or past) the end: play again from the top
            decoder = require "cc.audio.dfpwm".make_decoder()
            offset = 0
        end
        local ok, err = openStream(offset)
        if not ok then return false, err end
        playing = true
        dirtyState = true
        os.queueEvent("music_wake")
        return true, "resumed at byte " .. tostring(offset)
    elseif cmd == "music_stop" then
        haltPlayback()
        decoder = require "cc.audio.dfpwm".make_decoder()
        offset = 0
        curGen = nil
        dirtyState = true
        return true, "stopped"
    elseif cmd == "music_vol" then
        local v = tonumber(a.vol)
        if not v then return false, "need vol" end
        vol = math.max(0, math.min(3, v))
        dirtyState = true
        return true, "volume " .. string.format("%.2f", vol)
    elseif cmd == "music_scan" then
        rescanSpeakers()
        dirtyState = true
        return true, #speakers .. " speaker(s) attached"
    elseif cmd == "stop" then
        haltPlayback()
        return true, "stopping"
    end
    return false, "unknown command: " .. tostring(cmd)
end

-- ------------------------------------------------------------ transport ---
local function handleMessage(raw)
    local m = textutils.unserializeJSON(raw)
    if not m or type(m) ~= "table" then return end
    if m.t == "cmd" then
        local ok, msg = pcall(handleCmd, m.cmd, m.args)
        if not ok then ok, msg = false, tostring(msg) end
        push({ t = "result", seq = m.seq, ok = ok and true or false,
               msg = msg or "" })
        if not ok then
            log(tostring(m.cmd) .. ": " .. tostring(msg), "warn")
        end
        flushOutbox()
    elseif m.t == "welcome" then
        gotWelcome = true
        dirtyState = true
        pushState()
        flushOutbox()
        log("connected as " .. tostring(m.name or NAME), "ok")
    elseif m.t == "error" then
        error(tostring(m.msg), 0)
    end
end

local function reader()
    local tick = 0
    local timer = os.startTimer(1)
    while true do
        local ev = { os.pullEvent() }
        local e = ev[1]
        if e == "music_flush" then
            if not flushOutbox() then return end
        elseif e == "timer" and ev[2] == timer then
            tick = tick + 1
            if #speakers == 0 then rescanSpeakers() end
            -- heartbeat: the server drops units after 20s of silence, so
            -- push at least every 10s even when nothing is happening
            if dirtyState or playing or tick % 10 == 0 then
                pushState()
            end
            if not flushOutbox() then return end
            timer = os.startTimer(1)
        elseif e == "websocket_message" and ev[2] == WS_URL then
            handleMessage(ev[3])
        elseif (e == "websocket_closed" or e == "websocket_failure") and
                ev[2] == WS_URL then
            return
        end
    end
end

local function waitForWelcome()
    ws.send(textutils.serializeJSON(
        { t = "hello", token = TOKEN, name = NAME, cid = CID, ver = 1,
          kind = "music" }))
    local timer = os.startTimer(15)
    while true do
        local ev = { os.pullEvent() }
        local e = ev[1]
        if e == "websocket_message" and ev[2] == WS_URL then
            local m = textutils.unserializeJSON(ev[3])
            if m and m.t == "welcome" then
                handleMessage(ev[3])
                return
            elseif m and m.t == "error" then
                handleMessage(ev[3])
            end
        elseif e == "timer" and ev[2] == timer then
            error("server sent no welcome")
        elseif (e == "websocket_closed" or e == "websocket_failure") and
                ev[2] == WS_URL then
            error("connection closed")
        end
    end
end

-- ---------------------------------------------------------- self-heal -----
-- Quick tunnels get a fresh url on every server restart; the server
-- re-bakes this install file onto github whenever that happens. After a few
-- failed sessions, re-read the published file and adopt the URL/token it
-- carries (URL only - never code), same as the turtle and android agents.
local INSTALL_URL =
    "https://raw.githubusercontent.com/ArcTechTech/TurtleTest/main/music.lua"

local function refreshEndpoint()
    local ok, h = pcall(http.get, INSTALL_URL)
    if not ok or not h then return false end
    local okR, body = pcall(h.readAll)
    pcall(h.close)
    if not okR or not body then return false end
    local u = body:match('local%s+WS_URL%s*=%s*"([^"]+)"')
    local t = body:match('local%s+TOKEN%s*=%s*"([^"]+)"')
    local changed = false
    if u and u ~= "wss://interference-quebec-hormone-considering.trycloudflare.com/music" and u ~= WS_URL then
        WS_URL = u
        changed = true
    end
    if t and t ~= "447004d3aa68ca41" and t ~= TOKEN then
        TOKEN = t
        changed = true
    end
    if changed then
        deriveBase()
        log("endpoint refreshed -> " .. WS_URL, "ok")
        print("endpoint refreshed -> " .. WS_URL)
    end
    return changed
end

local function session()
    gotWelcome = false
    local w, err = http.websocket(WS_URL)
    if not w then error(tostring(err), 0) end
    ws = w
    waitForWelcome()
    parallel.waitForAny(reader, player)
end

-- ------------------------------------------------------------------ run --
-- Terminals only show state - there is no prompt, no menu, no read().
-- A terminate (Ctrl+T) just restarts the session: the program cannot be
-- steered in-game, only stopped by deleting the file.
print("Music agent starting...")
print("server: " .. WS_URL)

local backoff = 1
while true do
    local ok, err = pcall(session)
    haltPlayback()
    if ws then pcall(ws.close) end
    ws = nil
    outbox = {}
    if gotWelcome then
        -- a session that reached the server counts as healthy: a mid-
        -- playback drop (tunnel dying) starts a fresh failure streak
        backoff = 1
        sleep(ok and 0.5 or 0.25)
    else
        -- the tunnel probably rotated: adopt the freshly baked url from
        -- github (URL only, never code); the backoff still paces retries
        refreshEndpoint()
        printError(tostring(err or "connection closed"))
        log("disconnected: " .. tostring(err or "connection closed"),
            "error")
        sleep(backoff)
        backoff = math.min(backoff * 2, 10)
    end
end
