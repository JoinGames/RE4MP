"""Execute the actual mod in Lua 5.4 with a small REFramework test double.

These tests validate the file-exchange logic, not the native game's API.
"""
import os
from pathlib import Path
import unittest

from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
MOD = Path(os.environ.get("RE4LAN_TEST_SCRIPT", str(ROOT / "RE4LAN.lua")))

HARNESS = r'''
frame = 0
player_present = true
px, py, pz, yaw = 0, 0, 0, 0
fail_write = false
writes, errors, ui = {}, {}, {}
os.time = function() return 1800000000 + math.floor(frame / 60) end
local xf = {call = function(self, method)
    if method == "get_Position" then return {x=px, y=py, z=pz} end
    if method == "get_Rotation" then
        return {x=0, y=math.sin(yaw/2), z=0, w=math.cos(yaw/2)}
    end
    error("Unexpected transform method: " .. method)
end}
local go = {call = function(self, method)
    assert(method == "get_Transform", method)
    return xf
end}
local scene = {call = function(self, method)
    assert(method == "findGameObject(System.String)", method)
    if player_present then return go end
end}
sdk = {
    get_native_singleton = function() return {} end,
    find_type_definition = function() return {} end,
    call_native_func = function() return scene end,
}
json = {
    load_file = function(path)
        if path == "RE4LAN_cfg.json" then
            return {sync_doors=false, show_ghost=false}
        end
        if path == "RE4LAN_in.json" then return inbox end
        if path == "RE4LAN_status.json" then return link_status end
    end,
    dump_file = function(path, data)
        if fail_write == "throw" then error("File busy") end
        if fail_write then return false end
        if path == "RE4LAN_out.json" then
            writes[#writes+1] = {frame=frame, data=data}
        end
        return true
    end,
}
re = {
    on_frame = function(f) tick = f end,
    on_draw_ui = function(f) draw_ui = f end,
    on_script_reset = function(f) reset_script = f end,
}
draw = {text = function() end}
log = {info = function(s) errors[#errors+1] = s end}
imgui = {
    tree_node = function() return true end,
    tree_pop = function() end,
    text = function(s) ui[#ui+1] = s end,
    spacing = function() end,
    same_line = function() end,
    input_text = function(_, v) return false, v end,
    checkbox = function(_, v) return false, v end,
    combo = function(_, v) return false, v end,
    drag_float = function(_, v) return false, v end,
    button = function() return false end,
}
'''


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(HARNESS)
        self.lua.execute(MOD.read_text(encoding="utf-8"))
        self.g = self.lua.globals()

    def advance(self, count, motion=None):
        for _ in range(count):
            self.g.frame += 1
            if motion:
                motion(self.g)
            self.g.tick()
        self.assertEqual(list(self.g.errors.values()), [])

    def test_walking_publishes_every_two_frames(self):
        self.advance(120, lambda g: setattr(g, "px", g.frame * 0.1))
        frames = [w.frame for w in self.g.writes.values()]
        self.assertEqual(len(frames), 60)
        self.assertEqual(set(b - a for a, b in zip(frames, frames[1:])), {2})
        self.assertGreater(self.g.writes[60].data.pos[1], 11.8)

    def test_turning_without_walking_is_published(self):
        self.advance(60, lambda g: setattr(g, "yaw", g.frame * 0.03))
        self.assertEqual(len(self.g.writes), 30)
        self.assertGreater(self.g.writes[30].data.yaw, 1.7)

    def test_stationary_player_only_needs_keepalive(self):
        self.advance(121)
        self.assertEqual([w.frame for w in self.g.writes.values()], [1, 61, 121])

    def test_player_disappearing_clears_pose_promptly(self):
        self.advance(1)
        self.g.player_present = False
        self.advance(2)
        self.assertEqual(len(self.g.writes), 2)
        self.assertIsNone(self.g.writes[2].data.pos)
        self.g.player_present = True
        self.advance(2)
        self.assertEqual(len(self.g.writes), 3)
        self.assertIsNotNone(self.g.writes[3].data.pos)

    def test_failed_write_does_not_acknowledge_pose(self):
        self.advance(1)
        self.g.px = 2
        self.g.fail_write = True
        self.advance(2)
        self.assertEqual(len(self.g.writes), 1)
        self.g.fail_write = False
        self.advance(2)
        self.assertEqual(len(self.g.writes), 2)
        self.assertEqual(self.g.writes[2].data.pos[1], 2)

    def test_exception_during_write_is_retried(self):
        self.g.fail_write = "throw"
        self.advance(3)
        self.g.fail_write = False
        self.advance(2)
        self.assertEqual(len(self.g.writes), 1)

    def test_menu_can_render_after_moving(self):
        self.advance(120, lambda g: setattr(g, "px", g.frame * 0.1))
        self.g.draw_ui()
        self.assertTrue(any("Partner:" in s for s in self.g.ui.values()))

    def test_player_context_wins_over_duplicate_prefab_name(self):
        self.lua.execute('''
            local actual_xf = {call=function(_, method)
                if method=="get_Position" then return {x=42,y=0,z=0} end
                if method=="get_Rotation" then return {x=0,y=0,z=0,w=1} end
                error(method)
            end}
            local actual_body = {call=function(_, method)
                assert(method=="get_Transform"); return actual_xf
            end}
            local player = {call=function(_, method)
                assert(method=="get_BodyGameObject"); return actual_body
            end}
            sdk.get_managed_singleton=function()
                return {call=function(_, method)
                    assert(method=="getPlayerContextRef()"); return player
                end}
            end
        ''')
        self.advance(1)
        self.assertEqual(self.g.writes[1].data.pos[1], 42)

    def test_missing_player_context_does_not_publish_another_body(self):
        self.lua.execute('''
            sdk.get_managed_singleton=function()
                return {call=function() return nil end}
            end
        ''')
        self.advance(1)
        self.assertIsNone(self.g.writes[1].data.pos)

    def test_visual_bridge_smooths_with_wire_figure_hidden(self):
        self.lua.execute('''
            link_status = {t=os.time(), connected=true, role="host", ping_ms=0}
            inbox = {seq=1, d={name="Peer", pos={0,0,0}, yaw=0}}
        ''')
        self.advance(1)  # Discard a possibly stale inbox file once on startup.
        self.lua.execute('inbox = {seq=2, d={name="Peer", pos={0,0,0}, yaw=0}}')
        self.advance(29)
        self.lua.execute('inbox = {seq=3, d={name="Peer", pos={1,0,0}, yaw=0.3}}')
        self.advance(1)
        pose = self.g.RE4LAN_visual.get_pose()
        self.assertGreater(pose.pos[1], 0)
        self.assertLess(pose.pos[1], 1)
        pose.pos[1] = 999  # A consumer must not be able to modify internal ghost state.
        self.assertLess(self.g.RE4LAN_visual.get_pose().pos[1], 1)
        self.g.reset_script()
        self.assertIsNone(self.g.RE4LAN_visual)


