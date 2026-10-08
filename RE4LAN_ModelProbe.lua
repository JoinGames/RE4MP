-- RE4LAN Model Probe v0.3.0. Optional, manual, one body request per script session.
-- Uses APIs observed in RE4MP_scout_api4.json; native behavior is experimental.
-- No player/partner slot changes, head/AI creation, inventory or save operations.
-- Install beside RE4LAN.lua. See docs/MODEL_PROBE.md before running the test.

local REPORT = "RE4LAN_model_probe.json"
local S = {
    phase = "idle", message = "Capture API or start the manual body test.",
    action = nil, attempted = false, request_id = nil, context_code = nil,
    identity = nil, name = nil, cleanup_sent = false, frame = 0,
    started = nil, next_search = 0, moves = 0, report = { version = "0.3.0" },
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
        result.methods[#result.methods + 1] = m:get_name() .. "(" .. table.concat(params, ",") .. ")"
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

local function capture()
    S.report.api = {}
    for _, name in ipairs({
        "chainsaw.ContextID", "chainsaw.ContextID.EntityCategory", "chainsaw.CharacterManager",
        "chainsaw.CharacterBodyPoolInfo", "chainsaw.CharacterHeadPoolInfo",
        "chainsaw.CharacterInstanceCoordinator.InstancePoolInfo",
        "chainsaw.CharacterLinkCoordinator.CharacterLinkInfo", "chainsaw.BodyUpdater",
        "via.Scene", "via.GameObject", "via.Transform", "via.Component",
        "via.motion.Motion", "via.motion.MotionFsm2", "via.motion.MotionLayer",
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

local function remove(reason)
    if not S.request_id or S.cleanup_sent then return end
    local ok, scene, manager, player, identity = pcall(current)
    if not ok or not same_identity(identity) then
        status("abandoned", "Scene/player changed; old request ID will not be used for cleanup.")
        return
    end
    manager:call("requestDestroyBody", S.request_id)
    S.cleanup_sent = true
    status("removal_requested", reason .. " Engine deletion is asynchronous; restart before another test.")
end

local function update()
    S.frame = S.frame + 1
    if S.action then
        local action = S.action
        S.action = nil
        if action == "capture" then capture()
        elseif action == "start" then start()
        elseif action == "remove" then remove("Manual removal.") end
    end
    if S.phase ~= "waiting" and S.phase ~= "active" then return end
    local ok, scene, _, _, identity = pcall(current)
    if not ok or not same_identity(identity) then
        status("abandoned", "Scene/player changed; tracking stopped. Restart before another test.")
        return
    end
    local now = os.time()
    if now - S.started >= 60 or S.frame - S.start_frame >= 14400 then
        remove("60-second test finished.")
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
                -- No guessed animation/FSM or collision changes. First establish
                -- that an independently requested body exists and accepts its pose.
                status("active", "Owned body found; following partner. Visibility/animation unverified.")
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
    imgui.text("v0.3.0 | Experimental visual body test | default OFF")
    imgui.text("No animation or combat sync. Test lasts up to 60 seconds.")
    imgui.text("Use a disposable game session; restart after the test before saving.")
    imgui.text("State: " .. S.phase)
    imgui.text(S.message)
    if imgui.button("Capture model API (read-only)") then S.action = "capture" end
    if not S.attempted and imgui.button("TEST: create one visual body") then S.action = "start" end
    if S.request_id and not S.cleanup_sent and imgui.button("Remove test body") then S.action = "remove" end
    imgui.text("Report: reframework/data/" .. REPORT)
    if S.report_write_ok == false then imgui.text("Report write failed; check reframework.log.") end
    imgui.tree_pop()
end)
