--[[
    RE4 LAN Co-op  v0.2.1  (Resident Evil 4 Remake, REFramework)

    Что умеет:
      * связь с вторым игроком по локальной сети (через re4lan_relay.py);
      * синхронизация дверей (chainsaw.GmDoor) по СОБЫТИЯМ: быстрый пробег через дверь
        тоже воспроизводится (открылась -> закрылась), копируется сторона открытия;
      * второй игрок рисуется проволочной фигурой (сглаженное движение, направление взгляда).
    Позже: враги, катсцены, лодка, настоящая модель второго игрока.

    Установка: см. start_host.bat / start_join.bat и инструкцию в чате.
      RE4LAN.lua -> <игра>/reframework/autorun/   (у обоих игроков)
]]

local NAME = "RE4LAN"
local PLAYER_OBJECT = "ch0a0z0_body"

local F_OUT, F_IN, F_STATUS, F_CFG = "RE4LAN_out.json", "RE4LAN_in.json", "RE4LAN_status.json", "RE4LAN_cfg.json"

local PUBLISH_EVERY   = 2     -- кадров между отправками позиции (~30 Гц при 60 fps)
local KEEPALIVE_EVERY = 60
local DOOR_EVERY      = 6     -- опрос дверей (кадров)
local DOOR_QUIET      = 90    -- после применения чужого события столько кадров не считаем изменение своим
local EVENT_SPACING   = 18    -- минимум кадров между двумя событиями ОДНОЙ двери у получателя
local EVENT_KEEP      = 300   -- сколько кадров событие повторно рассылается (защита от потерь)
local GHOST_STALE, GHOST_HIDE = 180, 900

---------------------------------------------------------------------------
-- Настройки
---------------------------------------------------------------------------
local cfg = {
    name = "Player", show_ghost = true, sync_doors = true,
    ghost_height = 1.75,
    open_method = 1,      -- 1: makeOpened (мгновенно)   2: setKickOpen (анимация, сторону выбирает игра)
    copy_dir = true,      -- экспериментально: копировать сторону открытия двери
}
local OPEN_METHODS = { "makeOpened (instant)", "setKickOpen (animated, side chosen by game)" }

local function load_cfg()
    local ok, t = pcall(json.load_file, F_CFG)
    if ok and type(t) == "table" then
        for k, v in pairs(t) do
            if cfg[k] ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end
        end
    end
    if cfg.open_method ~= 1 and cfg.open_method ~= 2 then cfg.open_method = 1 end
end
local function save_cfg() pcall(json.dump_file, F_CFG, cfg) end
load_cfg()

---------------------------------------------------------------------------
-- Состояние
---------------------------------------------------------------------------
local S = {
    frame = 0, out_seq = os.time(), in_seq = nil, in_primed = false,
    remote = nil, ghost = nil, link = nil, is_host = false,
    dirty = true, last_pub = -999, last_pub_try = -999, last_pub_pos = nil, last_pub_yaw = nil,
    last_pos = nil, last_yaw = nil, publish_fail = 0,
    -- двери
    world = {}, last = {}, applied_v = {}, quiet = {}, key_next = {}, pending = {}, defer_t = {},
    ev_base = os.time() * 1000, ev_n = 0, out_events = {}, peer_ev_last = nil, in_events = {},
    door_count = 0, door_mode = "-", slow_last = -9999, prefer_slow = false, fast_zero_since = nil,
    pass_ms = 0,
    stats = { local_changes = 0, applied = 0, reverts = 0, apply_fail = 0, events_rx = 0 },
    log = {}, test_toggle = false,
    -- частота обмена
    rx_n = 0, tx_n = 0, rx_hz = 0, tx_hz = 0, fps = 0, rate_frame = 0, rate_time = os.time(),
}

local function r2(x) return math.floor(x * 100 + 0.5) / 100 end
local function log_ev(s)
    table.insert(S.log, 1, s)
    while #S.log > 8 do table.remove(S.log) end
end

---------------------------------------------------------------------------
-- Доступ к игре
---------------------------------------------------------------------------
local scene_manager, scene_manager_td
local function get_scene()
    if not scene_manager then
        scene_manager = sdk.get_native_singleton("via.SceneManager")
        scene_manager_td = sdk.find_type_definition("via.SceneManager")
    end
    if not scene_manager then return nil end
    return sdk.call_native_func(scene_manager, scene_manager_td, "get_CurrentScene")
