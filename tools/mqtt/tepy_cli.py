#!/usr/bin/env python3
"""Tepy v1 client: no automatic action retries, no password logging."""
from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import ssl
import threading
import time
import uuid
import warnings


KEYS = {"ENTER", "TAB", "ESC", "BACKSPACE", "DELETE", "SPACE", "LEFT", "RIGHT",
        "UP", "DOWN", "HOME", "END", "PAGEUP", "PAGEDOWN", "CAPSLOCK"}
KEYS.update(f"F{i}" for i in range(1, 13))
MODIFIERS = {"CTRL", "SHIFT", "ALT", "GUI"}


def validate_payload(kind: str, payload: dict) -> None:
    if not isinstance(payload, dict):
        raise ValueError("payload 必须为对象")
    if kind == "wake":
        if payload:
            raise ValueError("wake 不接受参数")
    elif kind == "type_text":
        if set(payload) - {"text", "press_enter"}:
            raise ValueError("未知输入参数")
        text = payload.get("text", "")
        if not isinstance(text, str) or not 1 <= len(text) <= 512:
            raise ValueError("输入长度必须为 1–512")
        if any(not 32 <= ord(char) <= 126 for char in text):
            raise ValueError("只支持 ASCII 可打印字符；换行请使用 --enter")
        if not isinstance(payload.get("press_enter", False), bool):
            raise ValueError("press_enter 必须为布尔值")
    elif kind == "key":
        if set(payload) - {"key", "modifiers"}:
            raise ValueError("未知按键参数")
        key = payload.get("key", "")
        if not isinstance(key, str) or not (key in KEYS or len(key) == 1 and 32 <= ord(key) <= 126):
            raise ValueError("不支持的按键")
        mods = payload.get("modifiers", [])
        if not isinstance(mods, list) or any(not isinstance(m, str) or m not in MODIFIERS for m in mods) or len(mods) != len(set(mods)):
            raise ValueError("修饰键无效或重复")
    else:
        raise ValueError("未知动作")


def build_command(state: dict, kind: str, payload: dict, *, now_ms: int | None = None,
                  request_id: str | None = None) -> dict:
    if type(state.get("v")) is not int or state.get("v") != 1 or state.get("online") is not True or state.get("time_ready") is not True:
        raise ValueError("设备未在线或尚未校时")
    session = state.get("session", "")
    if not isinstance(session, str) or not re.fullmatch(r"[0-9a-f]{32}", session):
        raise ValueError("设备会话无效")
    if not isinstance(state.get("ble"), dict) or state["ble"].get("ready") is not True:
        raise ValueError("蓝牙键盘尚未就绪")
    validate_payload(kind, payload)
    now_ms = int(time.time() * 1000) if now_ms is None else now_ms
    request_id = request_id or uuid.uuid4().hex
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", request_id):
        raise ValueError("请求 ID 无效")
    return {"v": 1, "id": request_id, "session": session, "expires_at": now_ms + 10000,
            "type": kind, "payload": payload}


