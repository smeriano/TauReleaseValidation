#!/usr/bin/env python3
"""Tau histogram/efficiency statistical screening from existing per_tau trees.

Run in a CMSSW checkout after cmsenv. Only PyROOT and the Python standard
library are required. SciPy, if available, accelerates Fisher exact tests.
This is a RelMon-style screening report, not the official RelMon or an
automatic physics-validation decision. See index.html for assumptions.

Example:
python3 tau_relval_statistics.py \
  --campaign-dir tau_relval_auto_outputs_MC_20_1_0_pre3_vs_20_0_0_patch1_D128_PU \
  --samples ZMM ZEE ZTT TTbar \
  --pileups PU \
  --target-release CMSSW_20_1_0_pre3 \
  --ref-release CMSSW_20_0_0_patch1 \
  --target-gt 150X_mcRun4_realistic_v1 \
  --ref-gt 150X_mcRun4_realistic_v1

Inputs: the campaign status.tsv, its target/ref ROOT trees, and the local
variables.py and compare.py used for plotting. Cuts and efficiency selections
are extracted from that local code; no CMSSW reconstruction is rerun.
Outputs: index.html, per-test HTML details, results.tsv, bins.tsv, results.json,
manifest.json and per-sample raw-count ROOT files. Existing inputs are read-only.
No absolute event-rate test is performed: tree rows are reference objects.
The output should be separate from the source checkout and input ROOT files.
"""
from __future__ import annotations

import argparse
import ast
from array import array
from collections import Counter
import csv
from datetime import datetime, timezone
import fnmatch
from functools import lru_cache
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import sys
from types import SimpleNamespace
from urllib.parse import quote
import uuid
import warnings

ROOT = None
VERSION = "1.0"
SUCCESS = {"OK", "OK_WITH_MISSING_OPTIONAL_BRANCHES"}
FIELDS = [
    "runtype", "pileup", "kind", "variable", "axis", "status", "test",
    "p_value", "p_holm", "flag_raw", "flag_holm", "statistic", "ndf",
    "target_total", "ref_total", "count_ratio", "target_pass", "ref_pass",
    "target_efficiency", "ref_efficiency", "max_abs_bin_difference",
    "total_variation", "original_bins", "tested_bins", "uncovered_bins",
    "min_bin_p", "notes", "plot", "counts_file",
]
DISCLAIMER = (
    "Screening assumes independent, unweighted reference-object trials. "
    "Multiple objects from the same event and shared/recycled events across releases "
    "can violate that model. p-values are therefore nominal screening diagnostics, "
    "not calibrated event-level evidence or an automatic campaign OK. "
    "GT/conditions changes can also cause real differences. "
    "A large p-value is not proof of equivalence."
)


def root_setup():
    global ROOT
    try:
        import ROOT as root
    except ImportError as exc:
        raise RuntimeError("PyROOT is required. Run cmsenv in the target CMSSW area.") from exc
    ROOT = root
    ROOT.PyConfig.IgnoreCommandLineOptions = True
    ROOT.gROOT.SetBatch(True)
    ROOT.TH1.AddDirectory(False)


def probability(chi2, ndf):
    if ndf < 1:
        return None
    if not math.isfinite(chi2) or chi2 < 0:
        raise ValueError("Invalid chi-square statistic.")
    p = float(ROOT.TMath.Prob(float(chi2), int(ndf)))
    if not math.isfinite(p) or not 0 <= p <= 1:
        raise ValueError("Invalid chi-square p-value.")
    return p


def logchoose(n, k):
    if k < 0 or k > n:
        return -math.inf
    return math.lgamma(n + 1) - math.lgamma(k + 1) - math.lgamma(n - k + 1)


@lru_cache(maxsize=32768)
def fisher_python(a, b, c, d):
    """Two-sided Fisher p: sum probabilities no greater than observed."""
    n1, successes, total = a + b, a + c, a + b + c + d
    if n1 == 0 or n1 == total or successes in (0, total):
        return 1.0
    low, high = max(0, n1 - (total - successes)), min(n1, successes)
    common = logchoose(total, n1)

    def logp(x):
        return logchoose(successes, x) + logchoose(total - successes, n1 - x) - common

    observed = logp(a)
    terms = [logp(x) for x in range(low, high + 1)]
    # Cancellation in lgamma requires a small relative probability tolerance.
    terms = [v for v in terms if v <= observed + 1e-9]
    maximum = max(terms)
    return min(1.0, math.exp(maximum) * math.fsum(math.exp(v - maximum) for v in terms))


def fisher(a, b, c, d):
    return fisher_python(int(a), int(b), int(c), int(d))


def enable_scipy():
    global fisher
    try:
        from scipy.stats import fisher_exact
    except ImportError:
        return "Python stdlib"

    @lru_cache(maxsize=32768)
    def accelerated(a, b, c, d):
        return float(fisher_exact([[a, b], [c, d]], alternative="two-sided")[1])
    fisher = accelerated
    return "scipy.stats.fisher_exact"


def checked_counts(values):
    counts = []
    for value in values:
        if not math.isfinite(value) or value < 0 or abs(value - round(value)) > 1e-7:
            raise ValueError("Non-integer, negative or non-finite bin content; unweighted tests not applicable.")
        counts.append(int(round(value)))
    return counts


