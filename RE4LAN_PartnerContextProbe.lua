-- RE4LAN Partner Context Probe v0.2.0.
-- Observes existing partner state and creation calls made by the original mod.
-- It does not spawn, release, teleport, change MotionFsm2, or touch saves.

local VERSION = "0.2.0"
local REPORT = "RE4LAN_partner_context_probe.json"
local CANDIDATE_NAMES = {"Player 2", "Player 2_head"}
local S = {phase = "idle", message = "Capture the existing partner slot.", action = nil,
    report = {version = VERSION}}
local TRACE_LIMIT, TRACE_SECONDS = 1024, 180
local T = {active = false, events = {}, hooks = {}, dropped = 0, errors = 0}

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
    if out.type == "chainsaw.ContextID" then
        for _, name in ipairs({"Code", "Category", "Kind", "Group", "Index"}) do
            local ok, number = pcall(function() return value:call("get_" .. name) end)
            if ok and type(number) == "number" then out[name:lower()] = number end
        end
    end
    return out
end

local function read(obj, names)
    local out = {}
    for _, name in ipairs(names) do
        local ok, value = pcall(function() return obj:call(name) end)
        if ok then out[name] = summary(value)
        else out[name] = {unavailable = tostring(value)} end
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
        if n:sub(-#name - 1) == "." .. name and #list(candidate:get_param_types()) == 0 then
            return candidate
        end
    end
end

local function items(value, limit)
    if not value then return {} end
    limit = limit or 128
    local function bounded(values)
        local out = {}
        for _, item in ipairs(list(values)) do
            if #out == limit then break end
            out[#out + 1] = item
        end
        return out
    end
    local ok, elements = pcall(function() return value:get_elements() end)
    if ok and elements then return bounded(elements) end
    if type(value) == "table" and not value.get_type_definition then return bounded(value) end
    local get_enum = zero_method(value, "GetEnumerator")
    if not get_enum then error("Collection.GetEnumerator unavailable") end
    local ok_enum, enum = pcall(function() return get_enum:call(value) end)
    if not ok_enum or not enum then error("Collection.GetEnumerator failed: " .. tostring(enum)) end
    local move, current = zero_method(enum, "MoveNext"), zero_method(enum, "get_Current")
    if not move or not current then error("Collection MoveNext/Current unavailable") end
    local out = {}
    local success, err = pcall(function()
        for _ = 1, limit do
            if not move:call(enum) then break end
            out[#out + 1] = current:call(enum)
        end
    end)
    pcall(function()
        local dispose = zero_method(enum, "Dispose")
        if dispose then dispose:call(enum) end
    end)
    if not success then error(err) end
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
            if name:match("BodyUpdater$") or name:match("HeadUpdater$") then
                entry.values = read(component, {"get_Context", "get_InstanceDemandID",
                    "get_InstanceParentID", "get_Valid"})
            elseif name == "chainsaw.HitController" then
                entry.values = read(component, {"get_Context", "get_CurrentHitPoint", "get_Invincible",
                    "get_AttackEnable", "get_Setuped", "get_RegisteredHitManager", "get_Colliders"})
            elseif name == "via.motion.Motion" then
                entry.values = read(component, {"get_JointCount", "get_JointsConstructed", "getLayerCount"})
                entry.layers = {}
                local ok_count, count = pcall(function() return component:call("getLayerCount") end)
                if ok_count and type(count) == "number" then
                    entry.layers_truncated = count > 32
                    for index = 0, math.min(count, 32) - 1 do
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
        "get_HitPoint", "get_HitPointVital", "get_Position", "get_CurrentStageID",
        "get_CharacterSpawnParam", "get_SpawnParamGameObject", "get_ContextStoreStyle",
        "get_BodyUpdater", "get_HeadUpdater"})}
    local ok, body = pcall(function() return ctx:call("get_BodyGameObject") end)
    if ok and body then out.body = body_snapshot(body) end
    local ok_head, head = pcall(function() return ctx:call("get_HeadGameObject") end)
    if ok_head and head then out.head = body_snapshot(head) end
    return out
end