end

local function typeof(n)
    if sdk.typeof then return sdk.typeof(n) end
    return _G.typeof(n)
end

local function player_xf()
    local scene = get_scene()
    if not scene then return nil end
    local ok, go = pcall(function() return scene:call("findGameObject(System.String)", PLAYER_OBJECT) end)
    if not ok or not go then return nil end
    local ok2, xf = pcall(function() return go:call("get_Transform") end)
    if ok2 then return xf end
    return nil
end

---------------------------------------------------------------------------
-- Двери: поиск и чтение
---------------------------------------------------------------------------
local function type_name(obj)
    local ok, n = pcall(function() return obj:get_type_definition():get_full_name() end)
    if ok and n then return tostring(n) end
    return "?"
end

local function find_doors_slow(scene)
    local out = {}
    pcall(function()
        local xf = scene:call("get_FirstTransform")
        local guard = 0
        while xf ~= nil and guard < 200000 do
            guard = guard + 1
            pcall(function()
                local arr = xf:call("get_GameObject"):call("get_Components")
                for _, c in ipairs(arr:get_elements()) do
                    if type_name(c) == "chainsaw.GmDoor" then out[#out + 1] = c end
                end
            end)
            local ok, nxt = pcall(function() return xf:call("get_Next") end)
            if not ok then break end
            xf = nxt
        end
    end)
    return out
end

-- Свежий список GmDoor (указатели между проходами не храним: объекты могут выгружаться)
local function find_doors()
    local scene = get_scene()
    if not scene then return nil end

    if not S.prefer_slow then
        local ok, arr = pcall(function()
            return scene:call("findComponents(System.Type)", typeof("chainsaw.GmDoor"))
        end)
        if ok and arr ~= nil then
            local ok2, el = pcall(function() return arr:get_elements() end)
            if ok2 and type(el) == "table" then
                S.door_mode = "fast"
                if #el > 0 then S.fast_zero_since = nil; return el end
                S.fast_zero_since = S.fast_zero_since or S.frame
                if S.frame - S.fast_zero_since < 600 then return el end
                S.fast_zero_since = S.frame
                local slow = find_doors_slow(scene)
                if #slow > 0 then
                    S.prefer_slow, S.door_mode = true, "slow"
                    return slow
                end
                return el
            end
        end
    end

    if S.frame - S.slow_last < 240 then return nil end
    S.slow_last = S.frame
    S.door_mode = "slow"
    return find_doors_slow(scene)
end

local function door_key(c)
    local ok, key = pcall(function()
        local go = c:call("get_GameObject")
        local p = go:call("get_Transform"):call("get_Position")
        return string.format("%s|%.1f|%.1f|%.1f", tostring(go:call("get_Name")),
            p.x + 0.0, p.y + 0.0, p.z + 0.0)
    end)
    if ok then return key end
    return nil
end

-- Открыта ли дверь: IsOpen ИЛИ рутина не "закрыта" (в покое у всех дверей Routine = 0)
local function door_state(c)
    local ok, v = pcall(function() return c:call("get_IsOpen") end)
    local open = (ok and v == true)
    local ok2, rt = pcall(function() return c:get_field("_Routine") end)
    if ok2 and type(rt) == "number" and rt ~= 0 then open = true end
    if not ok and not ok2 then return nil end
    return open
end

-- Сторона открытия: знак _CurRot (-1 / 0 / 1)
local function door_dir(c)
    local ok, cr = pcall(function() return c:get_field("_CurRot") end)
    if ok and type(cr) == "number" then
        if cr > 0.05 then return 1 elseif cr < -0.05 then return -1 end
        return 0
    end
    return nil
end

local function door_apply(c, open, dir)
    local ok = pcall(function()
        if open then
            if cfg.open_method == 2 then
                c:call("setKickOpen")
            else
                if cfg.copy_dir and dir and dir ~= 0 then
                    pcall(function() c:set_field("IsKickOpenSideA", dir > 0) end)
                end
                c:call("makeOpened")
            end
        else
            c:call("makeClosed")
        end
    end)
    if ok and open and cfg.open_method == 1 and cfg.copy_dir and dir and dir ~= 0 then
        pcall(function()
            local ro = c:get_field("RotOpen")
            if type(ro) ~= "number" or ro <= 0 then ro = 1.57 end
            c:set_field("_CurRot", dir * ro)
        end)
    end
    return ok
end

local function short(key) return (key:match("^[^|]+") or key):sub(1, 30) end

local function push_event(key, s, v, d)
    S.ev_n = S.ev_n + 1
    S.out_events[#S.out_events + 1] = { id = S.ev_base + S.ev_n, k = key, s = s and 1 or 0, v = v, d = d or 0, f = S.frame }
end

local function door_pass()
    if not cfg.sync_doors then return end
    local t0 = os.clock()
    local list = find_doors()
    if not list then return end
    S.door_count = #list

    local by_key, state = {}, {}
    for _, c in ipairs(list) do
        local key = door_key(c)
        if key then
            local cur = door_state(c)
            if cur ~= nil then by_key[key] = c; state[key] = cur end
        end
    end

    -- 1) Воспроизводим события второго игрока по порядку
    if #S.in_events > 0 then
        local keep, blocked = {}, {}
        for _, e in ipairs(S.in_events) do
            local c = by_key[e.key]
            if c == nil then
                S.pending[e.key] = math.max(0, (S.pending[e.key] or 1) - 1)   -- двери нет в сцене: применится позже по снимку
            elseif blocked[e.key] or (S.key_next[e.key] or 0) > S.frame then
                blocked[e.key] = true
                keep[#keep + 1] = e
            else
                local av = S.applied_v[e.key] or 0
                if e.v > av or (e.v == av and not S.is_host) then
                    if state[e.key] ~= e.s then
                        if door_apply(c, e.s, e.d) then
                            S.stats.applied = S.stats.applied + 1
                            log_ev(string.format("remote: %s -> %s (v%d dir%d)", short(e.key), e.s and "open" or "closed", e.v, e.d or 0))
                        else
                            S.stats.apply_fail = S.stats.apply_fail + 1
                            log_ev("APPLY FAILED: " .. short(e.key))
                        end
                        state[e.key] = e.s
                    end
                    S.applied_v[e.key] = math.max(av, e.v)
                    S.last[e.key] = e.s
                    S.quiet[e.key] = S.frame + DOOR_QUIET
                end
                S.key_next[e.key] = S.frame + EVENT_SPACING
                S.pending[e.key] = math.max(0, (S.pending[e.key] or 1) - 1)
            end
        end
        S.in_events = keep
    end

    -- 2) Свои изменения и страховка по снимку мира
    for key, cur in pairs(state) do
        local c = by_key[key]
        if S.last[key] == nil then S.last[key] = cur end
        local last = S.last[key]
        local quiet = (S.quiet[key] or 0) > S.frame
        local busy = (S.pending[key] or 0) > 0

        if cur ~= last and not busy then
            if quiet then
                S.last[key] = cur
                S.stats.reverts = S.stats.reverts + 1
            else
                local dir, defer = nil, false
                if cur then
                    dir = door_dir(c)
                    if dir == 0 then
                        -- дверь только начала открываться: ждём пару кадров, чтобы узнать сторону
                        S.defer_t[key] = S.defer_t[key] or S.frame
                        if S.frame - S.defer_t[key] < 12 then defer = true else dir = nil end
                    end
                end
                if not defer then
                    S.defer_t[key] = nil
                    S.last[key] = cur
                    local w = S.world[key]
                    local v = (w and w.v or 0) + 1
                    S.world[key] = { s = cur, v = v, d = dir or 0 }
                    S.applied_v[key] = v
                    push_event(key, cur, v, dir)
                    S.dirty = true
                    S.stats.local_changes = S.stats.local_changes + 1
                    log_ev(string.format("local: %s -> %s (v%d dir%d)", short(key), cur and "open" or "closed", v, dir or 0))
                end
            end
        elseif cur == last and not busy then
            S.defer_t[key] = nil
            local w = S.world[key]
            if w and w.v > (S.applied_v[key] or 0) then
                if w.s ~= cur then
                    if door_apply(c, w.s, w.d) then
                        S.stats.applied = S.stats.applied + 1
                        S.quiet[key] = S.frame + DOOR_QUIET
                        log_ev(string.format("sync: %s -> %s (v%d)", short(key), w.s and "open" or "closed", w.v))
                    else
                        S.stats.apply_fail = S.stats.apply_fail + 1
                    end
                end
                S.last[key] = w.s
                S.applied_v[key] = w.v
            end
        end
    end
    S.pass_ms = r2((os.clock() - t0) * 1000)
end

-- Снимок мира от второго игрока (для дверей, загруженных позже)
local function merge_world(doors)
    for key, e in pairs(doors) do
        if type(key) == "string" and type(e) == "table" and type(e.v) == "number" and e.s ~= nil then
            local s = (e.s == true or e.s == 1)
            local w = S.world[key]
            if not w or e.v > w.v then
                S.world[key] = { s = s, v = e.v, d = e.d or 0 }
            elseif e.v == w.v and w.s ~= s and not S.is_host then
                S.world[key] = { s = s, v = e.v, d = e.d or 0 }
                S.applied_v[key] = e.v - 1
            end
        end
    end
end

-- События второго игрока: дедупликация по id, постановка в очередь
local function receive_events(ev)
    local list = {}
    for _, e in ipairs(ev) do
        if type(e) == "table" and type(e.id) == "number" and type(e.k) == "string"
            and (S.peer_ev_last == nil or e.id > S.peer_ev_last) then
            list[#list + 1] = e
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    for _, e in ipairs(list) do
        S.peer_ev_last = e.id
        local s = (e.s == 1 or e.s == true)
        local v = tonumber(e.v) or 0
        S.in_events[#S.in_events + 1] = { key = e.k, s = s, v = v, d = tonumber(e.d) or 0 }
        S.pending[e.k] = (S.pending[e.k] or 0) + 1
        S.stats.events_rx = S.stats.events_rx + 1
        local w = S.world[e.k]
        if not w or v > w.v then S.world[e.k] = { s = s, v = v, d = tonumber(e.d) or 0 } end
    end
end

local function doors_payload()
    local t = {}
    for key, w in pairs(S.world) do t[key] = { s = w.s and 1 or 0, v = w.v, d = w.d or 0 } end
    return t
end

local function events_payload()
    local keep, out = {}, {}
    for _, e in ipairs(S.out_events) do
        if S.frame - e.f < EVENT_KEEP then
            keep[#keep + 1] = e
            out[#out + 1] = { id = e.id, k = e.k, s = e.s, v = e.v, d = e.d }
        end
    end
    S.out_events = keep
    return out
end

local function test_toggle_nearest()
    local list = find_doors()
    if not list or not S.last_pos then log_ev("test: no doors or no player"); return end
    local best, bd
    for _, c in ipairs(list) do
        local ok, p = pcall(function() return c:call("get_GameObject"):call("get_Transform"):call("get_Position") end)
        if ok and p then
            local dx, dy, dz = p.x - S.last_pos[1], p.y - S.last_pos[2], p.z - S.last_pos[3]
            local d = dx * dx + dy * dy + dz * dz
            if not bd or d < bd then best, bd = c, d end
        end
    end
    if not best then return end
    local cur = door_state(best)
    if cur == nil then log_ev("test: cannot read door state"); return end
    local ok = door_apply(best, not cur, nil)
    log_ev(string.format("test: nearest door %.1fm -> %s (%s)", math.sqrt(bd), (not cur) and "open" or "closed", ok and "ok" or "FAILED"))
end

---------------------------------------------------------------------------
-- Обмен с ретранслятором
---------------------------------------------------------------------------
-- Читаем игру ДО решения об отправке. Иначе last_pos обновляется только в publish,
-- всегда равна last_pub_pos, и движение отправляется лишь по keepalive.
local function sample_player()
    local pos, yaw
    local xf = player_xf()
    if xf then
        local ok = pcall(function()
            local p = xf:call("get_Position")
            local q = xf:call("get_Rotation")
            pos = { r2(p.x), r2(p.y), r2(p.z) }
            yaw = r2(math.atan(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.z * q.z)))
        end)
        if not ok then pos, yaw = nil, nil end
    end
    S.last_pos, S.last_yaw = pos, yaw
end

local function publish()
    local pos, yaw = S.last_pos, S.last_yaw
    S.last_pub_try = S.frame
    S.out_seq = S.out_seq + 1
    local ok, result = pcall(json.dump_file, F_OUT, {
        seq = S.out_seq, name = cfg.name, pos = pos, yaw = yaw,
        doors = doors_payload(), ev = events_payload(),
    })
    if not ok or result == false then
        S.publish_fail = S.publish_fail + 1
        S.dirty = true
        return
    end
    S.tx_n = S.tx_n + 1
    S.last_pub, S.last_pub_pos, S.last_pub_yaw, S.dirty = S.frame, pos, yaw, false
end

local function moved_enough()
    local p = S.last_pos
    if not p then return S.last_pub_pos ~= nil end
    if not S.last_pub_pos then return true end
    local dx, dy, dz = p[1] - S.last_pub_pos[1], p[2] - S.last_pub_pos[2], p[3] - S.last_pub_pos[3]
    if (dx * dx + dy * dy + dz * dz) > 0.0001 then return true end
    -- Поворот на месте тоже меняет позу. Угол сравниваем через границу -pi/+pi.
    if S.last_yaw ~= nil and S.last_pub_yaw ~= nil then
        local dy = S.last_yaw - S.last_pub_yaw
        return math.abs(math.atan(math.sin(dy), math.cos(dy))) > 0.01
    end
    return S.last_yaw ~= S.last_pub_yaw
end

-- Сглаживание: запоминаем цель и скорость
local function ghost_update(pos, yaw)
    local g = S.ghost
    if not g then
        S.ghost = { pos = { pos[1], pos[2], pos[3] }, tgt = { pos[1], pos[2], pos[3] }, vel = { 0, 0, 0 },
                    yaw = yaw or 0, tyaw = yaw or 0, f = S.frame }
        return
    end
    local df = math.max(1, S.frame - g.f)
    for i = 1, 3 do
        local v = (pos[i] - g.tgt[i]) / df
        if v > 0.5 then v = 0.5 elseif v < -0.5 then v = -0.5 end
        g.vel[i] = v
        g.tgt[i] = pos[i]
    end
    g.tyaw = yaw or g.tyaw
    g.f = S.frame
    local dx, dy, dz = g.pos[1] - pos[1], g.pos[2] - pos[2], g.pos[3] - pos[3]
    if dx * dx + dy * dy + dz * dz > 36 then   -- телепорт далеко: не плывём
        g.pos = { pos[1], pos[2], pos[3] }
        g.vel = { 0, 0, 0 }
    end
end

local function poll_inbox()
    local ok, obj = pcall(json.load_file, F_IN)
    if not ok or type(obj) ~= "table" or type(obj.seq) ~= "number" then return end
    if not S.in_primed then
        S.in_primed, S.in_seq = true, obj.seq   -- остаток прошлой сессии игнорируем
        return
    end
    if obj.seq == S.in_seq then return end
    S.in_seq = obj.seq
    S.rx_n = S.rx_n + 1
    local d = obj.d
    if type(d) ~= "table" then return end
    if type(d.pos) == "table" and #d.pos == 3 then
        S.remote = { name = tostring(d.name or "Player"), pos = d.pos, yaw = d.yaw, frame = S.frame }
        ghost_update(d.pos, tonumber(d.yaw))
    else
        S.remote, S.ghost = nil, nil
    end
    if type(d.doors) == "table" then merge_world(d.doors) end
    if type(d.ev) == "table" then receive_events(d.ev) end
end

local function poll_status()
    local ok, obj = pcall(json.load_file, F_STATUS)
    if ok and type(obj) == "table" then
        S.link = obj
        S.is_host = (obj.role == "host")
    end
end

local function relay_alive()
    return S.link ~= nil and type(S.link.t) == "number" and S.link.t > 0 and (os.time() - S.link.t) < 4
end

---------------------------------------------------------------------------
-- Второй игрок: проволочная фигура
---------------------------------------------------------------------------
local function proj(x, y, z)
    local ok, v = pcall(function() return draw.world_to_screen(Vector3f.new(x, y, z)) end)
    if ok then return v end
    return nil
end

local function draw_ghost()
    local g, r = S.ghost, S.remote
    if not cfg.show_ghost or not g or not r then return end
    local age = S.frame - r.frame
    if age > GHOST_HIDE then return end

    -- сглаживание: тянемся к цели + экстраполяция по скорости
    local ext = math.min(age, 6)
    for i = 1, 3 do
        g.pos[i] = g.pos[i] + ((g.tgt[i] + g.vel[i] * ext) - g.pos[i]) * 0.35
    end
    local dy = math.atan(math.sin(g.tyaw - g.yaw), math.cos(g.tyaw - g.yaw))
    g.yaw = g.yaw + dy * 0.35

    local x0, y0, z0 = g.pos[1], g.pos[2], g.pos[3]
    local sy, cy = math.sin(g.yaw), math.cos(g.yaw)
    local fx, fz = sy, cy        -- вперёд
    local rx, rz = cy, -sy       -- вправо
    local k = cfg.ghost_height / 1.75
    -- точка в системе координат фигуры: (вправо, вверх, вперёд)
    local function P(a, b, c)
        return proj(x0 + rx * a * k + fx * c * k, y0 + b * k, z0 + rz * a * k + fz * c * k)
    end

    local col = (age > GHOST_STALE) and 0xFF909090 or 0xFF40C8FF
    local function L(p, q)
        if p and q then pcall(function() draw.line(p.x, p.y, q.x, q.y, col) end) end
    end

    local head, neck, hip = P(0, 1.62, 0), P(0, 1.45, 0), P(0, 0.95, 0)
    local shl, shr = P(-0.22, 1.42, 0), P(0.22, 1.42, 0)
    local ell, elr = P(-0.30, 1.15, 0.05), P(0.30, 1.15, 0.05)
    local hl, hr = P(-0.28, 0.92, 0.18), P(0.28, 0.92, 0.18)
    local hipl, hipr = P(-0.12, 0.95, 0), P(0.12, 0.95, 0)
    local knl, knr = P(-0.12, 0.50, 0.04), P(0.12, 0.50, 0.04)
    local ftl, ftr = P(-0.12, 0.02, 0.08), P(0.12, 0.02, 0.08)
    local nose = P(0, 1.62, 0.35)

    L(neck, hip); L(shl, shr); L(shl, ell); L(ell, hl); L(shr, elr); L(elr, hr)
    L(hipl, hipr); L(hipl, knl); L(knl, ftl); L(hipr, knr); L(knr, ftr)
    L(head, nose)
    if head then
        pcall(function() draw.filled_circle(head.x, head.y, 9, col, 16) end)
    end

    local top = P(0, 1.95, 0)
    if top then
        local label = r.name
        if S.last_pos then
            local ddx, ddy, ddz = g.pos[1] - S.last_pos[1], g.pos[2] - S.last_pos[2], g.pos[3] - S.last_pos[3]
            label = string.format("%s  %.0f m", label, math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz))
        end
        if age > GHOST_STALE then label = label .. "  (no signal)" end
        pcall(function() draw.text(label, top.x - 40, top.y - 14, col) end)
    end
end

---------------------------------------------------------------------------
-- Главный цикл
---------------------------------------------------------------------------
local function on_frame_impl()
    S.frame = S.frame + 1

    poll_inbox()
    if S.frame % 30 == 0 then poll_status() end
    if S.frame % DOOR_EVERY == 3 then door_pass() end

    if S.test_toggle then
        S.test_toggle = false
        test_toggle_nearest()
    end

    local since = S.frame - S.last_pub
    if S.frame - S.last_pub_try >= PUBLISH_EVERY then
        sample_player()
        if S.dirty or moved_enough() or since >= KEEPALIVE_EVERY then publish() end
    end

    -- частота обмена раз в секунду (по реальному времени)
    local now = os.time()
    if now > S.rate_time then
        local dt = now - S.rate_time
        S.rx_hz, S.tx_hz = math.floor(S.rx_n / dt + 0.5), math.floor(S.tx_n / dt + 0.5)
        S.fps = math.floor((S.frame - S.rate_frame) / dt + 0.5)
        S.rx_n, S.tx_n, S.rate_time, S.rate_frame = 0, 0, now, S.frame
    elseif now < S.rate_time then
        S.rx_n, S.tx_n, S.rate_time, S.rate_frame = 0, 0, now, S.frame
    end

    draw_ghost()

    pcall(function()
        local txt, col
        if not relay_alive() then
            txt, col = "RE4LAN: relay offline", 0xFF4040FF
        elseif S.link.connected then
            txt, col = string.format("RE4LAN: connected  %s  %.0fms", S.remote and S.remote.name or "-", S.link.ping_ms or -1), 0xFF40FF40
        else
            txt, col = "RE4LAN: waiting for partner...", 0xFF40C8FF
        end
        draw.text(txt, 24, 64, col)
    end)
end

re.on_frame(function()
    local ok, err = pcall(on_frame_impl)
    if not ok and (S.frame % 300 == 0) then
        log.info("[" .. NAME .. "] frame error: " .. tostring(err))
    end
end)

re.on_script_reset(function() pcall(json.dump_file, F_OUT, { seq = 0 }) end)

---------------------------------------------------------------------------
-- Меню REFramework
---------------------------------------------------------------------------
re.on_draw_ui(function()
    if not imgui.tree_node("RE4 LAN Co-op") then return end

    imgui.text("RE4LAN v0.2.1 | movement publication fix")

    local changed
    changed, cfg.name = imgui.input_text("Your name", cfg.name)
    if changed then save_cfg() end

    if not relay_alive() then
        imgui.text("Relay: OFFLINE. Start start_host.bat / start_join.bat")
    else
        local l = S.link
        imgui.text(string.format("Relay: %s | %s | ping %s ms | tx %d rx %d | write fails %d",
            tostring(l.role), l.connected and "CONNECTED" or "waiting",
            tostring(l.ping_ms or "-"), l.tx or 0, l.rx or 0, l.wfail or 0))
    end
    imgui.text(string.format("Partner: %s | Lua file writes %d Hz, reads %d Hz | FPS ~%d | write fails %d",
        S.remote and S.remote.name or "-", S.tx_hz, S.rx_hz, S.fps, S.publish_fail))
    local l = S.link
    if relay_alive() and type(l.out_hz) == "number" then
        imgui.text(string.format("Relay: Lua out %.1f Hz | network in %.1f Hz | Lua gap %.0f ms | remote age %.0f ms",
            l.out_hz, l.in_hz or 0, l.out_gap_ms or 0, l.in_age_ms or -1))
    else
        imgui.text("Relay rates unavailable: use re4lan_relay.py v0.2.1")
    end

    imgui.spacing()
    changed, cfg.show_ghost = imgui.checkbox("Show partner figure", cfg.show_ghost)
    if changed then save_cfg() end
    changed, cfg.sync_doors = imgui.checkbox("Sync doors", cfg.sync_doors)
    if changed then save_cfg() end
    changed, cfg.copy_dir = imgui.checkbox("Door: copy open side (experimental)", cfg.copy_dir)
    if changed then save_cfg() end
    changed, cfg.open_method = imgui.combo("Door open method", cfg.open_method, OPEN_METHODS)
    if changed then save_cfg() end
    changed, cfg.ghost_height = imgui.drag_float("Figure height (m)", cfg.ghost_height, 0.01, 1.0, 2.5)
    if changed then save_cfg() end

    imgui.spacing()
    local n = 0
    for _ in pairs(S.world) do n = n + 1 end
    imgui.text(string.format("Doors: %d found (%s search, pass %.2f ms) | synced states: %d | queued events: %d",
        S.door_count, S.door_mode, S.pass_ms, n, #S.in_events))
    imgui.text(string.format("Local changes %d | events received %d | applied %d | reverted by game %d | failed %d",
        S.stats.local_changes, S.stats.events_rx, S.stats.applied, S.stats.reverts, S.stats.apply_fail))

    if imgui.button("TEST: toggle nearest door") then S.test_toggle = true end
    imgui.same_line()
    if imgui.button("Reset synced doors") then
        S.world, S.last, S.applied_v, S.quiet, S.key_next, S.pending, S.in_events, S.defer_t = {}, {}, {}, {}, {}, {}, {}, {}
        S.dirty = true
    end

    if #S.log > 0 then
        imgui.text("Recent events:")
        for _, line in ipairs(S.log) do imgui.text("  " .. line) end
    end
    imgui.tree_pop()
end)