def shape_test(target, reference, min_expected=5.0):
    """2xK Pearson homogeneity test, with label-blind adjacent pooling."""
    target, reference = checked_counts(target), checked_counts(reference)
    if len(target) != len(reference):
        raise ValueError("Different bin counts.")
    nt, nr = sum(target), sum(reference)
    base = dict(target_total=nt, ref_total=nr, original_bins=len(target),
                tested_bins=0, p_value=None, statistic=None, ndf=None,
                count_ratio=nt / nr if nr else None, groups=[])
    if nt == 0 and nr == 0:
        return dict(base, status="BOTH_EMPTY", notes="No selected entries in either histogram.")
    if not nt or not nr:
        return dict(base, status="ONE_EMPTY", notes="Shape undefined for an empty sample; inspect availability/selection.")
    pt, pr = [v / nt for v in target], [v / nr for v in reference]
    base.update(max_abs_bin_difference=max(abs(a - b) for a, b in zip(pt, pr)),
                total_variation=0.5 * sum(abs(a - b) for a, b in zip(pt, pr)))
    groups, pending, total = [], [], 0
    for i, (a, b) in enumerate(zip(target, reference)):
        if a + b == 0:
            continue
        pending.append(i)
        total += a + b
        if min(total * nt / (nt + nr), total * nr / (nt + nr)) >= min_expected:
            groups.append(pending)
            pending, total = [], 0
    if pending:
        if groups:
            groups[-1].extend(pending)
        else:
            groups.append(pending)
    base.update(groups=groups, tested_bins=len(groups))
    if len(groups) < 2:
        return dict(base, status="INSUFFICIENT_BINS",
                    notes="Fewer than two populated groups after pooling; no chi-square p-value.")
    chi2 = 0.0
    for group in groups:
        a, b = sum(target[i] for i in group), sum(reference[i] for i in group)
        ea, eb = (a + b) * nt / (nt + nr), (a + b) * nr / (nt + nr)
        chi2 += (a - ea) ** 2 / ea + (b - eb) ** 2 / eb
    return dict(base, status="TESTED", statistic=chi2, ndf=len(groups) - 1,
                p_value=probability(chi2, len(groups) - 1),
                notes="Shape only; different total sample sizes allowed. Adjacent pooling uses pooled bin totals.")


def efficiency_test(tp, td, rp, rd):
    """Fisher exact per x bin; Bonferroni min-p is a conservative curve test."""
    tp, td, rp, rd = map(checked_counts, (tp, td, rp, rd))
    if len({len(tp), len(td), len(rp), len(rd)}) != 1:
        raise ValueError("Different efficiency binning.")
    details, covered, uncovered, deltas = [], [], 0, []
    for i, (a, n, c, m) in enumerate(zip(tp, td, rp, rd)):
        if a > n or c > m:
            raise ValueError("Efficiency numerator exceeds denominator.")
        p = None
        if n and m:
            p = fisher(a, n - a, c, m - c)
            if not math.isfinite(p) or not 0 <= p <= 1:
                raise ValueError("Invalid Fisher exact p-value.")
            covered.append(p)
            deltas.append(abs(a / n - c / m))
        elif n or m:
            uncovered += 1
        details.append(dict(bin=i + 1, target_pass=a, target_total=n,
                            ref_pass=c, ref_total=m, p_value=p,
                            target_efficiency=a / n if n else None,
                            ref_efficiency=c / m if m else None))
    nt, nr, kt, kr = sum(td), sum(rd), sum(tp), sum(rp)
    base = dict(target_total=nt, ref_total=nr, target_pass=kt, ref_pass=kr,
                target_efficiency=kt / nt if nt else None,
                ref_efficiency=kr / nr if nr else None,
                count_ratio=nt / nr if nr else None,
                original_bins=len(td), tested_bins=len(covered),
                uncovered_bins=uncovered, p_value=None,
                max_abs_bin_difference=max(deltas) if deltas else None,
                min_bin_p=min(covered) if covered else None,
                details=details)
    if not covered:
        return dict(base, status="NO_COMMON_DENOMINATOR",
                    notes="No x bin has nonzero denominators in both samples.")
    return dict(base, status="TESTED", p_value=min(1.0, len(covered) * min(covered)),
                notes="Per-bin Fisher exact, curve p=min(1, K*min(p_bin)); conservative Bonferroni over covered bins. "
                      "Integrated efficiencies are descriptive only.")


def holm_adjust(rows):
    tested = sorted((r for r in rows if r.get("p_value") is not None),
                    key=lambda r: r["p_value"])
    maximum = 0.0
    for rank, row in enumerate(tested):
        maximum = max(maximum, min(1.0, (len(tested) - rank) * row["p_value"]))
        row["p_holm"] = maximum


def literal_dicts(path):
    tree = ast.parse(path.read_text(), filename=str(path))
    result = {}
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in {"vardict", "hvardict"}:
                    result[target.id] = ast.literal_eval(node.value)
    if set(result) != {"vardict", "hvardict"}:
        raise ValueError("variables.py must define literal vardict and hvardict dictionaries.")
    return result["vardict"], result["hvardict"]


