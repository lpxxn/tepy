import argparse
import json
import threading
import unittest
from unittest.mock import Mock

from tepy_cli import TepyClient, build_command, device_id, validate_payload


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.state = {"v": 1, "online": True, "time_ready": True,
                      "session": "a" * 32, "ble": {"ready": True}}

    def test_envelope(self):
        command = build_command(self.state, "wake", {}, now_ms=100000, request_id="test-1")
        self.assertEqual(command["expires_at"], 110000)
        self.assertEqual(command["session"], "a" * 32)
        self.assertEqual(command["id"], "test-1")

    def test_text(self):
        for text in ("", "\n", "中文", "a" * 513):
            with self.subTest(text_length=len(text)), self.assertRaises(ValueError):
                validate_payload("type_text", {"text": text})
        validate_payload("type_text", {"text": "".join(chr(i) for i in range(32, 127))})

    def test_bad_session(self):
        for session in ("", "a", "g" * 32, None):
            with self.subTest(session=session), self.assertRaises(ValueError):
                build_command({**self.state, "session": session}, "wake", {})

    def test_not_ready(self):
        for field in ("online", "time_ready", "v"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                build_command({**self.state, field: False}, "wake", {})
        with self.assertRaises(ValueError):
            build_command({**self.state, "ble": {}}, "wake", {})

    def test_keys(self):
        validate_payload("key", {"key": "ENTER", "modifiers": ["GUI", "SHIFT"]})
        for payload in ({"key": "unknown"}, {"key": "a", "modifiers": ["GUI", "GUI"]},
                        {"key": "a", "modifiers": ["unknown"]}):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                validate_payload("key", payload)

    def test_device_id(self):
        self.assertEqual(device_id("AABBCCDDEEFF"), "aabbccddeeff")
        with self.assertRaises(argparse.ArgumentTypeError):
            device_id("../../cmd")

    def test_real_send_api_no_retain_or_retry(self):
        # Exercise the actual transport method with a deterministic broker callback.
        client = TepyClient.__new__(TepyClient)
        client.condition = threading.Condition()
        client.pending, client.replies = set(), {}
        client.prefix = "tepy/aabbccddeeff"
        client.get_state = lambda: self.state
        client.client = Mock()

        def broker(topic, wire, qos, retain):
            self.assertEqual(topic, client.prefix + "/cmd")
            self.assertEqual(qos, 1)
            self.assertFalse(retain)
            command = json.loads(wire)
            client.replies[command["id"]] = {"id": command["id"], "status": "sent", "error": ""}
            result = Mock()
            result.is_published.return_value = True
            return result

        client.client.publish.side_effect = broker
        self.assertEqual(client.send("wake", {})["status"], "sent")
        client.client.publish.assert_called_once()
        self.assertFalse(client.pending)
        self.assertFalse(client.replies)

    def test_rejected_send_not_retried(self):
        client = TepyClient.__new__(TepyClient)
        client.condition = threading.Condition()
        client.pending, client.replies = set(), {}
        client.prefix = "tepy/aabbccddeeff"
        client.get_state = lambda: self.state
        client.client = Mock()

        def broker(topic, wire, qos, retain):
            command = json.loads(wire)
            client.replies[command["id"]] = {"status": "rejected", "error": "old_session"}
            result = Mock()
            result.is_published.return_value = True
            return result

        client.client.publish.side_effect = broker
        with self.assertRaisesRegex(RuntimeError, "old_session"):
            client.send("wake", {})
        client.client.publish.assert_called_once()


if __name__ == "__main__":
    unittest.main()
