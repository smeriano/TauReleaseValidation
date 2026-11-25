#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# Automatic HIN/UPC DataTau production + MC-style comparison
#
# Searches DAS for:
#   /<PD>/<release>-*<TAG>*/MINIAOD
# filtered by GT flavor (Prompt, dataRun3, dataRun2).
#
# Produces:
#   tau_hin_relval_outputs/root/Myroot_<release>_<GT>_DataTau_<SAMPLE>.root
#   tau_hin_relval_outputs/plots/compare_DataTau_<SAMPLE>_officialMCstyle
#   tau_hin_relval_outputs/status_HINData.tsv
# ============================================================

TARGET_REL="${TARGET_REL:-CMSSW_17_0_0}"
REF_REL="${REF_REL:-CMSSW_17_0_0_pre7}"

TARGET_VER="${TARGET_REL#CMSSW_}"
REF_VER="${REF_REL#CMSSW_}"

DEFAULT_SAMPLES=(
  HIForward0_upc2024_dataRun3_Prompt
  HIForward0_upc2025_dataRun3_Prompt
  HIForward1_upc2023_dataRun3
  HIForward1_upc2023_dataRun3_Prompt
  IonPhysics0_oxy2025_dataRun3_Prompt
  PAForward_upcPA2016_dataRun2
)

if [[ "$#" -gt 0 ]]; then
  SAMPLES=("$@")
else
  SAMPLES=("${DEFAULT_SAMPLES[@]}")
fi

BASE="tau_hin_relval_outputs"
ROOT_DIR="${BASE}/root"
MCROOT_DIR="${BASE}/root_mccompare"
PLOT_DIR="${BASE}/plots"
LOG_DIR="${BASE}/logs"
TAR_DIR="${BASE}/tars"

FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"
ALLOW_LUMI_MISMATCH="${ALLOW_LUMI_MISMATCH:-0}"

case "${ALLOW_LUMI_MISMATCH}" in
  0|1) ;;
  *)
    echo "ERROR: ALLOW_LUMI_MISMATCH must be 0 or 1." >&2
    exit 2
    ;;
esac

mkdir -p "${ROOT_DIR}" "${MCROOT_DIR}" "${PLOT_DIR}" "${LOG_DIR}" "${TAR_DIR}"

for req in produceTauValTree.py compare.py make_datatau_mccompare_input.py; do
  if [[ ! -f "${req}" ]]; then
    echo "ERROR: ${req} not found. Run from TauReleaseValidation." >&2
    exit 1
  fi
done

if ! grep -q "DataTau" compare.py; then
  echo "ERROR: compare.py does not seem to contain DataTau in options_dict." >&2
  exit 1
fi

python3 -m py_compile produceTauValTree.py compare.py make_datatau_mccompare_input.py || exit 1

parse_sample () {
  local sample="$1"
  PD="${sample%%_*}"
  local rest="${sample#*_}"
  TAG="${rest%%_*}"
  GT_FLAVOR="${rest#*_}"
}

extract_gt_from_dataset () {
  local ds="$1"
  local rel="$2"
  python3 - "${ds}" "${rel}" <<'PYGT'
import sys, re
ds, rel = sys.argv[1], sys.argv[2]
parts = ds.strip("/").split("/")
if len(parts) < 2:
    print("dummy")
    sys.exit(0)
ps = parts[1]
prefix = rel + "-"
if ps.startswith(prefix):
    ps = ps[len(prefix):]
m = re.match(r"^([0-9A-Za-z_]+?_v\d+)", ps)
if m:
    print(m.group(1))
else:
    print(re.sub(r"-v\d+$", "", ps))
PYGT
}

