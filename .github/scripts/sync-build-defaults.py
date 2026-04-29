#!/usr/bin/env python3
"""
Sync workflow_dispatch defaults in .github/workflows/build.yml with the
tracked-version files. Invoked by the scheduled auto-bump workflows after
they write `version`, `train`, or `.hailo-driver-version`, so a manual
dispatch from the Actions UI always pre-fills the latest tracked combo.

Usage:
    sync-build-defaults.py KEY=VALUE [KEY=VALUE ...]

Recognized keys: truenas_version, hailo_driver_version, train_name.
The substitution is scoped to workflow_dispatch by requiring the
`description:` line, which workflow_call inputs do not have. Each KEY
must match exactly once; zero or multiple matches fail loudly so a
silent no-op cannot ship a stale default.
"""
import re
import sys
from pathlib import Path

ALLOWED_KEYS = {"truenas_version", "hailo_driver_version", "train_name"}
BUILD_YML = Path(__file__).resolve().parents[1] / "workflows" / "build.yml"


def update(content: str, key: str, value: str) -> str:
    pattern = re.compile(
        rf"(^      {re.escape(key)}:\n"
        rf"        description: [^\n]*\n"
        rf"        required: true\n"
        rf"        default: ')[^']*(')",
        re.MULTILINE,
    )
    new_content, n = pattern.subn(rf"\g<1>{value}\g<2>", content)
    if n != 1:
        raise SystemExit(
            f"ERROR: expected exactly 1 workflow_dispatch default for "
            f"'{key}' in {BUILD_YML}, got {n}. Refusing to write."
        )
    return new_content


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        raise SystemExit(f"Usage: {argv[0]} KEY=VALUE [KEY=VALUE ...]")
    pairs = []
    for arg in argv[1:]:
        if "=" not in arg:
            raise SystemExit(f"ERROR: argument '{arg}' is not KEY=VALUE")
        key, value = arg.split("=", 1)
        if key not in ALLOWED_KEYS:
            raise SystemExit(
                f"ERROR: unknown key '{key}'. Allowed: {sorted(ALLOWED_KEYS)}"
            )
        if not value:
            raise SystemExit(f"ERROR: empty value for '{key}'")
        pairs.append((key, value))

    content = BUILD_YML.read_text()
    original = content
    for key, value in pairs:
        content = update(content, key, value)
    if content == original:
        print("No changes needed (defaults already match).")
        return
    BUILD_YML.write_text(content)
    for key, value in pairs:
        print(f"Set {key} default to '{value}' in {BUILD_YML.name}")


if __name__ == "__main__":
    main(sys.argv)
