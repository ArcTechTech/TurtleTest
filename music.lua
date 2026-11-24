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
local WS_URL = "wss://organizing-moisture-edges-township.trycloudflare.com/music"
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

-- ---------------------------------------------------------- timing utils --
-- CC has no async http: a request blocks the calling coroutine and its
-- internal event loop eats every event that arrives while it waits. Run
-- inside reader(), that silently kills the 1s heartbeat timer (one-shot,
-- re-armed only by its own branch) - the unit then goes offline in the
-- HUD 20s later and every transport command refuses, until the in-game
-- computer is rebooted. So every blocking call gets a deadline, and
-- reader() re-arms its timer after any command that may have blocked.
local function timedCall(secs, fn, ...)
    -- `...` may not be used inside the nested closures below (Lua forbids
    -- referencing a vararg from a non-vararg function - cobalt rejects the
    -- whole file with "cannot use '...' outside a vararg function"), so the
    -- arguments are packed here, in the vararg function itself.
    local args = table.pack(...)
    local ok, a, b
    local which = parallel.waitForAny(
        function() ok, a, b = pcall(fn, table.unpack(args, 1, args.n)) end,
        function() sleep(secs) end)
    if which == 2 then
        return nil, "timed out after " .. tostring(secs) .. "s"
    end
    if not ok then
        return nil, tostring(a)
    end
    return a, b
end

-- --------------------------------------------------------------- speakers --
local speakers = {}
local function rescanSpeakers()
    speakers = { peripheral.find("speaker") }
end
rescanSpeakers()

-- monitor display (optional): the first attached monitor. Works with basic
-- (monochrome) monitors - frames are pre-rendered ASCII from the server.
local monitor = peripheral.find("monitor")
local monW, monH = 0, 0
if monitor then
    monW, monH = monitor.getSize()
    pcall(function() monitor.setTextScale(1) end)
    monW, monH = monitor.getSize()
    pcall(function() monitor.clear() end)
end

