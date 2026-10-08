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
local function id(code) return {call=function(_, method) assert(method=="get_Code", method); return code end} end
local td = {
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
local xf = {call=function(_, method, value)
    if method == "set_Position" then moved = moved + 1; last_position = value; return end
    if method == "set_Rotation" then last_rotation = value; return end
    if method == "get_Position" then return last_position end
    error("Unexpected transform call: " .. method)
end}
local body = {get_address=function() return 40 end}
local comp = {
    get_type_definition=function() return td end,
    call=function(_, method)
        if method=="get_InstanceDemandID" then return 7 end
        if method=="get_InstanceParentID" then return id(wrong_owner and 123 or new_code) end
        if method=="get_GameObject" then return body end
        error("Unexpected component call: " .. method)
    end,
}
body.call=function(_, method, value)
    if method=="get_Name" then return body_name or "ch0a0z0_body" end
    if method=="get_Components" then return array({comp}) end
    if method=="get_Transform" then return xf end
    if method=="set_Name" then renamed=renamed+1; body_name=value; return end
    error("Unexpected body call: " .. method)
end
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
local manager = {
    get_address=function() return manager_address end,
    get_type_definition=function() return td end,
    call=function(_, method, context, kind, purpose, callback)
        if method=="getPlayerContextRef()" then return player end
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


if __name__ == "__main__":
    unittest.main()