list_hin_datasets () {
  local release="$1"
  local pd="$2"
  local tag="$3"
  local gt_flavor="$4"

  local query1="dataset=/${pd}/${release}-*${tag}*/MINIAOD"
  local query2="dataset=/${pd}/${release}-*/MINIAOD"

  echo "[DAS] ${query1}" >&2
  mapfile -t cands < <(dasgoclient --query "${query1}" 2>/dev/null | sort -u)

  if [[ "${#cands[@]}" -eq 0 ]]; then
    echo "[DAS] no candidates with tag query; trying broader PD query" >&2
    echo "[DAS] ${query2}" >&2
    mapfile -t cands < <(dasgoclient --query "${query2}" 2>/dev/null | sort -u)
  fi

  if [[ "${#cands[@]}" -eq 0 ]]; then
    echo "ERROR: no DAS datasets found for release=${release}, pd=${pd}, tag=${tag}" >&2
    return 1
  fi

  CANDS="$(printf '%s\n' "${cands[@]}")" python3 - "${tag}" "${gt_flavor}" <<'PYSEL'
import os
import sys
import re

tag = sys.argv[1]
gt_flavor = sys.argv[2]
cands = [line.strip() for line in os.environ.get("CANDS", "").splitlines() if line.strip()]

reject_tokens = [
    "GPUvsCPU",
    "G4VECGEOM",
    "FastSIM",
    "FastSim",
    "ReHLT",
    "RecoOnly",
    "ALCARECO",
    "DQMIO",
]

year_m = re.search(r"(20\d{2})", tag)
year = year_m.group(1) if year_m else ""

def matches_gt_flavor(d):
    if gt_flavor in ("dataRun3_Prompt_frozenGT", "dataRun3_Prompt"):
        return "dataRun3_Prompt" in d
    if gt_flavor == "dataRun3":
        return ("dataRun3" in d) and ("Prompt" not in d)
    if gt_flavor == "dataRun2":
        return "dataRun2" in d
    return gt_flavor in d

def matches_tag_or_year(d):
    if tag.lower() in d.lower():
        return True
    if year and year in d:
        return True
    return False

good = [
    d for d in cands
    if not any(tok in d for tok in reject_tokens)
    and matches_gt_flavor(d)
    and matches_tag_or_year(d)
]

if not good:
    sys.exit(2)

def version(d):
    m = re.search(r"-v(\d+)(?:/|$)", d)
    return int(m.group(1)) if m else 0

def campaign_rank(d):
    if "_STD_" in d:
        return 0
    if "RV281" in d:
        return 1
    if "SpecialRV" in d:
        return 3
    return 2

def score(d):
    return (
        0 if tag.lower() in d.lower() else 1,
        campaign_rank(d),
        -version(d),
        d,
    )

for d in sorted(good, key=score):
    print(d)
PYSEL
}

normalised_lumis () {
  local ds="$1"
  dasgoclient --query="run,lumi dataset=${ds}" 2>/dev/null \
    | python3 -c '
import sys, re
pairs = []
for line in sys.stdin:
    line = line.strip()
    m = re.match(r"^(\d+)\s+\[(.*)\]$", line)
    if not m:
        continue
    run = int(m.group(1))
    lumis = [int(x) for x in re.findall(r"\d+", m.group(2))]
    for lumi in lumis:
        pairs.append((run, lumi))
for run, lumi in sorted(set(pairs)):
    print(f"{run}:{lumi}")
'
}

das_nevents () {
  local ds="$1"
  dasgoclient --query="summary dataset=${ds}" 2>/dev/null \
    | python3 -c '
import sys, json
txt = sys.stdin.read().strip()
if not txt:
    print("-1")
    raise SystemExit
try:
    d = json.loads(txt)[0]
    print(d.get("nevents", d.get("num_event", -1)))
except Exception:
    print("-1")
'
}

datasets_lumi_match () {
  local ds1="$1"
  local ds2="$2"
  local tmp
  tmp=$(mktemp -d)

  normalised_lumis "${ds1}" > "${tmp}/a.lumis"
  normalised_lumis "${ds2}" > "${tmp}/b.lumis"

  if cmp -s "${tmp}/a.lumis" "${tmp}/b.lumis"; then
    rm -rf "${tmp}"
    return 0
  fi

  echo "Lumis in TARGET but not REF:" >&2
  comm -13 "${tmp}/b.lumis" "${tmp}/a.lumis" | head -40 | sed 's/^/  /' >&2
  echo "Lumis in REF but not TARGET:" >&2
  comm -23 "${tmp}/b.lumis" "${tmp}/a.lumis" | head -40 | sed 's/^/  /' >&2

  rm -rf "${tmp}"
  return 1
}