def plot_settings(path, onebin=False):
    """Read only the cut/binning assignments in compare.py's main block."""
    module = ast.parse(path.read_text(), filename=str(path))
    mains = [n for n in module.body if isinstance(n, ast.If)
             and "__name__" in ast.unparse(n.test)]
    required = {"ptPlotsBinning", "etaPlotsBinning", "reco_cut", "gen_cut", "loose_id"}
    nodes = {}
    for main in mains:
        for node in ast.walk(main):
            if isinstance(node, ast.Assign):
                for name in node.targets:
                    if isinstance(name, ast.Name) and name.id in required:
                        nodes[name.id] = node.value
    if set(nodes) != required:
        raise ValueError("Cannot extract all plotting cuts/binning from compare.py; no defaults silently substituted.")
    result = {}
    allowed_names = {"array", "round", "range", "args"}
    for name, node in nodes.items():
        for child in ast.walk(node):
            if isinstance(child, ast.Name) and isinstance(child.ctx, ast.Load):
                # Comprehension variable i is also present in the existing binning.
                if child.id not in allowed_names | {"i"}:
                    raise ValueError("Unsupported name in plotting settings: " + child.id)
            if isinstance(child, ast.Attribute):
                if not (isinstance(child.value, ast.Name) and child.value.id == "args"
                        and child.attr == "onebin"):
                    raise ValueError("Unsupported attribute in plotting settings.")
        result[name] = eval(compile(ast.Expression(node), str(path), "eval"),
                            {"__builtins__": {}, "array": array, "round": round, "range": range,
                             "args": SimpleNamespace(onebin=onebin)})
    for name in ("ptPlotsBinning", "etaPlotsBinning"):
        edges = list(result[name])
        if len(edges) < 2 or not all(math.isfinite(x) for x in edges):
            raise ValueError("Invalid plot binning.")
        if any(b <= a for a, b in zip(edges, edges[1:])):
            raise ValueError("Non-increasing plot binning.")
        result[name] = edges
    return result


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def efficiency_planner(path, settings):
    """Capture actual plotting-function arguments, without projecting or drawing.

    This preserves local selection logic, including legacy denominator behavior.
    Only the three selected functions from the user's local compare.py are loaded.
    Synthetic leaves bypass its missing-leaf file-writing branch; real leaves are
    checked separately before projection. No compare.py main block is executed.
    """
    module = ast.parse(path.read_text(), filename=str(path))
    wanted = {"is_number", "word_finder", "make_efficiency_plots"}
    functions = [n for n in module.body if isinstance(n, ast.FunctionDef) and n.name in wanted]
    if {n.name for n in functions} != wanted:
        raise ValueError("Cannot locate efficiency plotting functions in compare.py.")
    namespace = dict(settings, re=re, warnings=warnings, overlay=lambda **kwargs: None,
                     options_dict={name: SimpleNamespace(xlabel="x", xlabel_eta="eta", tlabel="sample")
                                   for name in ("ZMM", "ZEE", "ZTT", "TTbar", "ZpTT", "TTbarTau", "TenTaus")})
    exec(compile(ast.Module(body=functions, type_ignores=[]), str(path), "exec"), namespace)

    def plan(name, definition, runtype):
        requests = []
        namespace["runtype"] = runtype
        namespace["makeEffPlotsVars"] = lambda **kwargs: requests.append(kwargs)
        sample = dict(tree=None, leaves=re.findall(r"\w+", definition["var"]),
                      index=0, marker=20, col=1, label="sample")
        try:
            namespace["make_efficiency_plots"]({"sample": sample}, name, definition)
        except Exception as exc:
            raise ValueError("Cannot capture local efficiency selections: " + str(exc)) from exc
        if len(requests) != 2:
            raise ValueError("Expected one pt and one eta efficiency request from compare.py.")
        return requests

    return plan, namespace["word_finder"]


def resolve_input(raw, campaign, subdir):
    path = Path(raw).expanduser()
    candidates = [path, campaign.parent / path, campaign / path,
                  campaign / subdir / path.name]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise FileNotFoundError("Cannot locate input: " + raw)


