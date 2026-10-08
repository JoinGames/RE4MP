"""Lifecycle/ownership checks for the actual Lua probe, with a fake native API.

No assertions here establish that RE4 can instantiate or render the requested body.
"""
import math
from pathlib import Path
import unittest

from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
now = 1000
scene_address, manager_address, player_address = 10, 20, 30
player_code, new_code = 262148, 900
remote_live, scene_live = true, true
body_ready, wrong_owner, fail_create, fail_destroy = true, false, false, false
pose_x, pose_yaw = 8, math.pi / 2
created, destroyed, renamed, moved, generated = 0, 0, 0, 0, 0
draw_self, inherited_draw, update_self = false, true, false
draw_writes, child_draw_writes, source_draw_writes = 0, 0, 0
mesh_present, mesh_enabled, include_foreign_child = true, false, false
draw_setter_fails, children_fail = false, false
enumerable_children, enumeration_error, explicit_interfaces = false, false, false
enumerator_disposed, extra_children = 0, 0
costume_requests, costume_discards = 0, 0
costume_changes_pending, costume_discards_pending = 0, 0
costume_registered, costume_asset, costume_fail, costume_counts_fail = false, true, false, false
costume_address = 60
pending_button = nil
os.time = function() return now end
Vector3f = {new = function(x,y,z) return {x=x,y=y,z=z} end}
Quaternion = {new = function() return {} end}
RE4LAN_visual = {version=1, get_pose=function()
    if remote_live then return {pos={pose_x,2,3}, yaw=pose_yaw} end
end}
json = {dump_file = function(_, value) report = value; return true end}
log = {info = function(s) last_log = s end}
imgui = {
    tree_node = function() return true end,
    tree_pop = function() end,
    text = function() end,
    button = function(label)
        if label == pending_button then pending_button = nil; return true end
        return false
    end,
}
local function array(values) return {get_elements = function() return values end} end
local function enumerable(values)
    local index = 0
    local function object(methods)
        local defs = {}
        for name, fn in pairs(methods) do
            defs[#defs+1] = {get_name=function() return explicit_interfaces and ("Some.Interface."..name) or name end,
                get_param_types=function() return {} end, call=function() return fn() end}
        end
        return {get_type_definition=function() return {
            get_methods=function() return defs end,
            get_method=function(_, name)
                for _, d in ipairs(defs) do if d:get_name()==name then return d end end
            end,
        } end}
    end
    local e = object({MoveNext=function()
        index=index+1
        if enumeration_error then error("enumeration failed") end
        return index<=#values
    end, get_Current=function() return values[index] end,
    Dispose=function() enumerator_disposed=enumerator_disposed+1 end})
    return object({GetEnumerator=function() return e end})
end
local function id(code) return {call=function(_, method) assert(method=="get_Code", method); return code end} end
local td = {
    get_full_name = function() return "chainsaw.Ch0a0z0BodyUpdater" end,
    get_methods = function() return {} end,
    get_fields = function() return {} end,
    get_method = function() return {} end,
    get_runtime_type = function() return {} end,
    is_a = function(_, name) return name == "chainsaw.CharacterBodyUpdater" end,
    get_field = function(_, name)
        assert(name=="Dynamic", name)
        return {get_data=function() return 2 end}
    end,
}
local original_body = {get_address=function() return player_address end}
original_body.call = function(_, method)
    if method=="set_DrawSelf" then source_draw_writes=source_draw_writes+1; error("Do not change source") end
    if method=="get_Name" then return "local_player" end
    if method=="get_Components" then return array({}) end
    if method:find("^get_") then return true end
    error(method)
