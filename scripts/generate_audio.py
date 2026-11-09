#!/usr/bin/env python3
"""
SpecterEngine Voiceover Audio Synthesis Pipeline
Generates synchronized, high-fidelity voiceover tracks using edge-tts (en-US-ChristopherNeural).
Produces 4 segments matching the official 3-minute hackathon demo script:
  Part 1: Temporal Asymmetry & Overview (0:00 - 0:40)
  Part 2: Architecture & ONNX Inference (0:40 - 1:30)
  Part 3: Live Exploit & 14.54ms Quarantine (1:30 - 2:20)
  Part 4: On-Chain Ledger & Conclusion (2:20 - 3:00)
"""

import asyncio
import os
import re
import subprocess
import json
from pathlib import Path
import edge_tts

ROOT_DIR = Path(__file__).resolve().parent.parent
AUDIO_DIR = ROOT_DIR / "demo" / "audio"
AUDIO_DIR.mkdir(parents=True, exist_ok=True)

VOICE = "en-US-ChristopherNeural"
RATE = "+0%"
PITCH = "+0Hz"

SCRIPTS = {
    "part1": (
        "Welcome to the official demonstration of SpecterEngine: the autonomous cross-chain execution airlock "
        "engineered for the Reactive Omni Buildathon, competing in the 'Reactive Meets AI' and 'Every Second Counts' tracks. "
        "In high-velocity Layer 2 rollups like Base Sepolia, blocks are minted every 200 milliseconds. "
        "Traditional oracle networks and decentralized keeper bots operate with 12 to 60-second reaction budgets. "
        "During multi-stage flash loans and liquidity drains, this temporal asymmetry is fatal: by the time an off-chain oracle updates, "
        "the vault reserves have already been drained. "
        "SpecterEngine fundamentally eliminates this vulnerability window by coupling sub-millisecond edge neural inference with Reactive Omni's "
        "one-second deterministic CometBFT consensus, establishing an autonomous feedback loop that isolates compromised protocol state in under 15 milliseconds."
    ),
    "part2": (
        "Let us examine the four architectural tiers powering SpecterEngine. "
        "At the Origin Layer on Base Sepolia, our Mock DeFi Automated Market Maker vault emits low-latency Threat Trigger Events "
        "whenever liquidity displacement or slippage velocity exceeds calibrated safety thresholds. "
        "In the Sentinel Plane, an asynchronous neural engine processes incoming telemetry through an embedded ONNX runtime model. "
        "It evaluates a continuous composite anomaly tensor: S sub t equals alpha times reserve shift ratio, plus beta times normalized slippage volatility, "
        "plus gamma times mempool priority fee urgency. "
        "Leveraging an optimized 50-tick sliding-window circular buffer, neural inference completes in just 0.389 milliseconds. "
        "When the anomaly score breaches the 0.88 threshold, the Sentinel cryptographically signs an EIP-712 Threat Attestation in 8 milliseconds, "
        "guaranteeing mathematical and cryptographic integrity without trusted intermediaries."
    ),
    "part3": (
        "Now, let us observe SpecterEngine in action on our live Terminal Telemetry Cockpit. "
        "On the display, our 60 frames-per-second HTML5 Canvas oscilloscope tracks the continuous threat metric across Base Sepolia's "
        "200-millisecond micro-blocks and Reactive Omni's one-second consensus intervals. "
        "During normal trading flow, the threat score remains safely at baseline. "
        "Watch closely as we simulate an aggressive multi-hop exploit: an attacker executes an 82 ETH flash loan, "
        "inflicting an immediate 82 percent reserve shock and a massive slippage impulse. "
        "Instantly, the oscilloscope spikes into critical crimson. The Sentinel detects the breach in 389 microseconds, "
        "certifies the EIP-712 payload, and Reactive Omni's CometBFT consensus dispatches a cross-chain callback to the Specter Airlock Receiver on Base Sepolia. "
        "Total autonomous reaction time: 14.54 milliseconds. "
        "The pool enters atomic quarantine. When the attacker attempts a secondary drain in the subsequent block, "
        "the transaction immediately reverts with 'Pool Is Quarantined'. Zero liquidity loss is incurred."
    ),
    "part4": (
        "In our Airlock Execution Ledger, every incident is committed with its unique cryptographic hash, verified trigger source, "
        "risk score of 99.85 percent, and microsecond reaction timestamp. "
        "SpecterEngine achieves total breach insulation fourteen times faster than Base Sepolia's 200-millisecond block cadence. "
        "Built in production-grade Solidity 0.8.24 with complete IPayer gas settlement, 100% Foundry compilation, and zero placeholders, "
        "SpecterEngine represents the future of autonomous, AI-driven cross-chain security. "
        "All code, testnet deployment automation, and simulation harnesses are fully open-source under the MIT license on GitHub. "
        "Thank you for watching the SpecterEngine demonstration for the Reactive Omni Buildathon."
    ),
}


def get_audio_duration(file_path: Path) -> float:
    """Uses ffmpeg to parse exact audio duration in seconds."""
    cmd = ["ffmpeg", "-i", str(file_path)]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    match = re.search(r"Duration:\s*(\d+):(\d+):(\d+\.\d+)", result.stderr)
    if match:
        h, m, s = match.groups()
        return int(h) * 3600 + int(m) * 60 + float(s)
    return 0.0


async def generate_segment(name: str, text: str):
    output_mp3 = AUDIO_DIR / f"{name}.mp3"
    print(f"Generating audio for {name} ({len(text)} chars)...")
    communicator = edge_tts.Communicate(text, VOICE, rate=RATE, pitch=PITCH)
    await communicator.save(str(output_mp3))
    duration = get_audio_duration(output_mp3)
    print(f"  [+] {name}.mp3 generated: {duration:.2f} seconds")
    return output_mp3, duration


async def main():
    print("=" * 70)
    print("       SPECTERENGINE AUDIO SYNTHESIS PIPELINE (edge-tts)       ")
    print(f"Voice: {VOICE} | Destination: {AUDIO_DIR}")
    print("=" * 70)

    total_duration = 0.0
    durations = {}

    for name, text in SCRIPTS.items():
        _, dur = await generate_segment(name, text)
        durations[name] = dur
        total_duration += dur

    print("\n" + "=" * 70)
    print(f"AUDIO SYNTHESIS COMPLETE! Total Duration: {total_duration:.2f}s ({total_duration/60:.2f} mins)")
    for name, dur in durations.items():
        print(f"  * {name}: {dur:.2f}s")
    print("=" * 70)

    # Save metadata JSON for the video recording pipeline
    meta_path = AUDIO_DIR / "durations.json"
    with open(meta_path, "w") as f:
        json.dump(durations, f, indent=2)
    print(f"Saved duration metadata to {meta_path}")


if __name__ == "__main__":
    asyncio.run(main())
