--[[
    RE4MP Scout v4 — разведчик для ко-оп мода (Resident Evil 4 Remake, REFramework).

    v4: нужные enum/структуры выгружаются до общего лимита, добавлены живые контексты
    персонажей и отчёт о недоступных типах/полях. Нужен скан с меткой api4 в деревне.

    Скрипт ТОЛЬКО ЧИТАЕТ игру и ничего в ней не меняет. Он обходит все объекты сцены и
    сохраняет отчёт в JSON: типы компонентов, примеры объектов, API (методы/поля) важных
    классов и ТЕКУЩИЕ ЗНАЧЕНИЯ полей ближайших к тебе дверей/гимиков/врагов.

    Что исправлено в v2: в v1 методы и поля выгружались пустыми (REFramework отдаёт их
    не Lua-таблицей), и список менеджеров-синглтонов был неполным.

    Установка: заменить старый файл в  <игра>/reframework/autorun/RE4MP_Scout.lua
    Использование: F8 в игре (или меню REFramework -> RE4MP Scout -> Scan now).
    Отчёт: <игра>/reframework/data/RE4MP_scout_<метка>.json
    Метку пиши в поле "Label" ПЕРЕД нажатием F8.

    Нужные сканы (стой РЯДОМ с дверью, лучше ближе 3 метров):
      1) api          — где угодно (методы/поля классов; достаточно одного раза);
      2) door_closed  — рядом с ЗАКРЫТОЙ обычной дверью (до её открытия);
      3) door_open    — та же дверь, но ты её открыл (стоишь на том же месте);
      4) ladder_*     — по желанию: то же для лестницы/окна/ящика (до и после).
]]

local SCRIPT_NAME = "RE4MP_Scout"
local VK_F8 = 0x77

local MAX_OBJECTS     = 200000
local SAMPLES         = 3
local API_TYPES_MAX   = 70     -- сколько "ключевых" типов со сцены выгружать
local API_METHODS_MAX = 80
local API_FIELDS_MAX  = 60
local PRIO_METHODS_MAX = 300   -- для приоритетных типов и синглтонов
local PRIO_FIELDS_MAX  = 150
local RELATED_TYPES_MAX = 600
local DETAIL_NEAREST   = 25    -- сколько ближайших объектов каждого типа читать со значениями полей
local DETAIL_FIELDS_MAX = 90

local KEYWORDS = {
    "door", "gimmick", "boat", "jetski", "enemy", "cutscene", "timeline", "event", "character",
    "player", "ashley", "partner", "npc", "damage", "health", "hitpoint", "weapon",
    "inventory", "item", "save", "merchant", "mount", "vehicle", "ladder", "elevator",
    "trap", "switch", "lock", "key", "spawn", "synchro", "sequence", "demo", "movie",
    "flag", "scenario", "coop", "network", "railcar", "chapter", "stage",
}

