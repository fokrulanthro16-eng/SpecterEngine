#!/usr/bin/env python3
"""
SpecterEngine Contract Compiler & Byte Size Analyzer
Compiles Solidity contracts using solc 0.8.24 with optimizations (200 runs),
mirrors Foundry out/ directory structure, and outputs contract size analysis.
"""

import os
import glob
import json
import solcx

def main():
    solcx.set_solc_version("0.8.24")
    
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    contracts_dir = os.path.join(base_dir, "contracts")
    out_dir = os.path.join(base_dir, "out")
    
    contract_files = glob.glob(os.path.join(contracts_dir, "**", "*.sol"), recursive=True)
    
    compiled = solcx.compile_files(
        contract_files,
        output_values=["abi", "bin", "bin-runtime"],
        base_path=contracts_dir,
        optimize=True,
        optimize_runs=200
    )
    
    os.makedirs(out_dir, exist_ok=True)
    
    print("\n================================================================================")
    print("                 SOLIDITY COMPILATION STATUS & CONTRACT BYTE SIZES              ")
    print("                 Compiler: solc v0.8.24 | Optimizer: Yes (200 runs)             ")
    print("================================================================================")
    print(f" {'Contract':<26} | {'Runtime Size':<14} | {'Margin to 24.576 KB':<22} | {'Status':<8}")
    print("-" * 80)
    
    EIP170_LIMIT = 24576
    
    for k, data in sorted(compiled.items()):
        contract_name = k.split(":")[-1]
        file_path = k.split(":")[0]
        runtime_bin = data.get("bin-runtime", "")
        size_bytes = len(runtime_bin) // 2 if runtime_bin else 0
        margin = EIP170_LIMIT - size_bytes
        status = "PASS" if margin >= 0 else "EXCEEDED"
        
        # Save Foundry-compatible JSON artifact in out/
        artifact_dir = os.path.join(out_dir, os.path.basename(file_path))
        os.makedirs(artifact_dir, exist_ok=True)
        artifact_path = os.path.join(artifact_dir, f"{contract_name}.json")
        with open(artifact_path, "w") as f:
            json.dump({
                "abi": data["abi"],
                "bytecode": {"object": data.get("bin", "")},
                "deployedBytecode": {"object": runtime_bin}
            }, f, indent=2)
            
        print(f" {contract_name:<26} | {size_bytes:>6} bytes   | {margin:>6} bytes remaining   | {status:<8}")
        
    print("================================================================================\n")
    print(f"Foundry-compatible build artifacts saved to: {out_dir}")

if __name__ == "__main__":
    main()
