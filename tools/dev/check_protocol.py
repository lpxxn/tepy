"""Check schemas, fixtures, the CLI and the firmware production parser together."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "mqtt"))
from tepy_cli import build_command  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--core-executable", required=True)
    args = parser.parse_args()
    validators = {}
    schemas = [json.loads(path.read_text(encoding="utf-8"))
               for path in (ROOT / "protocol/v1/schemas").glob("*.schema.json")]
    registry = Registry().with_resources((schema["$id"], Resource.from_contents(schema))
                                         for schema in schemas)
    for path in (ROOT / "protocol/v1/schemas").glob("*.schema.json"):
        schema = json.loads(path.read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(schema)
        validators[path.name.removesuffix(".schema.json")] = Draft202012Validator(schema, registry=registry)
    count = 0
    for path in (ROOT / "protocol/v1/examples").glob("*.json"):
        value = json.loads(path.read_text(encoding="utf-8"))
        kind = "command" if path.stem in {"wake", "type", "key"} else path.stem
        validators[kind].validate(value)
        if kind == "command":
            subprocess.run([args.core_executable, json.dumps(value)], check=True)
        count += 1
    state = json.loads((ROOT / "protocol/v1/examples/state.json").read_text())
    for kind, payload in [("wake", {}), ("type_text", {"text": "Aa+ = !"}),
                          ("key", {"key": "ENTER", "modifiers": ["GUI"]})]:
        command = build_command(state, kind, payload, now_ms=1800000000000)
        validators["command"].validate(command)
        subprocess.run([args.core_executable, json.dumps(command)], check=True)
    print(f"PASS: {len(validators)} schemas, {count} fixtures, 3 CLI-to-firmware vectors")


if __name__ == "__main__":
    main()
