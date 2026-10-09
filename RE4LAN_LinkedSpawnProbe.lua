-- RE4LAN Linked Spawn Probe v0.1.0.
-- Disposable experiment: requestSpawn creates a complete CharacterContext.
-- It is intentionally separate from RE4LAN_ModelProbe.lua and default-off.
-- Do not save the game during this test; restart after releasing the probe.

local REPORT = "RE4LAN_linked_spawn_probe.json"
local S = { phase = "idle", action = nil, attempted = false, code = nil,
    started = nil, moves = 0, report = { version = "0.1.0" } }

local function list(value)
    local out = {}
    if value == nil then return out end
    pcall(function() for _, v in ipairs(value) do out[#out + 1] = v end end)
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
        for _, method in ipairs(list(td:get_methods())) do
            if tostring(method:get_name()):match("%.GetEnumerator$") then get_enum = method; break end
        end
    end
    if not get_enum then return {} end
    local ok_enum, enum = pcall(function() return get_enum:call(value) end)
    if not ok_enum or not enum then return {} end
    local etd = enum:get_type_definition()
    local move, current
    for _, method in ipairs(list(etd:get_methods())) do
        local name = tostring(method:get_name())
        if name == "MoveNext" or name:match("%.MoveNext$") then move = method end
        if name == "get_Current" or name:match("%.get_Current$") then current = method end
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

local function write(message)
    S.report.phase, S.report.message, S.report.time = S.phase, message or S.message, os.time()
    S.report.context_code, S.report.moves, S.report.cleanup_sent = S.code, S.moves, S.cleanup_sent or false
    pcall(json.dump_file, REPORT, S.report)
end

local function status(phase, message)
    S.phase, S.message = phase, message
    log.info("[RE4LAN Linked Spawn] " .. phase .. ": " .. message)
    write(message)
end

local function scene_now()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return nil end
    return sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
end

local function current()
    local scene = assert(scene_now(), "Load a playable scene first.")
    local manager = assert(sdk.get_managed_singleton("chainsaw.CharacterManager"), "CharacterManager unavailable")
    local player = assert(manager:call("getPlayerContextRef()"), "Local player context unavailable")
    local body = assert(player:call("get_BodyGameObject"), "Local player body unavailable")
    local id = assert(player:call("get_ID"), "Local player ID unavailable")
    return scene, manager, player, id:call("get_Code"), body
end

local function pose_now()
    local bridge = _G.RE4LAN_visual
    assert(bridge and bridge.version == 1, "Install RE4LAN.lua and start host/join or echo.")
    local pose = assert(bridge.get_pose(), "No fresh partner pose.")
    assert(type(pose.pos) == "table" and #pose.pos == 3, "Partner position unavailable.")
    return pose
end

local function value(obj, method)
    local ok, v = pcall(function() return obj:call(method) end)
    if not ok then return { unavailable = tostring(v) } end
    if v == nil or type(v) == "number" or type(v) == "string" or type(v) == "boolean" then return v end
    local out = { lua_type = type(v) }
    pcall(function() out.type = v:get_type_definition():get_full_name() end)
    pcall(function() out.address = tostring(v:get_address()) end)
    return out
end

local function context_from_db(manager)
    local ok, db = pcall(function() return manager:call("get_CharacterContextDB") end)
    if not ok or not db then return nil end
    local has, present = pcall(function() return db:call("ContainsKey", S.code) end)
    if has and present then
        local got, ctx = pcall(function() return db:call("get_Item", S.code) end)
        if got and ctx then return ctx end
    end
    return nil
end

local function context_snapshot(ctx)
    local result = {}
    for _, method in ipairs({"get_Valid", "get_Managed", "get_Setupped", "get_OperationEnable",
        "get_IsEliminated", "get_IsRespawn", "get_KindID", "get_SpawnerID", "get_BodyGameObject",
        "get_HeadGameObject", "get_HitPoint", "get_HitPointVital", "get_CostumePresetID"}) do
        result[method] = value(ctx, method)
    end
    return result
end

local function find_motion(go)
    local ok, arr = pcall(function() return go:call("get_Components") end)
    if not ok or not arr then return nil end
    local comps = {}
    local got, elements = pcall(function() return arr:get_elements() end)
    if got and elements then comps = list(elements) end
    for _, comp in ipairs(items(arr)) do
        local td = comp:get_type_definition()
        if td:get_full_name() == "via.motion.Motion" then
            local result = { type = "via.motion.Motion" }
            pcall(function()
                result.joints = value(comp, "get_JointCount")
                result.layers = {}
                local n = comp:call("getLayerCount")
                for i = 0, math.min(n, 8) - 1 do
                    local layer = comp:call("getLayer", i)
                    result.layers[#result.layers + 1] = {
                        bank = value(layer, "get_MotionBankID"), motion = value(layer, "get_MotionID"),
                        frame = value(layer, "get_Frame"), running = value(layer, "get_Running"),
                        setuped = value(layer, "get_Setuped"), stop = value(layer, "get_StopUpdate"),
                    }
                end
            end)
            return result
        end
    end
end

local function body_snapshot(go)
    local result = { address = tostring(go:get_address()), name = value(go, "get_Name"),
        draw = value(go, "get_Draw"), draw_self = value(go, "get_DrawSelf"),
        update = value(go, "get_Update"), update_self = value(go, "get_UpdateSelf"),
        components = {} }
    local ok, arr = pcall(function() return go:call("get_Components") end)
    if ok and arr then
        for _, comp in ipairs(items(arr)) do
                local td = comp:get_type_definition()
                local name = td:get_full_name()
                if name == "chainsaw.HitController" or name == "chainsaw.CharacterBodyUpdater"
                    or name == "chainsaw.PlayerGunDamageController" then
                    local item = { type = name }
                    for _, method in ipairs({"get_Context", "get_CurrentHitPoint", "get_Invincible",
                        "get_AttackEnable", "get_Setuped", "get_RegisteredHitManager", "get_Colliders"}) do
                        item[method] = value(comp, method)
                    end
                    result.components[#result.components + 1] = item
                end
        end
    end
    result.motion = find_motion(go)
    return result
end

local function start()
    assert(not S.attempted, "One linked spawn per session; restart before another test.")
    local _, manager, player, player_code = current()
    local td = manager:get_type_definition()
    for _, method in ipairs({"generateDynamicContextID", "requestSpawn", "get_CharacterContextDB"}) do
        assert(td:get_method(method), "Missing CharacterManager API: " .. method)
    end
    local purpose_td = assert(sdk.find_type_definition("chainsaw.CharacterUsePurposeFlag"))
    local purpose_field = assert(purpose_td:get_field("Dynamic"))
    local purpose = purpose_field:get_data(nil)
    local kind = player:call("get_KindID")
    local preset = player:call("get_CostumePresetID")
    assert(type(kind) == "number" and type(preset) == "number", "Local character data unavailable")
    local id = assert(manager:call("generateDynamicContextID"))
    S.code = assert(id:call("get_Code"))
    assert(S.code ~= player_code, "Generated ID equals local player ID")
    S.report.kind, S.report.purpose, S.report.preset, S.report.spawner_code = kind, purpose, preset, player_code
    S.attempted, S.started, S.next_poll = true, os.time(), 0
    status("requesting", "Calling requestSpawn once; disposable linked-character test.")
    manager:call("requestSpawn", player:call("get_ID"), id, kind, purpose, preset)
    status("waiting", "requestSpawn accepted; waiting for CharacterContext and body.")
end

local function linked_context(manager)
    local ctx = context_from_db(manager)
    if not ctx then return nil end
    local ok, body = pcall(function() return ctx:call("get_BodyGameObject") end)
    if ok and body then return ctx, body end
end

local function release()
    if not S.code or S.cleanup_sent then return end
    local ok, _, manager = pcall(current)
    if not ok then status("abandoned", "Scene/player changed; restart without releasing old context."); return end
    local ctx = context_from_db(manager)
    if not ctx then status("abandoned", "Linked context disappeared; restart before saving."); return end
    local release_method = ctx:get_type_definition():get_method("release")
    assert(release_method, "CharacterContext.release unavailable")
    ctx:call("release")
    S.cleanup_sent = true
    status("released", "CharacterContext.release requested; restart before saving.")
end

local function follow()
    if S.phase ~= "active" then return end
    local ok, _, manager, _, identity = pcall(function()
        local scene, m, player, code = current(); return scene, m, player, code
    end)
    if not ok then status("abandoned", "Scene/player changed; restart game."); return end
    local ctx, body = linked_context(manager)
    if not ctx then status("abandoned", "Linked context/body disappeared; restart game."); return end
    local pose_ok, pose = pcall(pose_now)
    if not pose_ok then return end
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
    if S.moves == 1 then
        S.report.first_context, S.report.first_body = context_snapshot(ctx), body_snapshot(body)
    end
    if S.moves % 30 == 0 then
        S.report.context = context_snapshot(ctx)
        S.report.body = body_snapshot(body)
        write()
    end
end

local function update()
    if S.action then
        local action = S.action; S.action = nil
        if action == "start" then start() elseif action == "release" then release() end
    end
    if S.phase == "waiting" then
        if os.time() - S.started > 30 then status("timeout", "No linked CharacterContext appeared; restart game."); return end
        if os.time() >= S.next_poll then
            S.next_poll = os.time() + 1
            local _, manager = current()
            local ctx, body = linked_context(manager)
            if ctx then
                S.report.context = context_snapshot(ctx); S.report.body = body_snapshot(body)
                status("active", "Linked CharacterContext found; following partner pose.")
            end
        end
    end
end

re.on_application_entry("UpdateBehavior", function() pcall(update) end)
re.on_application_entry("LateUpdateBehavior", function() pcall(follow) end)
re.on_draw_ui(function()
    if not imgui.tree_node("RE4LAN Linked Spawn Probe") then return end
    imgui.text("v0.1.0 | full CharacterContext test | default OFF")
    imgui.text("Disposable only: no save, restart after release.")
    imgui.text("State: " .. S.phase); imgui.text(S.message or "Capture or start the linked test.")
    if not S.attempted and imgui.button("TEST: request linked character") then S.action = "start" end
    if S.phase == "active" and imgui.button("Release linked character") then S.action = "release" end
    imgui.text("Report: reframework/data/" .. REPORT)
    imgui.tree_pop()
end)