local function api_summary(type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then return {type = type_name, unavailable = true} end
    local out = {type = type_name, methods = {}, fields = {}}
    for _, m in ipairs(list(td:get_methods())) do
        local params = {}
        for _, p in ipairs(list(m:get_param_types())) do params[#params + 1] = p:get_full_name() end
        out.methods[#out.methods + 1] = m:get_name() .. "(" .. table.concat(params, ",") .. ")"
    end
    for _, f in ipairs(list(td:get_fields())) do
        out.fields[#out.fields + 1] = f:get_name() .. " : " .. f:get_type():get_full_name()
    end
    table.sort(out.methods)
    return out
end

local function write(message)
    S.report.phase, S.report.message, S.report.time = S.phase, message or S.message, os.time()
    S.report.trace = T
    local ok, result = pcall(json.dump_file, REPORT, S.report)
    S.write_ok = ok and result ~= false
end

local function status(phase, message)
    S.phase, S.message = phase, message
    log.info("[RE4LAN Partner Probe] " .. phase .. ": " .. message)
    write(message)
end

-- Only these known instance methods are observed. No state-changing method is
-- called by this script. Arguments are copied to primitives inside the hook;
-- native objects and pointers are never queued for use on a later frame.
local WATCH = {
    ["chainsaw.CharacterManager"] = {
        requestSpawn = true, requestCreateHead = true, requestCreateBody = true,
        registerContext = true, makeCharacterContext = true, registerHead = true,
        registerBody = true, registerHeadCatalog = true, registerBodyCatalog = true,
        requestCostumeChange = true,
    },
    ["chainsaw.CharacterContext"] = {initialize = true, link = true, applySpawnParam = true},
    ["chainsaw.CostumeManager"] = {requestCostumeChange = true, registerCatalog = true},
}
local INTEGER_TYPES = { ["System.UInt32"] = true, ["System.Int32"] = true,
    ["chainsaw.CharacterKindID"] = true, ["chainsaw.CharacterUsePurposeFlag"] = true }
local OBJECT_TYPES = { ["chainsaw.ContextID"] = true, ["chainsaw.CharacterContext"] = true,
    ["chainsaw.CharacterBackup"] = true, ["chainsaw.CharacterSpawnParam"] = true,
    ["chainsaw.CharacterHeadUpdater"] = true, ["chainsaw.CharacterBodyUpdater"] = true,
    ["chainsaw.CharacterHeadCatalogUserData"] = true, ["chainsaw.CharacterBodyCatalogUserData"] = true,
    ["chainsaw.CostumePresetCatalogUserData"] = true,
    ["chainsaw.CostumePresetCatalogUserData.Data"] = true, ["via.GameObject"] = true }

local function hook_argument(raw, type_name)
    if INTEGER_TYPES[type_name] then return sdk.to_int64(raw) & 0xffffffff end
    if OBJECT_TYPES[type_name] then return summary(sdk.to_managed_object(raw)) end
    -- Vectors/quaternions can use a different ABI; callbacks and arrays are not
    -- dereferenced. The signature still records that the parameter was present.
    return {not_read = type_name}
end

local function observe(signature, params, args)
    if not T.active then return end
    if os.time() >= T.deadline then T.active = false; T.stop_reason = "time_limit"; return end
    if #T.events >= TRACE_LIMIT then T.dropped = T.dropped + 1; return end
    local event = {sequence = #T.events + 1, seconds = os.time() - T.started,
        method = signature, arguments = {}}
    T.events[#T.events + 1] = event
    -- REFramework instance hooks: args[1] = thread context, args[2] = this.
    local ok_self, self_value = pcall(function() return summary(sdk.to_managed_object(args[2])) end)
    if ok_self then event.instance = self_value end
    for index, type_name in ipairs(params) do
        local ok, value = pcall(hook_argument, args[index + 2], type_name)
        if ok then event.arguments[index] = value
        else event.arguments[index] = {unavailable = tostring(value)} end
    end
end

local function install_trace_hooks()
    if type(sdk.hook) ~= "function" or type(sdk.to_int64) ~= "function"
        or type(sdk.to_managed_object) ~= "function" then
        T.hooks[#T.hooks + 1] = {unavailable = "SDK hook/argument conversion API missing"}
        return
    end
    for type_name, names in pairs(WATCH) do
        local td = sdk.find_type_definition(type_name)
        if td then
            for _, m in ipairs(list(td:get_methods())) do
                local name = m:get_name()
                if names[name] then
                    local params = {}
                    for _, p in ipairs(list(m:get_param_types())) do params[#params + 1] = p:get_full_name() end
                    local signature = type_name .. "." .. name .. "(" .. table.concat(params, ",") .. ")"
                    local ok, err = pcall(function()
                        return sdk.hook(m, function(args)
                            local success = pcall(observe, signature, params, args)
                            if not success then T.errors = T.errors + 1 end
                            if T.errors >= 3 then T.active = false; T.stop_reason = "hook_errors" end
                            -- nil: leave original execution alone, including other hooks.
                        end, function(retval) return retval end)
                    end)
                    if ok and err == false then ok, err = false, "sdk.hook returned false" end
                    local entry = {method = signature, installed = ok}
                    if not ok then entry.error = tostring(err) end
                    T.hooks[#T.hooks + 1] = entry
                end
            end
        else T.hooks[#T.hooks + 1] = {type = type_name, unavailable = "type missing"} end
    end
end

local function start_trace()
    T.events, T.dropped, T.errors = {}, 0, 0
    T.started, T.stop_reason = os.time(), nil
    T.installed_count = 0
    for _, hook in ipairs(T.hooks) do
        if hook.installed then T.installed_count = T.installed_count + 1 end
    end
    T.deadline, T.active = T.started + TRACE_SECONDS, T.installed_count > 0
    S.report = {version = VERSION}
    if T.active then
        status("recording", "Recording creation for 180s. Connect using the original mod, then Capture.")
    else
        status("trace_unavailable", "No creation hooks installed; snapshot still available. Send report.")
    end
end

local function capture()
    T.active, T.stop_reason = false, T.stop_reason or "capture"
    local scene = assert(scene_now(), "Load a playable scene first.")
    local manager = assert(sdk.get_managed_singleton("chainsaw.CharacterManager"), "CharacterManager unavailable")
    local player = method(manager, "getPlayerContextRef()")
    assert(player, "Local player context unavailable")
    local report = {
        version = VERSION, scene = summary(scene), manager = summary(manager),
        player = context_snapshot(player, "player"), contexts = {}, game_objects = {},
        queries = {}, control_targets = {}, api = {},
    }
    for _, type_name in ipairs({"chainsaw.CharacterManager", "chainsaw.CharacterContext",
        "chainsaw.PartnerBaseContext", "chainsaw.CharacterBackup", "chainsaw.CharacterSpawnParam",
        "chainsaw.Ch2a3z0BodyUpdater", "chainsaw.Ch2a3z0HeadUpdater", "chainsaw.CostumeManager"}) do
        report.api[type_name] = api_summary(type_name)
    end
    local partner = method(manager, "getPartnerContextRef()")
    report.partner_present = partner ~= nil
    report.partner = context_snapshot(partner, "getPartnerContextRef")
    local ref_methods = {"get_PlayerAndPartnerContextList", "get_PartnerContextList",
        "get_DollNpcContextList", "get_ControlTargets", "get_CharacterContextDB"}
    for _, name in ipairs(ref_methods) do
        local ok, value = pcall(function() return manager:call(name) end)
        if ok then report.queries[name] = summary(value)
        else report.queries[name] = {unavailable = tostring(value)} end
        if ok and value then
            if name == "get_CharacterContextDB" then
                report.context_db = summary(value)
            else
                local collected, err = pcall(function()
                    for index, item in ipairs(items(value, 32)) do
                        if name == "get_ControlTargets" then
                            report.control_targets[#report.control_targets + 1] = {
                                object = summary(item), values = read(item, {"get_ContextID",
                                    "get_BodyGameObject", "get_HeadGameObject"})}
                        else
                            report.contexts[#report.contexts + 1] = context_snapshot(item, name .. "[" .. index .. "]")
                        end
                    end
                end)
                if not collected then report.queries[name].collection_error = tostring(err) end
            end
        end
    end
    for _, name in ipairs(CANDIDATE_NAMES) do
        local ok, go = pcall(function() return scene:call("findGameObject(System.String)", name) end)
        if ok and go then report.game_objects[#report.game_objects + 1] = body_snapshot(go) end
    end
    S.report = report
    status(report.partner_present and "found" or "empty", report.partner_present and
        "Partner context and creation trace captured; send the JSON report." or
        "No direct partner context. Report saved, including creation trace and query results.")
end

re.on_application_entry("UpdateBehavior", function()
    if S.action then
        local action = S.action
        S.action = nil
        local ok, err = pcall(function()
            if action == "capture" then capture() elseif action == "trace" then start_trace() end
        end)
        if not ok then status("error", tostring(err)) end
    end
    if T.active and os.time() >= T.deadline then
        T.active, T.stop_reason = false, "time_limit"
    end
    if S.phase == "recording" and T.stop_reason == "time_limit" then
        status("trace_stopped", "180s elapsed; trace kept. Capture when the partner is visible.")
    end
    if #T.events ~= S.saved_events and os.time() >= (S.next_write or 0) then
        write(); S.saved_events = #T.events; S.next_write = os.time() + 2
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("RE4LAN Partner Context Probe") then return end
    imgui.text("v" .. VERSION .. " | partner snapshot + passive creation trace")
    imgui.text("No spawn, release, teleport, animation, damage, or save changes.")
    imgui.text("State: " .. S.phase)
    imgui.text(S.message)
    imgui.text("Trace: " .. (T.active and "recording" or "stopped") .. " | events " .. #T.events
        .. " | hooks " .. (T.installed_count or 0))
    if imgui.button("Start creation trace (before connecting)") then S.action = "trace" end
    if imgui.button("Capture partner/Ashley slot") then S.action = "capture" end
    if S.write_ok == false then imgui.text("Could not write report. Check reframework/data access.") end
    imgui.text("Report: reframework/data/" .. REPORT)
    imgui.tree_pop()
end)

if re.on_script_reset then re.on_script_reset(function() T.active = false end) end
-- Install and arm during autorun to include creation before the first UI click.
local installed, err = pcall(install_trace_hooks)
if not installed then T.hooks[#T.hooks + 1] = {unavailable = tostring(err)} end
start_trace()
