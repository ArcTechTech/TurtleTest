-- Wake Node keeper for ComputerCraft Wake Nodes (ccwake).
--
-- Install:   wget https://raw.githubusercontent.com/ArcTechTech/TurtleTest/
--            main/wake.lua startup   + reboot
--
-- Run this on a computer adjacent to a wake_controller. It force-loads every
-- registered wake node and keeps them loaded - the chunk tickets the mod
-- hands out do NOT survive a server restart (registrations do), so without
-- a keeper the whole fleet's work areas go dark on the first reboot and
-- every turtle parked there stops ticking (offline in the HUD until someone
-- walks over). This is the same self-heal pattern the hud agents use, just
-- driven by a timer instead of a websocket.
--
-- Setup, once, in-game:
--   1. place a wake_node (or wake_node_advanced) against a stationary
--      computer at the area to keep awake - the mod refuses turtle blocks,
--      so the anchor must be a regular computer.
--   2. on that node computer:   local w = peripheral.find("wake_node")
--                               w.setId("my_area")
--                               w.grantController(<this computer's id>)
--      this program prints its own computer id on boot to make step 2 easy.
--   3. reboot this computer; it loads everything it can see from now on.
--
-- There is no websocket / token here: chunk loading is purely in-game, so
-- this program works even while the turtle-hud server is down.

local INTERVAL = 30     -- seconds between reconciles

local args = { ... }
if args[1] then
    local n = tonumber(args[1])
    if n and n >= 5 then INTERVAL = n end
end

local function findController()
    while true do
        local ok, p = pcall(peripheral.find, "wake_controller")
        if ok and p then return p end
        print("wake: no wake_controller beside this computer, retrying...")
        sleep(5)
    end
end

-- ids we already complained about, so a permanently failing node (auth /
-- max_loaded_nodes) prints once instead of every reconcile
local reported = {}

local function loadNode(ctl, id)
    local okL, loaded = pcall(ctl.isNodeLoaded, id)
    if okL and loaded then
        reported[id] = nil
        return
    end
    local ok, err = pcall(ctl.loadNode, id)
    if ok then
        reported[id] = nil
        print("wake: loaded " .. id)
    else
        local msg = tostring(err)
        if not reported[id] then
            reported[id] = true
            print("wake: FAILED " .. id .. ": " .. msg)
            if msg:find("authoriz", 1, true) or
               msg:find("permission", 1, true) then
                print("wake: run on the node computer: " ..
                      'peripheral.find("wake_node").grantController(' ..
                      tostring(os.getComputerID()) .. ")")
            end
        end
    end
end

local function reconcile(ctl)
    local ok, nodes = pcall(ctl.listNodes)
    if not ok then
        print("wake: controller lost: " .. tostring(nodes))
        return false
    end
    for _, id in ipairs(nodes) do
        loadNode(ctl, id)
    end
    return true
end

print("wake: keeper starting on computer id " ..
      tostring(os.getComputerID()) ..
      " (interval " .. INTERVAL .. "s)")

local ctl = findController()
print("wake: wake_controller found")
reconcile(ctl)

local timer = os.startTimer(INTERVAL)
while true do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "timer" and ev[2] == timer then
        if not reconcile(ctl) then
            ctl = findController()
            print("wake: wake_controller re-acquired")
            reconcile(ctl)
        end
        timer = os.startTimer(INTERVAL)
    elseif e == "peripheral_detach" then
        -- controller block broken / computer moved: detect on next tick
        -- by failing a reconcile, then re-find
        timer = os.startTimer(1)
    elseif e == "peripheral" then
        timer = os.startTimer(1)
    end
end
