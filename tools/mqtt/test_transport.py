"""Local socket fixture verifies Paho's real MQTT 3.1.1 wire behavior."""
import argparse
import json
import socket
import struct
import threading
import time
import unittest
from unittest.mock import patch

from tepy_cli import TepyClient


def remaining_length(value):
    result = bytearray()
    while True:
        digit = value % 128
        value //= 128
        result.append(digit | (128 if value else 0))
        if not value:
            return bytes(result)


def read_exact(connection, size):
    result = bytearray()
    while len(result) < size:
        part = connection.recv(size - len(result))
        if not part:
            raise EOFError()
        result.extend(part)
    return bytes(result)


def read_packet(connection):
    header = read_exact(connection, 1)[0]
    size, multiplier = 0, 1
    for _ in range(4):
        digit = read_exact(connection, 1)[0]
        size += (digit & 127) * multiplier
        if not digit & 128:
            if size > 16384:
                raise ValueError("oversized test packet")
            return header, read_exact(connection, size)
        multiplier *= 128
    raise ValueError("invalid remaining length")


def publish_packet(topic, value):
    topic = topic.encode()
    body = struct.pack("!H", len(topic)) + topic + json.dumps(value).encode()
    return b"\x30" + remaining_length(len(body)) + body


class BrokerFixture:
    def __init__(self, status="sent", error=""):
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(5)
        self.port = self.listener.getsockname()[1]
        self.status, self.error = status, error
        self.commands = []
        self.failure = None
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        try:
            with self.listener, self.listener.accept()[0] as connection:
                connection.settimeout(5)
                while True:
                    header, body = read_packet(connection)
                    kind = header >> 4
                    if kind == 1:
                        if body[7] & 2 != 2:
                            raise AssertionError("client must use clean session")
                        connection.sendall(b"\x20\x02\x00\x00")
                    elif kind == 8:
                        packet_id = body[:2]
                        connection.sendall(b"\x90\x04" + packet_id + b"\x01\x01")
                        state = {"v": 1, "device_id": "aabbccddeeff", "session": "a" * 32,
                                 "online": True, "time_ready": True, "ble": {"ready": True},
                                 "now": int(time.time() * 1000)}
                        connection.sendall(publish_packet("tepy/aabbccddeeff/state", state))
                    elif kind == 3:
                        if header & 1:
                            raise AssertionError("actions must not be retained")
                        if header >> 1 & 3 != 1:
                            raise AssertionError("actions must use QoS 1")
                        length = struct.unpack("!H", body[:2])[0]
                        topic = body[2:2 + length].decode()
                        if topic != "tepy/aabbccddeeff/cmd":
                            raise AssertionError("wrong command topic")
                        packet_id = body[2 + length:4 + length]
                        command = json.loads(body[4 + length:])
                        self.commands.append(command)
                        connection.sendall(b"\x40\x02" + packet_id)
                        reply = {"v": 1, "id": command["id"], "status": self.status, "error": self.error}
                        connection.sendall(publish_packet("tepy/aabbccddeeff/reply", reply))
                    elif kind == 12:
                        connection.sendall(b"\xd0\x00")
                    elif kind == 14:
                        return
        except EOFError:
            pass
        except Exception as error:
            self.failure = error

    def finish(self):
        self.thread.join(6)
        if self.thread.is_alive():
            raise AssertionError("fixture did not terminate")
        if self.failure:
            raise self.failure


class TransportTests(unittest.TestCase):
    def run_fixture(self, status="sent", error=""):
        broker = BrokerFixture(status, error)
        args = argparse.Namespace(host="127.0.0.1", port=broker.port,
                                  device="aabbccddeeff", tls=False, ca=None)
        with patch.dict("os.environ", {"TEPY_MQTT_USERNAME": "", "TEPY_MQTT_PASSWORD": ""}):
            client = TepyClient(args)
        try:
            client.start()
            if status == "sent":
                self.assertEqual(client.send("type_text", {"text": "Demo + =", "press_enter": False})["status"], "sent")
            else:
                with self.assertRaisesRegex(RuntimeError, error):
                    client.send("wake", {})
        finally:
            client.close()
            broker.finish()
        self.assertEqual(len(broker.commands), 1)
        self.assertEqual(broker.commands[0]["session"], "a" * 32)

    def test_real_mqtt_round_trip(self):
        self.run_fixture()

    def test_real_mqtt_rejection_no_retry(self):
        self.run_fixture("rejected", "old_session")


if __name__ == "__main__":
    unittest.main()
