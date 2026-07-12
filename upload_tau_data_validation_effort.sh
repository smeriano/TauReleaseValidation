#!/usr/bin/env bash
set -euo pipefail

SRC="/eos/user/s/smeriano/UCLouvain/TAU_RELVAL/CMSSW_17_0_0_pre2/src/TauReleaseValidation/tau_data_relval_outputs/plots"

WWW="/eos/user/s/smeriano/www"
TAU_ROOT="${WWW}/TauValidationEffort"
DEST="${TAU_ROOT}/17_0_0_pre2_2025Data_vs_17_0_0_pre1_2025Data"

echo "Source:      ${SRC}"
echo "Destination: ${DEST}"

if [ ! -d "${SRC}" ]; then
  echo "ERROR: source does not exist:"
  echo "  ${SRC}"
  exit 1
fi

mkdir -p "${DEST}"

echo
echo "Copying plot folders with web-safe permissions..."
rsync -a --delete \
  --no-perms \
  --chmod=D755,F644 \
  "${SRC}/" \
  "${DEST}/"

echo
echo "Generating recursive index.html pages..."
python3 - <<'PY'
from pathlib import Path
import html
import os
import time

WWW = Path("/eos/user/s/smeriano/www")
TAU_ROOT = WWW / "TauValidationEffort"
DEST = TAU_ROOT / "17_0_0_pre2_2025Data_vs_17_0_0_pre1_2025Data"

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
    return "/" + str(path)

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
        lines.append('<input type="text" id="filterInput" onkeyup="filterItems()" placeholder="Filter folders / plots...">')
        lines.append("</div>")

    if subdirs:
        lines.append("<h2>Subdirs</h2>")
        lines.append('<div class="grid">')
        for d in subdirs:
            name = d.name
            esc = html.escape(name)
            lines.append(f'<div class="folder-card filter-item" data-name="{esc}">')
            lines.append(f'<h3><a href="{esc}/">[{esc}]</a></h3>')
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
            lines.append(f'<a href="{esc}"><img src="{esc}" alt="{esc}"></a>')
            if pdf.exists():
                pdf_name = html.escape(pdf.name)
                lines.append(f'<p class="small"><a href="{pdf_name}">PDF version</a></p>')
            lines.append("</div>")
        lines.append("</div>")

    if not subdirs and not pngs:
        lines.append('<p class="small">No subdirectories or PNG plots found here.</p>')

    lines.append("")
    lines.append("</body>")
    lines.append("</html>")
    lines.append("")

    (path / "index.html").write_text("\n".join(lines), encoding="utf-8")

# Generate TauValidationEffort/index.html and all nested pages
for root, dirs, files in os.walk(TAU_ROOT):
    root_path = Path(root)

    if any(part.startswith(".") for part in root_path.parts):
        continue

    write_index(root_path)

# Add TauValidationEffort card to the main /www/index.html if missing
main_index = WWW / "index.html"

card = """
<div class="folder-card filter-item" data-name="TauValidationEffort">
<h3><a href="TauValidationEffort/">TauValidationEffort</a></h3>
<p class="small">Tau validation comparisons and efficiency plots</p>
</div>
"""

if main_index.exists():
    text = main_index.read_text(encoding="utf-8")

    if "TauValidationEffort/" not in text:
        backup = WWW / f"index.html.bak.{time.strftime('%Y%m%d_%H%M%S')}"
        backup.write_text(text, encoding="utf-8")

        body_pos = text.rfind("</body>")
        insert_pos = text.rfind("</div>", 0, body_pos)

        if insert_pos == -1:
            raise RuntimeError("Could not find the final grid </div> in main index.html")

        text = text[:insert_pos] + "\n" + card + "\n" + text[insert_pos:]
        main_index.write_text(text, encoding="utf-8")
        print(f"Updated main index.html. Backup saved as {backup}")
    else:
        print("Main index.html already contains TauValidationEffort. Not adding duplicate.")
else:
    print(f"WARNING: main index does not exist: {main_index}")

print("Done.")
PY

echo
echo "Fixing permissions..."
find "${TAU_ROOT}" -type d -exec chmod 755 {} \;
find "${TAU_ROOT}" -type f -exec chmod 644 {} \;

if [ -f "${WWW}/index.html" ]; then
  chmod 644 "${WWW}/index.html"
fi

echo
echo "Checking copied folders:"
find "${DEST}" -maxdepth 1 -mindepth 1 -type d | sort

echo
echo "Checking nested index files:"
find "${DEST}" -maxdepth 3 -type f -name index.html | head -30

echo
echo "Created:"
echo "  ${DEST}"

echo
echo "Open:"
echo "  https://spyros.web.cern.ch/TauValidationEffort/17_0_0_pre2_2025Data_vs_17_0_0_pre1_2025Data/"
