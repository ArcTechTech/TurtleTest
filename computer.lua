-- Computer / Wake-Node status agent for CC: Tweaked + CC Wake Nodes.
--
-- Install:   wget <server>/computer.lua?token=<token> startup   + reboot
-- Public:    wget https://raw.githubusercontent.com/ArcTechTech/TurtleTest/
--            main/computer.lua startup   + reboot
--
-- Install this on ANY computer you want visible in the HUD:
--   * a computer with a wake_node / wake_node_advanced attached -> reports
--     the node's id, dimension, chunk, range and loaded-chunk count
--   * a computer beside a wake_controller  -> reports every registered node
--     with its loaded flag and (where the ACL allows) full chunk info
--   * a plain computer                      -> reports online / idle status
--
-- The turtle agent cannot do this: the mod only attaches nodes to stationary
-- computercraft:computer_* blocks, and turtles only see left/right upgrades.
-- No world interaction, no commands, no keys - just a 10s heartbeat so the
-- server (which drops units after 20s of silence) keeps it online.
local WS_URL = "wss://variable-kid-def-saint.trycloudflare.com/computer"
local TOKEN = "447004d3aa68ca41"

local args = { ... }
local CID = os.getComputerID()
local NAME = args[1] or os.getComputerLabel() or ("computer-" .. tostring(CID))

local outbox = {}
local function push(o)
    outbox[#outbox + 1] = o
    os.queueEvent("computer_flush")
end

local function log(msg, level)
    push({ t = "log", msg = tostring(msg), level = level or "info" })
end

-- ------------------------------------------------------------ wake nodes --
-- Scans this computer's peripherals for wake_* types. Node computers report
-- getInfo(); a controller reports listNodes() + getNodeInfo() so the dashboard
-- can show each node's loaded state, not just the controller's own view.
local wakeInfo = nil
local function rescanWake()
    wakeInfo = nil
    for _, n in ipairs(peripheral.getNames()) do
        local ok, ty = pcall(peripheral.getType, n)
        if ok and type(ty) == "string" and ty:sub(1, 5) == "wake_" then
            local okw, p = pcall(peripheral.wrap, n)
            if okw and p then
                if ty == "wake_controller" then
                    local okc, nodes = pcall(p.listNodes)
                    if okc and type(nodes) == "table" then
                        local list = {}
                        for _, id in ipairs(nodes) do
                            local oki, info = pcall(p.getNodeInfo, id)
                            if oki and type(info) == "table" then
                                list[#list + 1] = {
                                    id = tostring(id),
                                    loaded = info.loaded == true,
                                    dimension = info.dimension,
                                    chunk_x = info.chunk_x,
                                    chunk_z = info.chunk_z,
                                    range = info.range,
                                    loaded_chunks = info.loaded_chunks,
                                }
                            else
                                -- ACL denied or node vanished: still show it
                                list[#list + 1] = {
                                    id = tostring(id), loaded = false,
                                }
                            end
                        end
                        wakeInfo = { type = ty, nodes = #nodes, nodeList = list }
                    else
                        wakeInfo = { type = ty, nodes = 0, nodeList = {} }
                    end
                else
                    -- wake_node / wake_node_advanced: full info
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

local function statusText()
    if not wakeInfo then return "computer" end
    if wakeInfo.type == "wake_controller" then
        return "controller (" .. tostring(wakeInfo.nodes or 0) .. " node(s))"
    end
    if wakeInfo.id and wakeInfo.id ~= "" then
        return "wake node " .. wakeInfo.id
    end
    return "wake node"
end

local gotWelcome = false   -- set once the server welcomes a session

-- Redstone output support (same surface as the turtle agent).
local redTimers = {}
local RS_SIDES = { "front", "back", "left", "right", "top", "bottom" }
local function normSide(s)
    s = tostring(s or "front"):lower()
    local map = { up = "top", down = "bottom", north = "front",
                  south = "back", east = "right", west = "left" }
    return map[s] or s
end
local function redSet(side, level)
    side = normSide(side)
    local lv = tonumber(level)
    local ok = pcall(function()
        if lv then
            if redstone.setAnalogOutput then
                redstone.setAnalogOutput(side, math.max(0, math.min(15, math.floor(lv))))
            else
                redstone.setOutput(side, lv > 0)
            end
        else
            local on = (level == true) or (level == nil) or
                (tostring(level):lower() == "true")
            redstone.setOutput(side, on)
        end
    end)
    return ok
end
local function redState()
    local out = {}
    for _, s in ipairs(RS_SIDES) do
        local ok, lv = pcall(function()
            return redstone.getAnalogOutput and redstone.getAnalogOutput(s) or
                (redstone.getOutput(s) and 15 or 0)
        end)
        out[s] = ok and tonumber(lv) or 0
    end
    return out
end

local function pushState()
    push({
        t = "state", name = NAME, label = os.getComputerLabel(),
        kind = "computer", status = statusText(),
        wake = wakeInfo,
        redstone = redState(),
        cid = CID,
    })
end

-- ------------------------------------------------------------------ net ---
local ws = nil
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

local function handleMessage(raw)
    local m = textutils.unserializeJSON(raw)
    if not m or type(m) ~= "table" then return end
    if m.t == "welcome" then
        pushState()
        flushOutbox()
    elseif m.t == "cmd" then
        -- computer units accept only redstone control; everything else is
        -- acked as unsupported so the server's pending table cannot leak
        local ok, msg, data = false, "unsupported command", nil
        local c, a = tostring(m.cmd or ""), m.args or {}
        if c == "setredstone" then
            ok, msg = redSet(a.side, a.level ~= nil and a.level or true)
            if ok then msg = "redstone " .. normSide(a.side) .. " set"
            else msg = "redstone API not available" end
        elseif c == "redpulse" then
            local secs = tonumber(a.secs) or 0.5
            if secs < 0.05 then secs = 0.05 elseif secs > 30 then secs = 30 end
            local side = normSide(a.side)
            redSet(side, a.level ~= nil and a.level or true)
            redTimers[os.startTimer(secs)] = { side = side, level = false }
            ok, msg = true, string.format("pulsing %s for %.2fs", side, secs)
        elseif c == "getredstone" then
            ok, msg, data = true, "ok", { redstone = redState() }
        end
        push({ t = "result", seq = m.seq, ok = ok, msg = msg, data = data })
        if ok then pushState() end
        flushOutbox()
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
        if e == "computer_flush" then
            if not flushOutbox() then return end
        elseif e == "timer" and redTimers[ev[2]] then
            local p = redTimers[ev[2]]
            redTimers[ev[2]] = nil
            redSet(p.side, p.level)
            pushState()
            if not flushOutbox() then return end
        elseif e == "timer" and ev[2] == timer then
            tick = tick + 1
            if tick % 10 == 0 then
                rescanWake()
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
          kind = "computer" }))
    local timer = os.startTimer(15)
    while true do
        local ev = { os.pullEvent() }
        local e = ev[1]
        if e == "websocket_message" and ev[2] == WS_URL then
            local m = textutils.unserializeJSON(ev[3])
            if m and m.t == "welcome" then
                gotWelcome = true
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
-- Quick tunnels get a fresh url on every server restart; the server re-bakes
-- this install file onto github then. After failed sessions re-read the
-- published file and adopt its URL/token (URL only - never code).
local INSTALL_URL =
    "https://raw.githubusercontent.com/ArcTechTech/TurtleTest/main/computer.lua"