-- Эти типы выгружаем ВСЕГДА (если существуют), с расширенным лимитом
local PRIORITY_TYPES = {
    "chainsaw.CharacterManager", "chainsaw.GimmickManager", "chainsaw.GimmickCore",
    "chainsaw.GimmickLite", "chainsaw.InteractHolder", "chainsaw.GmDoor", "chainsaw.GmBigDoor",
    "chainsaw.GmMotionDoor", "chainsaw.GmBreakDoor", "chainsaw.GmLocker", "chainsaw.GmWindow",
    "chainsaw.GmLeaningLadder", "chainsaw.GmUprightLadder", "chainsaw.GmSavePoint",
    "chainsaw.GmCoopMoveUp", "chainsaw.CoopMediatorBehavior", "chainsaw.CoopMediator",
    "chainsaw.ScenarioFlagManager", "chainsaw.ScenarioFlagManagerBehavior",
    "chainsaw.SetFlagSettings", "chainsaw.CheckFlagSettings",
    "chainsaw.TimelineEventMediator", "chainsaw.TimelineEventMediatorBehavior",
    "chainsaw.TimelineEventScheduler", "chainsaw.AppEventManager", "chainsaw.AppEventManagerBehavior",
    "chainsaw.EventSceneFolderController", "chainsaw.TimelineEventActorPlayer",
    "chainsaw.TimelineEventCharaBody", "chainsaw.MovieMediator", "chainsaw.RealTimeTimelineMediator",
    "chainsaw.JetSkiManager", "chainsaw.JetSkiManagerBehavior", "chainsaw.RailCarManager",
    "chainsaw.CustomGmJeep", "chainsaw.CharacterSpawnController", "chainsaw.CharacterContext",
    "chainsaw.PlayerContext", "chainsaw.EnemyContext", "chainsaw.PartnerControlParamHolder",
    "chainsaw.Ch0a0z0BodyUpdater", "chainsaw.Ch1c0z0BodyUpdater", "chainsaw.Ch1c0z0Parameter",
    "chainsaw.EnemyCommonParameter", "chainsaw.HateController", "chainsaw.NetworkManager",
    "chainsaw.NetworkManagerBehavior", "chainsaw.ItemManager", "chainsaw.InventoryManager",
    "chainsaw.SaveDataManager", "chainsaw.StageManager", "chainsaw.CampaignManager",
    "chainsaw.CharacterManagerBehavior", "chainsaw.AutoWalkCharacter",
}

-- Для этих компонентов читаем ТЕКУЩИЕ значения полей (ближайшие к игроку экземпляры)
local DETAIL_TYPES = {
    "chainsaw.GmDoor", "chainsaw.GmBigDoor", "chainsaw.GmMotionDoor", "chainsaw.GmBreakDoor",
    "chainsaw.GmLocker", "chainsaw.GmWindow", "chainsaw.GmLeaningLadder", "chainsaw.GmUprightLadder",
    "chainsaw.GimmickCore", "chainsaw.InteractHolder",
    "chainsaw.Ch0a0z0BodyUpdater", "chainsaw.Ch1c0z0BodyUpdater", "chainsaw.Ch1c0z0Parameter",
}

local SINGLETON_CANDIDATES = {
    "chainsaw.CharacterManager", "chainsaw.EnemyManager", "chainsaw.GimmickManager",
    "chainsaw.CameraManager", "chainsaw.CutSceneManager", "chainsaw.EventManager",
    "chainsaw.GameStatusManager", "chainsaw.SaveDataManager", "chainsaw.ItemManager",
    "chainsaw.InventoryManager", "chainsaw.SceneManager", "chainsaw.StageManager",
}

-- Эти типы не должны теряться из-за сортировки и общего лимита зависимостей.
local REQUIRED_TYPES = {
    "chainsaw.GmGateBase.DoorSide", "chainsaw.GmDoorBase.DoorOpenOption",
    "chainsaw.GmDoor.RoutineType", "chainsaw.GmGateBase", "chainsaw.CharacterKindID",
    "chainsaw.ContextID", "chainsaw.Context", "chainsaw.CharacterUsePurposeFlag",
    "chainsaw.CharacterControlIndex", "chainsaw.CharacterManager.PlayerNo",
    "chainsaw.CharacterManager.PlayerKind", "chainsaw.CharacterManager.ControlTargetInfo",
    "chainsaw.StageIdentifier", "chainsaw.TimelineEventDefine.ID",
    "chainsaw.TimelineEventPlayerInfo", "chainsaw.AppEventDefine.RequestEntry",
    "chainsaw.EnemyBaseContext", "chainsaw.PlayerManager", "chainsaw.EnemyManager",
    "chainsaw.CharacterInstanceCoordinator", "chainsaw.CharacterLinkCoordinator",
}

local S = {
    label = "scan", status = "idle", pending = false, f8_prev = false, toast = nil, count = 0,
}

---------------------------------------------------------------------------
-- Вспомогательные функции
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

local function type_name(obj)
    local ok, n = pcall(function() return obj:get_type_definition():get_full_name() end)
    if ok and n then return tostring(n) end
    return "?"
end

local function r2(x) return math.floor(x * 100 + 0.5) / 100 end

