-- RE4LAN Linked Spawn Probe v0.2.0.
-- Disposable experiment based on the observed PartnerBaseContext recipe.
-- It is default-off and must be run in a disposable session without saves.
-- Do not run the original co-op mod at the same time: an existing partner slot
-- is detected and this probe will refuse to create a second one.

local VERSION = "0.3.0"
local REPORT = "RE4LAN_linked_spawn_probe.json"
local S = {phase = "idle", message = "Capture the confirmed partner recipe.", action = nil,
    attempted = false, code = nil, started = nil, next_poll = 0, moves = 0,
    report = {version = VERSION}}

local function list(value)
    local out = {}
    if value == nil then return out end
    pcall(function() for _, item in ipairs(value) do out[#out + 1] = item end end)
    return out
end

local function items(value)
    if not value then return {} end
    local ok, elements = pcall(function() return value:get_elements() end)
    if ok and elements then return list(elements) end
    local td_ok, td = pcall(function() return value:get_type_definition() end)
    if not td_ok or not td then return {} end
    local get_enum = td:get_method("GetEnumerator")
    if not get_enum then
        for _, candidate in ipairs(list(td:get_methods())) do
            if tostring(candidate:get_name()):match("%.GetEnumerator$") then get_enum = candidate; break end
        end
    end
    if not get_enum then return {} end
    local ok_enum, enum = pcall(function() return get_enum:call(value) end)
    if not ok_enum or not enum then return {} end
    local etd = enum:get_type_definition(); local move, current
    for _, candidate in ipairs(list(etd:get_methods())) do
        local name = tostring(candidate:get_name())
        if name == "MoveNext" or name:match("%.MoveNext$") then move = candidate end
        if name == "get_Current" or name:match("%.get_Current$") then current = candidate end
    end
    if not move or not current then return {} end
    local out = {}
    pcall(function()
        for _ = 1, 256 do
            if not move:call(enum) then break end
            out[#out + 1] = current:call(enum)
        end
    end)
    pcall(function()
        local dispose = etd:get_method("Dispose")
        if dispose then dispose:call(enum) end
    end)
    return out
end

local function scene_now()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return nil end
    return sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
end

local function value(obj, method)
    local ok, result = pcall(function() return obj:call(method) end)
    if not ok then return {unavailable = tostring(result)} end
    if result == nil then return {is_nil = true} end
    if type(result) == "number" or type(result) == "string" or type(result) == "boolean" then return result end
    local out = {lua_type = type(result)}
    pcall(function() out.type = result:get_type_definition():get_full_name() end)
    pcall(function() out.address = tostring(result:get_address()) end)
    pcall(function()
        if out.type == "chainsaw.ContextID" then out.code = result:call("get_Code") end
    end)
    if out.type == "via.vec3" then
        pcall(function() out.xyz = {result.x, result.y, result.z} end)
    elseif out.type == "via.Quaternion" then
        pcall(function() out.xyzw = {result.x, result.y, result.z, result.w} end)
    end
    return out
end

local function transform_snapshot(go)
    if not go then return {is_nil = true} end
    local ok, transform = pcall(function() return go:call("get_Transform") end)
    if not ok or not transform then return {unavailable = tostring(transform)} end
    return {position = value(transform, "get_Position"), rotation = value(transform, "get_Rotation")}
end

local function write(message)
    S.report.phase, S.report.message, S.report.time = S.phase, message or S.message, os.time()
    S.report.context_code, S.report.moves = S.code, S.moves
    S.report.cleanup_sent = false
    local ok, result = pcall(json.dump_file, REPORT, S.report)
    S.report_write_ok = ok and result ~= false
end

local function status(phase, message)
    S.phase, S.message = phase, message
    log.info("[RE4LAN Linked Spawn] " .. phase .. ": " .. message)
    write(message)
end

local function current()
    local scene = assert(scene_now(), "Load a playable scene first.")
    local manager = assert(sdk.get_managed_singleton("chainsaw.CharacterManager"), "CharacterManager unavailable")
    local player = assert(manager:call("getPlayerContextRef()"), "Local player context unavailable")
    local body = assert(player:call("get_BodyGameObject"), "Local player body unavailable")
    local id = assert(player:call("get_ID"), "Local player ID unavailable")
    return scene, manager, player, id, id:call("get_Code"), body
end

local function partner_context(manager)
    local ok, ctx = pcall(function() return manager:call("getPartnerContextRef()") end)
    if not ok or not ctx then return nil end
    local body_ok, body = pcall(function() return ctx:call("get_BodyGameObject") end)
    if body_ok and body then return ctx, body end
end

local function context_snapshot(ctx)
    local out = {}
    for _, name in ipairs({"get_ID", "get_Valid", "get_Managed", "get_Setupped", "get_OperationEnable",
        "get_KindID", "get_SpawnerID", "get_CostumePresetID", "get_BodyGameObject", "get_HeadGameObject",
        "get_HitPoint", "get_HitPointVital", "get_CurrentStageID", "get_BodyUpdater", "get_HeadUpdater"}) do
        out[name] = value(ctx, name)
    end
    return out
end

local function motion_snapshot(go)
    local ok, collection = pcall(function() return go:call("get_Components") end)
    if not ok or not collection then return nil end
    for _, component in ipairs(items(collection)) do
        local td = component:get_type_definition()
        if td:get_full_name() == "via.motion.Motion" then
            local result = {type = "via.motion.Motion", joints = value(component, "get_JointCount"), layers = {}}
            local ok_count, count = pcall(function() return component:call("getLayerCount") end)
            if ok_count and type(count) == "number" then
                for index = 0, math.min(count, 16) - 1 do
                    local ok_layer, layer = pcall(function() return component:call("getLayer", index) end)
                    if ok_layer and layer then
                        result.layers[#result.layers + 1] = {index = index,
                            bank = value(layer, "get_MotionBankID"), motion = value(layer, "get_MotionID"),
                            frame = value(layer, "get_Frame"), running = value(layer, "get_Running")}
                    end
                end
            end
            return result
        end
    end
end

local function body_snapshot(go)
    local result = {address = tostring(go:get_address()), name = value(go, "get_Name"),
        transform = transform_snapshot(go), components = {}}
    local ok, collection = pcall(function() return go:call("get_Components") end)
    if ok and collection then
        for _, component in ipairs(items(collection)) do
            local td = component:get_type_definition(); local name = td:get_full_name()
            if name:match("BodyUpdater$") or name == "chainsaw.HitController"
                or name == "chainsaw.PlayerGunDamageController" then
                local entry = {type = name}
                for _, getter in ipairs({"get_Context", "get_InstanceDemandID", "get_InstanceParentID",
                    "get_CurrentHitPoint", "get_Invincible", "get_AttackEnable", "get_Setuped",
                    "get_RegisteredHitManager", "get_Colliders"}) do
                    entry[getter] = value(component, getter)
                end
                result.components[#result.components + 1] = entry
            end
        end
    end
    result.motion = motion_snapshot(go)
    return result
end

local function start()
    assert(not S.attempted, "One partner spawn per session; restart before another test.")
    local _, manager, player, player_id, player_code = current()
    if partner_context(manager) then
        S.attempted = true
        S.report.recipe = "already_present"
        status("already_present", "Partner context already exists. Disable the original co-op mod for this probe.")
        return
    end
    local purpose_td = assert(sdk.find_type_definition("chainsaw.CharacterUsePurposeFlag"))
    local kind_td = assert(sdk.find_type_definition("chainsaw.CharacterKindID"))
    local purpose = assert(purpose_td:get_field("Spawner")):get_data(nil)
    local kind = assert(kind_td:get_field("ch2_a3z0")):get_data(nil)
    assert(type(purpose) == "number" and type(kind) == "number", "Partner enum values unavailable")
    assert(manager:get_type_definition():get_method("requestSpawn"), "Missing CharacterManager.requestSpawn")
    S.code = player_code
    S.report.recipe = {spawner_code = player_code, context_code = player_code,
        kind = kind, purpose = purpose, costume_preset = 0, same_context_id = true}
    S.report.local_player_transform = transform_snapshot(player:call("get_BodyGameObject"))
    S.attempted, S.started, S.next_poll = true, os.time(), 0
    status("requesting", "Calling confirmed PartnerBaseContext requestSpawn once; disposable test.")
    -- The original trace used the six-argument overload with an empty accessory
    -- array. The five-argument overload has the same default empty accessories.
    manager:call("requestSpawn", player_id, player_id, kind, purpose, 0)
    status("waiting", "requestSpawn accepted; waiting for PartnerBaseContext and body.")
end

local function place_next_to_player()
    local _, manager, player = current()
    local ctx, body = partner_context(manager)
    assert(ctx and body, "PartnerBaseContext is not active")
    local player_body = player:call("get_BodyGameObject")
    local transform = player_body:call("get_Transform")
    local position = transform:call("get_Position")
    local rotation = transform:call("get_Rotation")
    local target = Vector3f.new(position.x + 2.0, position.y, position.z)
    local ok = pcall(function() ctx:call("setTransform", target, rotation) end)
    if not ok then
        local target_transform = body:call("get_Transform")
        target_transform:call("set_Position", target)
        target_transform:call("set_Rotation", rotation)
    end
    S.report.placement = {target = {position = {target.x, target.y, target.z}},
        player = transform_snapshot(player_body)}
    S.report.context, S.report.body = context_snapshot(ctx), body_snapshot(body)
    status("placed", "Partner body placed 2m beside the local player; inspect the model now.")
end

local function follow(ctx, body)
    local bridge = _G.RE4LAN_visual
    if not bridge or bridge.version ~= 1 then return end
    local ok_pose, pose = pcall(bridge.get_pose)
    if not ok_pose or not pose or type(pose.pos) ~= "table" then return end
    local rotation = Quaternion.new()
    rotation.x, rotation.y, rotation.z, rotation.w = 0, math.sin(pose.yaw / 2), 0, math.cos(pose.yaw / 2)
    local set_ok = pcall(function()
        ctx:call("setTransform", Vector3f.new(pose.pos[1], pose.pos[2], pose.pos[3]), rotation)
    end)
    if not set_ok then
        local xf = body:call("get_Transform")
        xf:call("set_Position", Vector3f.new(pose.pos[1], pose.pos[2], pose.pos[3]))
        xf:call("set_Rotation", rotation)
    end
    S.moves = S.moves + 1
    if S.moves % 30 == 0 then
        S.report.context, S.report.body = context_snapshot(ctx), body_snapshot(body)
        write()
    end
end

local function update()
    if S.action then
        local action = S.action; S.action = nil
        if action == "start" then
            local ok, err = pcall(start)
            if not ok then status("error", tostring(err)) end
        end
    end
    if S.phase == "waiting" then
        if os.time() - S.started > 30 then status("timeout", "No PartnerBaseContext appeared; restart game."); return end
        if os.time() >= S.next_poll then
            S.next_poll = os.time() + 1
            local ok, _, manager = pcall(function()
                local scene, m = current(); return scene, m
            end)
            if ok then
                local ctx, body = partner_context(manager)
                if ctx then
                    S.report.context, S.report.body = context_snapshot(ctx), body_snapshot(body)
                    status("active", "PartnerBaseContext found; model and HitController are linked.")
                end
            end
        end
    end
end

local function late_update()
    if S.phase ~= "active" then return end
    local ok, _, manager = pcall(function()
        local scene, m = current(); return scene, m
    end)
    if not ok then status("abandoned", "Scene/player changed; restart game."); return end
    local ctx, body = partner_context(manager)
    if not ctx then status("abandoned", "Partner context disappeared; restart game."); return end
    follow(ctx, body)
end

re.on_application_entry("UpdateBehavior", function() pcall(update) end)
re.on_application_entry("LateUpdateBehavior", function() pcall(late_update) end)
re.on_draw_ui(function()
    if not imgui.tree_node("RE4LAN Linked Spawn Probe") then return end
    imgui.text("v" .. VERSION .. " | confirmed PartnerBaseContext recipe | default OFF")
    imgui.text("Disposable only: no save; restart after the test.")
    imgui.text("State: " .. S.phase); imgui.text(S.message)
    if not S.attempted and imgui.button("TEST: create partner slot") then S.action = "start" end
    if S.phase == "active" and imgui.button("Place partner next to me") then
        local ok, err = pcall(place_next_to_player)
        if not ok then status("error", tostring(err)) end
    end
    imgui.text("Report: reframework/data/" .. REPORT)
    imgui.tree_pop()
end)
