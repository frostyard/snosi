#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/build-native-images.yml"
STEP_PREFIX = "      - name: "


def named_step_blocks(text: str, name: str) -> list[list[str]]:
    lines = text.splitlines()
    starts = [
        index
        for index, line in enumerate(lines)
        if line == f"{STEP_PREFIX}{name}"
    ]
    blocks = []
    for start in starts:
        end = next(
            (
                index
                for index in range(start + 1, len(lines))
                if lines[index].startswith(STEP_PREFIX)
            ),
            len(lines),
        )
        blocks.append(lines[start:end])
    return blocks


workflow = WORKFLOW.read_text()
blocks = named_step_blocks(workflow, "Install rclone")
if len(blocks) != 4:
    raise SystemExit(f"expected exactly 4 Install rclone steps, found {len(blocks)}")

for number, block in enumerate(blocks, start=1):
    commands = [line.strip() for line in block]
    try:
        update = commands.index("sudo apt-get update")
        install = commands.index("sudo apt-get install -y rclone")
    except ValueError as error:
        raise SystemExit(
            f"Install rclone step {number} must refresh APT and install rclone"
        ) from error
    if update >= install:
        raise SystemExit(
            f"Install rclone step {number} must refresh APT before installation"
        )

print("native-rclone-install-test: PASSED")