class LuaSyntaxTests(unittest.TestCase):
    def test_all_lua_scripts_compile(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        for name in ("RE4LAN.lua", "RE4LAN_ModelProbe.lua", "RE4LAN_LinkedSpawnProbe.lua",
                     "RE4LAN_PartnerContextProbe.lua", "RE4MP_Scout.lua"):
            lua.execute("assert(load(...))", (ROOT / name).read_text(encoding="utf-8"))


SCOUT_HARNESS = r'''
local definitions = {}
local function td(name, fields, methods, enum)
    local obj = {
        get_full_name = function() return name end,
        get_parent_type = function() return nil end,
        get_fields = function() return fields or {} end,
        get_methods = function() return methods or {} end,
        is_a = function(_, parent) return enum == true and parent == "System.Enum" end,
    }
    definitions[name] = obj
    return obj
end
local function field(name, typename, value)
    return {
        get_name = function() return name end,
        get_type = function() return definitions[typename] end,
        get_data = function() return value end,
    }
end
td("System.UInt32")
td("System.Boolean")
local context_id_type = td("chainsaw.ContextID", {field("Index", "System.UInt32")})
td("chainsaw.GmGateBase.DoorSide", {field("SideA", "System.UInt32", 0), field("SideB", "System.UInt32", 1)}, nil, true)
local context_type = td("chainsaw.CharacterContext", {
    field("KindID", "System.UInt32"), field("ContextID", "chainsaw.ContextID"), field("Enabled", "System.Boolean"),
})
local context_id = {
    get_type_definition = function() return context_id_type end,
    get_field = function(_, name) assert(name == "Index"); return 7 end,
}
local context = {
    get_type_definition = function() return context_type end,
    get_field = function(_, name)
        if name == "KindID" then return 4294967295 end
        if name == "ContextID" then return context_id end
        if name == "Enabled" then return false end
        error(name)
    end,
}
local list = {call = function(_, method, i)
    if method == "get_Count" then return 4 end
    if method == "get_Item" then assert(i >= 0 and i < 4); return context end
    error(method)
end}
local methods = {}
for i=1,250 do
    local params = {}
    for j=1,3 do params[j] = td(string.format("chainsaw.A%04d", (i-1)*3+j)) end
    methods[i] = {
        get_name = function() return "read" end,
        get_num_params = function() return 3 end,
        get_return_type = function() return definitions["System.UInt32"] end,
        get_param_types = function() return params end,
        get_param_names = function() return {"a", "b", "c"} end,
    }
end
td("chainsaw.CharacterManager", {}, methods)
local manager = {call = function(_, method)
    if method == "getPlayerContextRef()" then
        if fail_player then error("player not loaded") end
        return context
    end
    if method == "get_EnemyContextList" then return list end
    error("not supported: " .. method)
end}
local scene = {call = function() return nil end}
sdk = {
    get_native_singleton = function() return {} end,
    find_type_definition = function(name) return definitions[name] end,
    call_native_func = function() return scene end,
    get_managed_singleton = function(name)
        if name == "chainsaw.CharacterManager" then return manager end
    end,
    get_primary_camera = function() return nil end,
}
json = {dump_file = function(name, data)
    saved_name, saved = name, data
    return not fail_write
end}
reframework = {is_key_down = function() return true end}
re = {
    on_frame = function(f) tick = f end,
    on_draw_ui = function(f) draw_ui = f end,
}
draw = {text = function() end}
log = {info = function(s) last_log = s end}
'''


class ScoutTests(unittest.TestCase):
    def run_scan(self, fail_player=False, fail_write=False):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(SCOUT_HARNESS)
        g = lua.globals()
        g.fail_player, g.fail_write = fail_player, fail_write
        lua.execute((ROOT / "RE4MP_Scout.lua").read_text(encoding="utf-8"))
        g.tick()
        self.assertIsNotNone(g.saved, g.last_log)
        return g

    def test_required_types_survive_related_type_limit(self):
        result = self.run_scan().saved
        self.assertEqual(result.version, 4)
        self.assertEqual(result.related_candidates, 750)
        self.assertTrue(result.related_truncated)
        self.assertEqual(result.enums["chainsaw.GmGateBase.DoorSide"].SideA, 0)
        self.assertEqual(result.enums["chainsaw.GmGateBase.DoorSide"].SideB, 1)
        self.assertEqual(result.required_types["chainsaw.ContextID"], "type")
        self.assertEqual(result.required_types["chainsaw.CharacterKindID"], "missing")

    def test_live_contexts_preserve_ids_and_false_values(self):
        live = self.run_scan().saved.live
        self.assertEqual(live.player.fields.KindID, 4294967295)
        self.assertFalse(live.player.fields.Enabled)
        self.assertEqual(live.player.fields.ContextID.fields.Index, 7)
        self.assertEqual(live.enemies.count, 4)
        self.assertEqual(len(live.enemies["items"]), 3)
        self.assertIn("not supported", live.control_targets.unavailable)

    def test_unavailable_player_does_not_abort_scan(self):
        result = self.run_scan(fail_player=True).saved
        self.assertIn("player not loaded", result.live.player.unavailable)
        self.assertEqual(result.live.enemies.count, 4)

    def test_failed_write_is_not_reported_as_saved(self):
        result = self.run_scan(fail_write=True)
        self.assertIn("Could not write file", result.last_log)


if __name__ == "__main__":
    unittest.main()