class TepyClient:
    def __init__(self, args: argparse.Namespace):
        import paho.mqtt.client as mqtt

        self.prefix = f"tepy/{args.device}"
        self.condition = threading.Condition()
        self.state: dict = {}
        self.pending: set[str] = set()
        self.replies: dict[str, dict] = {}
        self.connection_error = ""
        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                                  client_id=f"tepy-cli-{uuid.uuid4().hex}",
                                  clean_session=True, protocol=mqtt.MQTTv311)
        self.client.on_connect = self._connect
        self.client.on_message = self._message
        if os.getenv("TEPY_MQTT_USERNAME"):
            self.client.username_pw_set(os.environ["TEPY_MQTT_USERNAME"], os.getenv("TEPY_MQTT_PASSWORD"))
        if args.tls or args.ca:
            self.client.tls_set_context(ssl.create_default_context(cafile=args.ca))
        self.host = args.host
        self.port = args.port or (8883 if args.tls or args.ca else 1883)

    def _connect(self, client, userdata, flags, reason_code, properties):
        with self.condition:
            if reason_code.is_failure:
                self.connection_error = f"Broker 连接失败：{reason_code}"
            else:
                self.state = {}
                client.subscribe([(self.prefix + "/state", 1), (self.prefix + "/reply", 1)])
            self.condition.notify_all()

    def _message(self, client, userdata, message):
        if len(message.payload) > 16384:
            return
        try:
            value = json.loads(message.payload)
        except (ValueError, UnicodeDecodeError):
            return
        if not isinstance(value, dict) or value.get("v") != 1:
            return
        with self.condition:
            if message.topic == self.prefix + "/state" and value.get("device_id") == self.prefix.split("/")[1]:
                self.state = value
            elif message.topic == self.prefix + "/reply" and value.get("id") in self.pending:
                self.replies[value["id"]] = value
            self.condition.notify_all()

    def start(self):
        self.client.connect(self.host, self.port, 30)
        self.client.loop_start()

    def close(self):
        self.client.disconnect()
        self.client.loop_stop()

    def get_state(self, timeout=15) -> dict:
        deadline = time.monotonic() + timeout
        with self.condition:
            while not self.state.get("online") or not self.state.get("time_ready"):
                if self.connection_error:
                    raise RuntimeError(self.connection_error)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("等待设备在线并完成校时超时")
                self.condition.wait(remaining)
            return dict(self.state)

    def send(self, kind, payload) -> dict:
        command = build_command(self.get_state(), kind, payload)
        request_id = command["id"]
        with self.condition:
            self.pending.add(request_id)
        try:
            wire = json.dumps(command, separators=(",", ":"))
            result = self.client.publish(self.prefix + "/cmd", wire, qos=1, retain=False)
            result.wait_for_publish(timeout=10)
            if not result.is_published():
                raise TimeoutError("指令发布未确认；请人工检查，不要自动重试")
            # Firmware permits 200 ms for each key-down and key-up. A maximum-size
            # text can legitimately take over three minutes; do not time out at 60 s.
            strokes = len(payload.get("text", "")) + int(payload.get("press_enter", False)) if kind == "type_text" else 1
            deadline = time.monotonic() + max(30, strokes * 0.4 + 20)
            with self.condition:
                while request_id not in self.replies:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError("等待 HID 发送结果超时；请人工检查，不要自动重试")
                    self.condition.wait(remaining)
                reply = self.replies.pop(request_id)
            if reply.get("status") != "sent":
                raise RuntimeError(f"动作未完成：{reply.get('error', 'unknown')}；不自动重试")
            return reply
        finally:
            with self.condition:
                self.pending.discard(request_id)
                self.replies.pop(request_id, None)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", required=True)
    p.add_argument("--device", required=True, type=lambda value: device_id(value))
    p.add_argument("--port", type=int)
    p.add_argument("--tls", action="store_true")
    p.add_argument("--ca", help="自定义 CA PEM 文件；启用 TLS")
    sub = p.add_subparsers(dest="action", required=True)
    sub.add_parser("status")
    sub.add_parser("wake")
    for action in ("type", "unlock"):
        child = sub.add_parser(action)
        child.add_argument("--enter", action="store_true", help="输入完成后按回车")
        if action == "unlock":
            child.add_argument("--wait", type=float, default=3, help="唤醒后等待秒数，默认 3")
    key = sub.add_parser("key")
    key.add_argument("key")
    key.add_argument("--modifier", action="append", choices=sorted(MODIFIERS), default=[])
    return p


def device_id(value: str) -> str:
    if not re.fullmatch(r"[0-9a-fA-F]{12}", value):
        raise argparse.ArgumentTypeError("device 必须为 12 位 MAC 十六进制字符串")
    return value.lower()


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    if args.action == "unlock" and not 0 <= args.wait <= 30:
        parser().error("--wait 必须为 0–30 秒")
    content = None
    try:
        if args.action in {"type", "unlock"}:
            with warnings.catch_warnings():
                # Refuse getpass's echoing fallback when no interactive terminal exists.
                warnings.simplefilter("error", getpass.GetPassWarning)
                content = getpass.getpass("输入内容（隐藏，不记录）：")
            validate_payload("type_text", {"text": content, "press_enter": args.enter})
        client = TepyClient(args)
        try:
            client.start()
            if args.action == "status":
                print(json.dumps(client.get_state(), ensure_ascii=False, indent=2))
            elif args.action == "wake":
                print(json.dumps(client.send("wake", {})))
            elif args.action == "key":
                print(json.dumps(client.send("key", {"key": args.key, "modifiers": args.modifier})))
            else:
                if args.action == "unlock":
                    client.send("wake", {})
                    time.sleep(args.wait)
                print(json.dumps(client.send("type_text", {"text": content, "press_enter": args.enter})))
        finally:
            client.close()
        return 0
    except (ValueError, RuntimeError, OSError, TimeoutError, ImportError, getpass.GetPassWarning) as error:
        print(f"错误：{error}")
        return 1
    finally:
        # Python strings cannot be reliably zeroed; keep their lifetime short.
        content = None


if __name__ == "__main__":
    raise SystemExit(main())
