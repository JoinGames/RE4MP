-- RE4LAN Partner Context Probe v0.1.0.
-- Read-only diagnostic for an existing Ashley/partner slot.
-- It does not spawn, release, teleport, change MotionFsm2, or touch saves.

local REPORT = "RE4LAN_partner_context_probe.json"
local CANDIDATE_NAMES = {"Player 2", "Ashley", "Ashley_body", "ch1c0z0_body"}
local S = {phase = "idle", message = "Capture the existing partner slot.", action = nil,
    report = {version = "0.1.0"}}

local function list(value)
    local out = {}
    if value == nil then return out end
    pcall(function() for _, item in ipairs(value) do out[#out + 1] = item end end)
    return out
end

local function method(obj, name)
    if not obj then return nil end
    local ok, result = pcall(function() return obj:call(name) end)
    if ok then return result end
end

local function summary(value)
    if value == nil then return {is_nil = true} end
    local kind = type(value)
    if kind == "number" or kind == "string" or kind == "boolean" then return value end
    local out = {lua_type = kind}
    pcall(function() out.type = value:get_type_definition():get_full_name() end)
    pcall(function() out.address = tostring(value:get_address()) end)
    return out
end

local function read(obj, names)
    local out = {}
    for _, name in ipairs(names) do
        local ok, value = pcall(function() return obj:call(name) end)
        out[name] = ok and summary(value) or {unavailable = tostring(value)}
    end
    return out
end

local function zero_method(obj, name)
    local ok, td = pcall(function() return obj:get_type_definition() end)
    if not ok or not td then return nil end
    local direct = td:get_method(name)
    if direct then return direct end
    for _, candidate in ipairs(list(td:get_methods())) do
        local n = tostring(candidate:get_name())
        if n:sub(-#name - 1) == "." .. name then return candidate end
    end
end

local function items(value, limit)
    if not value then return {} end
    local ok, elements = pcall(function() return value:get_elements() end)
    if ok and elements then return list(elements) end
    if type(value) == "table" and not value.get_type_definition then return value end
    local get_enum = zero_method(value, "GetEnumerator")
    if not get_enum then return {} end
    local ok_enum, enum = pcall(function() return get_enum:call(value) end)
    if not ok_enum or not enum then return {} end
    local move, current = zero_method(enum, "MoveNext"), zero_method(enum, "get_Current")
    if not move or not current then return {} end
    local out = {}
    pcall(function()
        for _ = 1, limit or 128 do
            if not move:call(enum) then break end
            out[#out + 1] = current:call(enum)
        end
    end)
    pcall(function()
        local dispose = zero_method(enum, "Dispose")
        if dispose then dispose:call(enum) end
    end)
    return out
end

local function scene_now()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return nil end
    return sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
end

local function body_snapshot(go)
    if not go then return {is_nil = true} end
    local out = {address = summary(go:get_address()), name = summary(method(go, "get_Name")),
        draw = summary(method(go, "get_Draw")), draw_self = summary(method(go, "get_DrawSelf")), components = {}}
    local components = method(go, "get_Components")
    for _, component in ipairs(items(components, 256)) do
        local ok, td = pcall(function() return component:get_type_definition() end)
        if ok and td then
            local name = td:get_full_name()
            local entry = {type = name}
            if name == "chainsaw.CharacterBodyUpdater" then
                entry.values = read(component, {"get_Context", "get_Setuped", "get_ConfiguredBody", "get_Valid"})
            elseif name == "chainsaw.HitController" then
                entry.values = read(component, {"get_Context", "get_CurrentHitPoint", "get_Invincible",
                    "get_AttackEnable", "get_Setuped", "get_RegisteredHitManager", "get_Colliders"})
            elseif name == "via.motion.Motion" then
                entry.values = read(component, {"get_JointCount", "get_JointsConstructed", "getLayerCount"})
                entry.layers = {}
                local ok_count, count = pcall(function() return component:call("getLayerCount") end)
                if ok_count and type(count) == "number" then
                    for index = 0, math.min(count, 8) - 1 do
                        local ok_layer, layer = pcall(function() return component:call("getLayer", index) end)
                        if ok_layer and layer then
                            entry.layers[#entry.layers + 1] = {index = index, values = read(layer, {
                                "get_MotionBankID", "get_MotionID", "get_Frame", "get_Running",
                                "get_Setuped", "get_StopUpdate"})}
                        end
                    end
                end
            elseif name == "via.motion.MotionFsm2" then
                entry.values = read(component, {"getLayerCount", "get_Setuped"})
            end
            out.components[#out.components + 1] = entry
        end
    end
    return out
end

local function context_snapshot(ctx, label)
    if not ctx then return {label = label, is_nil = true} end
    local out = {label = label, type = summary(ctx), values = read(ctx, {
        "get_ID", "get_Valid", "get_Managed", "get_Setupped", "get_OperationEnable",
        "get_KindID", "get_SpawnerID", "get_CostumePresetID", "get_BodyGameObject", "get_HeadGameObject",
        "get_HitPoint", "get_HitPointVital", "get_Position", "get_CurrentStageID"})}
    local ok, body = pcall(function() return ctx:call("get_BodyGameObject") end)
    if ok and body then out.body = body_snapshot(body) end
    local ok_head, head = pcall(function() return ctx:call("get_HeadGameObject") end)
    if ok_head and head then out.head = body_snapshot(head) end
    return out
end

local function api_summary(type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then return {type = type_name, unavailable = true} end
    local out = {type = type_name, methods = {}}
    for _, m in ipairs(list(td:get_methods())) do
        local n = tostring(m:get_name())
        if n:match("Context") or n:match("Partner") or n:match("Character") or n:match("Spawn")
            or n:match("Control") or n:match("Body") or n:match("Motion") then
            out.methods[#out.methods + 1] = n
        end
    end
    table.sort(out.methods)
    return out
end

local function write(message)
    S.report.phase, S.report.message, S.report.time = S.phase, message or S.message, os.time()
    pcall(json.dump_file, REPORT, S.report)
end

local function status(phase, message)
    S.phase, S.message = phase, message
    log.info("[RE4LAN Partner Probe] " .. phase .. ": " .. message)
    write(message)
end

local function capture()
    local scene = assert(scene_now(), "Load a playable scene first.")
    local manager = assert(sdk.get_managed_singleton("chainsaw.CharacterManager"), "CharacterManager unavailable")
    local player = method(manager, "getPlayerContextRef()")
    assert(player, "Local player context unavailable")
    local report = {
        version = "0.1.0", scene = summary(scene), manager = summary(manager),
        player = context_snapshot(player, "player"), contexts = {}, game_objects = {},
        api = {manager = api_summary("chainsaw.CharacterManager"), context = api_summary("chainsaw.CharacterContext")},
    }
    local ref_methods = {"getPartnerContextRef", "getPlayerAndPartnerContextList", "getPartnerContextList",
        "getDollNpcContextRef", "getDollNpcContextRefs", "get_ControlTargets", "get_CharacterContextDB"}
    for _, name in ipairs(ref_methods) do
        local ok, value = pcall(function() return manager:call(name .. "()") end)
        if not ok then ok, value = pcall(function() return manager:call(name) end) end
        if ok and value then
            if name == "getPartnerContextRef" or name == "getDollNpcContextRef" then
                report.contexts[#report.contexts + 1] = context_snapshot(value, name)
            elseif name == "get_CharacterContextDB" then
                report.context_db = summary(value)
            else
                for index, item in ipairs(items(value, 64)) do
                    report.contexts[#report.contexts + 1] = context_snapshot(item, name .. "[" .. index .. "]")
                end
            end
        end
    end
    for _, name in ipairs(CANDIDATE_NAMES) do
        local ok, go = pcall(function() return scene:call("findGameObject(System.String)", name) end)
        if ok and go then report.game_objects[#report.game_objects + 1] = body_snapshot(go) end
    end
    S.report = report
    status(#report.contexts > 0 and "found" or "empty",
        #report.contexts > 0 and "Partner/Ashley context captured; send the JSON report." or
            "No partner context returned; send the JSON report and restart before another test.")
end

re.on_application_entry("UpdateBehavior", function()
    if S.action == "capture" then
        S.action = nil
        local ok, err = pcall(capture)
        if not ok then status("error", tostring(err)) end
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("RE4LAN Partner Context Probe") then return end
    imgui.text("v0.1.0 | read-only existing Ashley/partner slot probe | default OFF")
    imgui.text("No spawn, release, teleport, animation, damage, or save changes.")
    imgui.text("State: " .. S.phase)
    imgui.text(S.message)
    if S.phase == "idle" and imgui.button("Capture partner/Ashley slot") then S.action = "capture" end
    imgui.text("Report: reframework/data/" .. REPORT)
    imgui.tree_pop()
end)