pick_ref_matching_target () {
  local target_ds="$1"
  shift
  local refs=("$@")

  local tmp
  tmp=$(mktemp -d)

  normalised_lumis "${target_ds}" > "${tmp}/target.lumis"
  local target_events
  target_events=$(das_nevents "${target_ds}")

  echo "[match] target dataset: ${target_ds} (events=${target_events})" >&2

  local best_lumi_match=""
  for ref in "${refs[@]}"; do
    normalised_lumis "${ref}" > "${tmp}/ref.lumis"
    local ref_events
    ref_events=$(das_nevents "${ref}")
    echo "[match] testing REF: ${ref} (events=${ref_events})" >&2

    if cmp -s "${tmp}/target.lumis" "${tmp}/ref.lumis"; then
      if [[ "${ref_events}" == "${target_events}" ]]; then
        rm -rf "${tmp}"
        echo "${ref}"
        return 0
      fi
      [[ -z "${best_lumi_match}" ]] && best_lumi_match="${ref}"
    fi
  done

  rm -rf "${tmp}"
  if [[ -n "${best_lumi_match}" ]]; then
    echo "${best_lumi_match}"
    return 0
  fi

  echo "[match] WARNING: no REF candidate matches target lumi set; falling back to first ranked." >&2
  echo "${refs[0]}"
  return 0
}

produce_one () {
  local role="$1"
  local release="$2"
  local sample="$3"
  local dataset="$4"
  local gt="$5"

  local local_file="Myroot_${release}_${gt}_DataTau_${sample}.root"
  local out_file="${ROOT_DIR}/${local_file}"
  local log_file="${LOG_DIR}/produce_${role}_DataTau_${sample}.log"
  local dataset_meta="${out_file}.dataset.txt"

  echo >&2
  echo "Producing ${role} DataTau for ${sample}" >&2
  echo "  release: ${release}" >&2
  echo "  GT:      ${gt}" >&2
  echo "  dataset: ${dataset}" >&2
  echo "  output:  ${out_file}" >&2

  if [[ -s "${out_file}" && "${FORCE}" != "1" ]]; then
    if [[ -f "${dataset_meta}" ]] && [[ "$(cat "${dataset_meta}")" == "${dataset}" ]]; then
      echo "[skip] existing ROOT file from same dataset: ${out_file}" >&2
      return 0
    else
      rm -f "${out_file}" "${dataset_meta}"
    fi
  fi

  rm -f "${local_file}" "${out_file}"

  python3 produceTauValTree.py \
    --release "${release}" \
    --globalTag "${gt}" \
    --runtype DataTau \
    -s das \
    --exact "${dataset}" \
    -o "${local_file}" \
    --mvaid \
      deepTauIDv2p5VSe \
      deepTauIDv2p5VSmu \
      deepTauIDv2p5VSjet \
    2>&1 | tee "${log_file}" >&2

  local rc=${PIPESTATUS[0]}
  if [[ "${rc}" -ne 0 || ! -f "${local_file}" ]]; then
    echo "ERROR: ${role} production failed for ${sample}" >&2
    return 1
  fi

  mv "${local_file}" "${out_file}"
  echo "${dataset}" > "${dataset_meta}"
  echo "[ok] saved ${out_file}" >&2
  return 0
}

produce_with_fallback () {
  local role="$1"
  local release="$2"
  local sample="$3"
  shift 3
  local datasets=("$@")

  for ds in "${datasets[@]}"; do
    local gt
    gt="$(extract_gt_from_dataset "${ds}" "${release}")"
    if produce_one "${role}" "${release}" "${sample}" "${ds}" "${gt}"; then
      echo "${ds}"
      return 0
    fi
    echo "[fallback] ${role} production failed for ${ds}, trying next candidate" >&2
  done

  echo "ERROR: all ${role} dataset candidates failed for ${sample}" >&2
  return 1
}

convert_one () {
  local role="$1"
  local sample="$2"
  local input="$3"
  local output="$4"

  if [[ -s "${output}" && "${FORCE}" != "1" && ! "${input}" -nt "${output}" ]]; then
    echo "[skip] existing converted ROOT file is up to date: ${output}"
    return 0
  fi

  rm -f "${output}"
  python3 make_datatau_mccompare_input.py --input "${input}" --output "${output}"
}

quick_check_root () {
  local sample="$1"
  local target="$2"
  local ref="$3"

  echo
  echo "Quick ROOT check for ${sample}"
  python3 - <<PY
import ROOT
for fn in ["${target}", "${ref}"]:
    f = ROOT.TFile.Open(fn)
    if not f or f.IsZombie():
        raise RuntimeError("Cannot open " + fn)
    t = f.Get("per_tau")
    if not t:
        raise RuntimeError("No per_tau tree in " + fn)
    print(fn, "entries:", t.GetEntries())
PY
}