-- ------------------------------------------------------------ wake nodes --
-- ComputerCraft Wake Nodes (ccwake): a wake_node attached to THIS computer
-- keeps its chunk force-loaded, so playback survives the player walking
-- away. Only stationary computers can host a node (the mod refuses turtle
-- blocks), which is why this lives in the music agent and not in the turtle
-- one. Reported in state so the dashboard can show it; rescanned on the
-- slow heartbeat because nodes are placed/broken by hand.
local wakeInfo = nil
local function rescanWake()
    wakeInfo = nil
    for _, n in ipairs(peripheral.getNames()) do
        local ok, ty = pcall(peripheral.getType, n)
        if ok and type(ty) == "string" and ty:sub(1, 5) == "wake_" then
            local okw, p = pcall(peripheral.wrap, n)
            if okw and p then
                if ty == "wake_controller" then
                    -- controller: report how many nodes it can see
                    local okc, nodes = pcall(p.listNodes)
                    wakeInfo = { type = ty,
                                 nodes = okc and type(nodes) == "table"
                                         and #nodes or nil }
                else
                    -- wake_node / wake_node_advanced: id + chunk coverage
                    local okg, info = pcall(p.getInfo)
                    if okg and type(info) == "table" then
                        info.type = ty
                        wakeInfo = info
                    else
                        wakeInfo = { type = ty }
                    end
                end
                break
            end
        end
    end
end
rescanWake()

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
local resumeAt = nil          -- byte offset to resume after a reconnect

-- video playback state: frame index is derived from the audio byte offset so
-- picture and sound stay in sync (dfpwm = 8 samples/byte @ 44.1kHz).
local videoFrames = 0         -- total frames available on the server
local mediaMode = "video"     -- "video" (audio+monitor) | "music" (audio only)
local videoFps = 8
local videoW, videoH = monW, monH
local frameCache = {}         -- index -> frame string (small window)
local lastFrame = -1
local videoHandle = nil       -- open frame-fetch http handle

-- Frame index from audio offset: bytes-per-frame = (44100/8) / fps.
local function frameIndex()
    if videoFrames <= 0 or not monitor then return nil end
    local bpf = (44100 / 8) / videoFps
    local i = math.floor(offset / bpf)
    if i < 0 then i = 0 elseif i >= videoFrames then i = videoFrames - 1 end
    return i
end

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
        speakers = #speakers, wake = wakeInfo,
        monitor = monitor and { w = videoW, h = videoH } or nil,
        video = { frames = videoFrames, fps = videoFps,
                  frame = lastFrame >= 0 and lastFrame or nil },
        mediaMode = mediaMode,
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
    local h, err = timedCall(15, http.get, url)
    if not h then return nil, err or "stream fetch failed" end
    stream = h
    return true
end

--- Silence everything and wake a player stuck waiting on a speaker.
local function haltPlayback()
    playing = false
    closeStream()
    for _, sp in ipairs(speakers) do pcall(sp.stop) end
    if videoHandle then pcall(videoHandle.close) videoHandle = nil end
    if monitor then pcall(function() monitor.clear() end) end
    lastFrame = -1
    os.queueEvent("music_wake")
end

-- --------------------------------------------------------- video display --
-- Fetch one frame over HTTP (small, cached) and paint it to the monitor.
-- Frames are plain text of exactly w*h characters; we write them row by row.
local function paintFrame(idx)
    if not monitor or idx == lastFrame then return end
    local data = frameCache[idx]
    if not data then
        if videoHandle then pcall(videoHandle.close) videoHandle = nil end
        local url = BASE .. "/video/frame?token=" ..
            textutils.urlEncode(TOKEN) .. "&i=" .. tostring(idx)
        local h, err = timedCall(6, http.get, url)
        if not h then return end
        videoHandle = h
        data = h.readAll()
        pcall(h.close)
        videoHandle = nil
        if not data or #data < videoW * videoH then return end
        -- one-slot cache: consecutive frames are fetched one at a time
        frameCache = { [idx] = data }
    end
    local ok = pcall(function()
        monitor.setCursorPos(1, 1)
        for y = 0, videoH - 1 do
            monitor.setCursorPos(1, y + 1)
            monitor.write(data:sub(y * videoW + 1, (y + 1) * videoW))
        end
    end)
    if ok then lastFrame = idx end
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
        if playing and tlen > 0 and offset < tlen then
            -- the tunnel dropped the stream mid-track: raise so the player
            -- reopens it at `offset` instead of "finishing" the track early
            error("stream ended early (" .. offset .. "/" .. tlen .. ")", 0)
        end
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

-- Video runs as its own coroutine so a slow HTTP frame fetch or monitor write
-- never delays the audio. It follows `offset`, so picture tracks sound.
local function videoPlayer()
    local timer = os.startTimer(0.05)
    while true do
        local ev = { os.pullEvent() }
        if ev[1] == "timer" and ev[2] == timer then
            if playing and monitor and mediaMode ~= "music" then
                local fi = frameIndex()
                if fi then pcall(paintFrame, fi) end
            end
            timer = os.startTimer(0.05)
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
        -- video metadata from the server (frame count / grid / fps)
        if a.mode then mediaMode = tostring(a.mode) end
        if type(a.video) == "table" then
            videoFrames = tonumber(a.video.frames) or 0
            videoFps = tonumber(a.video.fps) or 8
            videoW = tonumber(a.video.w) or monW
            videoH = tonumber(a.video.h) or monH
        else
            videoFrames = 0
            videoW, videoH = monW, monH
        end
        if mediaMode == "music" and monitor then
            pcall(function() monitor.clear() end)
        end
        frameCache, lastFrame = {}, -1
        local ok, err = openStream(0)
        if not ok then return false, err end
        if #speakers == 0 and not monitor then
            rescanSpeakers()
            if #speakers == 0 and not monitor then
                return false, "no speakers/monitor attached"
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
    elseif cmd == "media_mode" then
        mediaMode = tostring(a.mode or "video")
        if mediaMode == "music" and monitor then
            pcall(function() monitor.clear() end)
        end
        lastFrame = -1
        frameCache = {}
        dirtyState = true
        return true, "mode: " .. mediaMode
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
            -- wake nodes are placed/broken by hand: a slow rescan keeps the
            -- reported chunk-load status current without per-tick probing
            if tick % 10 == 0 then rescanWake() end
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
    if u and u ~= "wss://organizing-moisture-edges-township.trycloudflare.com/music" and u ~= WS_URL then
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
    parallel.waitForAny(reader, player, videoPlayer)
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
