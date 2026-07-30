#!/usr/bin/env python3
"""Encode Unity interaction capture takes into review MP4s and contact sheets.

The Unity side renders deterministic PNG sequences (fixed timestep, fixed frame
rate) plus a ``metrics.json`` per take. This script owns everything after that:
H.264 encoding, contact sheets, and the acceptance gate over the measured
numbers. Keeping it here means the project never takes com.unity.recorder as a
dependency, and means the gate can run in CI without a GPU.

Layout it expects under the capture root:

    <root>/takes/<take-id>/frame_00000.png ...
    <root>/takes/<take-id>/metrics.json

Layout it produces:

    <root>/mp4/<take-id>.mp4
    <root>/contact-sheets/<take-id>.png
    <root>/summary.json

Every output is a pure function of the inputs: frames are consumed in sorted
order, sampling indices are computed arithmetically, and no wall-clock time or
random value reaches the output. Re-running over the same takes reproduces the
same bytes, so contact sheets can be committed as golden images.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys


FRAME_GLOB = "frame_*.png"
METRICS_FILENAME = "metrics.json"
SUMMARY_FILENAME = "summary.json"
SCHEMA_VERSION = 1

# The acceptance gates from the approved interaction plan. A take that reports
# metrics outside these bounds fails the run; a take that reports no metrics at
# all also fails, because a silently unmeasured take reads like a passing one.
GATES: dict[str, tuple[str, float]] = {
    "gripPositionErrorMeters": ("max", 0.02),
    "gripAngleErrorDegrees": ("max", 5.0),
    "footErrorMeters": ("max", 0.02),
    "propPenetrationMeters": ("max", 0.0),
    "supportRestoreErrorMeters": ("max", 0.005),
    "maxPropSpeedMetersPerSecond": ("max", 2.5),
    "propMovementBeforeContactMeters": ("max", 0.001),
}


class CaptureError(RuntimeError):
    """A capture take is malformed or an encoder invocation failed."""


def require_ffmpeg() -> str:
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise CaptureError(
            "ffmpeg is not on PATH. Install it (brew install ffmpeg) and re-run."
        )
    return ffmpeg


def run(command: list[str]) -> None:
    completed = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise CaptureError(
            f"command failed ({completed.returncode}): {' '.join(command)}\n"
            f"{completed.stdout.strip()}"
        )


def discover_takes(root: pathlib.Path) -> list[pathlib.Path]:
    takes_root = root / "takes"
    if not takes_root.is_dir():
        raise CaptureError(f"no takes directory under {root}")
    takes = sorted(path for path in takes_root.iterdir() if path.is_dir())
    if not takes:
        raise CaptureError(f"no takes found under {takes_root}")
    return takes


def frames_of(take: pathlib.Path) -> list[pathlib.Path]:
    frames = sorted(take.glob(FRAME_GLOB))
    if not frames:
        raise CaptureError(f"take {take.name} contains no {FRAME_GLOB} frames")
    return frames


def encode_mp4(
    ffmpeg: str, take: pathlib.Path, frames: list[pathlib.Path], destination: pathlib.Path, fps: int
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    first = frames[0].stem
    digits = len(first.split("_")[-1])
    pattern = str(take / f"frame_%0{digits}d.png")
    start_number = int(first.split("_")[-1])
    run(
        [
            ffmpeg,
            "-y",
            "-nostdin",
            "-loglevel",
            "error",
            "-framerate",
            str(fps),
            "-start_number",
            str(start_number),
            "-i",
            pattern,
            "-frames:v",
            str(len(frames)),
            # yuv420p needs even dimensions; capture sizes are chosen even but a
            # stray odd render target should degrade rather than abort the run.
            "-vf",
            "scale=trunc(iw/2)*2:trunc(ih/2)*2",
            "-c:v",
            "libx264",
            "-preset",
            "slow",
            "-crf",
            "18",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            str(destination),
        ]
    )


def sample_indices(count: int, wanted: int) -> list[int]:
    """Evenly spaced frame indices, always including the first and last frame."""
    if wanted >= count:
        return list(range(count))
    if wanted == 1:
        return [0]
    step = (count - 1) / (wanted - 1)
    return [round(index * step) for index in range(wanted)]


def build_contact_sheet(
    ffmpeg: str,
    frames: list[pathlib.Path],
    destination: pathlib.Path,
    columns: int,
    rows: int,
    tile_width: int,
) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    chosen = [frames[index] for index in sample_indices(len(frames), columns * rows)]
    listing = destination.with_suffix(".concat.txt")
    listing.write_text(
        "".join(f"file '{frame.resolve()}'\nduration 1\n" for frame in chosen),
        encoding="utf-8",
    )
    try:
        run(
            [
                ffmpeg,
                "-y",
                "-nostdin",
                "-loglevel",
                "error",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                str(listing),
                "-vf",
                f"scale={tile_width}:-1,tile={columns}x{rows}",
                "-frames:v",
                "1",
                str(destination),
            ]
        )
    finally:
        listing.unlink(missing_ok=True)


def read_metrics(take: pathlib.Path) -> dict | None:
    metrics_path = take / METRICS_FILENAME
    if not metrics_path.is_file():
        return None
    try:
        return json.loads(metrics_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise CaptureError(f"take {take.name}: unreadable {METRICS_FILENAME}: {error}") from error


def evaluate_gates(take_id: str, metrics: dict | None) -> list[str]:
    if metrics is None:
        return [f"{take_id}: no {METRICS_FILENAME}; the take was never measured"]

    failures: list[str] = []
    for key, (kind, bound) in GATES.items():
        if key not in metrics:
            failures.append(f"{take_id}: metrics are missing '{key}'")
            continue
        value = metrics[key]
        if not isinstance(value, (int, float)):
            failures.append(f"{take_id}: '{key}' is not numeric ({value!r})")
            continue
        if kind == "max" and value > bound:
            failures.append(f"{take_id}: {key} {value:.4f} exceeds {bound:.4f}")

    if metrics.get("attachFrame", -1) < 0:
        failures.append(f"{take_id}: the prop never attached")
    if metrics.get("releaseFrame", -1) < 0:
        failures.append(f"{take_id}: the prop never released")
    if metrics.get("bothFeetGrounded") is False:
        failures.append(f"{take_id}: a foot left the ground during the interaction")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("root", type=pathlib.Path, help="capture root containing takes/")
    parser.add_argument("--fps", type=int, default=60, help="capture frame rate (default 60)")
    parser.add_argument("--columns", type=int, default=6, help="contact sheet columns")
    parser.add_argument("--rows", type=int, default=4, help="contact sheet rows")
    parser.add_argument("--tile-width", type=int, default=320, help="contact sheet tile width")
    parser.add_argument(
        "--skip-video",
        action="store_true",
        help="only re-evaluate the acceptance gates over existing metrics.json files",
    )
    arguments = parser.parse_args()

    root: pathlib.Path = arguments.root
    try:
        takes = discover_takes(root)
        ffmpeg = "" if arguments.skip_video else require_ffmpeg()

        summary: dict = {
            "schemaVersion": SCHEMA_VERSION,
            "fps": arguments.fps,
            "takes": [],
            "failures": [],
        }

        for take in takes:
            metrics = read_metrics(take)
            entry: dict = {"takeId": take.name, "metrics": metrics}

            if not arguments.skip_video:
                frames = frames_of(take)
                mp4 = root / "mp4" / f"{take.name}.mp4"
                sheet = root / "contact-sheets" / f"{take.name}.png"
                encode_mp4(ffmpeg, take, frames, mp4, arguments.fps)
                build_contact_sheet(
                    ffmpeg, frames, sheet, arguments.columns, arguments.rows, arguments.tile_width
                )
                entry["frameCount"] = len(frames)
                entry["mp4"] = str(mp4.relative_to(root))
                entry["contactSheet"] = str(sheet.relative_to(root))
                print(f"encoded {take.name} ({len(frames)} frames)")

            failures = evaluate_gates(take.name, metrics)
            entry["passed"] = not failures
            summary["takes"].append(entry)
            summary["failures"].extend(failures)

        summary["passed"] = not summary["failures"]
        (root / SUMMARY_FILENAME).write_text(
            json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )

        if summary["failures"]:
            print(f"\n✗ {len(summary['failures'])} acceptance failure(s):", file=sys.stderr)
            for failure in summary["failures"]:
                print(f"  - {failure}", file=sys.stderr)
            return 1

        print(f"\n✓ {len(takes)} take(s) passed every acceptance gate")
        return 0
    except CaptureError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