def load_jobs(args):
    campaign = args.campaign_dir.resolve()
    status = (args.status or campaign / "status.tsv").resolve()
    with status.open(encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    jobs = []
    for sample in args.samples:
        for pileup in args.pileups:
            matches = [r for r in rows if (r.get("runtype"), r.get("pileup")) == (sample, pileup)]
            if len(matches) != 1 or matches[0].get("status") not in SUCCESS:
                raise ValueError("Expected exactly one completed status row for %s/%s; found %s"
                                 % (sample, pileup, matches))
            row = matches[0]
            for role, release, gt in [
                ("target", args.target_release, args.target_gt),
                ("ref", args.ref_release, args.ref_gt),
            ]:
                ds = row.get(role + "_dataset", "")
                if not ds.endswith("/MINIAODSIM") or "/" + release + "-" not in ds or gt not in ds:
                    raise ValueError("Unexpected %s dataset in %s/%s: %s" % (role, sample, pileup, ds))
            target = resolve_input(row["target_root"], campaign, "root")
            reference = resolve_input(row["ref_root"], campaign, "root")
            if target == reference:
                raise ValueError("Target and reference resolve to the same ROOT file.")
            jobs.append(dict(runtype=sample, pileup=pileup, target=str(target), ref=str(reference),
                             target_dataset=row["target_dataset"], ref_dataset=row["ref_dataset"],
                             plots=row.get("plots", "")))
    return status, jobs


def leaf_names(tree):
    return {leaf.GetName() for leaf in tree.GetListOfLeaves()}


def project(tree, expression, selection, edges, leaves, label):
    needed = set(re.findall(r"\btau_[A-Za-z0-9_]+\b", expression + " " + selection))
    missing = sorted(needed - leaves)
    if missing:
        raise KeyError("Missing branches: " + ", ".join(missing))
    ROOT.gROOT.cd()
    name = "tau_stat_" + uuid.uuid4().hex
    hist = ROOT.TH1D(name, label, len(edges) - 1, array("d", edges))
    hist.SetDirectory(ROOT.gROOT)
    hist.Sumw2()
    try:
        count = int(tree.Project(name, expression, selection))
        if count < 0:
            raise ValueError("TTree.Project failed: %s with selection %s" % (expression, selection))
    finally:
        hist.SetDirectory(0)
    for i in range(hist.GetNbinsX() + 2):
        content = float(hist.GetBinContent(i))
        error2 = float(hist.GetBinError(i)) ** 2
        if not math.isclose(content, error2, rel_tol=1e-7, abs_tol=1e-7):
            raise ValueError("Weighted/non-count selection; Poisson/binomial tests disabled.")
    return hist


def hist_counts(hist, flows):
    indices = range(0, hist.GetNbinsX() + 2) if flows else range(1, hist.GetNbinsX() + 1)
    return checked_counts([float(hist.GetBinContent(i)) for i in indices])


def write_hist(directory, hist, name):
    directory.WriteObject(hist, name)


def plot_link(args, job, name, kind, axis):
    folder = args.campaign_dir / "plots" / Path(job["plots"]).name
    if not folder.is_dir():
        return ""
    if kind == "shape":
        candidates = [folder / "histograms" / ("hist_" + name + ".png")]
    else:
        suffix = "_eta" if axis == "eta" else ""
        candidates = [folder / ("all_eta" if axis == "eta" else "all_pt") / (name + suffix + ".png"),
                      folder / ("all_eta" if axis == "eta" else "all") / (name + suffix + ".png"),
                      folder / (name + suffix) / (name + suffix + ".png")]
    for path in candidates:
        if path.is_file():
            if args.plot_url_base:
                return (args.plot_url_base.rstrip("/") + "/" + quote(job["pileup"]) +
                        "/plots/" + quote(folder.name) + "/" +
                        quote(path.relative_to(folder).as_posix(), safe="/"))
            return quote(os.path.relpath(path.resolve(), args.outdir.resolve()), safe="/")
    return ""


def base_row(job, name, kind, axis, definition, args):
    return dict(runtype=job["runtype"], pileup=job["pileup"], kind=kind,
                variable=name, axis=axis, title=definition.get("title", name),
                expression=definition["var"], status="PENDING",
                p_value=None, p_holm=None, plot=plot_link(args, job, name, kind, axis))


def save_tsv(path, rows, fields):
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields, delimiter="\t", extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({k: json.dumps(v) if isinstance(v, (list, dict)) else v
                             for k, v in row.items()})


def fmt(value):
    if value is None or value == "":
        return "—"
    if isinstance(value, float):
        if value == 0:
            return "0"
        return "%.4g" % value
    return str(value)


def html_report(args, rows, manifest):
    escape = lambda v: html.escape(fmt(v), quote=True)
    counts = Counter(r["status"] for r in rows)
    cards = "".join('<span class="card %s">%s: <b>%d</b></span>' %
                    (html.escape(status), html.escape(status), count)
                    for status, count in sorted(counts.items()))
    data = []
    for row in sorted(rows, key=lambda r: (r.get("p_value") is None,
                                          r.get("p_value", 1.0) or 0.0,
                                          r["runtype"], r["pileup"], r["variable"])):
        name = escape(row["variable"])
        if row.get("plot"):
            name = '<a href="%s" target="_blank">%s</a>' % (html.escape(row["plot"], quote=True), name)
        detail = "details/%s.html" % row["id"]
        data.append(
            '<tr data-status="%s"><td>%s</td><td>%s</td><td>%s</td><td>%s</td>'
            '<td><a href="%s">details</a></td><td>%s</td><td>%s</td>'
            '<td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>' %
            (escape(row["status"]), escape(row["runtype"]), escape(row["pileup"]),
             escape(row["kind"] + " " + row["axis"]), name, detail, escape(row["status"]),
             escape(row.get("p_value")), escape(row.get("p_holm")),
             escape(row.get("max_abs_bin_difference")), escape(row.get("target_total")),
             escape(row.get("ref_total")), escape(row.get("notes"))))
    dataset_rows = "".join("<tr><td>%s/%s</td><td>%s</td><td>%s</td></tr>" %
                           (escape(j["runtype"]), escape(j["pileup"]),
                            escape(j["target_dataset"]), escape(j["ref_dataset"]))
                           for j in manifest["jobs"])
    page = """<!doctype html><html><head><meta charset="utf-8"><title>Tau statistical screening</title>
<style>
body{font:15px system-ui,sans-serif;margin:26px;background:#f7f8fa;color:#17212b}
h1{margin-bottom:6px}a{color:#1655a8}p{max-width:1100px;line-height:1.5}
table{border-collapse:collapse;width:100%;background:white;margin:18px 0}
th,td{border:1px solid #dce1e6;padding:7px;text-align:left;vertical-align:top}
th{background:#e7edf5;position:sticky;top:0;cursor:pointer}
td:last-child{max-width:440px;min-width:190px}input,select{padding:9px;margin-right:12px}
.card{display:inline-block;padding:10px 16px;margin:5px;border-radius:6px;background:#e4eaf2}
.FLAG,.ONE_EMPTY,.ERROR{background:#ffdddf}.PASS{background:#dcf1e1}
.MISSING_BRANCH,.INSUFFICIENT_BINS,.NO_COMMON_DENOMINATOR,.INCOMPLETE_COVERAGE{background:#fff0cd}
.note{border-left:5px solid #c98719;padding:10px 16px;background:#fff5df}
.small{font-size:13px;color:#485667}.datasets{font-size:12px;overflow-wrap:anywhere}
</style></head><body><h1>Tau statistical screening</h1>
<p>__TITLE__</p><p class="note">__DISCLAIMER__</p>
<p>Shape: two-sample Pearson chi-square on raw counts, with adjacent bins pooled until
both expected counts reach __MIN_EXPECTED__. Overall normalization is free.
Efficiency: two-sided Fisher exact pass/fail tests per covered x bin;
curve p = min(1, number of covered bins × smallest bin p).
No chi-square test is applied to efficiency values or normalized PNG pixels.</p>
<p>FLAG means nominal p &lt; __ALPHA__. PASS means no flag at that threshold, not equivalence.
p(Holm) corrects across all tested shapes/curves in this run. Efficiencies already include
their within-curve Bonferroni correction. Missing/empty/unsupported cases are not marked PASS.
Max |Δbin| is a probability difference (shape) or efficiency difference; 0.01 means 1 percentage point.</p>
<p class="small">Underflow/overflow in shape tests: __FLOWS__.
Efficiency tests use regular plotted bins only. Bins with no denominator in one sample
are reported as uncovered. p=0 can indicate numerical underflow.</p>
<div>__CARDS__</div><p><a href="results.tsv">Results TSV</a> ·
<a href="bins.tsv">Per-bin counts TSV</a> · <a href="results.json">Full results JSON</a> ·
<a href="manifest.json">Inputs and configuration</a></p>
<p><input id="search" placeholder="Filter sample, variable or note" oninput="filterRows()">
<select id="status" onchange="filterRows()"><option value="">All statuses</option>__OPTIONS__</select>
Click a column heading to sort. Variable links open existing plots where found.</p>
<table id="results"><thead><tr>__HEADERS__</tr></thead><tbody>__ROWS__</tbody></table>
<details><summary>Datasets and interpretation</summary><table class="datasets"><tr><th>Sample</th>
<th>Target</th><th>Reference</th></tr>__DATASETS__</table>
<p>These are reference-object counts, not numbers of processed collision events.
No absolute event-rate test or per-event bootstrap is performed.
Recycled/shared GEN-SIM samples may be correlated between releases.
A pooled shape test can lose sensitivity to narrow features; per-bin original counts remain available.</p>
</details><script>
function filterRows(){
const q=document.getElementById('search').value.toLowerCase(),s=document.getElementById('status').value;
for(const r of document.querySelectorAll('#results tbody tr'))
r.hidden=!(r.textContent.toLowerCase().includes(q)&&(!s||r.dataset.status===s));
}
let direction=1;
document.querySelectorAll('#results th').forEach((h,i)=>h.onclick=()=>{
const body=document.querySelector('#results tbody'),rows=[...body.rows];direction*=-1;
rows.sort((a,b)=>{let x=a.cells[i].textContent.trim(),y=b.cells[i].textContent.trim();
let nx=Number(x),ny=Number(y);return direction*((x!==''&&y!==''&&Number.isFinite(nx)&&Number.isFinite(ny))?nx-ny:x.localeCompare(y));});
rows.forEach(r=>body.appendChild(r));});
</script></body></html>"""
    replacements = {
        "__TITLE__": escape(args.target_release + " versus " + args.ref_release),
        "__DISCLAIMER__": html.escape(DISCLAIMER),
        "__MIN_EXPECTED__": escape(args.min_expected),
        "__ALPHA__": escape(args.alpha),
        "__FLOWS__": "included" if args.flows else "excluded",
        "__CARDS__": cards, "__ROWS__": "\n".join(data), "__DATASETS__": dataset_rows,
        "__OPTIONS__": "".join('<option>%s</option>' % html.escape(s) for s in sorted(counts)),
        "__HEADERS__": "".join("<th>%s</th>" % h for h in [
            "Sample", "PU", "Test kind", "Variable", "Details", "Status",
            "Nominal p", "p(Holm)", "Max |Δbin|", "Target count", "Ref count", "Notes"]),
    }
    for key, value in replacements.items():
        page = page.replace(key, value)
    (args.outdir / "index.html").write_text(page, encoding="utf-8")


def detail_report(outdir, row, bins):
    # Everything used in a test remains visible, including skipped/empty bins.
    esc = lambda value: html.escape(fmt(value))
    keys = sorted(set().union(*(b.keys() for b in bins))) if bins else []
    table = "<table><tr>" + "".join("<th>%s</th>" % esc(k) for k in keys) + "</tr>"
    for b in bins:
        table += "<tr>" + "".join("<td>%s</td>" % esc(b.get(k)) for k in keys) + "</tr>"
    table += "</table>"
    metadata = {k: v for k, v in row.items() if k != "details"}
    content = ('<!doctype html><meta charset="utf-8"><title>Tau test detail</title>'
               '<style>body{font:14px system-ui;margin:25px}table{border-collapse:collapse}'
               'td,th{padding:6px;border:1px solid #ccd}pre{white-space:pre-wrap}</style>'
               '<p><a href="../index.html">Back to summary</a></p><h1>%s / %s / %s</h1>'
               '<p>%s</p><pre>%s</pre>%s' %
               (esc(row["runtype"]), esc(row["pileup"]), esc(row["variable"]),
                html.escape(DISCLAIMER), html.escape(json.dumps(metadata, indent=2, allow_nan=False)), table))
    (outdir / "details" / (row["id"] + ".html")).write_text(content, encoding="utf-8")


def select_definitions(args, vardict, hvardict):
    selected = lambda name: any(fnmatch.fnmatchcase(name, pattern) for pattern in args.include)
    shapes = [(n, d) for n, d in hvardict.items() if selected(n)] if args.kind != "efficiencies" else []
    efficiencies = [(n, d) for n, d in vardict.items() if selected(n)] if args.kind != "shapes" else []
    if not shapes and not efficiencies:
        raise ValueError("No variable definitions match the requested filters.")
    return shapes, efficiencies


def process_job(args, job, shapes, efficiencies, settings, bin_rows):
    print("\n[%s/%s] Opening saved trees" % (job["runtype"], job["pileup"]), flush=True)
    files = [ROOT.TFile.Open(job[side], "READ") for side in ("target", "ref")]
    results = []
    try:
        if any(not f or f.IsZombie() for f in files):
            raise RuntimeError("Cannot open one of the input ROOT files.")
        trees = [f.Get("per_tau") for f in files]
        if any(not t or not t.InheritsFrom("TTree") for t in trees):
            raise RuntimeError("Missing per_tau TTree.")
        job["target_tree_entries"], job["ref_tree_entries"] = [int(t.GetEntries()) for t in trees]
        leaves = [leaf_names(t) for t in trees]
        planner, original_word_finder = efficiency_planner(args.compare_file, settings)
        plans = {}
        counts_path = args.outdir / ("counts_%s_%s.root" % (job["runtype"], job["pileup"]))
        if counts_path.resolve() in {Path(job["target"]), Path(job["ref"])}:
            raise ValueError("Output evidence file would overwrite an input ROOT file.")
        output = ROOT.TFile.Open(str(counts_path), "RECREATE")
        if not output or output.IsZombie():
            raise RuntimeError("Cannot create histogram evidence file.")
        try:
            todo = [(name, definition, "shape", "x") for name, definition in shapes]
            todo += [(name, definition, "efficiency", axis) for name, definition in efficiencies
                     for axis in ("pt", "eta")]
            for index, (name, definition, kind, axis) in enumerate(todo):
                if index % 25 == 0:
                    print("  %d/%d tests" % (index + 1, len(todo)), flush=True)
                row = base_row(job, name, kind, axis, definition, args)
                row["id"] = hashlib.sha256(("%s/%s/%s/%s/%s" %
                                            (job["runtype"], job["pileup"], kind, axis, name)).encode()).hexdigest()[:16]
                row["counts_file"] = counts_path.name
                if kind == "shape" and "pt_resolution" in name and job["runtype"] not in {"ZpTT", "ZTT", "TTbarTau", "TenTaus"}:
                    row.update(status="NOT_APPLICABLE", notes="Excluded by compare.py for this sample.")
                    results.append(row)
                    continue
                details = []
                try:
                    if kind == "shape":
                        n = int(definition["nbin"])
                        lo, hi = float(definition["min"]), float(definition["max"])
                        if n <= 0 or hi <= lo:
                            raise ValueError("Invalid histogram bounds.")
                        edges = [lo + (hi - lo) * i / n for i in range(n + 1)]
                        selection = str(definition.get("sel", "1"))
                        row["selection"] = selection
                        histograms = [project(t, definition["var"], selection, edges, l, role)
                                      for t, l, role in zip(trees, leaves, ("target", "reference"))]
                        a, b = [hist_counts(h, args.flows) for h in histograms]
                        row.update(shape_test(a, b, args.min_expected))
                        root_bins = list(range(n + 2)) if args.flows else list(range(1, n + 1))
                        for j, (ibin, av, bv) in enumerate(zip(root_bins, a, b)):
                            details.append(dict(bin=ibin, target_count=av, ref_count=bv,
                                                low=edges[ibin - 1] if ibin > 0 else "-inf",
                                                high=edges[ibin] if ibin <= n else "+inf",
                                                flow="underflow" if ibin == 0 else "overflow" if ibin == n + 1 else "regular",
                                                target_fraction=av / sum(a) if sum(a) else None,
                                                ref_fraction=bv / sum(b) if sum(b) else None))
                        row["target_underflow"], row["ref_underflow"] = [h.GetBinContent(0) for h in histograms]
                        row["target_overflow"], row["ref_overflow"] = [h.GetBinContent(n + 1) for h in histograms]
                        root_objects = list(zip(("target", "reference"), histograms))
                        row["test"] = "Pearson shape chi-square (pooled raw counts)"
                    else:
                        for leaf_set in leaves:
                            missing = set(original_word_finder(definition["var"])) - leaf_set
                            if missing:
                                raise KeyError("Missing branches: " + ", ".join(sorted(missing)))
                        if name not in plans:
                            plans[name] = planner(name, definition, job["runtype"])
                        request = plans[name][0 if axis == "pt" else 1]
                        varx, edges = request["varx"], list(request["binning"])
                        base = str(request["baseSelection"])
                        numerator = "(%s) && (%s)" % (base, request["numeratorAddSelection"])
                        row.update(selection=base, numerator_selection=numerator, x_expression=varx)
                        totals, passed = [], []
                        for t, l, role in zip(trees, leaves, ("target", "reference")):
                            totals.append(project(t, varx, base, edges, l, role + "_total"))
                            passed.append(project(t, varx, numerator, edges, l, role + "_pass"))
                        result = efficiency_test(hist_counts(passed[0], False), hist_counts(totals[0], False),
                                                 hist_counts(passed[1], False), hist_counts(totals[1], False))
                        details = result.pop("details")
                        row.update(result, test="Fisher exact per bin + Bonferroni curve test")
                        for i, detail in enumerate(details):
                            detail.update(low=edges[i], high=edges[i + 1])
                        root_objects = [("target_pass", passed[0]), ("target_total", totals[0]),
                                        ("reference_pass", passed[1]), ("reference_total", totals[1])]
                    row["bin_edges"] = edges
                    directory = output.mkdir(row["id"])
                    for label, histogram in root_objects:
                        write_hist(directory, histogram, label)
                except KeyError as exc:
                    row.update(status="MISSING_BRANCH", notes=str(exc))
                except (ValueError, RuntimeError) as exc:
                    row.update(status="ERROR", notes=str(exc))
                row["details"] = details
                for detail in details:
                    bin_rows.append(dict(runtype=job["runtype"], pileup=job["pileup"],
                                         kind=kind, axis=axis, variable=name, **detail))
                results.append(row)
        finally:
            output.Close()
    finally:
        for f in files:
            if f:
                f.Close()
    return results


def self_test():
    """Check statistical kernels and the PyROOT projection API without input files."""
    root_setup()
    r = shape_test([200, 0], [0, 200])
    assert r["statistic"] == 400 and r["ndf"] == 1
    assert math.isclose(r["p_value"], 5.507248237212379e-89, rel_tol=1e-6)
    assert math.isclose(fisher_python(6, 2, 1, 4), 0.10256410256410257, rel_tol=1e-10)
    assert shape_test([0, 0], [0, 0])["status"] == "BOTH_EMPTY"
    assert shape_test([1, 0], [0, 1])["status"] == "INSUFFICIENT_BINS"
    assert efficiency_test([10], [10], [10], [10])["p_value"] == 1
    rows = [{"p_value": 0.001}, {"p_value": 0.02}, {"p_value": 0.5}]
    holm_adjust(rows)
    assert [r["p_holm"] for r in rows] == [0.003, 0.04, 0.5]
    tree = ROOT.TTree("tau_statistics_selftest", "in-memory test")
    tree.SetDirectory(0)
    value = array("d", [0.0])
    tree.Branch("tau_probe", value, "tau_probe/D")
    for x in [0.2, 0.2, 0.8, 0.8]:
        value[0] = x
        tree.Fill()
    hist = project(tree, "tau_probe", "1", [0, 0.5, 1], {"tau_probe"}, "test")
    assert hist_counts(hist, False) == [2, 2]
    try:
        project(tree, "tau_probe", "0.5", [0, 0.5, 1], {"tau_probe"}, "weighted test")
    except ValueError:
        pass
    else:
        raise AssertionError("Weighted selection was accepted by the count tests.")
    print("Self-test passed: chi-square, Fisher exact, empty/sparse bins, Holm, "
          "TTree projection and weighted-selection rejection. ROOT " + ROOT.gROOT.GetVersion())
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--campaign-dir", type=Path, default=Path("tau_relval_auto_outputs_MC_17_0_0_vs_pre7_Run3_2026"))
    parser.add_argument("--status", type=Path, help="Optional status.tsv location")
    parser.add_argument("--outdir", type=Path, help="Default: CAMPAIGN_DIR/statistics")
    parser.add_argument("--variables-file", type=Path, default=Path("variables.py"))
    parser.add_argument("--compare-file", type=Path, default=Path("compare.py"))
    parser.add_argument("--samples", nargs="+", default=["ZMM", "ZEE", "ZTT", "TTbar"])
    parser.add_argument("--pileups", nargs="+", choices=["noPU", "PU"], default=["noPU", "PU"])
    parser.add_argument("--target-release", default="CMSSW_17_0_0")
    parser.add_argument("--ref-release", default="CMSSW_17_0_0_pre7")
    parser.add_argument("--target-gt", default="170X_mcRun3_2026_realistic_v1")
    parser.add_argument("--ref-gt", default="160X_mcRun3_2026_realistic_v6")
    parser.add_argument("--kind", choices=["all", "shapes", "efficiencies"], default="all")
    parser.add_argument("--include", nargs="+", default=["*"], help="Variable-key glob patterns; quote wildcards")
    parser.add_argument("--alpha", type=float, default=1e-5, help="Nominal screening threshold, not a campaign decision")
    parser.add_argument("--min-expected", type=float, default=5.0, help="Minimum expected count in pooled shape bins")
    parser.add_argument("--flows", action=argparse.BooleanOptionalAction, default=True,
                        help="Include under/overflow in shape tests, matching normalization in compare.py")
    parser.add_argument("--onebin", action="store_true", help="Match compare.py --onebin efficiency binning")
    parser.add_argument("--plot-url-base", help="Optional website campaign URL; link to its PU/plots and noPU/plots layout")
    parser.add_argument("--fail-on-flag", action="store_true", help="Exit 2 for statistical flags; otherwise flags do not fail execution")
    parser.add_argument("--dry-run", action="store_true", help="Validate config/input paths and list jobs; no ROOT processing")
    parser.add_argument("--self-test", action="store_true", help="Test kernels and PyROOT in memory; no campaign files needed")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if not 0 < args.alpha < 1 or not math.isfinite(args.alpha):
        parser.error("--alpha must be finite and between 0 and 1.")
    if not math.isfinite(args.min_expected) or args.min_expected < 5:
        parser.error("--min-expected must be finite and at least 5.")
    if len(set(args.samples)) != len(args.samples) or len(set(args.pileups)) != len(args.pileups):
        parser.error("Duplicate samples/pileups.")
    if args.plot_url_base and not args.plot_url_base.startswith(("https://", "http://")):
        parser.error("--plot-url-base must start with https:// or http://.")
    args.campaign_dir = args.campaign_dir.resolve()
    args.outdir = (args.outdir or args.campaign_dir / "statistics").resolve()
    vardict, hvardict = literal_dicts(args.variables_file)
    settings = plot_settings(args.compare_file, args.onebin)
    shapes, efficiencies = select_definitions(args, vardict, hvardict)
    status, jobs = load_jobs(args)
    if args.dry_run:
        for job in jobs:
            print("%s/%s\n  TARGET %s\n  REF    %s" %
                  (job["runtype"], job["pileup"], job["target"], job["ref"]))
        print("Definitions: %d shapes and %d efficiency selections, each versus pt and eta." %
              (len(shapes), len(efficiencies)))
        print("Cuts/binning:", settings)
        print("Output:", args.outdir)
        return 0
    root_setup()
    fisher_backend = enable_scipy()
    args.outdir.mkdir(parents=True, exist_ok=True)
    (args.outdir / "details").mkdir(exist_ok=True)
    bin_rows, rows = [], []
    manifest = dict(tool_version=VERSION, tool_sha256=digest(Path(__file__)),
                    root_version=ROOT.gROOT.GetVersion(), python_version=sys.version,
                    created_utc=datetime.now(timezone.utc).isoformat(),
                    target_release=args.target_release, ref_release=args.ref_release,
                    target_gt=args.target_gt, ref_gt=args.ref_gt,
                    input_status=str(status), input_status_sha256=digest(status),
                    variables_file=str(args.variables_file.resolve()),
                    variables_sha256=digest(args.variables_file),
                    compare_file=str(args.compare_file.resolve()),
                    compare_sha256=digest(args.compare_file),
                    settings=settings, alpha=args.alpha, min_expected=args.min_expected,
                    include_flows=args.flows, onebin=args.onebin, fisher_backend=fisher_backend,
                    assumptions=DISCLAIMER, jobs=jobs, command=sys.argv)
    for job in jobs:
        rows.extend(process_job(args, job, shapes, efficiencies, settings, bin_rows))
    holm_adjust(rows)
    for row in rows:
        p, adjusted = row.get("p_value"), row.get("p_holm")
        row["flag_raw"] = p is not None and p < args.alpha
        row["flag_holm"] = adjusted is not None and adjusted < args.alpha
        if row["status"] == "TESTED":
            row["status"] = "FLAG" if row["flag_raw"] else "PASS"
            if row.get("uncovered_bins"):
                row["notes"] += " Some bins lack a denominator on one side; comparison coverage is incomplete."
                if row["status"] == "PASS":
                    row["status"] = "INCOMPLETE_COVERAGE"
        detail_report(args.outdir, row, row.get("details", []))
    save_tsv(args.outdir / "results.tsv", rows, FIELDS)
    bin_fields = ["runtype", "pileup", "kind", "axis", "variable", "bin", "low", "high",
                  "flow", "target_count", "ref_count", "target_fraction", "ref_fraction",
                  "target_pass", "target_total", "ref_pass", "ref_total",
                  "target_efficiency", "ref_efficiency", "p_value"]
    save_tsv(args.outdir / "bins.tsv", bin_rows, bin_fields)
    (args.outdir / "manifest.json").write_text(json.dumps(manifest, indent=2, allow_nan=False) + "\n")
    (args.outdir / "results.json").write_text(json.dumps(rows, indent=2, allow_nan=False) + "\n")
    html_report(args, rows, manifest)
    counts = dict(Counter(row["status"] for row in rows))
    print("\nScreening results:", counts)
    print("Report:", args.outdir / "index.html")
    print("These are screening diagnostics; no campaign validation status is assigned.")
    if any(row["status"] == "ERROR" for row in rows):
        return 1
    if not any(row.get("p_value") is not None for row in rows):
        print("ERROR: no statistical test could be computed; inspect missing/empty cases.", file=sys.stderr)
        return 1
    return 2 if args.fail_on_flag and any(row["flag_raw"] for row in rows) else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print("ERROR:", exc, file=sys.stderr)
        raise SystemExit(1)