local function refreshEndpoint()
    local ok, h = pcall(http.get, INSTALL_URL)
    if not ok or not h then return false end
    local okR, body = pcall(h.readAll)
    pcall(h.close)
    if not okR or not body then return false end
    local u = body:match('local%s+WS_URL%s*=%s*"([^"]+)"')
    local t = body:match('local%s+TOKEN%s*=%s*"([^"]+)"')
    local changed = false
    if u and u ~= "wss://variable-kid-def-saint.trycloudflare.com/computer" and u ~= WS_URL then
        WS_URL = u
        changed = true
    end
    if t and t ~= "447004d3aa68ca41" and t ~= TOKEN then
        TOKEN = t
        changed = true
    end
    if changed then
        log("endpoint refreshed -> " .. WS_URL, "ok")
        print("endpoint refreshed -> " .. WS_URL)
    end
    return changed
end

local function session()
    local w, err = http.websocket(WS_URL)
    if not w then error(tostring(err), 0) end
    ws = w
    gotWelcome = false
    waitForWelcome()
    reader()
end

-- ------------------------------------------------------------------ run --
print("Computer agent starting...")
print("server: " .. WS_URL)

local backoff = 1
while true do
    local ok, err = pcall(session)
    if ws then pcall(ws.close) end
    ws = nil
    outbox = {}
    if gotWelcome then
        -- reached the server: a mid-session drop starts a fresh failure streak
        backoff = 1
        sleep(ok and 0.5 or 0.25)
    else
        -- tunnel probably rotated: adopt the freshly baked url from github
        refreshEndpoint()
        printError(tostring(err or "connection closed"))
        log("disconnected: " .. tostring(err or "connection closed"), "error")
        sleep(backoff)
        backoff = math.min(backoff * 2, 10)
    end
end