run_compare () {
  local sample="$1"
  local mc_target="$2"
  local mc_ref="$3"
  local target_gt="$4"
  local ref_gt="$5"

  local outdir="${PLOT_DIR}/compare_DataTau_${sample}_officialMCstyle"
  local logfile="${LOG_DIR}/compare_DataTau_${sample}_officialMCstyle.log"
  local tarfile="${TAR_DIR}/compare_DataTau_${sample}_officialMCstyle.tar.gz"

  echo
  echo "Running MC-style compare.py for DataTau ${sample}"

  rm -f "Myroot_${TARGET_REL}_${target_gt}_DataTau.root"
  rm -f "Myroot_${REF_REL}_${ref_gt}_DataTau.root"

  ln -s "$(readlink -f "${mc_target}")" "Myroot_${TARGET_REL}_${target_gt}_DataTau.root"
  ln -s "$(readlink -f "${mc_ref}")" "Myroot_${REF_REL}_${ref_gt}_DataTau.root"

  rm -rf compare_DataTau missing_leaves.txt "${outdir}" "${tarfile}"

  python3 compare.py \
    --releases "${TARGET_VER}" "${REF_VER}" \
    --inputfiles \
      "Myroot_${TARGET_REL}_${target_gt}_DataTau.root" \
      "Myroot_${REF_REL}_${ref_gt}_DataTau.root" \
    --runtype DataTau \
    2>&1 | tee "${logfile}"

  local rc=${PIPESTATUS[0]}
  if [[ "${rc}" -ne 0 || ! -d compare_DataTau ]]; then
    echo "ERROR: compare.py failed for ${sample}"
    return 1
  fi

  mv compare_DataTau "${outdir}"
  [[ -f missing_leaves.txt ]] && cp missing_leaves.txt "${outdir}/missing_leaves.txt"
  tar -czf "${tarfile}" -C "$(dirname "${outdir}")" "$(basename "${outdir}")"

  echo "[ok] plots: ${outdir} (PNGs: $(find "${outdir}" -name "*.png" | wc -l))"
  echo "[ok] tar:   ${tarfile}"
  return 0
}

STATUS="${BASE}/status_HINData.tsv"
echo -e "sample\tstatus\ttarget_dataset\tref_dataset\ttarget_root\tref_root\tplots\tlumi_match" > "${STATUS}"

