-- RE4LAN Model Probe v0.3.3. Optional, manual, one body request per script session.
-- Uses APIs observed in RE4MP_scout_api4.json; native behavior is experimental.
-- No player/partner slot changes, head/AI creation, inventory or save operations.
-- Install beside RE4LAN.lua. See docs/MODEL_PROBE.md before running the test.

local REPORT = "RE4LAN_model_probe.json"
local TEST_SECONDS = 180
local S = {
    phase = "idle", message = "Capture API or start the manual body test.",
    action = nil, attempted = false, request_id = nil, context_code = nil,
    identity = nil, name = nil, cleanup_sent = false, frame = 0,
    started = nil, next_search = 0, moves = 0, report = { version = "0.3.3" },
}

local function list(value)
    local result = {}
    if value == nil then return result end
    local ok = pcall(function() for _, v in ipairs(value) do result[#result + 1] = v end end)
    if not ok and #result == 0 then
        pcall(function() for _, v in pairs(value) do result[#result + 1] = v end end)
    end
    return result
end

local function write_report()
    S.report.phase, S.report.message, S.report.time = S.phase, S.message, os.time()
    S.report.request_id, S.report.context_code = S.request_id, S.context_code
    S.report.body_name, S.report.moves = S.name, S.moves
    S.report.cleanup_sent = S.cleanup_sent
    local ok, result = pcall(json.dump_file, REPORT, S.report)
    S.report_write_ok = ok and result ~= false
end

local function status(phase, message)
    S.phase, S.message = phase, message
    if phase == "abandoned" then S.revoked = true end
    log.info("[RE4LAN Model Probe] " .. phase .. ": " .. message)
    write_report()
end

local function api(name)
    local td = sdk.find_type_definition(name)
    if not td then return { unavailable = "type not found" } end
    local result = { methods = {}, fields = {} }
    for _, m in ipairs(list(td:get_methods())) do
        local params = {}
        for _, p in ipairs(list(m:get_param_types())) do params[#params + 1] = p:get_full_name() end
        local signature = m:get_name() .. "(" .. table.concat(params, ",") .. ")"
        local ok, ret = pcall(function() return m:get_return_type():get_full_name() end)
        result.methods[#result.methods + 1] = signature .. (ok and (" -> " .. ret) or "")
    end
    for _, f in ipairs(list(td:get_fields())) do
        result.fields[#result.fields + 1] = f:get_name() .. " : " .. f:get_type():get_full_name()
    end
    return result
end

local function scene_now()
    local sm = sdk.get_native_singleton("via.SceneManager")
    if not sm then return nil end
    return sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
end

local function current()
    local scene = scene_now()
    local manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
    assert(scene and manager, "Load a playable scene first.")
    local player = manager:call("getPlayerContextRef()")
    assert(player, "Local player context unavailable.")
    local body = player:call("get_BodyGameObject")
    assert(body, "Local player body unavailable.")
    local id = player:call("get_ID")
    assert(id, "Local player ID unavailable.")
    local identity = {
        scene = tostring(scene:get_address()), manager = tostring(manager:get_address()),
        body = tostring(body:get_address()), player_code = id:call("get_Code"),
    }
    return scene, manager, player, identity
end

local function same_identity(identity)
    if not S.identity or S.revoked then return false end
    for _, k in ipairs({"scene", "manager", "body", "player_code"}) do
        if identity[k] ~= S.identity[k] then return false end
    end
    return true
end

local function pose_now()
    local bridge = _G.RE4LAN_visual
    assert(bridge and bridge.version == 1, "Install RE4LAN.lua v0.3.0 and start host/join or echo.")
    local pose = bridge.get_pose()
    assert(pose and type(pose.pos) == "table", "No fresh partner pose. Start host/join or echo.")
    for i = 1, 3 do
        local n = pose.pos[i]
        assert(type(n) == "number" and n == n and math.abs(n) < 1e7, "Invalid partner position.")
    end
    assert(type(pose.yaw) == "number" and pose.yaw == pose.yaw and math.abs(pose.yaw) < 1e7,
        "Invalid partner rotation.")
    return pose
end

-- Keep nil/false distinct and serialize primitives only. Diagnostics must never
-- retain a native object between callbacks or let a failed getter abort cleanup.
local function value_summary(value)
    if value == nil then return { is_nil = true } end
    local t = type(value)
    if t == "number" or t == "string" or t == "boolean" then return value end
    local result = { lua_type = t }
    pcall(function() result.type = value:get_type_definition():get_full_name() end)
    pcall(function() result.address = tostring(value:get_address()) end)
    return result
end

local function read_getters(obj, names)
    local result = {}
    for _, name in ipairs(names) do
        local ok, value = pcall(function() return value_summary(obj:call(name)) end)
        if ok then result[name] = value else result[name] = { unavailable = tostring(value) } end
    end
    return result
end

local function zero_method(obj, name)
    -- Compiler-generated IEnumerable implementations may use explicit interface names.
    local td = obj:get_type_definition()
    local direct = td:get_method(name)
    if direct then return direct end
    for _, method in ipairs(list(td:get_methods())) do
        local n = method:get_name()
        if n:sub(-#name - 1) == "." .. name and #list(method:get_param_types()) == 0 then
            return method
        end
    end
end

local function children(xf)
    local arr = xf:call("get_Children")
    if not arr then return {} end
    local ok, elements = pcall(function() return arr:get_elements() end)
    if ok and elements then return list(elements) end
    if type(arr) == "table" and not arr.get_type_definition then return arr end
    -- RE4 returns IEnumerable<Transform>, not an indexed List or managed array.
    local get_enum = assert(zero_method(arr, "GetEnumerator"), "Children.GetEnumerator unavailable")
    local enumerator = assert(get_enum:call(arr), "Children enumerator is nil")
    local success, result, clipped = pcall(function()
        local next_item = assert(zero_method(enumerator, "MoveNext"), "Children.MoveNext unavailable")
        local get_current = assert(zero_method(enumerator, "get_Current"), "Children.Current unavailable")
        local values = {}
        for _ = 1, 129 do
            local more = next_item:call(enumerator)
            assert(type(more) == "boolean", "Children.MoveNext did not return Boolean")
            if not more then return values, false end
            if #values == 128 then return values, true end
            values[#values + 1] = assert(get_current:call(enumerator), "Children.Current is nil")
        end
    end)
    pcall(function()
        local dispose = zero_method(enumerator, "Dispose")
        if dispose then dispose:call(enumerator) end
    end)
    if not success then error(result) end
    return result, clipped
end

local DRAW_GETTERS = {"get_DrawSelf", "get_Draw", "get_UpdateSelf", "get_Update", "get_Valid"}
local function inspect_tree(root)
    local result = { nodes = {}, mesh_count = 0, truncated = false, errors = {} }
    local seen = {}
    local function inspect(go, depth)
        if #result.nodes >= 128 then result.truncated = true; return end
        local address = tostring(go:get_address())
        if seen[address] then return end
        seen[address] = true
        local node = { address = address, depth = depth, state = read_getters(go, DRAW_GETTERS), components = {} }
        result.nodes[#result.nodes + 1] = node
        pcall(function() node.name = tostring(go:call("get_Name")) end)
        local xf = go:call("get_Transform")
        pcall(function()
            local p = xf:call("get_Position")
            node.position = {p.x, p.y, p.z}
        end)
        local ok_scale, scale = pcall(function()
            local p = xf:call("get_Scale")
            return {p.x, p.y, p.z}
        end)
        if ok_scale then node.scale = scale end
        local comps = go:call("get_Components")
        for _, comp in ipairs(comps and list(comps:get_elements()) or {}) do
            local td = comp:get_type_definition()
            local entry = { type = td:get_full_name() }
            node.components[#node.components + 1] = entry
            if entry.type == "via.motion.Motion" then
                entry.motion = read_getters(comp, {"get_JointCount", "get_JointsConstructed"})
                pcall(function()
                    local count = comp:call("getLayerCount")
                    entry.layers = {}
                    for i = 0, math.min(count, 8) - 1 do
                        local layer = comp:call("getLayer", i)
                        if layer then entry.layers[#entry.layers + 1] = read_getters(layer,
                            {"get_MotionBankID", "get_MotionID", "get_Frame", "get_EndFrame", "get_Running",
                            "get_StopUpdate", "get_Setuped", "get_Jacked", "get_LayerNo"}) end
                    end
                end)
            end
            if td:is_a("chainsaw.CharacterBodyUpdater") then
                local ok, ctx = pcall(function() return comp:call("get_Context") end)
                if ok then
                    entry.context = value_summary(ctx)
                    if ctx then
                        entry.context_values = read_getters(ctx,
                            {"get_KindID", "get_CostumePresetID", "get_IsCostumeChanging", "get_Setupped",
                            "get_HitPoint", "get_HitPointVital", "get_BodyGameObject"})
                    end
                else entry.context = { unavailable = tostring(ctx) } end
            end
            if entry.type == "chainsaw.HitController" then
                entry.combat = read_getters(comp, {"get_Context", "get_CurrentHitPoint", "get_Invincible",
                    "get_AttackEnable", "get_DamageToParent", "get_Setuped", "get_RegisteredHitManager",
                    "get_Colliders", "get_DamageCalcInfo", "get_AttackOwner", "get_DamageOwner"})
            end
            if entry.type:find("^via%.render%.") then
                if td:is_a("via.render.Mesh") or entry.type == "via.render.CompositeMesh" then
                    result.mesh_count = result.mesh_count + 1
                end
                -- Read only methods that introspection confirms exist. No guessed setters.
                entry.properties = {}
                for _, name in ipairs({"get_Enabled", "get_Visible", "getMesh", "get_MeshReady",
                    "get_Material", "get_MaterialReady", "get_Valid", "get_SharedSkeleton"}) do
                    local ok, method = pcall(function() return td:get_method(name) end)
                    if ok and method then
                        local values = read_getters(comp, {name})
                        entry.properties[name] = values[name]
                    end
                end
            end
        end
        if depth >= 8 then result.truncated = true; return end
        local ok, next_children, clipped = pcall(children, xf)
        if not ok then node.children_error = tostring(next_children); return end
        if clipped then result.truncated = true end
        for _, child in ipairs(next_children) do
            if #result.nodes >= 128 then result.truncated = true; break end
            local child_ok, child_err = pcall(function()
                local parent = child:call("get_Parent")
                assert(parent and tostring(parent:get_address()) == tostring(xf:get_address()),
                    "Child has a different parent; skipped")
                local child_go = child:call("get_GameObject")
                if child_go then inspect(child_go, depth + 1) end
            end)
            if not child_ok then result.errors[#result.errors + 1] = tostring(child_err) end
        end
    end
    local ok, err = pcall(inspect, root, 0)
    if not ok then result.errors[#result.errors + 1] = tostring(err) end
    -- Ancestors/folders may suppress effective Draw even when DrawSelf is true.
    -- They are reported read-only; changing shared containers could affect the game.
    result.ancestors = {}
    pcall(function()
        local xf = root:call("get_Transform"):call("get_Parent")
        for _ = 1, 8 do
            if not xf then break end
            local go = xf:call("get_GameObject")
            if go then
                local item = read_getters(go, DRAW_GETTERS)
                item.name = tostring(go:call("get_Name"))
                result.ancestors[#result.ancestors + 1] = item
            end
            xf = xf:call("get_Parent")
        end
    end)
    local ok_folder, folder = pcall(function() return root:call("get_Folder") end)
    if ok_folder then
        result.folder = value_summary(folder)
        if folder then result.folder_state = read_getters(folder,
            {"get_Name", "get_Draw", "get_DrawSelf", "get_Update", "get_UpdateSelf"}) end
    else result.folder = { unavailable = tostring(folder) } end
    return result
end

local function visual_snapshot(go, label)
    S.report.visuals = S.report.visuals or {}
    if #S.report.visuals >= 12 then return end
    local snapshot = inspect_tree(go)
    snapshot.label, snapshot.elapsed = label, os.time() - S.started
    S.report.visuals[#S.report.visuals + 1] = snapshot
    write_report()
end

local function capture()
    S.report.api = {}
    for _, name in ipairs({
        "chainsaw.ContextID", "chainsaw.ContextID.EntityCategory", "chainsaw.CharacterManager",
        "chainsaw.CharacterBodyPoolInfo", "chainsaw.CharacterHeadPoolInfo",
        "chainsaw.CharacterInstanceCoordinator.InstancePoolInfo",
        "chainsaw.CharacterLinkCoordinator.CharacterLinkInfo", "chainsaw.BodyUpdater",
        "via.Scene", "via.GameObject", "via.Transform", "via.Component",
        "via.Folder", "via.render.Mesh", "via.render.CompositeMesh",
        "via.motion.Motion", "via.motion.MotionFsm2", "via.motion.TreeLayer",
        "chainsaw.CostumeManager", "chainsaw.CostumeManager.CostumeApplyingInfo",
        "chainsaw.CostumeManager.CostumeChangeRequest", "chainsaw.CostumeManager.CostumeDiscardRequest",
        "chainsaw.CostumeManager.Results", "chainsaw.CharacterContext",
        "chainsaw.CostumeManager.CostumeApplyingInfo.State",
        "chainsaw.GPUClothCharacter", "chainsaw.GPUClothCharacterPart", "via.dynamics.GpuCloth",
        "via.Joint", "via.motion.MotionNodeCtrl", "chainsaw.HitController", "chainsaw.HitManager",
        "chainsaw.CharacterDamageInfo", "chainsaw.HitController.DamageInfo",
        "chainsaw.character.ControlMode",
    }) do
        local ok, result = pcall(api, name)
        S.report.api[name] = ok and result or { unavailable = tostring(result) }
    end
    local ok, result = pcall(function()
        local _, _, player, identity = current()
        local values = { identity = identity, kind = player:call("get_KindID") }
        for _, field in ipairs({"get_SpawnerID", "get_CostumePresetID", "get_CurrentStageID"}) do
            local success, value = pcall(function()
                local v = player:call(field)
                if field == "get_SpawnerID" and v then return v:call("get_Code") end
                return v
            end)
            if success and (type(value) == "number" or type(value) == "string") then
                values[field] = value
            elseif not success then values[field] = tostring(value) end
        end
        return values
    end)
    S.report.local_player = ok and result or { unavailable = tostring(result) }
    local tree_ok, tree = pcall(function()
        local _, _, player = current()
        return inspect_tree(player:call("get_BodyGameObject"))
    end)
    S.report.local_visual = tree_ok and tree or { unavailable = tostring(tree) }
    write_report()
end

local function start()
    assert(not S.attempted, "One body request per script session; restart the game before another test.")
    pose_now() -- No native mutation until game and network prerequisites pass.
    local _, manager, player, identity = current()
    local td = manager:get_type_definition()
    for _, method in ipairs({"generateDynamicContextID", "requestCreateBody", "requestDestroyBody"}) do
        assert(td:get_method(method), "Missing CharacterManager API: " .. method)
    end
    local purpose_td = sdk.find_type_definition("chainsaw.CharacterUsePurposeFlag")
    local dynamic = purpose_td and purpose_td:get_field("Dynamic")
    local purpose = dynamic and dynamic:get_data(nil)
    assert(purpose == 2, "Unexpected Dynamic enum; capture API before proceeding.")
    local kind = player:call("get_KindID")
    assert(type(kind) == "number" and kind >= 0, "No valid local character template.")
    capture()

    local id = manager:call("generateDynamicContextID()")
    assert(id, "generateDynamicContextID returned nil.")
    local code = id:call("get_Code")
    assert(type(code) == "number" and code >= 0 and code < 4294967295 and code % 1 == 0
        and code ~= identity.player_code,
        "New context ID is empty or matches the local player.")
    S.identity, S.context_code = identity, code
    S.report.kind, S.report.purpose = kind, purpose
    S.attempted, S.started, S.start_frame = true, os.time(), S.frame
    S.deadline = S.started + TEST_SECONDS
    status("requesting", "Calling requestCreateBody once; no head or control request.")
    -- Unique overload in api4. Passing a nil callback is experimental; the scan
    -- establishes the signature, not native null handling. Discover ownership
    -- independently via InstanceDemandID + InstanceParentID if creation succeeds.
    local request = manager:call("requestCreateBody", id, kind, purpose, nil)
    assert(type(request) == "number" and request >= 0 and request % 1 == 0,
        "No usable body request ID returned; restart before another test.")
    S.request_id, S.next_search = request, 0
    status("waiting", "Body request accepted; waiting for an owned body (15 s limit).")
end

local function owned_component(component)
    local td = component:get_type_definition()
    if not td:is_a("chainsaw.CharacterBodyUpdater") then return false end
    local demand = component:call("get_InstanceDemandID")
    local parent = component:call("get_InstanceParentID")
    local parent_code = parent and parent:call("get_Code")
    local owned = demand == S.request_id and parent_code == S.context_code
    if not S.name and (#S.report.body_candidates < 32 or owned) then
        local go = component:call("get_GameObject")
        S.report.body_candidates[#S.report.body_candidates + 1] = {
            request_id = demand, parent_code = parent_code,
            name = go and tostring(go:call("get_Name")) or "<nil>",
        }
    end
    return owned
end

local function verify_object(go)
    if not go or tostring(go:get_address()) == S.identity.body then return false end
    local components = go:call("get_Components")
    if not components then return false end
    for _, component in ipairs(list(components:get_elements())) do
        if owned_component(component) then return true end
    end
    return false
end

local function find_owned(scene)
    -- Never keep native objects across callbacks. Once renamed, reacquire and verify
    -- BOTH ownership identifiers on each use, rather than trusting the object name.
    if S.name then
        local go = scene:call("findGameObject(System.String)", S.name)
        if go and verify_object(go) then return go end
        return nil
    end
    S.report.body_candidates = {}
    local ok, elements = pcall(function()
        local rt = sdk.find_type_definition("chainsaw.CharacterBodyUpdater"):get_runtime_type()
        return scene:call("findComponents(System.Type)", rt):get_elements()
    end)
    if ok and elements then
        for _, component in ipairs(list(elements)) do
            if owned_component(component) then
                local go = component:call("get_GameObject")
                if verify_object(go) then return go end
            end
        end
    else S.report.fast_search_error = tostring(elements) end

    -- Temporary discovery only, once per second while waiting. No persistent cursor
    -- into the scene, no component cache, and no full scan during active following.
    local xf, count = scene:call("get_FirstTransform"), 0
    while xf and count < 10000 do
        count = count + 1
        local go = xf:call("get_GameObject")
        if go and verify_object(go) then return go end
        xf = xf:call("get_Next")
    end
    S.report.last_search_count, S.report.search_truncated = count, xf ~= nil
    return nil
end

local function costume_manager(manager)
    local cm = assert(manager:call("get_CostumeManager"), "CostumeManager unavailable")
    if S.costume_manager_address then
        assert(tostring(cm:get_address()) == S.costume_manager_address, "CostumeManager changed; restart game")
    end
    return cm
end

local function costume_state(cm, go)
    local function count(getter)
        local queue = assert(cm:call(getter), getter .. " returned nil")
        local n = queue:call("get_Count")
        assert(type(n) == "number" and n >= 0 and n % 1 == 0, getter .. " count unavailable")
        return n
    end
    local info = assert(cm:call("get_CostumeApplyingInfoList"), "Costume registry unavailable")
    local registered = info:call("ContainsKey", go)
    assert(type(registered) == "boolean", "Costume registry lookup unavailable")
    local state = { change_requests = count("get_CostumeChangeRequestList"),
        discard_requests = count("get_CostumeDiscardRequestList"), registered = registered }
    if registered then
        local ok, detail = pcall(function()
            local item = assert(info:call("get_Item", go), "Costume entry unavailable")
            local owner = assert(item:call("get_OwnerGameObject"), "Costume entry owner unavailable")
            assert(tostring(owner:get_address()) == tostring(go:get_address()), "Costume entry owner mismatch")
            local entries = assert(item:call("get_CostumeInfoList"), "Costume data list unavailable")
            return { empty = item:call("get_Empty"), state = item:call("get_CurrentState"),
                reserve_discard = item:call("get_ReserveDiscard"), count = entries:call("get_Count") }
        end)
        if ok then state.entry = detail else state.entry_error = tostring(detail) end
    end
    return state
end

local function apply_costume()
    assert(S.phase == "active" and not S.costume_attempted, "Costume test requires an active body; once per session")
    local ok, scene, manager, player, identity = pcall(current)
    if not ok or not same_identity(identity) then
        status("abandoned", "Scene/player changed before costume request. Restart game.")
        return
    end
    local go = assert(find_owned(scene), "Owned body unavailable")
    local cm = costume_manager(manager)
    local td = cm:get_type_definition()
    for _, name in ipairs({"requestCostumeChange", "requestCostumeDiscard", "isExistAsset"}) do
        assert(td:get_method(name), "Missing CostumeManager API: " .. name)
    end
    local preset = player:call("get_CostumePresetID")
    assert(type(preset) == "number" and preset > 0 and preset < 4294967296 and preset % 1 == 0,
        "Local costume preset unavailable")
    assert(player:call("get_KindID") == S.report.kind, "Local character kind changed")
    assert(cm:call("isExistAsset", S.report.kind, preset) == true, "Local costume asset unavailable")
    local before = costume_state(cm, go)
    assert(before.change_requests == 0 and before.discard_requests == 0 and not before.registered,
        "CostumeManager busy or owned body already registered; restart before another test")
    visual_snapshot(go, "before_costume")
    assert(verify_object(go), "Body ownership changed before costume request")
    S.costume_manager_address = tostring(cm:get_address())
    S.costume_attempted, S.costume_started = true, os.time()
    S.deadline = S.costume_started + TEST_SECONDS
    S.report.costume = { preset = preset, kind = S.report.kind, before = before,
        request_attempted = true, callback = "nil (experimental)", samples = {} }
    write_report() -- Keep evidence even if the native request fails.
    cm:call("requestCostumeChange", go, S.report.kind, preset, nil)
    S.report.costume.request_returned = true
    status("active", "Costume requested for owned body. Wait 10 seconds; appearance is unverified.")
end

local function cleanup_costume(scene, manager)
    -- Both queues are global. Waiting for zero is deliberately conservative: a
    -- pending change must not recreate resources after the body has been freed.
    local go = assert(find_owned(scene), "Owned body unavailable for costume cleanup; restart game")
    local cm = costume_manager(manager)
    local state = costume_state(cm, go)
    S.report.costume.cleanup_state = state
    if os.time() - S.cleanup_started >= 15 then
        status("cleanup_blocked", "Costume cleanup not confirmed within 15 seconds. Restart game before saving.")
        return
    end
    if state.change_requests > 0 then write_report(); return end
    if not S.costume_discard_sent then
        cm:call("requestCostumeDiscard", go)
        S.costume_discard_sent = true
        S.report.costume.discard_sent = true
        write_report()
        return -- Observe the asynchronous discard on a later update.
    end
    -- RE4 retains an empty CostumeApplyingInfo entry after discarding meshes.
    -- Presence of the cache key alone does not mean a costume is still loaded.
    local entry = state.entry
    local released = not state.registered or (entry and entry.empty == true
        and entry.count == 0 and entry.reserve_discard == false)
    if not released or state.discard_requests > 0 then
        S.empty_seen = nil
        write_report(); return
    end
    if not S.empty_seen then S.empty_seen = os.time(); write_report(); return end
    if os.time() <= S.empty_seen then return end
    manager:call("requestDestroyBody", S.request_id)
    S.cleanup_sent = true
    status("removal_requested", "Costume resources reported empty; body deletion requested. Restart before another test.")
end

local function remove(reason)
    if not S.request_id or S.cleanup_sent then return end
    if not S.report.stop_reason then
        S.report.stop_reason, S.report.stopped_elapsed = reason, os.time() - S.started
    end
    if S.phase == "costume_cleanup" or S.phase == "cleanup_blocked" then return end
    local ok, scene, manager, player, identity = pcall(current)
    if not ok or not same_identity(identity) then
        status("abandoned", "Scene/player changed; old request ID will not be used for cleanup.")
        return
    end
    if S.name then
        local read_ok, go = pcall(find_owned, scene)
        if read_ok and go then visual_snapshot(go, "before_remove") end
    end
    if S.costume_attempted then
        S.cleanup_started = S.cleanup_started or os.time()
        S.next_cleanup = os.time() + 1
        status("costume_cleanup", reason .. " Waiting for costume requests and resource discard.")
        cleanup_costume(scene, manager)
        return
    end
    manager:call("requestDestroyBody", S.request_id)
    S.cleanup_sent = true
    status("removal_requested", reason .. " Engine deletion is asynchronous; restart before another test.")
end

local function cloth_component(go)
    for _, comp in ipairs(list(go:call("get_Components"):get_elements())) do
        if comp:get_type_definition():get_full_name() == "chainsaw.GPUClothCharacter" then return comp end
    end
end

local function enable_cloth()
    assert(S.phase == "active" and S.costume_attempted, "Load the owned costume first")
    local ok, scene, _, _, identity = pcall(current)
    if not ok or not same_identity(identity) then
        status("abandoned", "Scene/player changed before cloth test. Restart game."); return
    end
    local go = assert(find_owned(scene), "Owned body unavailable")
    local cloth = assert(cloth_component(go), "Owned GPUClothCharacter unavailable")
    assert(cloth:get_type_definition():get_method("teleportGpuCloth"), "Cloth teleport API unavailable")
    visual_snapshot(go, "before_cloth_follow")
    S.cloth_follow = true
    S.report.cloth = { enabled = true, calls = 0, method = "GPUClothCharacter.teleportGpuCloth" }
    status("active", "Cloth teleport test enabled for owned body. Observe jacket while partner moves.")
end

local function update()
    S.frame = S.frame + 1
    if S.action then
        local action = S.action
        S.action = nil
        if action == "capture" then capture()
        elseif action == "start" then start()
        elseif action == "remove" then remove("Manual removal.")
        elseif action == "costume" then apply_costume()
        elseif action == "cloth" then enable_cloth() end
    end
    if S.phase == "costume_cleanup" then
        local ok, scene, manager, _, identity = pcall(current)
        if not ok or not same_identity(identity) then
            status("abandoned", "Scene/player changed during costume cleanup. Restart game.")
            return
        end
        if os.time() >= (S.next_cleanup or 0) then
            S.next_cleanup = os.time() + 1
            cleanup_costume(scene, manager)
        end
        return
    end
    if S.phase ~= "waiting" and S.phase ~= "active" then return end
    local ok, scene, _, _, identity = pcall(current)
    if not ok or not same_identity(identity) then
        status("abandoned", "Scene/player changed; tracking stopped. Restart before another test.")
        return
    end
    local now = os.time()
    if now >= S.deadline then
        remove("180-second test timer expired.")
        return
    end
    if S.phase == "waiting" then
        if now - S.started >= 15 or S.frame - S.start_frame >= 3600 then
            remove("Timed out finding the owned body.")
        elseif now >= S.next_search then
            S.next_search = now + 1
            local go = find_owned(scene)
            if go then
                local name = "RE4LAN_VisualProbe_" .. tostring(S.context_code)
                assert(not scene:call("findGameObject(System.String)", name), "Probe object name already in use.")
                S.name = name
                go:call("set_Name", name)
                visual_snapshot(go, "before_draw")
                -- The user report confirms this setter exists. Affect only our
                -- verified root, never a shared folder, ancestor or local player.
                assert(verify_object(go), "Body ownership changed before enabling DrawSelf.")
                local before = go:call("get_DrawSelf")
                assert(type(before) == "boolean", "DrawSelf could not be read as a boolean.")
                S.report.draw_change = { before = before, called = false }
                if not before then
                    go:call("set_DrawSelf", true)
                    S.report.draw_change.called = true
                end
                S.report.draw_change.after = go:call("get_DrawSelf")
                visual_snapshot(go, "after_draw")
                S.active_since, S.active_frame = now, S.frame
                status("active", "Owned body found; DrawSelf checked. Collecting visibility diagnostics.")
            end
        end
    elseif S.phase == "active" then
        local label
        if not S.visual_1s and now - S.active_since >= 1 then
            S.visual_1s, label = true, "after_1s"
        elseif not S.visual_3s and now - S.active_since >= 3 then
            S.visual_3s, label = true, "after_3s"
        end
        if label then
            local go = find_owned(scene)
            if go then visual_snapshot(go, label) end
        end
        if S.costume_attempted then
            for _, seconds in ipairs({1, 3, 10}) do
                local samples = S.report.costume.samples
                if now - S.costume_started >= seconds and not samples[tostring(seconds)] then
                    local go = assert(find_owned(scene), "Owned body unavailable")
                    local _, manager = current()
                    local ok_state, state = pcall(function() return costume_state(costume_manager(manager), go) end)
                    samples[tostring(seconds)] = ok_state and state or { unavailable = tostring(state) }
                    visual_snapshot(go, "costume_after_" .. seconds .. "s")
                    break
                end
            end
        end
    end
end

local function follow()
    if S.phase ~= "active" then return end
    local scene, _, _, identity = current()
    if not same_identity(identity) then
        status("abandoned", "Scene/player changed; pose writes stopped.")
        return
    end
    local pose_ok, pose = pcall(pose_now)
    if not pose_ok then remove("Partner data unavailable."); return end
    local go = find_owned(scene)
    if not go then remove("Owned body no longer found."); return end
    local xf = go:call("get_Transform")
    local rotation = Quaternion.new()
    rotation.x, rotation.y, rotation.z, rotation.w = 0, math.sin(pose.yaw / 2), 0, math.cos(pose.yaw / 2)
    xf:call("set_Position", Vector3f.new(pose.pos[1], pose.pos[2], pose.pos[3]))
    xf:call("set_Rotation", rotation)
    if S.cloth_follow then
        local cloth = assert(cloth_component(go), "Owned cloth component disappeared")
        cloth:call("teleportGpuCloth")
        S.report.cloth.calls = S.report.cloth.calls + 1
        if S.report.cloth.calls == 1 then visual_snapshot(go, "after_cloth_follow") end
    end
    S.moves = S.moves + 1
    if S.moves == 1 then
        S.report.first_pose = { pos = pose.pos, yaw = pose.yaw }
        local actual = xf:call("get_Position")
        S.report.position_after_write = { actual.x, actual.y, actual.z }
        write_report()
    end
end

local function guarded(fn)
    local ok, err = pcall(fn)
    if not ok then status("error", tostring(err)) end
end

-- Queue UI actions; perform native changes at game-update boundaries.
re.on_application_entry("UpdateBehavior", function() guarded(update) end)
re.on_application_entry("LateUpdateBehavior", function() guarded(follow) end)
re.on_script_reset(function() guarded(function() remove("Script reset.") end) end)
re.on_draw_ui(function()
    if not imgui.tree_node("RE4LAN Model Probe") then return end
    imgui.text("v0.3.3 | Owned-body costume / cloth test | default OFF")
    imgui.text("No animation or combat sync. 180 seconds after the costume request.")
    imgui.text("Use a disposable game session; restart after the test before saving.")
    imgui.text("State: " .. S.phase)
    imgui.text(S.message)
    if S.phase == "active" or S.phase == "waiting" then
        imgui.text("Auto-remove in: " .. math.max(0, S.deadline - os.time()) .. " seconds")
    end
    if S.report.draw_change then
        imgui.text("DrawSelf: " .. tostring(S.report.draw_change.before) .. " -> " .. tostring(S.report.draw_change.after))
    end
    if imgui.button("Capture model API (read-only)") then S.action = "capture" end
    if not S.attempted and imgui.button("TEST: create one visual body") then S.action = "start" end
    if S.phase == "active" and not S.costume_attempted and imgui.button("TEST: apply local costume") then
        S.action = "costume"
    end
    if S.phase == "active" and S.costume_attempted and not S.cloth_follow
        and imgui.button("TEST: follow cloth (teleport)") then S.action = "cloth" end
    if S.request_id and not S.cleanup_sent and imgui.button("Remove test body") then S.action = "remove" end
    imgui.text("Report: reframework/data/" .. REPORT)
    if S.report_write_ok == false then imgui.text("Report write failed; check reframework.log.") end
    imgui.tree_pop()
end)
