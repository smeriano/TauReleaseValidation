#!/usr/bin/env bash
# Run after validation finishes. Preview: bash upload_tau_hin_data_all.sh --dry-run
# Overrides: BASE=checkout_dir SRC=output_dir WWW=website_root CAMPAIGN=folder_name
# Only PNG/PDF/TXT plots and status are published; ROOT files stay local.
set -euo pipefail
python3 - "$@" <<'PYTHON'
DEFAULT_BASE = '/eos/user/s/smeriano/UCLouvain/TAU_RELVAL/CMSSW_17_0_0/src/TauReleaseValidation_HINData'
OUTPUT = 'tau_hin_relval_outputs'
STATUS = 'status_HINData.tsv'
DEFAULT_CAMPAIGN = '17_0_0_HINData_vs_17_0_0_pre7_HINData'
TARGET_RELEASE = 'CMSSW_17_0_0'
REF_RELEASE = 'CMSSW_17_0_0_pre7'
TIER = 'MINIAOD'

# (sample, target_gt, ref_gt)
EXPECTED = [
    ('HIForward0_upc2024_dataRun3_Prompt',  '170X_dataRun3_Prompt_v2', '161X_dataRun3_Prompt_frozen_v1'),
    ('HIForward0_upc2025_dataRun3_Prompt',  '170X_dataRun3_Prompt_v2', '161X_dataRun3_Prompt_frozen_v1'),
    ('HIForward1_upc2023_dataRun3',         '170X_dataRun3_v2',        '150X_dataRun3_v8'),
    ('HIForward1_upc2023_dataRun3_Prompt',  '170X_dataRun3_Prompt_v2', '161X_dataRun3_Prompt_frozen_v1'),
    ('IonPhysics0_oxy2025_dataRun3_Prompt', '170X_dataRun3_Prompt_v2', '161X_dataRun3_Prompt_frozen_v1'),
    ('PAForward_upcPA2016_dataRun2',        '170X_dataRun2_v2',        '150X_dataRun2_v1'),
]

import argparse, csv, fcntl, html, os, re, shutil, subprocess, time
from pathlib import Path
from urllib.parse import quote
from html.parser import HTMLParser

parser = argparse.ArgumentParser(description="Publish completed HIN DataTau validation plots")
parser.add_argument('--dry-run', action='store_true')
args = parser.parse_args()

WWW = Path(os.environ.get('WWW', '/eos/user/s/smeriano/www'))
TAU_ROOT = WWW / 'TauValidationEffort'
BASE = Path(os.environ.get('BASE', DEFAULT_BASE))
SRC = Path(os.environ.get('SRC', str(BASE / OUTPUT)))
CAMPAIGN = os.environ.get('CAMPAIGN', DEFAULT_CAMPAIGN)
DEST = TAU_ROOT / CAMPAIGN

status = SRC / STATUS
if not status.is_file():
    raise SystemExit(f'Missing status file: {status}. Set BASE or SRC to the actual output location.')

with status.open() as f:
    rows = list(csv.DictReader(f, delimiter='\t'))

jobs = []
for sample, target_gt, ref_gt in EXPECTED:
    matches = [r for r in rows if (r.get('sample') or r.get('era')) == sample]
    if len(matches) != 1 or matches[0].get('status') not in ('OK', 'OK_WITH_MISSING_OPTIONAL_BRANCHES'):
        raise SystemExit(f'Expected one completed row for {sample} in {status}; found {matches}')
    row = matches[0]
    datasets = [v for v in row.values() if isinstance(v, str) and v.startswith('/') and v.endswith('/' + TIER)]
    for release, gt in ((TARGET_RELEASE, target_gt), (REF_RELEASE, ref_gt)):
        if not any('/' + release + '-' in d and gt in d for d in datasets):
            raise SystemExit(f'Unexpected or missing {release} ({gt}) dataset in row {sample}: {row}')
    name = f'compare_DataTau_{sample}_officialMCstyle'
    source = SRC / 'plots' / name
    target = DEST / sample / name
    pngs = list(source.rglob('*.png'))
    if not pngs or any(p.stat().st_size == 0 for p in pngs):
        raise SystemExit(f'Missing or empty PNGs: {source}')
    lumi = row.get('lumi_match', 'N/A')
    print(f'{sample}: {row["status"]} (lumi={lumi}); {len(pngs)} PNGs; {source} -> {target}')
    jobs.append((source, target))