for SAMPLE in "${SAMPLES[@]}"; do
  LUMI_STATUS="NOT_CHECKED"
  parse_sample "${SAMPLE}"

  echo
  echo "========================================================================================"
  echo "HIN DataTau sample: ${SAMPLE}  (PD=${PD}, TAG=${TAG}, GT_FLAVOR=${GT_FLAVOR})"
  echo "========================================================================================"

  mapfile -t TARGET_CANDS < <(list_hin_datasets "${TARGET_REL}" "${PD}" "${TAG}" "${GT_FLAVOR}")
  rc_target_pick=$?

  mapfile -t REF_CANDS < <(list_hin_datasets "${REF_REL}" "${PD}" "${TAG}" "${GT_FLAVOR}")
  rc_ref_pick=$?

  if [[ "${rc_target_pick}" -ne 0 || "${rc_ref_pick}" -ne 0 || "${#TARGET_CANDS[@]}" -eq 0 || "${#REF_CANDS[@]}" -eq 0 ]]; then
    echo "ERROR: dataset discovery failed for ${SAMPLE}"
    echo -e "${SAMPLE}\tFAILED_DISCOVERY\t\t\t\t\t\t${LUMI_STATUS}" >> "${STATUS}"
    continue
  fi

  echo "Ranked target candidates:"
  printf '  %s\n' "${TARGET_CANDS[@]}"
  echo "Ranked reference candidates:"
  printf '  %s\n' "${REF_CANDS[@]}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    DRY_TARGET_DS="${TARGET_CANDS[0]}"
    DRY_REF_DS="$(pick_ref_matching_target "${DRY_TARGET_DS}" "${REF_CANDS[@]}")"

    echo "[dry-run] TARGET: ${DRY_TARGET_DS}"
    echo "[dry-run] REF:    ${DRY_REF_DS}"

    if datasets_lumi_match "${DRY_TARGET_DS}" "${DRY_REF_DS}"; then
      DRY_STATUS="DRY_RUN_LUMI_MATCH"
      LUMI_STATUS="MATCH"
    else
      DRY_STATUS="DRY_RUN_LUMI_MISMATCH"
      LUMI_STATUS="MISMATCH"
      [[ "${ALLOW_LUMI_MISMATCH}" == "1" ]] && LUMI_STATUS="MISMATCH_ALLOWED"
    fi

    echo -e "${SAMPLE}\t${DRY_STATUS}\t${DRY_TARGET_DS}\t${DRY_REF_DS}\t\t\t\t${LUMI_STATUS}" >> "${STATUS}"
    continue
  fi

  TARGET_DS="$(produce_with_fallback "target" "${TARGET_REL}" "${SAMPLE}" "${TARGET_CANDS[@]}")"
  if [[ $? -ne 0 || -z "${TARGET_DS}" ]]; then
    echo -e "${SAMPLE}\tFAILED_TARGET_PRODUCTION\t\t\t\t\t\t${LUMI_STATUS}" >> "${STATUS}"
    continue
  fi

  MATCHED_REF_DS="$(pick_ref_matching_target "${TARGET_DS}" "${REF_CANDS[@]}")"
  REF_ORDERED=("${MATCHED_REF_DS}")
  for ds in "${REF_CANDS[@]}"; do
    [[ "${ds}" != "${MATCHED_REF_DS}" ]] && REF_ORDERED+=("${ds}")
  done

  REF_DS="$(produce_with_fallback "reference" "${REF_REL}" "${SAMPLE}" "${REF_ORDERED[@]}")"
  if [[ $? -ne 0 || -z "${REF_DS}" ]]; then
    echo -e "${SAMPLE}\tFAILED_REF_PRODUCTION\t${TARGET_DS}\t\t\t\t\t${LUMI_STATUS}" >> "${STATUS}"
    continue
  fi

  TARGET_GT="$(extract_gt_from_dataset "${TARGET_DS}" "${TARGET_REL}")"
  REF_GT="$(extract_gt_from_dataset "${REF_DS}" "${REF_REL}")"

  ORIG_TARGET="${ROOT_DIR}/Myroot_${TARGET_REL}_${TARGET_GT}_DataTau_${SAMPLE}.root"
  ORIG_REF="${ROOT_DIR}/Myroot_${REF_REL}_${REF_GT}_DataTau_${SAMPLE}.root"
  MC_TARGET="${MCROOT_DIR}/target_DataTau_${SAMPLE}_mccompare.root"
  MC_REF="${MCROOT_DIR}/ref_DataTau_${SAMPLE}_mccompare.root"
  OUTDIR="${PLOT_DIR}/compare_DataTau_${SAMPLE}_officialMCstyle"

  LUMI_STATUS="MATCH"
  if ! datasets_lumi_match "${TARGET_DS}" "${REF_DS}"; then
    LUMI_STATUS="MISMATCH"
    if [[ "${ALLOW_LUMI_MISMATCH}" != "1" ]]; then
      echo "ERROR: lumi mismatch for ${SAMPLE}; set ALLOW_LUMI_MISMATCH=1 to proceed."
      echo -e "${SAMPLE}\tFAILED_LUMI_MISMATCH\t${TARGET_DS}\t${REF_DS}\t${ORIG_TARGET}\t${ORIG_REF}\t\t${LUMI_STATUS}" >> "${STATUS}"
      continue
    fi
    LUMI_STATUS="MISMATCH_ALLOWED"
  fi

  quick_check_root "${SAMPLE}" "${ORIG_TARGET}" "${ORIG_REF}"

  if ! convert_one "target" "${SAMPLE}" "${ORIG_TARGET}" "${MC_TARGET}" || \
     ! convert_one "reference" "${SAMPLE}" "${ORIG_REF}" "${MC_REF}"; then
    echo -e "${SAMPLE}\tFAILED_CONVERSION\t${TARGET_DS}\t${REF_DS}\t${ORIG_TARGET}\t${ORIG_REF}\t\t${LUMI_STATUS}" >> "${STATUS}"
    continue
  fi

  if ! run_compare "${SAMPLE}" "${MC_TARGET}" "${MC_REF}" "${TARGET_GT}" "${REF_GT}"; then
    echo -e "${SAMPLE}\tFAILED_COMPARE\t${TARGET_DS}\t${REF_DS}\t${ORIG_TARGET}\t${ORIG_REF}\t${OUTDIR}\t${LUMI_STATUS}" >> "${STATUS}"
    continue
  fi

  echo -e "${SAMPLE}\tOK\t${TARGET_DS}\t${REF_DS}\t${ORIG_TARGET}\t${ORIG_REF}\t${OUTDIR}\t${LUMI_STATUS}" >> "${STATUS}"
done

echo
echo "============================================================"
echo "Final HIN DataTau summary"
echo "============================================================"
column -t -s $'\t' "${STATUS}"