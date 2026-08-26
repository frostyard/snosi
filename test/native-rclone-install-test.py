#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = {
    ROOT / ".github/workflows/build-native-images.yml": 3,
    ROOT / ".github/workflows/build-installer-iso.yml": 1,
}
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


for workflow, expected_count in WORKFLOWS.items():
    blocks = named_step_blocks(workflow.read_text(), "Install rclone")
    if len(blocks) != expected_count:
        raise SystemExit(
            f"expected exactly {expected_count} Install rclone steps in "
            f"{workflow.name}, found {len(blocks)}"
        )

    for number, block in enumerate(blocks, start=1):
        commands = [line.strip() for line in block]
        try:
            update = commands.index("sudo apt-get update")
            install = commands.index("sudo apt-get install -y rclone")
        except ValueError as error:
            raise SystemExit(
                f"{workflow.name} Install rclone step {number} must refresh "
                "APT and install rclone"
            ) from error
        if update >= install:
            raise SystemExit(
                f"{workflow.name} Install rclone step {number} must refresh "
                "APT before installation"
            )

print("native-rclone-install-test: PASSED")
