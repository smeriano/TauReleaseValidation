#!/usr/bin/env python3
"""
Automate CMS Tau RelVal comparisons between two CMSSW releases.

Run this from inside a TauReleaseValidation checkout after cmsenv, for example:

  cd /eos/home-s/smeriano/UCLouvain/TAU_RELVAL/CMSSW_17_0_0_pre1/src/TauReleaseValidation
  cmsenv
  python3 tau_relval_auto_compare.py --target-release CMSSW_17_0_0_pre1 --ref-release CMSSW_16_0_0_pre4 --runtype ZTT --pileups noPU --dry-run

Then remove --dry-run to produce ROOT files and plots.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
import tarfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

DEFAULT_REJECT = ["GPUvsCPU", "G4VECGEOM", "RV286", "FastSIM", "FastSim", "FullSim", "ReHLT", "RecoOnly", "HI", "HIN"]
DEFAULT_GEN_ORDER = ["RegeneratedGS", "RegeneratedGEN", "RecycledGS", "RecycledGEN", "any"]


def msg(text: str = "") -> None:
    print(text, flush=True)


def die(text: str, code: int = 1) -> None:
    print(f"ERROR: {text}", file=sys.stderr, flush=True)
    raise SystemExit(code)


def run(cmd: list[str], *, log: Path | None = None, cwd: Path | None = None, check: bool = True) -> int:
    msg("+ " + " ".join(cmd))
    if log is None:
        proc = subprocess.run(cmd, cwd=str(cwd) if cwd else None)
        if check and proc.returncode != 0:
            die(f"command failed with exit code {proc.returncode}: {' '.join(cmd)}")
        return proc.returncode

    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as fh:
        proc = subprocess.Popen(cmd, cwd=str(cwd) if cwd else None, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        assert proc.stdout is not None
        for line in proc.stdout:
            print(line, end="")
            fh.write(line)
        proc.wait()
    if check and proc.returncode != 0:
        die(f"command failed with exit code {proc.returncode}; see {log}")
    return proc.returncode


def capture(cmd: list[str]) -> list[str]:
    try:
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as exc:
        msg(exc.output)
        die(f"command failed: {' '.join(cmd)}")
    return [line.strip() for line in out.splitlines() if line.strip()]


def version_from_release(release: str) -> str:
    return release.removeprefix("CMSSW_")


def slug(text: str, limit: int = 150) -> str:
    out = re.sub(r"[^A-Za-z0-9._+-]+", "_", text).strip("_")
    out = re.sub(r"_+", "_", out)
    return out[:limit] if out else "dataset"


def campaign_part(dataset: str) -> str:
    parts = dataset.split("/")
    return parts[2] if len(parts) > 2 else dataset


def primary_dataset(dataset: str) -> str:
    parts = dataset.split("/")
    return parts[1] if len(parts) > 1 else dataset


def data_tier(dataset: str) -> str:
    parts = dataset.split("/")
    return parts[3] if len(parts) > 3 else ""


def classify_pileup(dataset: str) -> str:
    lower = dataset.lower()
    if "nopu" in lower:
        return "noPU"
    if re.search(r"(^|[-_])pu($|[-_])", lower) or "kitfarm_pu" in lower:
        return "PU"
    return "unknownPU"


def classify_gen(dataset: str) -> str:
    for token in ["RegeneratedGS", "RegeneratedGEN", "RecycledGS", "RecycledGEN", "ReHLT", "RecoOnly"]:
        if token in dataset:
            return token
    return "UNKNOWN"


def classify_family(dataset: str) -> str:
    camp = campaign_part(dataset)
    match = re.search(r"(mcRun\d+)", camp)
    return match.group(1) if match else "UNKNOWN"


def classify_geometry(dataset: str) -> str:
    camp = campaign_part(dataset)
    match = re.search(r"Run4D\d+", camp)
    return match.group(0) if match else ""


def newest_date_token(dataset: str) -> int:
    camp = campaign_part(dataset)
    matches = re.findall(r"(20\d{6})(?:[_-]?(\d{6}))?", camp)
    if not matches:
        return 0
    date, time = matches[-1]
    return int(date + (time or "000000"))


def dataset_version(dataset: str) -> int:
    camp = campaign_part(dataset)
    match = re.search(r"-v(\d+)(?:/|$)", dataset)
    return int(match.group(1)) if match else 0


def label_from_dataset(dataset: str, release: str) -> str:
    camp = campaign_part(dataset)
    label = camp.removeprefix(f"{release}-").removeprefix(release).strip("_-")
    return slug(label)


@dataclass(frozen=True)
class Candidate:
    dataset: str
    release: str
    runtype: str
    pileup: str
    gen: str
    family: str
    geometry: str
    label: str
    primary: str
    date_score: int
    score: tuple[int, ...]


def das_query(runtype: str, release: str, data_format: str) -> str:
    version = version_from_release(release)
    return f"dataset dataset=/*{runtype}*/*{version}*/{data_format}"


def allowed_dataset(dataset: str, reject_contains: Iterable[str], require_std: bool) -> bool:
    if any(token in dataset for token in reject_contains):
        return False
    if require_std and "_STD_" not in dataset:
        return False
    return True


def score_dataset(dataset: str, gen_order: list[str]) -> tuple[int, int, int, int, int]:
    gen = classify_gen(dataset)
    try:
        gen_rank = gen_order.index(gen)
    except ValueError:
        try:
            gen_rank = gen_order.index("any")
        except ValueError:
            gen_rank = len(gen_order)
    std_rank = 0 if "_STD_" in dataset else 1
    known_pu_rank = 0 if classify_pileup(dataset) in {"noPU", "PU"} else 1
    # Prefer newest date when present, and higher -vN when date is absent/equal.
    return (gen_rank, std_rank, known_pu_rank, -newest_date_token(dataset), -dataset_version(dataset))


def candidate_tag(c: "Candidate") -> str:
    label = getattr(c, "label", "")
    primary = getattr(c, "primary", "")

    if not primary:
        return label

    if primary in label:
        return label

    return slug(f"{primary}__{label}", limit=220)


def candidate_from_dataset(args: argparse.Namespace, dataset: str, release: str, runtype: str, pileup: str) -> Candidate:
    return Candidate(dataset=dataset, release=release, runtype=runtype, pileup=classify_pileup(dataset) if classify_pileup(dataset) != "unknownPU" else pileup, gen=classify_gen(dataset), family=classify_family(dataset), geometry=classify_geometry(dataset), label=label_from_dataset(dataset, release), primary=primary_dataset(dataset), date_score=newest_date_token(dataset), score=score_dataset(dataset, args.gen_order))


def discover_candidates(args: argparse.Namespace, release: str, runtype: str, pileup: str, contains: list[str], exact_dataset: str | None = None) -> list[Candidate]:
    if exact_dataset:
        return [candidate_from_dataset(args, exact_dataset, release, runtype, pileup)]
    query = das_query(runtype, release, args.data_format)
    msg(f"[DAS] {query}")
    datasets = [d for d in capture(["dasgoclient", f"--query={query}"]) if d.startswith("/")]
    out: list[Candidate] = []
    for ds in datasets:
        # "*TTbar*" also finds RelValTTbarToDilepton datasets.
        # Reject them so TTbar always means inclusive TTbar.
        if runtype == "TTbar" and "dilepton" in primary_dataset(ds).lower():
            msg(f"[reject] TTbar dilepton dataset: {ds}")
            continue
        if not allowed_dataset(ds, args.reject_contains, args.require_std):
            continue
        if classify_pileup(ds) != pileup:
            continue
        if any(token not in ds for token in contains):
            continue
        if args.only_gen != "any" and classify_gen(ds) != args.only_gen:
            continue
        out.append(Candidate(dataset=ds, release=release, runtype=runtype, pileup=pileup, gen=classify_gen(ds), family=classify_family(ds), geometry=classify_geometry(ds), label=label_from_dataset(ds, release), primary=primary_dataset(ds), date_score=newest_date_token(ds), score=score_dataset(ds, args.gen_order)))
    return sorted(out, key=lambda c: c.score)


def choose_pair(args: argparse.Namespace, targets: list[Candidate], refs: list[Candidate]) -> tuple[Candidate, Candidate] | None:
    if not targets or not refs:
        return None
    for target in targets:
        compatible = refs
        if args.strict_primary and target.primary:
            compatible = [ref for ref in compatible if ref.primary == target.primary]
        if args.strict_family and target.family != "UNKNOWN":
            compatible = [ref for ref in compatible if ref.family == target.family]
        if args.strict_geometry and target.geometry:
            compatible = [ref for ref in compatible if ref.geometry == target.geometry]
        if compatible:
            return target, compatible[0]
    return None


def candidate_pairs(args: argparse.Namespace, targets: list[Candidate], refs: list[Candidate]) -> list[tuple[Candidate, Candidate]]:
    """
    Return compatible target/ref pairs in the intended fallback order:

      1. RegeneratedGS vs RegeneratedGS/UNKNOWN
      2. RecycledGS     vs RecycledGS/UNKNOWN
      3. RegeneratedGS vs RecycledGS
      4. RecycledGS     vs RegeneratedGS
      5. anything else

    UNKNOWN is allowed because old PU reference datasets often do not encode
    RegeneratedGS/RecycledGS in the dataset name.
    """
    target_rank = {c.dataset: i for i, c in enumerate(targets)}
    ref_rank = {c.dataset: i for i, c in enumerate(refs)}

    def family_geometry_ok(target: Candidate, ref: Candidate) -> bool:
        if args.strict_primary and target.primary and ref.primary != target.primary:
            return False
        if args.strict_family and target.family != "UNKNOWN" and ref.family != target.family:
            return False
        if args.strict_geometry and target.geometry and ref.geometry != target.geometry:
            return False
        return True

    def phase(target: Candidate, ref: Candidate) -> int:
        tg, rg = target.gen, ref.gen

        if tg == "RegeneratedGS" and rg in {"RegeneratedGS", "UNKNOWN"}:
            return 0
        if tg == "RecycledGS" and rg in {"RecycledGS", "UNKNOWN"}:
            return 1
        if tg == "RegeneratedGS" and rg == "RecycledGS":
            return 2
        if tg == "RecycledGS" and rg == "RegeneratedGS":
            return 3
        return 4

    pairs = []
    for target in targets:
        for ref in refs:
            if family_geometry_ok(target, ref):
                pairs.append((target, ref))

    pairs.sort(key=lambda tr: (phase(tr[0], tr[1]), target_rank[tr[0].dataset], ref_rank[tr[1].dataset]))
    return pairs



def print_candidates(title: str, candidates: list[Candidate], max_show: int = 20) -> None:
    msg(f"\n{title}: {len(candidates)} candidate(s)")
    for i, c in enumerate(candidates[:max_show], 1):
        msg(f"  {i:2d}. gen={c.gen:14s} pileup={c.pileup:4s} family={c.family:8s} geom={c.geometry or '-':9s} primary={c.primary:30s} label={candidate_tag(c)}")
        msg(f"      {c.dataset}")
    if len(candidates) > max_show:
        msg(f"      ... {len(candidates) - max_show} more not shown")


def check_environment() -> None:
    if not Path("produceTauValTree.py").is_file() or not Path("compare.py").is_file():
        die("run this from inside the TauReleaseValidation directory, where produceTauValTree.py and compare.py exist")
    if not os.environ.get("CMSSW_BASE"):
        die("CMSSW environment is not set; run cmsenv first")
    if shutil.which("dasgoclient") is None:
        die("dasgoclient not found; did you source cmsset_default.sh and run cmsenv?")
    if shutil.which("voms-proxy-info") is not None:
        rc = subprocess.run(["voms-proxy-info", "-exists", "-valid", "1:00"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        if rc != 0:
            run(["voms-proxy-init", "--voms", "cms", "-rfc", "--valid", "192:00"])


def root_output_name(release: str, runtype: str, produce_gt: str) -> str:
    return f"Myroot_{release}_{produce_gt}_{runtype}.root"


def produce(args: argparse.Namespace, cand: Candidate, side: str, out_root: Path) -> bool:
    out_root.parent.mkdir(parents=True, exist_ok=True)
    if out_root.exists() and not args.force:
        msg(f"[skip] ROOT file already exists: {out_root}")
        return True
    if out_root.exists() and args.force:
        out_root.unlink()

    default_name = Path(root_output_name(cand.release, cand.runtype, args.produce_gt))
    if default_name.exists() or default_name.is_symlink():
        default_name.unlink()

    cmd = ["python3", "produceTauValTree.py", "--release", cand.release, "--globalTag", args.produce_gt, "--runtype", cand.runtype, "-s", "das", "--exact", cand.dataset, "-o", default_name.name]
    if args.max_events is not None:
        cmd += ["-n", str(args.max_events)]
    for mvaid in args.mvaid:
        cmd += ["--mvaid", mvaid]

    log = args.outdir / "logs" / f"produce_{side}_{cand.runtype}_{cand.pileup}__{candidate_tag(cand)}.log"
    rc = run(cmd, log=log, check=False)
    if rc != 0:
        msg(f"[failed] production failed for {side} {cand.runtype} {cand.pileup}; see {log}")
        return False
    if not default_name.exists():
        msg(f"[failed] expected output was not produced: {default_name}")
        return False
    default_name.rename(out_root)
    msg(f"[ok] saved {out_root}")
    return True


def compare(args: argparse.Namespace, target: Candidate, ref: Candidate, target_root: Path, ref_root: Path) -> bool:
    plot_name = f"compare_{target.runtype}_{target.pileup}__target_{candidate_tag(target)}__ref_{candidate_tag(ref)}"
    plot_dest = args.outdir / "plots" / plot_name
    tar_dest = args.outdir / "tars" / f"{plot_name}.tar.gz"
    log = args.outdir / "logs" / f"{plot_name}.log"
    args.outdir.joinpath("plots").mkdir(parents=True, exist_ok=True)
    args.outdir.joinpath("tars").mkdir(parents=True, exist_ok=True)

    work_target = Path(root_output_name(target.release, target.runtype, args.produce_gt))
    work_ref = Path(root_output_name(ref.release, ref.runtype, args.produce_gt))
    for link in [work_target, work_ref]:
        if link.exists() or link.is_symlink():
            link.unlink()
    work_target.symlink_to(target_root.resolve())
    work_ref.symlink_to(ref_root.resolve())

    compare_dir = Path(f"compare_{target.runtype}")
    if compare_dir.exists():
        shutil.rmtree(compare_dir)
    if Path("missing_leaves.txt").exists():
        Path("missing_leaves.txt").unlink()
    if plot_dest.exists():
        shutil.rmtree(plot_dest)

    cmd = ["python3", "compare.py", "--releases", version_from_release(target.release), version_from_release(ref.release), "--inputfiles", str(work_target), str(work_ref), "--runtype", target.runtype]
    rc = run(cmd, log=log, check=False)
    if rc != 0:
        msg(f"[failed] comparison failed; see {log}")
        return False
    if not compare_dir.exists():
        msg(f"[failed] compare.py did not produce {compare_dir}")
        return False

    shutil.move(str(compare_dir), str(plot_dest))
    if Path("missing_leaves.txt").exists():
        shutil.copy2("missing_leaves.txt", plot_dest / "missing_leaves.txt")
    with tarfile.open(tar_dest, "w:gz") as tf:
        tf.add(plot_dest, arcname=plot_dest.name)
    msg(f"[ok] plots: {plot_dest}")
    msg(f"[ok] tar:   {tar_dest}")
    return True


def write_status(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = ["runtype", "pileup", "status", "detail", "target_dataset", "ref_dataset", "target_root", "ref_root", "plots"]
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields, delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description="Discover DAS RelVal tau samples, produce tau validation ROOT trees and run compare.py.")
    parser.add_argument("--target-release", required=True, help="Target CMSSW release, e.g. CMSSW_17_0_0_pre1")
    parser.add_argument("--ref-release", required=True, help="Reference CMSSW release, e.g. CMSSW_16_0_0_pre4")
    parser.add_argument("--runtype", nargs="+", default=["ZTT"], help="One or more runtypes: ZTT ZMM ZEE TTbar")
    parser.add_argument("--all-tau", action="store_true", help="Shortcut for --runtype ZTT ZMM ZEE TTbar")
    parser.add_argument("--pileups", nargs="+", default=["noPU"], choices=["noPU", "PU"], help="Pileup selections to compare")
    parser.add_argument("--data-format", default="MINIAOD*", help="DAS data tier pattern, usually MINIAOD* or MINIAODSIM")
    parser.add_argument("--target-contains", nargs="*", default=[], help="Additional substrings required in the target dataset path")
    parser.add_argument("--ref-contains", nargs="*", default=[], help="Additional substrings required in the reference dataset path")
    parser.add_argument("--target-dataset", default=None, help="Use this exact DAS target dataset instead of discovery")
    parser.add_argument("--ref-dataset", default=None, help="Use this exact DAS reference dataset instead of discovery")
    parser.add_argument("--only-gen", default="any", choices=["RegeneratedGS", "RegeneratedGEN", "RecycledGS", "RecycledGEN", "any"], help="Force a generator/reco origin instead of using the preference order")
    parser.add_argument("--gen-order", nargs="+", default=DEFAULT_GEN_ORDER, help="Preference order for dataset origin")
    parser.add_argument("--reject-contains", nargs="+", default=DEFAULT_REJECT, help="Datasets containing any of these tokens are rejected")
    parser.add_argument("--require-std", action=argparse.BooleanOptionalAction, default=True, help="Require _STD_ in the campaign name")
    parser.add_argument("--strict-family", action=argparse.BooleanOptionalAction, default=True, help="Require target/ref to have the same mcRunX family when known")
    parser.add_argument("--strict-geometry", action="store_true", help="Require target/ref to have the same Run4Dxxx geometry when target has one")
    parser.add_argument("--strict-primary", action=argparse.BooleanOptionalAction, default=True, help="Require target/ref to have the same DAS primary dataset name")
    parser.add_argument("--produce-gt", default="dummy", help="GlobalTag string passed to produceTauValTree.py; with --exact it is mostly used in file names")
    parser.add_argument("--max-events", type=int, default=None, help="Optional -n passed to produceTauValTree.py")
    parser.add_argument("--mvaid", action="append", default=[], help="Optional --mvaid to forward to produceTauValTree.py; can be repeated")
    parser.add_argument("--outdir", type=Path, default=Path("tau_relval_auto_outputs"), help="Output directory")
    parser.add_argument("--dry-run", action="store_true", help="Only discover and print candidate pairs; do not produce or compare")
    parser.add_argument("--force", action="store_true", help="Overwrite existing produced ROOT files")
    parser.add_argument("--keep-going", action="store_true", help="Continue after failed production/comparison")
    args = parser.parse_args()

    if args.all_tau:
        args.runtype = ["ZTT", "ZMM", "ZEE", "TTbar"]
    args.outdir.mkdir(parents=True, exist_ok=True)
    check_environment()

    rows: list[dict[str, str]] = []
    for runtype in args.runtype:
        for pileup in args.pileups:
            msg("\n" + "=" * 88)
            msg(f"Runtype={runtype} | pileup={pileup}")
            msg("=" * 88)
            targets = discover_candidates(args, args.target_release, runtype, pileup, args.target_contains, args.target_dataset)
            refs = discover_candidates(args, args.ref_release, runtype, pileup, args.ref_contains, args.ref_dataset)
            print_candidates("Target datasets", targets)
            print_candidates("Reference datasets", refs)

            pairs = candidate_pairs(args, targets, refs)
            if not pairs:
                detail = "missing target datasets" if not targets else "missing reference datasets"
                rows.append({"runtype": runtype, "pileup": pileup, "status": "SKIPPED", "detail": detail, "target_dataset": targets[0].dataset if targets else "", "ref_dataset": refs[0].dataset if refs else "", "target_root": "", "ref_root": "", "plots": ""})
                if not args.keep_going:
                    write_status(args.outdir / "status.tsv", rows)
                    die(detail)
                continue

            msg(f"\nCandidate fallback pairs: {len(pairs)}")
            for i, (t, r) in enumerate(pairs[:10], 1):
                msg(f"  {i:2d}. TARGET {candidate_tag(t)} (primary={t.primary})")
                msg(f"      REF    {candidate_tag(r)} (primary={r.primary})")
            if len(pairs) > 10:
                msg(f"      ... {len(pairs) - 10} more fallback pair(s)")

            if args.dry_run:
                target, ref = pairs[0]
                rows.append({"runtype": runtype, "pileup": pileup, "status": "DRY_RUN", "detail": f"{len(pairs)} fallback pair(s); first pair shown", "target_dataset": target.dataset, "ref_dataset": ref.dataset, "target_root": "", "ref_root": "", "plots": ""})
                continue

            ok_compare = False
            chosen_target = None
            chosen_ref = None
            chosen_target_root = None
            chosen_ref_root = None
            failure_details: list[str] = []

            target_cache: dict[str, tuple[bool, Path]] = {}
            ref_cache: dict[str, tuple[bool, Path]] = {}
            attempted_pairs: set[tuple[str, str]] = set()

            def family_geometry_ok(target: Candidate, ref: Candidate) -> bool:
                if args.strict_primary and target.primary and ref.primary != target.primary:
                    return False
                if args.strict_family and target.family != "UNKNOWN" and ref.family != target.family:
                    return False
                if args.strict_geometry and target.geometry and ref.geometry != target.geometry:
                    return False
                return True

            def produce_target_once(target: Candidate) -> tuple[bool, Path]:
                target_root = args.outdir / "root" / f"target_{runtype}_{pileup}__{candidate_tag(target)}.root"
                if target.dataset in target_cache:
                    ok, cached_root = target_cache[target.dataset]
                    msg(f"[reuse] target {candidate_tag(target)}: {'OK' if ok else 'FAILED'}")
                    return ok, cached_root

                ok = produce(args, target, "target", target_root)
                target_cache[target.dataset] = (ok, target_root)
                return ok, target_root

            def produce_ref_once(ref: Candidate) -> tuple[bool, Path]:
                ref_root = args.outdir / "root" / f"ref_{runtype}_{pileup}__{candidate_tag(ref)}.root"
                if ref.dataset in ref_cache:
                    ok, cached_root = ref_cache[ref.dataset]
                    msg(f"[reuse] reference {candidate_tag(ref)}: {'OK' if ok else 'FAILED'}")
                    return ok, cached_root

                ok = produce(args, ref, "reference", ref_root)
                ref_cache[ref.dataset] = (ok, ref_root)
                return ok, ref_root

            phases = [
                (
                    "RegeneratedGS target vs RegeneratedGS/UNKNOWN reference",
                    lambda t: t.gen == "RegeneratedGS",
                    lambda t, r: r.gen in {"RegeneratedGS", "UNKNOWN"},
                ),
                (
                    "RecycledGS target vs RecycledGS/UNKNOWN reference",
                    lambda t: t.gen == "RecycledGS",
                    lambda t, r: r.gen in {"RecycledGS", "UNKNOWN"},
                ),
                (
                    "LAST-RESORT mixed: RegeneratedGS target vs RecycledGS reference",
                    lambda t: t.gen == "RegeneratedGS",
                    lambda t, r: r.gen == "RecycledGS",
                ),
                (
                    "LAST-RESORT mixed: RecycledGS target vs RegeneratedGS reference",
                    lambda t: t.gen == "RecycledGS",
                    lambda t, r: r.gen == "RegeneratedGS",
                ),
                (
                    "LAST-RESORT anything compatible",
                    lambda t: True,
                    lambda t, r: True,
                ),
            ]

            for phase_idx, (phase_name, target_pred, ref_pred) in enumerate(phases, 1):
                if ok_compare:
                    break

                phase_targets = [t for t in targets if target_pred(t)]
                if not phase_targets:
                    continue

                msg("\\n" + "=" * 88)
                msg(f"Fallback phase {phase_idx}/{len(phases)}: {phase_name}")
                msg("=" * 88)

                for target in phase_targets:
                    phase_refs = [
                        ref for ref in refs
                        if family_geometry_ok(target, ref)
                        and ref_pred(target, ref)
                        and (target.dataset, ref.dataset) not in attempted_pairs
                    ]

                    if not phase_refs:
                        continue

                    msg("\\n" + "-" * 88)
                    msg(f"Trying target for phase: {candidate_tag(target)}")
                    msg(f"  TARGET: {target.dataset}")

                    ok_target, target_root = produce_target_once(target)
                    if not ok_target:
                        failure_details.append(f"target failed: {candidate_tag(target)}")
                        msg("[fallback] target failed; trying next target in this phase")
                        continue

                    chosen_target = target
                    chosen_target_root = target_root

                    msg(f"Reference candidates for this target: {len(phase_refs)}")
                    for i, ref in enumerate(phase_refs, 1):
                        if target.gen == ref.gen:
                            tag = "same-gen"
                        elif target.gen == "UNKNOWN" or ref.gen == "UNKNOWN":
                            tag = "unknown-gen-compatible"
                        else:
                            tag = "LAST-RESORT-MIXED-GEN"
                        msg(f"  {i:2d}. [{tag}] {candidate_tag(ref)} (primary={ref.primary})")

                    for ref in phase_refs:
                        attempted_pairs.add((target.dataset, ref.dataset))

                        msg("\\n" + "-" * 88)
                        msg(f"Trying reference in phase: {phase_name}")
                        msg(f"  TARGET: {target.dataset}")
                        msg(f"  REF:    {ref.dataset}")

                        if target.gen != ref.gen and target.gen != "UNKNOWN" and ref.gen != "UNKNOWN":
                            msg(f"  WARNING: last-resort mixed known gen classes: target={target.gen}, ref={ref.gen}")

                        ok_ref, ref_root = produce_ref_once(ref)
                        if not ok_ref:
                            failure_details.append(f"reference failed: {candidate_tag(ref)}")
                            msg("[fallback] reference failed; trying next reference")
                            continue

                        ok_compare = compare(args, target, ref, target_root, ref_root)
                        if not ok_compare:
                            failure_details.append(f"compare failed: target={candidate_tag(target)} ref={candidate_tag(ref)}")
                            msg("[fallback] compare failed; trying next reference")
                            continue

                        chosen_target = target
                        chosen_ref = ref
                        chosen_target_root = target_root
                        chosen_ref_root = ref_root
                        msg("[fallback] success")
                        break

                    # Important:
                    # If the newest target for this phase produced successfully but all refs failed,
                    # do NOT try older target versions in the same phase. Move to next phase.
                    if ok_compare:
                        break

                    msg("[fallback] newest working target for this phase exhausted its references; moving to next phase")
                    break

            # If all phases failed, keep a valid status row.
            if chosen_target is None and pairs:
                chosen_target = pairs[0][0]
                chosen_target_root = args.outdir / "root" / f"target_{runtype}_{pileup}__{candidate_tag(chosen_target)}.root"

            if chosen_ref is None:
                # Prefer the last attempted reference if available, otherwise first compatible one.
                if attempted_pairs:
                    last_tds, last_rds = list(attempted_pairs)[-1]
                    for ref in refs:
                        if ref.dataset == last_rds:
                            chosen_ref = ref
                            chosen_ref_root = args.outdir / "root" / f"ref_{runtype}_{pileup}__{candidate_tag(ref)}.root"
                            break
                elif refs:
                    chosen_ref = refs[0]
                    chosen_ref_root = args.outdir / "root" / f"ref_{runtype}_{pileup}__{candidate_tag(chosen_ref)}.root"

            status = "OK" if ok_compare else "FAILED"
            detail = "comparison produced" if ok_compare else "all fallback pairs failed"
            if not ok_compare and failure_details:
                detail += "; " + " | ".join(failure_details[-5:])

            if chosen_target is None:
                chosen_target = pairs[0][0]
                chosen_ref = pairs[0][1]
                chosen_target_root = args.outdir / "root" / f"target_{runtype}_{pileup}__{candidate_tag(chosen_target)}.root"
                chosen_ref_root = args.outdir / "root" / f"ref_{runtype}_{pileup}__{candidate_tag(chosen_ref)}.root"

            # If all reference fallbacks failed, chosen_target may exist but chosen_ref is still None.
            # Keep the status row valid and leave the comparison marked FAILED.
            if chosen_ref is None:
                same_gen_refs = [ref for ref in refs if chosen_target is not None and ref.gen == chosen_target.gen]
                chosen_ref = same_gen_refs[0] if same_gen_refs else (refs[0] if refs else None)

            if chosen_ref is None:
                ref_dataset = ""
                ref_root_str = ""
                plots_str = ""
            else:
                if chosen_ref_root is None:
                    chosen_ref_root = args.outdir / "root" / f"ref_{runtype}_{pileup}__{candidate_tag(chosen_ref)}.root"
                ref_dataset = chosen_ref.dataset
                ref_root_str = str(chosen_ref_root)
                plots_str = str(args.outdir / "plots" / f"compare_{chosen_target.runtype}_{chosen_target.pileup}__target_{candidate_tag(chosen_target)}__ref_{candidate_tag(chosen_ref)}")

            rows.append({"runtype": runtype, "pileup": pileup, "status": status, "detail": detail, "target_dataset": chosen_target.dataset, "ref_dataset": ref_dataset, "target_root": str(chosen_target_root), "ref_root": ref_root_str, "plots": plots_str})
            write_status(args.outdir / "status.tsv", rows)

            if not ok_compare and not args.keep_going:
                die("stopping after all fallback pairs failed; use --keep-going to continue")

    write_status(args.outdir / "status.tsv", rows)
    msg(f"\nDone. Status: {args.outdir / 'status.tsv'}")


if __name__ == "__main__":
    main()
