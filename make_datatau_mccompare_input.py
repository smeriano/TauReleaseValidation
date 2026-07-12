#!/usr/bin/env python3
import argparse
import os
import ROOT

ROOT.gROOT.SetBatch(True)

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

    # Never construct or overwrite DeepTau working points here.
    # Official decisions must come from produceTauValTree.py / PAT tau IDs.
    print()
    print("DeepTau branches preserved unchanged:")
    for name in sorted(cols):
        if "deeptau" in name.lower():
            print("Keep    ", name)

    df.Snapshot(args.tree, args.output)
    print("[ok] wrote", args.output)

if __name__ == "__main__":
    main()