if args.dry_run:
    print(f'Dry-run complete ({len(jobs)} samples). Sources validated; website unchanged.')
    raise SystemExit(0)

if not shutil.which('rsync'):
    raise SystemExit('Missing command: rsync')

STYLE = r"""
body {
    font-family: "Corbel", "Segoe UI", sans-serif;
    font-size: 10pt;
    line-height: 1.4;
    margin: 24px;
    background: #f7f7f8;
    color: #222;
}

h1 {
    font-size: 22pt;
    margin-bottom: 0.2em;
}

h2 {
    font-size: 15pt;
    margin-top: 1.2em;
}

a {
    text-decoration: none;
    color: rgb(0,0,90);
}

a:hover {
    text-decoration: underline;
    color: rgb(220,60,60);
}

div.grid {
    display: flex;
    flex-wrap: wrap;
    gap: 14px;
    align-items: flex-start;
}

div.pic {
    display: block;
    background-color: white;
    border: 1px solid #ccc;
    border-radius: 8px;
    padding: 8px;
    text-align: center;
    width: 360px;
    box-shadow: 0 2px 6px rgba(0,0,0,0.08);
}

div.pic h3 {
    font-size: 10.5pt;
    margin: 0.3em 0 0.5em 0;
    word-break: break-word;
}

div.pic p {
    font-size: 9pt;
    margin: 0.3em 0;
    word-break: break-word;
}

div.pic img {
    max-width: 340px;
    max-height: 300px;
    border: 0;
}

div.folder-card {
    display: block;
    background-color: white;
    border: 1px solid #ccc;
    border-radius: 8px;
    padding: 12px;
    width: 260px;
    box-shadow: 0 2px 6px rgba(0,0,0,0.08);
}

div.folder-card h3 {
    font-size: 11pt;
    margin: 0;
    word-break: break-word;
}

.filter-box {
    margin: 1em 0 1.5em 0;
}

.filter-box input {
    font-size: 11pt;
    padding: 6px 10px;
    width: 420px;
    max-width: 90%;
    border: 1px solid #bbb;
    border-radius: 5px;
}

.topnav {
    margin: 0.8em 0 1.4em 0;
}

.small {
    color: #666;
    font-size: 9pt;
}
"""

SCRIPT = r"""
function filterItems() {
    var input = document.getElementById("filterInput");
    if (!input) return;

    var filter = input.value.toLowerCase();
    var items = document.getElementsByClassName("filter-item");

    for (var i = 0; i < items.length; i++) {
        var text = items[i].getAttribute("data-name").toLowerCase();
        if (text.indexOf(filter) > -1) {
            items[i].style.display = "";
        } else {
            items[i].style.display = "none";
        }
    }
}
"""

def rel_title(path: Path) -> str:
    return "TauValidationEffort" if path == TAU_ROOT else str(path.relative_to(TAU_ROOT))

def write_index(path: Path):
    subdirs = sorted(
        [p for p in path.iterdir() if p.is_dir() and not p.name.startswith(".")],
        key=lambda p: p.name.lower(),
    )

    pngs = sorted(
        [p for p in path.iterdir() if p.is_file() and p.suffix.lower() == ".png"],
        key=lambda p: p.name.lower(),
    )

    title = rel_title(path)

    if path == TAU_ROOT:
        back = "../"
    elif path == WWW:
        back = None
    else:
        back = "../"

    lines = []
    lines.append("<html>")
    lines.append("<head>")
    lines.append('<meta charset="UTF-8">')
    lines.append(f"<title>{html.escape(title)}</title>")
    lines.append("<style type='text/css'>")
    lines.append(STYLE)
    lines.append("</style>")
    lines.append('<script type="text/javascript">')
    lines.append(SCRIPT)
    lines.append("</script>")
    lines.append("</head>")
    lines.append("")
    lines.append("<body>")
    lines.append(f"<h1>{html.escape(title)}</h1>")

    if back:
        lines.append("")
        lines.append('<div class="topnav">')
        lines.append(f'<a href="{back}">[back]</a>')
        lines.append("</div>")

    if subdirs or pngs:
        lines.append("")
        lines.append('<div class="filter-box">')
        lines.append(
            '<input type="text" id="filterInput" '
            'onkeyup="filterItems()" '
            'placeholder="Filter folders / plots...">'
        )
        lines.append("</div>")

    if subdirs:
        lines.append("<h2>Subdirs</h2>")
        lines.append('<div class="grid">')

        for d in subdirs:
            name = d.name
            esc = html.escape(name)

            lines.append(
                f'<div class="folder-card filter-item" data-name="{esc}">'
            )
            lines.append(f'<h3><a href="{quote(name)}/">[{esc}]</a></h3>')
            lines.append("</div>")

        lines.append("</div>")

    if pngs:
        lines.append("<h2>Plots</h2>")
        lines.append('<div class="grid">')

        for png in pngs:
            name = png.name
            esc = html.escape(name)
            pdf = png.with_suffix(".pdf")

            lines.append(f'<div class="pic filter-item" data-name="{esc}">')
            lines.append(f"<h3>{esc}</h3>")
            lines.append(
                f'<a href="{quote(name)}">'
                f'<img src="{quote(name)}" alt="{esc}" loading="lazy">'
                f"</a>"
            )

            if pdf.exists():
                pdf_name = quote(pdf.name)
                lines.append(
                    f'<p class="small">'
                    f'<a href="{pdf_name}">PDF version</a>'
                    f"</p>"
                )

            lines.append("</div>")

        lines.append("</div>")

    if not subdirs and not pngs:
        lines.append(
            '<p class="small">'
            "No subdirectories or PNG plots found here."
            "</p>"
        )

    lines.append("")
    lines.append("</body>")
    lines.append("</html>")
    lines.append("")

    (path / "index.html").write_text(
        "\n".join(lines),
        encoding="utf-8",
    )