local function vec(v)
    if v == nil then return nil end
    local ok, t = pcall(function() return { r2(v.x), r2(v.y), r2(v.z) } end)
    if ok then return t end
    return nil
end

local function dist(a, b)
    if not a or not b then return 1e9 end
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function matches_keyword(name)
    local low = name:lower()
    for _, k in ipairs(KEYWORDS) do
        if low:find(k, 1, true) then return true end
    end
    return false
end

local function safe_label(s)
    s = tostring(s or ""):gsub("[^%w_%-]", "_")
    if s == "" then s = "scan" end
    return s
end

-- REFramework отдаёт списки методов/полей не всегда Lua-таблицей — обходим любой вариант
local function to_list(x)
    local out = {}
    if x == nil then return out end
    pcall(function() for _, v in ipairs(x) do out[#out + 1] = v end end)
    if #out == 0 then
        pcall(function() for _, v in pairs(x) do out[#out + 1] = v end end)
    end
    if #out == 0 then
        pcall(function()
            for i = 0, #x do
                local v = x[i]
                if v ~= nil then out[#out + 1] = v end
            end
        end)
    end
    return out
end

-- Типы, встреченные в параметрах/возвратах приоритетных методов (для выгрузки enum и структур)
local COLLECT = {}
local function note_type(n)
    if n and n ~= "?" and not n:find("^System%.") and not n:find("^via%.") then COLLECT[n] = true end
end

local function dump_api(tn, mmax, fmax, collect)
    local td = sdk.find_type_definition(tn)
    if not td then return nil end
    local api = { methods = {}, fields = {} }
    pcall(function()
        local p = td:get_parent_type()
        if p then api.parent = tostring(p:get_full_name()) end
    end)

    local ok_m, ms = pcall(function() return td:get_methods() end)
    local mlist = ok_m and to_list(ms) or {}
    api.n_methods = #mlist
    for i, m in ipairs(mlist) do
        if i > mmax then break end
        local ok, n = pcall(function() return m:get_name() end)
        if ok and n then
            local np, ret = "?", "?"
            pcall(function() np = m:get_num_params() end)
            pcall(function() ret = tostring(m:get_return_type():get_full_name()) end)
            local params = {}
            pcall(function()
                local pt = to_list(m:get_param_types())
                local pn = {}
                pcall(function() pn = to_list(m:get_param_names()) end)
                for j, t in ipairs(pt) do
                    local tname = "?"
                    pcall(function() tname = tostring(t:get_full_name()) end)
                    params[#params + 1] = tname .. (pn[j] and (" " .. tostring(pn[j])) or "")
                    if collect then note_type(tname) end
                end
            end)
            if collect then note_type(ret) end
            local sig = (#params > 0) and table.concat(params, ", ") or (tostring(np) .. " params")
            api.methods[#api.methods + 1] = tostring(n) .. "(" .. sig .. ") -> " .. ret
        end
    end

    local ok_f, fs = pcall(function() return td:get_fields() end)
    local flist = ok_f and to_list(fs) or {}
    api.n_fields = #flist
    for i, f in ipairs(flist) do
        if i > fmax then break end
        local ok, n = pcall(function() return f:get_name() end)
        if ok and n then
            local ft = "?"
            pcall(function() ft = f:get_type():get_full_name() end)
            api.fields[#api.fields + 1] = tostring(n) .. " : " .. tostring(ft)
        end
    end
    return api
end

-- Поля типа вместе с унаследованными (до границы via.* / System.*)
local function field_defs(td)
    local defs, depth, cur = {}, 0, td
    while cur and depth < 6 do
        local n = ""
        pcall(function() n = tostring(cur:get_full_name()) end)
        if n:find("^via%.") or n:find("^System%.") then break end
        local ok, fs = pcall(function() return cur:get_fields() end)
        if ok then
            for _, f in ipairs(to_list(fs)) do defs[#defs + 1] = f end
        end
        local okp, p = pcall(function() return cur:get_parent_type() end)
        if not okp or not p then break end
        cur = p
        depth = depth + 1
    end
    return defs
end

-- Читает текущие значения простых полей (числа/bool/строки) компонента
local function read_values(comp, tn, cache)
    local defs = cache[tn]
    if not defs then
        local td = sdk.find_type_definition(tn)
        defs = {}
        if td then
            for _, f in ipairs(field_defs(td)) do
                local ok, n = pcall(function() return f:get_name() end)
                if ok and n then defs[#defs + 1] = tostring(n) end
            end
        end
        cache[tn] = defs
    end
    local vals = {}
    local cnt = 0
    for _, fname in ipairs(defs) do
        if cnt >= DETAIL_FIELDS_MAX then break end
        local ok, v = pcall(function() return comp:get_field(fname) end)
        if ok and v ~= nil then
            local t = type(v)
            if t == "number" then
                vals[fname] = r2(v); cnt = cnt + 1
            elseif t == "boolean" or t == "string" then
                vals[fname] = v; cnt = cnt + 1
            end
        end
    end
    return vals
end

-- Read-only: числа идентификаторов сохраняем точно, без округления как у координат.
-- Рекурсивно читаем только известные структуры ID; ссылки на игровые объекты не обходим.
local function read_context(obj, depth)
    if obj == nil then return { unavailable = "nil" } end
    local result = { fields = {}, errors = {} }
    local ok, td = pcall(function() return obj:get_type_definition() end)
    if not ok or not td then return { unavailable = "no type definition: " .. tostring(td) } end
    result.type = tostring(td:get_full_name())
    for i, f in ipairs(field_defs(td)) do
        if i > DETAIL_FIELDS_MAX then result.truncated = true; break end
        local okn, name = pcall(function() return f:get_name() end)
        if okn and name then
            name = tostring(name)
            local okv, value = pcall(function() return obj:get_field(name) end)
            if not okv then
                result.errors[name] = tostring(value)
            elseif value ~= nil then
                local kind = type(value)
                if kind == "number" or kind == "boolean" or kind == "string" then
                    result.fields[name] = value
                elseif depth < 2 then
                    local okt, tn = pcall(function() return f:get_type():get_full_name() end)
                    if okt and (tn == "chainsaw.ContextID" or tn == "chainsaw.StageIdentifier") then
                        local okr, nested = pcall(read_context, value, depth + 1)
                        if okr then result.fields[name] = nested else result.errors[name] = tostring(nested) end
                    end
                end
            end
        end
    end
    return result
end

local function read_context_list(list)
    if list == nil then return { unavailable = "nil" } end
    local result = { items = {}, errors = {} }
    local oka, arr = pcall(function() return list:get_elements() end)
    if oka and arr ~= nil then
        local elements = to_list(arr)
        result.count = #elements
        for i = 1, math.min(3, #elements) do
            local ok, value = pcall(read_context, elements[i], 0)
            result.items[i] = ok and value or { unavailable = tostring(value) }
        end
        return result
    end
    local okc, count = pcall(function() return list:call("get_Count") end)
    if not okc or type(count) ~= "number" then
        result.unavailable = "cannot enumerate collection: " .. tostring(count)
        return result
    end
    result.count = count
    for i = 0, math.min(3, count) - 1 do
        local ok, value = pcall(function() return read_context(list:call("get_Item", i), 0) end)
        result.items[#result.items + 1] = ok and value or { unavailable = tostring(value) }
    end
    return result
end

local function read_live_contexts()
    local result = {}
    local ok, manager = pcall(sdk.get_managed_singleton, "chainsaw.CharacterManager")
    if not ok or not manager then return { unavailable = "CharacterManager unavailable" } end
    for _, entry in ipairs({
        { "player", "getPlayerContextRef()", false },
        { "enemies", "get_EnemyContextList", true },
        { "control_targets", "get_ControlTargets", true },
    }) do
        local success, value = pcall(function()
            local obj = manager:call(entry[2])
            if entry[3] then return read_context_list(obj) end
            return read_context(obj, 0)
        end)
        result[entry[1]] = success and value or { unavailable = tostring(value) }
    end
    return result
end

---------------------------------------------------------------------------
-- Сам скан
---------------------------------------------------------------------------
local function scan(label)
    label = safe_label(label)
    local t0 = os.clock()
    COLLECT = {} -- новый скан не наследует типы из предыдущей сцены
    local res = {
        version = 4, label = label, go_count = 0, errors = 0,
        types = {}, singletons = {}, api = {}, detail = {}, enums = {}, extra = {},
        required_types = {}, related_errors = {},
    }

    local scene = get_scene()
    if not scene then
        S.status = "No scene (are you in gameplay?)"
        return
    end

    pcall(function()
        local p = scene:call("findGameObject(System.String)", "ch0a0z0_body")
        if p then res.player_pos = vec(p:call("get_Transform"):call("get_Position")) end
    end)
    pcall(function()
        local cam = sdk.get_primary_camera()
        if cam then
            res.camera_pos = vec(cam:call("get_GameObject"):call("get_Transform"):call("get_Position"))
        end
    end)

    local detail_set = {}
    for _, tn in ipairs(DETAIL_TYPES) do detail_set[tn] = true end
    local cand = {}   -- кандидаты для чтения значений полей

    local xf = scene:call("get_FirstTransform")
    local guard = 0
    while xf ~= nil and guard < MAX_OBJECTS do
        guard = guard + 1
        local ok = pcall(function()
            local go = xf:call("get_GameObject")
            if not go then return end
            res.go_count = res.go_count + 1
            local gname = tostring(go:call("get_Name"))
            local pos = vec(xf:call("get_Position"))
            local arr = go:call("get_Components")
            if not arr then return end
            for _, c in ipairs(arr:get_elements()) do
                local tn = type_name(c)
                local e = res.types[tn]
                if not e then
                    e = { count = 0, samples = {} }
                    res.types[tn] = e
                end
                e.count = e.count + 1
                if #e.samples < SAMPLES then
                    e.samples[#e.samples + 1] = { name = gname, pos = pos }
                end
                if detail_set[tn] then
                    local l = cand[tn]
                    if not l then l = {}; cand[tn] = l end
                    if #l < 3000 then
                        l[#l + 1] = { c = c, name = gname, pos = pos, d = dist(pos, res.player_pos) }
                    end
                end
            end
        end)
        if not ok then res.errors = res.errors + 1 end

        local ok2, nxt = pcall(function() return xf:call("get_Next") end)
        if not ok2 then break end
        xf = nxt
    end

    -- Синглтоны: Behavior-компоненты сцены обычно имеют одноимённый синглтон без суффикса
    local seen = {}
    local function try_singleton(n)
        if seen[n] then return end
        local ok, inst = pcall(function() return sdk.get_managed_singleton(n) end)
        if ok and inst ~= nil then
            seen[n] = true
            res.singletons[#res.singletons + 1] = n
        end
    end
    for _, n in ipairs(SINGLETON_CANDIDATES) do try_singleton(n) end
    for tn, _ in pairs(res.types) do
        if tn:find("^chainsaw%.") and tn:find("Behavior$") then
            try_singleton((tn:gsub("Behavior$", "")))
        end
    end
    table.sort(res.singletons)

    -- Текущие значения полей ближайших объектов
    local fcache = {}
    for tn, list in pairs(cand) do
        table.sort(list, function(a, b) return a.d < b.d end)
        local out = {}
        for i = 1, math.min(DETAIL_NEAREST, #list) do
            local it = list[i]
            local ok, vals = pcall(read_values, it.c, tn, fcache)
            if ok then
                out[#out + 1] = { name = it.name, pos = it.pos, dist = r2(it.d), f = vals }
            end
        end
        res.detail[tn] = out
    end

    -- API: сначала синглтоны и приоритетные типы, потом "ключевые" типы со сцены
    local done = {}
    local function do_api(tn, mm, ff, collect)
        if done[tn] then return end
        done[tn] = true
        local ok, api = pcall(dump_api, tn, mm, ff, collect)
        if ok and api then res.api[tn] = api end
    end
    for _, n in ipairs(res.singletons) do do_api(n, PRIO_METHODS_MAX, PRIO_FIELDS_MAX, true) end
    for _, n in ipairs(PRIORITY_TYPES) do do_api(n, PRIO_METHODS_MAX, PRIO_FIELDS_MAX, true) end

    -- Значения enum и поля структур/классов, на которые ссылаются методы
    local collected = {}
    local function collect_type(n)
        if collected[n] then return "already collected" end
        collected[n] = true
        local td = sdk.find_type_definition(n)
        if not td then return "missing" end
        if td:is_a("System.Enum") then
            local vals = {}
            for _, f in ipairs(to_list(td:get_fields())) do
                local okn, fname = pcall(function() return f:get_name() end)
                local okd, data = pcall(function() return f:get_data(nil) end)
                if okn and okd and type(data) == "number" then vals[tostring(fname)] = data end
            end
            res.enums[n] = vals
            if next(vals) == nil then return "enum values unavailable" end
            return "enum"
        end
        if not res.api[n] then res.extra[n] = dump_api(n, PRIO_METHODS_MAX, PRIO_FIELDS_MAX, nil) end
        return "type"
    end
    for _, n in ipairs(REQUIRED_TYPES) do
        local ok, status = pcall(collect_type, n)
        res.required_types[n] = ok and status or ("error: " .. tostring(status))
    end
    local names = {}
    for n in pairs(COLLECT) do if not collected[n] then names[#names + 1] = n end end
    table.sort(names)
    res.related_candidates, res.related_truncated = #names, #names > RELATED_TYPES_MAX
    for i = 1, math.min(#names, RELATED_TYPES_MAX) do
        local ok, err = pcall(collect_type, names[i])
        if not ok then res.related_errors[names[i]] = tostring(err) end
    end

    res.live = read_live_contexts()

    local want = {}
    for tn, _ in pairs(res.types) do
        if not done[tn] and (tn:find("^chainsaw%.") or tn:find("^app%.")) and matches_keyword(tn) then
            want[#want + 1] = tn
        end
    end
    table.sort(want)
    for i, tn in ipairs(want) do
        if i > API_TYPES_MAX then break end
        do_api(tn, API_METHODS_MAX, API_FIELDS_MAX)
    end

    res.seconds = r2(os.clock() - t0)

    local fname = "RE4MP_scout_" .. label .. ".json"
    local ok_w, err = pcall(json.dump_file, fname, res)
    if ok_w and err ~= false then
        S.status = string.format("Saved %s (%d objects, %d singletons, %d api types, %.1fs)",
            fname, res.go_count, #res.singletons, #want + #PRIORITY_TYPES, res.seconds)
        S.toast = { text = "Scout saved: " .. fname, t = os.time() + 4 }
    else
        S.status = "Could not write file: " .. tostring(err)
    end
    log.info("[" .. SCRIPT_NAME .. "] " .. S.status)
end

---------------------------------------------------------------------------
-- Запуск и интерфейс
---------------------------------------------------------------------------
re.on_frame(function()
    local down = reframework:is_key_down(VK_F8)
    if down and not S.f8_prev then S.pending = true end
    S.f8_prev = down

    if S.pending then
        S.pending = false
        S.count = S.count + 1
        local lbl = S.label
        if lbl == nil or lbl == "" or lbl == "scan" then lbl = "scan" .. S.count end
        local ok, err = pcall(scan, lbl)
        if not ok then
            S.status = "Scan failed: " .. tostring(err)
            log.info("[" .. SCRIPT_NAME .. "] " .. S.status)
        end
    end

    if S.toast and os.time() < S.toast.t then
        draw.text(S.toast.text, 24, 24, 0xFF40FF40)
    end
end)

re.on_draw_ui(function()
    if imgui.tree_node("RE4MP Scout") then
        imgui.text("Scout v4 | Read-only scan. Label: api4. Hotkey: F8")
        local changed, v = imgui.input_text("Label", S.label)
        if changed then S.label = v end
        if imgui.button("Scan now") then S.pending = true end
        imgui.text("Status: " .. tostring(S.status))
        imgui.tree_pop()
    end
end)
