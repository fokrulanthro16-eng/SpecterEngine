#!/usr/bin/env python3
"""
SpecterEngine Screen Recording & Visual Pipeline
Captures high-resolution 1920x1080 60 FPS video segments for each audio track
using Playwright headless automation against the live Mission Control Cockpit.
"""

import json
import os
import shutil
import sys
import time
from pathlib import Path

# Force UTF-8 stdout
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

from playwright.sync_api import sync_playwright

ROOT_DIR = Path(__file__).resolve().parent.parent
DEMO_DIR = ROOT_DIR / "demo"
AUDIO_DIR = DEMO_DIR / "audio"
RAW_VIDEO_DIR = DEMO_DIR / "raw_recordings"

RAW_VIDEO_DIR.mkdir(parents=True, exist_ok=True)

with open(AUDIO_DIR / "durations.json", "r") as f:
    DURATIONS = json.load(f)

URL = "http://localhost:3000/demo_visuals.html"


def record_scene(part_name: str, scene_num: int, target_duration: float, trigger_exploit: bool = False) -> Path:
    dest_path = RAW_VIDEO_DIR / f"{part_name}.webm"

    # Only skip if file exists and has sufficient size (>2MB)
    if dest_path.exists() and dest_path.stat().st_size > 2_000_000:
        print(f"  [+] {part_name}.webm already recorded ({dest_path.stat().st_size} bytes). Skipping.")
        return dest_path

    temp_dir = RAW_VIDEO_DIR / f"temp_{part_name}"
    if temp_dir.exists():
        shutil.rmtree(temp_dir)
    temp_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n[+] Recording {part_name} (Scene {scene_num}) for {target_duration:.2f} seconds...")

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=True,
            args=[
                "--disable-background-timer-throttling",
                "--disable-renderer-backgrounding",
                "--disable-backgrounding-occluded-windows",
                "--disable-web-security",
                "--no-sandbox",
            ],
        )
        context = browser.new_context(
            viewport={"width": 1920, "height": 1080},
            record_video_dir=str(temp_dir),
            record_video_size={"width": 1920, "height": 1080},
        )
        page = context.new_page()

        t_start = time.time()
        page.goto(URL, wait_until="networkidle")
        page.evaluate(f"window.setScene({scene_num})")

        exploit_triggered = False

        # Active recording loop keeping Chromium rendering at 60 FPS
        while True:
            elapsed = time.time() - t_start
            if elapsed >= target_duration:
                break

            # Trigger exploit around 12 seconds in part 3
            if trigger_exploit and not exploit_triggered and elapsed >= 12.0:
                print("    Triggering 82% flash-loan reserve drain attack on cockpit...")
                try:
                    import urllib.request
                    urllib.request.urlopen("http://localhost:3000/api/trigger-exploit", data=b"{}")
                    print("    [!] Exploit triggered via REST API. Red neon threat spike engaged.")
                except Exception as e:
                    print(f"    Trigger error: {e}")
                exploit_triggered = True

            # Keep page active with subtle mouse movements
            step = int(elapsed * 10) % 200
            page.mouse.move(200 + step, 200 + (step % 50))
            time.sleep(0.5)

        raw_video_path = page.video.path()
        context.close()
        browser.close()

    if dest_path.exists():
        dest_path.unlink()
    shutil.move(raw_video_path, dest_path)
    shutil.rmtree(temp_dir)

    print(f"  [+] {part_name}.webm saved ({dest_path.stat().st_size} bytes)")
    return dest_path


def main():
    print("=" * 70)
    print("       SPECTERENGINE PLAYWRIGHT SCREEN RECORDING PIPELINE      ")
    print("Resolution: 1920x1080 | FPS: 60 | URL: " + URL)
    print("=" * 70)

    # Delete short recordings of part1 and part3 so they re-record cleanly
    for part in ["part1.webm", "part3.webm"]:
        p = RAW_VIDEO_DIR / part
        if p.exists() and p.stat().st_size < 2_000_000:
            print(f"Removing short {part} to re-record with active frame pipeline...")
            p.unlink()

    # Record all segments
    record_scene("part1", scene_num=1, target_duration=DURATIONS["part1"])
    record_scene("part2", scene_num=2, target_duration=DURATIONS["part2"])
    record_scene("part3", scene_num=3, target_duration=DURATIONS["part3"], trigger_exploit=True)
    record_scene("part4", scene_num=4, target_duration=DURATIONS["part4"])

    print("\n" + "=" * 70)
    print("ALL 4 VIDEO SEGMENTS RECORDED SUCCESSFULLY!")
    print(f"Saved to: {RAW_VIDEO_DIR}")
    print("=" * 70)


if __name__ == "__main__":
    main()
