import json
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import re4lan_relay as relay

ROOT = Path(__file__).resolve().parents[1]


class ExchangeTests(unittest.TestCase):
    def test_unicode_and_null_roundtrip(self):
        state = {"k": "s", "d": {"seq": 10, "name": "Игрок", "doors": {"扉|1|2|3": {"s": 0}}, "ev": None}}
        self.assertEqual(relay.unpack(relay.pack(state)), state)
        self.assertIsNone(relay.unpack(b"RE4L{"))
        self.assertIsNone(relay.unpack(b"invalid"))

    def test_partial_file_and_nonexistent_file_are_retryable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            self.assertIsNone(relay.read_json(path))
            path.write_text('{"seq":', encoding="utf-8")
            self.assertIsNone(relay.read_json(path))
            path.write_text('{"seq":1}', encoding="utf-8")
            self.assertEqual(relay.read_json(path), {"seq": 1})

    def test_busy_file_preserves_previous_state_then_recovers(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "state.json")
            self.assertTrue(relay.atomic_write(path, {"seq": 1}))
            with patch.object(relay.os, "replace", side_effect=PermissionError("busy")):
                self.assertFalse(relay.atomic_write(path, {"seq": 2}))
            self.assertEqual(relay.read_json(path), {"seq": 1})
            self.assertTrue(relay.atomic_write(path, {"seq": 2}))
            self.assertEqual(relay.read_json(path), {"seq": 2})

    def test_rates_measure_states_and_keep_silence_visible(self):
        rates = relay.ExchangeRates(100)
        for i in range(1, 31):
            rates.observe_out(100 + i / 30)
            if i % 2 == 0:
                rates.observe_in(100 + i / 30)
        self.assertEqual(rates.snapshot(101), {
            "out_hz": 30.0, "in_hz": 15.0, "out_gap_ms": 33.3, "in_age_ms": 0.0,
        })
        self.assertEqual(rates.snapshot(102), {
            "out_hz": 0.0, "in_hz": 0.0, "out_gap_ms": 1000.0, "in_age_ms": 1000.0,
        })


class RelayProcessesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def start(self, mode, port=7777):
        data = self.root / mode
        data.mkdir()
        output = (self.root / (mode + ".log")).open("w", encoding="utf-8")
        self.addCleanup(output.close)
        args = [sys.executable, "-u", str(ROOT / "re4lan_relay.py"), mode]
        if mode == "join":
            args.append("127.0.0.1")
        args.extend(["--data", str(data), "--port", str(port)])
        process = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT)
        self.addCleanup(self.stop, process)
        return data, process

    @staticmethod
    def stop(process):
        if process.poll() is None:
            if sys.platform == "win32":
                process.terminate()
            else:
                process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)

    def wait_json(self, path, predicate=lambda obj: bool(obj), timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            obj = relay.read_json(path)
            if obj is not None and predicate(obj):
                return obj
            time.sleep(0.005)
        logs = {p.name: p.read_text(encoding="utf-8") for p in self.root.glob("*.log")}
        self.fail("Timed out reading %s: %r; relay logs: %r" % (path.name, relay.read_json(path), logs))

    @staticmethod
    def state(seq, offset=0):
        return {
            "seq": seq, "name": "Игрок", "pos": [offset + seq / 10, 2, 3], "yaw": seq / 100,
            "doors": {"扉|1|2|3": {"s": seq % 2, "v": seq, "d": -1}},
            "ev": [{"id": seq, "k": "扉|1|2|3", "s": seq % 2, "v": seq, "d": -1}],
        }

    def test_host_join_bidirectional_movement_and_rates(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        host, host_process = self.start("host", port)
        join, join_process = self.start("join", port)
        for data in (host, join):
            status = self.wait_json(data / relay.F_STATUS, lambda obj: obj.get("connected"))
            self.assertGreater(status["t"], time.time() - 5)
            self.assertEqual(status["version"], "0.2.1")

        started = time.monotonic()
        for seq in range(1, 37):
            sent_host, sent_join = self.state(seq), self.state(seq, offset=100)
            relay.atomic_write(str(host / relay.F_OUT), sent_host)
            relay.atomic_write(str(join / relay.F_OUT), sent_join)
            at_join = self.wait_json(join / relay.F_IN, lambda obj: obj["d"]["seq"] == seq)
            at_host = self.wait_json(host / relay.F_IN, lambda obj: obj["d"]["seq"] == seq)
            self.assertEqual(at_join["d"], sent_host)
            self.assertEqual(at_host["d"], sent_join)
            time.sleep(max(0, started + seq / 30 - time.monotonic()))

        for data in (host, join):
            status = relay.read_json(data / relay.F_STATUS)
            self.assertGreater(status["out_hz"], 10)
            self.assertGreater(status["in_hz"], 10)
            self.assertEqual(status["wfail"], 0)
            self.assertLess(status["in_age_ms"], 300)
        self.assertIsNone(host_process.poll())
        self.assertIsNone(join_process.poll())

    def test_echo_preserves_world_and_only_offsets_position(self):
        data, process = self.start("echo")
        sent = self.state(1)
        relay.atomic_write(str(data / relay.F_OUT), sent)
        received = self.wait_json(data / relay.F_IN)
        expected = dict(sent, name="Echo", pos=[3.1, 2, 3])
        self.assertEqual(received["d"], expected)
        # Repeated reads of an unchanged seq must not appear as new snapshots.
        time.sleep(0.08)
        self.assertEqual(relay.read_json(data / relay.F_IN)["seq"], received["seq"])
        relay.atomic_write(str(data / relay.F_OUT), {"seq": 2, "pos": None, "doors": None, "ev": None})
        received = self.wait_json(data / relay.F_IN, lambda obj: obj["d"]["seq"] == 2)
        self.assertIsNone(received["d"]["pos"])
        self.assertIsNone(process.poll())

    def test_bad_file_recovers_without_restarting_relay(self):
        data, process = self.start("echo")
        path = data / relay.F_OUT
        for content in ('{"seq":', 'null', '[]', '42'):
            path.write_text(content, encoding="utf-8")
            time.sleep(0.03)
            self.assertIsNone(process.poll())
        relay.atomic_write(str(path), self.state(100))
        result = self.wait_json(data / relay.F_IN)
        self.assertEqual(result["d"]["seq"], 100)


if __name__ == "__main__":
    unittest.main()
