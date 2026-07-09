#!/usr/bin/env python3
import argparse
import os
import ROOT

ROOT.gROOT.SetBatch(True)

# Placeholder WP thresholds only for producing the same compare.py structure.
# Replace with official v2p5 thresholds if needed.
WP = {
    "Loose":  0.20,
    "Medium": 0.50,
    "Tight":  0.80,
}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--tree", default="per_tau")
    args = ap.parse_args()

    if os.path.exists(args.output):
        os.remove(args.output)

    df = ROOT.RDataFrame(args.tree, args.input)
    cols = {str(c) for c in df.GetColumnNames()}

    def dor(df, name, expr):
        nonlocal cols
        if name in cols:
            print("Redefine", name, "=", expr)
            return df.Redefine(name, expr)
        print("Define  ", name, "=", expr)
        cols.add(name)
        return df.Define(name, expr)

    # Make DATA usable by MC-style denominators.
    df = dor(df, "tau_genpt",  "tau_pt")
    df = dor(df, "tau_geneta", "tau_eta")

    if "tau_phi" in cols:
        df = dor(df, "tau_genphi", "tau_phi")
    if "tau_mass" in cols:
        df = dor(df, "tau_genmass", "tau_mass")
    if "tau_dm" in cols:
        df = dor(df, "tau_gendm", "tau_dm")

    # Add DeepTau WP leaves expected by variables.py.
    for wp, thr in WP.items():
        if "tau_rawDeepTauVSjet" in cols:
            df = dor(df, f"tau_by{wp}DeepTau2018v2p5VSjet", f"tau_rawDeepTauVSjet > {thr}")
        if "tau_rawDeepTauVSe" in cols:
            df = dor(df, f"tau_by{wp}DeepTau2018v2p5VSe", f"tau_rawDeepTauVSe > {thr}")
        if "tau_rawDeepTauVSmu" in cols:
            df = dor(df, f"tau_by{wp}DeepTau2018v2p5VSmu", f"tau_rawDeepTauVSmu > {thr}")

    df.Snapshot(args.tree, args.output)
    print("[ok] wrote", args.output)

if __name__ == "__main__":
    main()