end
local child_xf, foreign_xf
local xf = {get_address=function() return 41 end, call=function(_, method, value)
    if method == "set_Position" then moved = moved + 1; last_position = value; return end
    if method == "set_Rotation" then last_rotation = value; return end
    if method == "get_Position" then return last_position end
    if method == "get_Scale" then return {x=1,y=1,z=1} end
    if method == "get_Parent" then return nil end
    if method == "get_Children" then
        if children_fail then error("children unavailable") end
        local values = include_foreign_child and {child_xf, foreign_xf} or {child_xf}
        for _=1,extra_children do values[#values+1]=child_xf end
        return enumerable_children and enumerable(values) or array(values)
    end
    error("Unexpected transform call: " .. method)
end}
local body = {get_address=function() return 40 end}
local comp = {
    get_type_definition=function() return td end,
    call=function(_, method)
        if method=="get_InstanceDemandID" then return 7 end
        if method=="get_InstanceParentID" then return id(wrong_owner and 123 or new_code) end
        if method=="get_GameObject" then return body end
        if method=="get_Context" then return nil end
        error("Unexpected component call: " .. method)
    end,
}
body.call=function(_, method, value)
    if method=="get_Name" then return body_name or "ch0a0z0_body" end
    if method=="get_Components" then return array({comp}) end
    if method=="get_Transform" then return xf end
    if method=="set_Name" then renamed=renamed+1; body_name=value; return end
    if method=="get_DrawSelf" then return draw_self end
    if method=="get_Draw" then return draw_self and inherited_draw end
    if method=="get_UpdateSelf" or method=="get_Update" then return update_self end
    if method=="get_Valid" then return true end
    if method=="get_Folder" then return nil end
    if method=="set_DrawSelf" then
        if draw_setter_fails then error("draw setter failed") end
        draw_writes=draw_writes+1; draw_self=value; return
    end
    error("Unexpected body call: " .. method)
end
local mesh = {
    get_type_definition=function()
        return {
            get_full_name=function() return "via.render.Mesh" end,
            is_a=function(_, name) return name=="via.render.Mesh" end,
            get_method=function(_, name)
                if name=="get_Enabled" or name=="getMesh" or name=="get_MeshReady" then return {} end
            end,
        }
    end,
    call=function(_, method)
        if method=="get_Enabled" then return mesh_enabled end
        if method=="get_MeshReady" then return mesh_present end
        if method=="getMesh" then
            if not mesh_present then return nil end
            return {get_type_definition=function()
                return {get_full_name=function() return "via.render.MeshResourceHolder" end}
            end}
        end
        error(method)
    end,
}
local child = {get_address=function() return 50 end}
child_xf = {get_address=function() return 51 end, call=function(_, method)
    if method=="get_Parent" then return xf end
    if method=="get_Children" then return enumerable_children and enumerable({}) or array({}) end
    if method=="get_GameObject" then return child end
    if method=="get_Scale" then return {x=1,y=1,z=1} end
    error(method)
end}
child.call=function(_, method)
    if method=="get_Name" then return "costume_mesh" end
    if method=="get_Transform" then return child_xf end
    if method=="get_Components" then return array({mesh}) end
    if method=="get_DrawSelf" or method=="get_Draw" then return false end
    if method=="get_UpdateSelf" or method=="get_Update" or method=="get_Valid" then return true end
    if method=="set_DrawSelf" then child_draw_writes=child_draw_writes+1; error("Do not activate hidden child variants") end
    error(method)
end
foreign_xf = {call=function(_, method)
    if method=="get_Parent" then return {get_address=function() return 999 end} end
    error("Foreign object should not be traversed")
end}
local player = {call=function(_, method)
    if method=="get_BodyGameObject" then return original_body end
    if method=="get_ID" then return id(player_code) end
    if method=="get_KindID" then return 100000 end
    if method=="get_SpawnerID" then return id(262148) end
    if method=="get_CostumePresetID" then return 160198385 end
    if method=="get_CurrentStageID" then return 1 end
    error("Unexpected player call: " .. method)
end}
local scene = {
    get_address=function() return scene_address end,
    call=function(_, method, arg)
        if method=="findComponents(System.Type)" then
            if created>0 and body_ready then return array({comp}) end
            return array({})
        end
        if method=="findGameObject(System.String)" then
            if body_ready and arg==body_name then return body end
            return nil
        end
        if method=="get_FirstTransform" then return nil end
        error("Unexpected scene call: " .. method)
    end,
}
local costume_manager = {
    get_address=function() return costume_address end,
    get_type_definition=function() return td end,
    call=function(_, method, target, kind, preset, callback)
        if method=="isExistAsset" then
            assert(target==100000 and kind==160198385)
            return costume_asset
        end
        if method=="get_CostumeChangeRequestList" or method=="get_CostumeDiscardRequestList" then
            return {call=function(_, name)
                assert(name=="get_Count")
                if costume_counts_fail then return nil end
                return method=="get_CostumeChangeRequestList" and costume_changes_pending or costume_discards_pending
            end}
        end
        if method=="get_CostumeApplyingInfoList" then
            return {call=function(_, name, go)
                assert(name=="ContainsKey" and go==body, "Never query a different costume target")
                return costume_registered
            end}
        end
        assert(target==body, "Never mutate source or another costume target")
        if method=="requestCostumeChange" then
            assert(kind==100000 and preset==160198385 and callback==nil)
            costume_requests=costume_requests+1
            costume_changes_pending=1
            if costume_fail then error("Costume request failed") end
            return
        end
        if method=="requestCostumeDiscard" then
            costume_discards=costume_discards+1
            costume_discards_pending=1
            return
        end
        error(method)
    end,
}
local manager = {
    get_address=function() return manager_address end,
    get_type_definition=function() return td end,
    call=function(_, method, context, kind, purpose, callback)
        if method=="getPlayerContextRef()" then return player end
        if method=="get_CostumeManager" then return costume_manager end
        if method=="generateDynamicContextID()" then generated=generated+1; return id(new_code) end
        if method=="requestCreateBody" then
            assert(context:call("get_Code")==new_code)
            assert(kind==100000 and purpose==2 and callback==nil)
            created=created+1
            if fail_create then error("Native creation failed") end
            return 7
        end
        if method=="requestDestroyBody" then
            assert(context==7, "Never destroy a different request")
            if fail_destroy then error("Native cleanup failed") end
            destroyed=destroyed+1
            return
        end
        error("Unexpected manager mutation: " .. method)
    end,
}
sdk = {
    get_native_singleton=function() return {} end,
    find_type_definition=function() return td end,
    call_native_func=function() if scene_live then return scene end end,
    get_managed_singleton=function() return manager end,
}
callbacks = {}
re = {
    on_application_entry=function(name, fn) callbacks[name]=fn end,
    on_script_reset=function(fn) reset_script=fn end,
    on_draw_ui=function(fn) draw_ui=fn end,
}
'''


class ModelProbeTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(HARNESS)
        self.lua.execute((ROOT / "RE4LAN_ModelProbe.lua").read_text(encoding="utf-8"))
        self.g = self.lua.globals()

    def update(self):
        self.g.callbacks.UpdateBehavior()

    def follow(self):
        self.g.callbacks.LateUpdateBehavior()

    def click(self, label):
        self.g.pending_button = label
        self.g.draw_ui()
        self.update()

    def start(self):
        self.click("TEST: create one visual body")

    def test_default_is_inactive_and_capture_does_not_create(self):
        for _ in range(3):
            self.update()
            self.follow()
        self.assertEqual(self.g.created, 0)
        self.click("Capture model API (read-only)")
        self.assertEqual(self.g.generated, 0)
        self.assertEqual(self.g.report.local_player.kind, 100000)

    def test_ui_queues_actions_until_game_update(self):
        self.g.pending_button = "TEST: create one visual body"
        self.g.draw_ui()
        self.assertEqual(self.g.created, 0)
        self.update()
        self.assertEqual(self.g.created, 1)

    def test_create_follow_and_manual_remove_only_owned_body(self):
        self.start()
        self.assertEqual(self.g.report.phase, "active")
        self.assertEqual(self.g.renamed, 1)
        self.follow()
        self.assertEqual(self.g.last_position.x, 8)
        self.assertAlmostEqual(self.g.last_rotation.y, math.sqrt(0.5))
        self.assertAlmostEqual(self.g.last_rotation.w, math.sqrt(0.5))
        self.g.pose_x = 12
        self.follow()
        self.assertEqual(self.g.last_position.x, 12)
        self.click("Remove test body")
        self.assertEqual(self.g.destroyed, 1)
        self.assertEqual(self.g.report.phase, "removal_requested")
        self.follow()
        self.assertEqual(self.g.moved, 2)

    def test_missing_partner_does_not_generate_or_create(self):
        self.g.remote_live = False
        self.start()
        self.assertEqual(self.g.generated, 0)
        self.assertEqual(self.g.created, 0)
        self.assertEqual(self.g.report.phase, "error")

    def test_never_uses_local_player_context_id(self):
        self.g.new_code = self.g.player_code
        self.start()
        self.assertEqual(self.g.created, 0)
        self.assertIn("matches the local player", self.g.report.message)

    def test_create_exception_is_not_retried_automatically(self):
        self.g.fail_create = True
        self.start()
        for _ in range(5):
            self.update()
        self.assertEqual(self.g.created, 1)
        self.assertEqual(self.g.destroyed, 0)
        self.assertEqual(self.g.report.phase, "error")

    def test_matching_request_id_with_wrong_parent_is_not_moved(self):
        self.g.wrong_owner = True
        self.start()
        self.follow()
        self.assertEqual(self.g.renamed, 0)
        self.assertEqual(self.g.moved, 0)
        self.g.now += 16
        self.update()
        self.assertEqual(self.g.destroyed, 1)
        self.assertIn("Timed out", self.g.report.message)

    def test_asynchronous_creation_and_script_reset(self):
        self.g.body_ready = False
        self.start()
        self.assertEqual(self.g.report.phase, "waiting")
        self.g.body_ready = True
        self.g.now += 1
        self.update()
        self.assertEqual(self.g.report.phase, "active")
        self.g.reset_script()
        self.g.reset_script()
        self.assertEqual(self.g.destroyed, 1)

    def test_scene_change_permanently_revokes_old_request(self):
        self.start()
        self.g.scene_address = 99
        self.follow()
        self.assertEqual(self.g.report.phase, "abandoned")
        self.assertEqual(self.g.moved, 0)
        # Addresses can be reused; never restore authority over an old request.
        self.g.scene_address = 10
        self.click("Remove test body")
        self.g.reset_script()
        self.assertEqual(self.g.destroyed, 0)

    def test_player_change_stops_pending_discovery(self):
        self.g.body_ready = False
        self.start()
        self.g.player_address = 31
        self.update()
        self.assertEqual(self.g.report.phase, "abandoned")
        self.assertEqual(self.g.destroyed, 0)

    def test_lost_partner_requests_cleanup(self):
        self.start()
        self.g.remote_live = False
        self.follow()
        self.assertEqual(self.g.destroyed, 1)

    def test_timed_test_requests_cleanup_and_cannot_restart(self):
        self.start()
        self.g.now += 60
        self.update()
        self.assertEqual(self.g.destroyed, 1)
        self.start()
        self.assertEqual(self.g.created, 1)

    def test_cleanup_failure_is_visible_and_can_be_retried(self):
        self.start()
        self.g.fail_destroy = True
        self.click("Remove test body")
        self.assertEqual(self.g.report.phase, "error")
        self.assertFalse(self.g.report.cleanup_sent)
        self.g.fail_destroy = False
        self.click("Remove test body")
        self.assertEqual(self.g.destroyed, 1)

    def test_enables_only_our_root_draw_and_preserves_before_state(self):
        self.start()
        self.assertEqual(self.g.draw_writes, 1)
        self.assertEqual(self.g.child_draw_writes, 0)
        self.assertEqual(self.g.source_draw_writes, 0)
        self.assertFalse(self.g.update_self)
        before, after = self.g.report.visuals[1], self.g.report.visuals[2]
        self.assertFalse(before.nodes[1].state.get_DrawSelf)
        self.assertTrue(after.nodes[1].state.get_DrawSelf)
        self.assertEqual(before.mesh_count, 1)
        self.assertTrue(before.nodes[1].components[1].context.is_nil)
        mesh = before.nodes[2].components[1]
        self.assertFalse(mesh.properties.get_Enabled)
        self.assertEqual(mesh.properties.getMesh.type, "via.render.MeshResourceHolder")

    def test_hidden_parent_is_reported_without_claiming_visibility(self):
        self.g.inherited_draw = False
        self.start()
        after = self.g.report.visuals[2]
        self.assertTrue(after.nodes[1].state.get_DrawSelf)
        self.assertFalse(after.nodes[1].state.get_Draw)
        self.assertFalse(self.g.inherited_draw)

    def test_missing_mesh_resource_is_explicit(self):
        self.g.mesh_present = False
        self.start()
        props = self.g.report.visuals[1].nodes[2].components[1].properties
        self.assertTrue(props.getMesh.is_nil)
        self.assertFalse(props.get_MeshReady)

    def test_diagnostics_skip_child_with_different_parent(self):
        self.g.include_foreign_child = True
        self.start()
        snapshot = self.g.report.visuals[1]
        self.assertEqual(len(snapshot.nodes), 2)
        self.assertIn("different parent", snapshot.errors[1])

    def test_diagnostic_failure_does_not_block_cleanup(self):
        self.g.children_fail = True
        self.start()
        self.assertEqual(self.g.report.phase, "active")
        self.assertIn("children unavailable", self.g.report.visuals[1].nodes[1].children_error)
        self.click("Remove test body")
        self.assertEqual(self.g.destroyed, 1)

    def test_draw_is_not_forced_every_frame_and_resets_are_captured(self):
        self.start()
        self.g.draw_self = False  # Simulate the engine resetting the flag.
        self.g.now += 1
        self.update()
        self.assertFalse(self.g.report.visuals[3].nodes[1].state.get_DrawSelf)
        self.assertEqual(self.g.draw_writes, 1)
        self.g.now += 3
        self.update()
        self.assertEqual(self.g.report.visuals[4].label, "after_3s")

    def test_already_drawable_root_is_not_rewritten(self):
        self.g.draw_self = True
        self.start()
        self.assertEqual(self.g.draw_writes, 0)
        self.assertFalse(self.g.report.draw_change.called)

    def test_draw_failure_retains_owned_request_for_cleanup(self):
        self.g.draw_setter_fails = True
        self.start()
        self.assertEqual(self.g.report.phase, "error")
        self.assertEqual(self.g.report.request_id, 7)
        self.click("Remove test body")
        self.assertEqual(self.g.destroyed, 1)

    def test_ienumerable_children_without_count_or_indexer(self):
        self.g.enumerable_children = True
        self.start()
        self.assertEqual(self.g.report.visuals[1].mesh_count, 1)
        self.assertIsNone(self.g.report.visuals[1].nodes[1].children_error)
        self.assertGreater(self.g.enumerator_disposed, 0)

    def test_explicit_interface_enumeration(self):
        self.g.enumerable_children = self.g.explicit_interfaces = True
        self.start()
        self.assertEqual(self.g.report.visuals[1].mesh_count, 1)

    def test_failed_enumerator_is_disposed_and_error_reported(self):
        self.g.enumerable_children = self.g.enumeration_error = True
        self.start()
        self.assertIn("enumeration failed", self.g.report.visuals[1].nodes[1].children_error)
        self.assertGreater(self.g.enumerator_disposed, 0)
        self.click("Remove test body")
        self.assertEqual(self.g.destroyed, 1)

    def test_enumeration_is_bounded_and_truncation_reported(self):
        self.g.enumerable_children = True
        self.g.extra_children = 1000
        self.start()
        self.assertTrue(self.g.report.visuals[1].truncated)
        self.assertEqual(len(self.g.report.visuals[1].nodes), 2)

    def test_costume_requires_separate_manual_action_and_runs_once(self):
        self.start()
        self.assertEqual(self.g.costume_requests, 0)
        self.g.pending_button = "TEST: apply local costume"
        self.g.draw_ui()
        self.assertEqual(self.g.costume_requests, 0)
        self.update()
        self.click("TEST: apply local costume")
        self.assertEqual(self.g.costume_requests, 1)
        self.assertTrue(self.g.report.costume.request_returned)
        self.assertFalse(self.g.update_self)

    def test_costume_missing_asset_leaves_body_removable(self):
        self.start()
        self.g.costume_asset = False
        self.click("TEST: apply local costume")
        self.assertEqual(self.g.costume_requests, 0)
        self.assertIn("asset unavailable", self.g.report.message)
        self.click("Remove test body")
        self.assertEqual(self.g.destroyed, 1)

    def test_costume_ownership_rechecked_before_request(self):
        self.start()
        self.g.wrong_owner = True
        self.click("TEST: apply local costume")
        self.assertEqual(self.g.costume_requests, 0)

    def test_scene_change_before_costume_click_permanently_revokes_request(self):
        self.start()
        self.g.scene_address = 99
        self.click("TEST: apply local costume")
        self.assertEqual(self.g.report.phase, "abandoned")
        self.g.scene_address = 10
        self.click("Remove test body")
        self.assertEqual(self.g.costume_requests, 0)
        self.assertEqual(self.g.destroyed, 0)

    def test_costume_cleanup_waits_for_load_then_discard_then_registry(self):
        self.start()
        self.click("TEST: apply local costume")
        self.click("Remove test body")
        self.assertEqual(self.g.report.phase, "costume_cleanup")
        self.follow()
        self.assertEqual(self.g.moved, 0)
        self.assertEqual(self.g.destroyed, 0)
        self.assertEqual(self.g.costume_discards, 0)
        self.g.costume_changes_pending = 0
        self.g.costume_registered = True
        self.g.now += 1
        self.update()
        self.assertEqual(self.g.costume_discards, 1)
        self.assertEqual(self.g.destroyed, 0)
        self.g.costume_discards_pending = 0
        self.g.now += 1
        self.update()
        self.assertEqual(self.g.destroyed, 0)  # Registry entry still holds resources.
        self.g.costume_registered = False
        self.g.now += 1
        self.update()
        self.assertEqual(self.g.destroyed, 1)
        self.assertEqual(self.g.report.phase, "removal_requested")

    def test_unconfirmed_costume_cleanup_times_out_without_freeing_body(self):
        self.start()
        self.click("TEST: apply local costume")
        self.click("Remove test body")
        self.g.now += 16
        self.update()
        self.assertEqual(self.g.report.phase, "cleanup_blocked")
        self.assertEqual(self.g.destroyed, 0)

    def test_costume_scene_change_revokes_cleanup(self):
        self.start()
        self.click("TEST: apply local costume")
        self.click("Remove test body")
        self.g.scene_address = 123
        self.g.now += 1
        self.update()
        self.g.scene_address = 10
        self.click("Remove test body")
        self.assertEqual(self.g.report.phase, "abandoned")
        self.assertEqual(self.g.destroyed, 0)
        self.assertEqual(self.g.costume_discards, 0)

    def test_costume_manager_change_blocks_discard(self):
        self.start()
        self.click("TEST: apply local costume")
        self.g.costume_address = 61
        self.click("Remove test body")
        self.assertIn("CostumeManager changed", self.g.report.message)
        self.assertEqual(self.g.costume_discards, 0)
        self.assertEqual(self.g.destroyed, 0)

    def test_failed_costume_request_still_waits_for_possible_native_work(self):
        self.start()
        self.g.costume_fail = True
        self.click("TEST: apply local costume")
        self.assertEqual(self.g.report.phase, "error")
        self.click("Remove test body")
        self.assertEqual(self.g.report.phase, "costume_cleanup")
        self.assertEqual(self.g.destroyed, 0)

    def test_unreadable_cleanup_queues_do_not_authorize_destroy(self):
        self.start()
        self.click("TEST: apply local costume")
        self.g.costume_counts_fail = True
        self.click("Remove test body")
        self.assertEqual(self.g.destroyed, 0)
        self.assertIn("count unavailable", self.g.report.message)

    def test_delayed_costume_diagnostics_include_native_readiness(self):
        self.start()
        self.click("TEST: apply local costume")
        self.g.costume_changes_pending = 0
        self.g.costume_registered = True
        for delta in (1, 2, 7):
            self.g.now += delta
            self.update()
        self.assertTrue(self.g.report.costume.samples["10"].registered)
        snapshots = list(self.g.report.visuals.values())
        self.assertEqual(snapshots[-1].label, "costume_after_10s")
        self.assertTrue(snapshots[-1].nodes[2].components[1].properties.get_MeshReady)


if __name__ == "__main__":
    unittest.main()
