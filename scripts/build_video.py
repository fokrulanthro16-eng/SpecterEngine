#!/usr/bin/env python3
"""
SpecterEngine Video Compositing & Assembly Pipeline
Stitches recorded 1080p60 video clips with high-fidelity synthesized audio tracks,
applies H.264 / AAC encoding, and exports the final web-optimized MP4 demo video:
  demo/specter_engine_demo.mp4
"""

import os
import re
import subprocess
import sys
from pathlib import Path

# Force UTF-8 stdout
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

ROOT_DIR = Path(__file__).resolve().parent.parent
DEMO_DIR = ROOT_DIR / "demo"
AUDIO_DIR = DEMO_DIR / "audio"
RAW_VIDEO_DIR = DEMO_DIR / "raw_recordings"
STITCHED_DIR = DEMO_DIR / "stitched_segments"

STITCHED_DIR.mkdir(parents=True, exist_ok=True)

FINAL_OUTPUT_MP4 = DEMO_DIR / "specter_engine_demo.mp4"
PARTS = ["part1", "part2", "part3", "part4"]


def get_video_info(file_path: Path):
    """Parses duration, resolution, and bitrate using ffmpeg."""
    cmd = ["ffmpeg", "-i", str(file_path)]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    match_dur = re.search(r"Duration:\s*(\d+):(\d+):(\d+\.\d+)", result.stderr)
    duration = 0.0
    if match_dur:
        h, m, s = match_dur.groups()
        duration = int(h) * 3600 + int(m) * 60 + float(s)

    match_res = re.search(r",\s*(\d{3,4}x\d{3,4})", result.stderr)
    resolution = match_res.group(1) if match_res else "1920x1080"

    return duration, resolution


def stitch_segment(part_name: str) -> Path:
    raw_video = RAW_VIDEO_DIR / f"{part_name}.webm"
    audio_file = AUDIO_DIR / f"{part_name}.mp3"
    output_segment = STITCHED_DIR / f"{part_name}_sync.mp4"

    print(f"Stitching {part_name}...")
    print(f"  Video: {raw_video.name} | Audio: {audio_file.name}")

    # Combine video and audio: pad last frame if video is shorter, cut when audio ends
    cmd = [
        "ffmpeg", "-y",
        "-i", str(raw_video),
        "-i", str(audio_file),
        "-vf", "tpad=stop_mode=clone:stop_duration=60",
        "-map", "0:v:0",
        "-map", "1:a:0",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-crf", "20",
        "-pix_fmt", "yuv420p",
        "-r", "60",
        "-c:a", "aac",
        "-b:a", "192k",
        "-shortest",
        str(output_segment)
    ]

    subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    dur, res = get_video_info(output_segment)
    print(f"  [+] {output_segment.name} created ({dur:.2f}s, {res}, {output_segment.stat().st_size} bytes)")
    return output_segment


def concatenate_segments(segments: list[Path], output_mp4: Path) -> Path:
    concat_file = DEMO_DIR / "concat_list.txt"
    with open(concat_file, "w") as f:
        for seg in segments:
            safe_path = seg.as_posix()
            f.write(f"file '{safe_path}'\n")

    print(f"\nConcatenating {len(segments)} segments into final MP4 demo video...")
    cmd = [
        "ffmpeg", "-y",
        "-f", "concat",
        "-safe", "0",
        "-i", str(concat_file),
        "-c", "copy",
        "-movflags", "+faststart",
        str(output_mp4)
    ]

    subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    concat_file.unlink(missing_ok=True)
    return output_mp4


def main():
    print("=" * 70)
    print("     SPECTERENGINE VIDEO COMPOSITING & ASSEMBLY PIPELINE       ")
    print(f"Output Target: {FINAL_OUTPUT_MP4}")
    print("=" * 70)

    # 1. Stitch each segment with audio
    stitched_segments = []
    for part in PARTS:
        seg = stitch_segment(part)
        stitched_segments.append(seg)

    # 2. Concatenate into final video
    final_video = concatenate_segments(stitched_segments, FINAL_OUTPUT_MP4)

    # 3. Audit final video metrics
    total_dur, resolution = get_video_info(final_video)
    file_size_mb = final_video.stat().st_size / (1024 * 1024)

    print("\n" + "=" * 70)
    print("DEMO VIDEO GENERATION COMPLETED SUCCESSFULLY!")
    print(f"  * File Path   : {final_video}")
    print(f"  * Duration    : {total_dur:.2f} seconds ({total_dur/60:.2f} minutes)")
    print(f"  * Resolution  : {resolution} @ 60 FPS")
    print(f"  * File Size   : {file_size_mb:.2f} MB")
    print(f"  * Encoding    : H.264 / AAC (Web-Optimized FastStart)")
    print("=" * 70)


if __name__ == "__main__":
    main()