def add_card(index, href, label):
    # Preserve existing page content; insert into its first folder grid.
    class GridEnd(HTMLParser):
        def __init__(self, text):
            super().__init__(); self.text = text; self.depth = 0; self.end = None
        def position_in_text(self):
            line, col = self.getpos()
            return sum(len(s) for s in self.text.splitlines(keepends=True)[:line - 1]) + col
        def handle_starttag(self, tag, attrs):
            if tag != 'div': return
            if self.depth: self.depth += 1
            elif self.end is None and 'grid' in dict(attrs).get('class', '').split(): self.depth = 1
        def handle_endtag(self, tag):
            if tag == 'div' and self.depth:
                self.depth -= 1
                if not self.depth: self.end = self.position_in_text()

    card = f'<div class="folder-card filter-item" data-name="{html.escape(label)}"><h3><a href="{href}">[{html.escape(label)}]</a></h3></div>'
    if index.exists():
        text = index.read_text()
        if re.search(r'href=[\"\']' + re.escape(href) + r'[\"\']', text): return
        backup = index.with_name('.' + index.name + f'.bak.{time.time_ns()}')
        backup.write_text(text); backup.chmod(0o600)
        parser = GridEnd(text); parser.feed(text)
        pos = parser.end
        if pos is None:
            pos = text.lower().rfind('</body>')
            if pos < 0: pos = len(text)
            card = '<style>' + STYLE + '</style><div class="grid">' + card + '</div>'
        text = text[:pos] + card + '\n' + text[pos:]
    else:
        text = '<!doctype html><html><head><meta charset="UTF-8"><style>' + STYLE + '</style></head><body><h1>Tau validation</h1><div class="grid">' + card + '</div></body></html>'
    tmp = index.with_name('.' + index.name + f'.tmp.{os.getpid()}')
    tmp.write_text(text); tmp.chmod(0o644); tmp.replace(index)

for source, target in jobs:
    target.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            'rsync', '-rlt', '--chmod=D755,F644', '--delete', '--itemize-changes',
            '--include=*/', '--include=*.png', '--include=*.pdf', '--include=*.txt',
            '--exclude=*', str(source) + '/', str(target) + '/',
        ],
        check=True,
    )
    for root, dirs, files in os.walk(target):
        p = Path(root); write_index(p); p.chmod(0o755)
    # Generate navigation only within this campaign.
    p = target.parent
    while p != TAU_ROOT:
        write_index(p); p.chmod(0o755); p = p.parent

shutil.copyfile(status, DEST / STATUS)
(DEST / STATUS).chmod(0o644)

# Keep simultaneous uploaders from overwriting each other's root links.
with (TAU_ROOT / '.tau-upload.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    add_card(TAU_ROOT / 'index.html', CAMPAIGN + '/', CAMPAIGN)
    add_card(WWW / 'index.html', 'TauValidationEffort/', 'TauValidationEffort')

TAU_ROOT.chmod(0o755)
print('Upload complete: https://spyros.web.cern.ch/TauValidationEffort/' + CAMPAIGN + '/')
PYTHON