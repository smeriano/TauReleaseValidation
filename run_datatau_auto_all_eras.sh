#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# Automatic DataTau production + MC-style comparison for all eras
#
# Automatically searches DAS for:
#   /Tau/<release>-*<ERA>*Data_RelVal_Tau<ERA>*/MINIAOD
#
# Produces:
#   tau_data_relval_outputs/root/Myroot_<release>_dummy_DataTau_<ERA>.root
#
# Then converts to MC-style input and runs:
#   compare.py --runtype DataTau
# ============================================================

TARGET_REL="CMSSW_17_0_0_pre2"
REF_REL="CMSSW_17_0_0_pre1"

TARGET_GT="161X_dataRun3_Prompt_frozen260520_v1"
REF_GT="160X_dataRun3_Prompt_frozen260223_v1"

TARGET_VER="${TARGET_REL#CMSSW_}"
REF_VER="${REF_REL#CMSSW_}"




DEFAULT_ERAS=(2025B 2025C 2025D 2025E 2025F 2025G)

if [[ "$#" -gt 0 ]]; then
  ERAS=("$@")
else
  ERAS=("${DEFAULT_ERAS[@]}")
fi

BASE="tau_data_relval_outputs"
ROOT_DIR="${BASE}/root"
MCROOT_DIR="${BASE}/root_mccompare"
PLOT_DIR="${BASE}/plots"
LOG_DIR="${BASE}/logs"
TAR_DIR="${BASE}/tars"

FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "${ROOT_DIR}" "${MCROOT_DIR}" "${PLOT_DIR}" "${LOG_DIR}" "${TAR_DIR}"

if [[ ! -f produceTauValTree.py ]]; then
  echo "ERROR: produceTauValTree.py not found. Run from TauReleaseValidation."
  exit 1
fi

if [[ ! -f compare.py ]]; then
  echo "ERROR: compare.py not found. Run from TauReleaseValidation."
  exit 1
fi

if [[ ! -f make_datatau_mccompare_input.py ]]; then
  echo "ERROR: make_datatau_mccompare_input.py not found."
  exit 1
fi

if ! grep -q "DataTau" compare.py; then
  echo "ERROR: compare.py does not seem to contain DataTau in options_dict."
  echo "Patch compare.py first."
  exit 1
fi

python3 -m py_compile produceTauValTree.py compare.py make_datatau_mccompare_input.py || exit 1

list_datatau_datasets () {
  local release="$1"
  local era="$2"
  local preferred_token="${3:-}"

  local query1="dataset=/Tau/${release}-*${era}*Data_RelVal_Tau${era}*/MINIAOD"
  local query2="dataset=/Tau/${release}-*${era}*/MINIAOD"

  echo "[DAS] ${query1}" >&2
  mapfile -t cands < <(dasgoclient --query "${query1}" 2>/dev/null | sort -u)

  if [[ "${#cands[@]}" -eq 0 ]]; then
    echo "[DAS] no candidates with strict query; trying broader query" >&2
    echo "[DAS] ${query2}" >&2
    mapfile -t cands < <(dasgoclient --query "${query2}" 2>/dev/null | sort -u)
  fi

  if [[ "${#cands[@]}" -eq 0 ]]; then
    echo "ERROR: no DAS datasets found for release=${release}, era=${era}" >&2
    return 1
  fi

  echo "Candidates for ${release} ${era}:" >&2
  printf '  %s\n' "${cands[@]}" >&2

  CANDS="$(printf '%s\n' "${cands[@]}")" PREFERRED_TOKEN="${preferred_token}" python3 - "${era}" <<'PYSEL'
import os
import sys
import re

era = sys.argv[1]
preferred_token = os.environ.get("PREFERRED_TOKEN", "")
cands = [line.strip() for line in os.environ.get("CANDS", "").splitlines() if line.strip()]

if not cands:
    sys.exit(2)

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

good = [d for d in cands if not any(tok in d for tok in reject_tokens)]
if not good:
    good = cands

def version(d):
    m = re.search(r"-v(\d+)(?:/|$)", d)
    return int(m.group(1)) if m else 0

def campaign_rank(d):
    # Lower is better.
    if "_STD_" in d:
        return 0
    if "RV281" in d:
        return 1
    if "SpecialRV" in d:
        return 3
    return 2

def score(d):
    # Lower tuple is better.
    return (
        0 if preferred_token and preferred_token in d else 1,
        0 if f"Data_RelVal_Tau{era}" in d else 1,
        campaign_rank(d),
        0 if "dataRun3" in d else 1,
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

  echo "[match] target dataset:" >&2
  echo "        ${target_ds}" >&2
  echo "[match] target events: ${target_events}" >&2

  local best_lumi_match=""

  for ref in "${refs[@]}"; do
    normalised_lumis "${ref}" > "${tmp}/ref.lumis"
    local ref_events
    ref_events=$(das_nevents "${ref}")

    echo "[match] testing REF:" >&2
    echo "        ${ref}" >&2
    echo "        events=${ref_events}" >&2

    if cmp -s "${tmp}/target.lumis" "${tmp}/ref.lumis"; then
      if [[ "${ref_events}" == "${target_events}" ]]; then
        echo "[match] selected REF with matching lumis and events:" >&2
        echo "        ${ref}" >&2
        rm -rf "${tmp}"
        echo "${ref}"
        return 0
      fi

      if [[ -z "${best_lumi_match}" ]]; then
        best_lumi_match="${ref}"
      fi
    fi
  done

  if [[ -n "${best_lumi_match}" ]]; then
    echo "[match] selected REF with matching lumis, but event count differs:" >&2
    echo "        ${best_lumi_match}" >&2
    rm -rf "${tmp}"
    echo "${best_lumi_match}"
    return 0
  fi

  echo "[match] WARNING: no REF candidate matches target lumi set." >&2
  echo "[match] Falling back to first ranked REF candidate:" >&2
  echo "        ${refs[0]}" >&2

  rm -rf "${tmp}"
  echo "${refs[0]}"
  return 0
}


produce_one () {
  local role="$1"
  local release="$2"
  local era="$3"
  local dataset="$4"

  local gt
  if [[ "${role}" == "target" ]]; then
    gt="${TARGET_GT}"
  else
    gt="${REF_GT}"
  fi

  local local_file="Myroot_${release}_${gt}_DataTau_${era}.root"
  local out_file="${ROOT_DIR}/${local_file}"
  local log_file="${LOG_DIR}/produce_${role}_DataTau_${era}.log"
  local dataset_meta="${out_file}.dataset.txt"

  echo
  echo "Producing ${role} DataTau for ${era}"
  echo "  release: ${release}"
  echo "  GT:      ${gt}"
  echo "  dataset: ${dataset}"
  echo "  output:  ${out_file}"

  if [[ -s "${out_file}" && ! -f "${dataset_meta}" && -f "${log_file}" ]]; then
    old_dataset="$(grep -E "Getting files from DAS\. query: file dataset=" "${log_file}" 2>/dev/null | sed -E 's/.*dataset=([^[:space:]]+).*/\1/' | tail -n 1 || true)"
    if [[ -n "${old_dataset}" ]]; then
      echo "${old_dataset}" > "${dataset_meta}"
      echo "[meta] recovered dataset metadata from old log: ${dataset_meta}"
    fi
  fi

  if [[ -s "${out_file}" && "${FORCE}" != "1" ]]; then
    if [[ -f "${dataset_meta}" ]] && [[ "$(cat "${dataset_meta}")" == "${dataset}" ]]; then
      echo "[skip] existing ROOT file from same dataset: ${out_file}"
      echo "[skip] dataset: ${dataset}"
      return 0
    else
      echo "[redo] existing ROOT file is missing/different dataset metadata:"
      echo "       file: ${out_file}"
      echo "       old dataset: $(cat "${dataset_meta}" 2>/dev/null || echo '<unknown>')"
      echo "       new dataset: ${dataset}"
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
    --mvaid deepTauIDv2p5VSe \
    --mvaid deepTauIDv2p5VSmu \
    --mvaid deepTauIDv2p5VSjet \
    2>&1 | tee "${log_file}"

  local rc=${PIPESTATUS[0]}
  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: ${role} production failed for ${era}"
    return 1
  fi

  if [[ ! -f "${local_file}" ]]; then
    echo "ERROR: ${role} output was not created: ${local_file}"
    return 1
  fi

  mv "${local_file}" "${out_file}"
  echo "${dataset}" > "${dataset_meta}"
  echo "[ok] saved ${out_file}"
  echo "[ok] dataset metadata: ${dataset_meta}"
  return 0
}

produce_with_fallback () {
  local role="$1"
  local release="$2"
  local era="$3"
  shift 3

  local datasets=("$@")
  local picked=""

  for ds in "${datasets[@]}"; do
    echo
    echo "Trying ${role} dataset candidate:"
    echo "  ${ds}"

    produce_one "${role}" "${release}" "${era}" "${ds}"
    local rc=$?

    if [[ "${rc}" -eq 0 ]]; then
      picked="${ds}"
      echo "[ok] ${role} production succeeded with:"
      echo "  ${picked}"
      echo "${picked}"
      return 0
    fi

    echo "[fallback] ${role} production failed, trying next candidate"
  done

  echo "ERROR: all ${role} dataset candidates failed for ${era}" >&2
  return 1
}


convert_one () {
  local role="$1"
  local era="$2"
  local input="$3"
  local output="$4"

  echo
  echo "Converting ${role} to MC-style DataTau input"
  echo "  input:  ${input}"
  echo "  output: ${output}"

  if [[ -s "${output}" && "${FORCE}" != "1" ]]; then
    if [[ ! "${input}" -nt "${output}" ]]; then
      echo "[skip] existing converted ROOT file is up to date: ${output}"
      return 0
    else
      echo "[redo] converted ROOT is older than input:"
      echo "       input:  ${input}"
      echo "       output: ${output}"
      rm -f "${output}"
    fi
  fi

  rm -f "${output}"

  python3 make_datatau_mccompare_input.py \
    --input "${input}" \
    --output "${output}"

  local rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: conversion failed for ${role} ${era}"
    return 1
  fi

  return 0
}

quick_check_root () {
  local era="$1"
  local target="$2"
  local ref="$3"

  echo
  echo "Quick ROOT check for ${era}"

  python3 - <<PY
import ROOT

for fn in ["${target}", "${ref}"]:
    f = ROOT.TFile.Open(fn)
    if not f or f.IsZombie():
        raise RuntimeError("Cannot open " + fn)

    t = f.Get("per_tau")
    if not t:
        raise RuntimeError("No per_tau tree in " + fn)

    print(fn)
    print("  entries:", t.GetEntries())

    hname = "h_tau_pt_check"
    t.Draw(f"tau_pt>>{hname}(50,0,200)", "tau_pt > 20 && abs(tau_eta) < 2.3", "goff")
    h = ROOT.gDirectory.Get(hname)
    print("  tau_pt integral:", h.Integral() if h else "NO HIST")
    ROOT.gDirectory.Delete(hname + ";*")
PY
}

run_compare () {
  local era="$1"
  local mc_target="$2"
  local mc_ref="$3"

  local outdir="${PLOT_DIR}/compare_DataTau_${era}_officialMCstyle"
  local logfile="${LOG_DIR}/compare_DataTau_${era}_officialMCstyle.log"
  local tarfile="${TAR_DIR}/compare_DataTau_${era}_officialMCstyle.tar.gz"

  echo
  echo "Running MC-style compare.py for DataTau ${era}"

  rm -f "Myroot_${TARGET_REL}_${TARGET_GT}_DataTau.root"
  rm -f "Myroot_${REF_REL}_${REF_GT}_DataTau.root"

  ln -s "$(readlink -f "${mc_target}")" "Myroot_${TARGET_REL}_${TARGET_GT}_DataTau.root"
  ln -s "$(readlink -f "${mc_ref}")" "Myroot_${REF_REL}_${REF_GT}_DataTau.root"

  rm -rf compare_DataTau missing_leaves.txt "${outdir}" "${tarfile}"

  python3 compare.py \
    --releases "${TARGET_VER}" "${REF_VER}" \
    --inputfiles \
      "Myroot_${TARGET_REL}_${TARGET_GT}_DataTau.root" \
      "Myroot_${REF_REL}_${REF_GT}_DataTau.root" \
    --runtype DataTau \
    2>&1 | tee "${logfile}"

  local rc=${PIPESTATUS[0]}
  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: compare.py failed for ${era}"
    return 1
  fi

  if [[ ! -d compare_DataTau ]]; then
    echo "ERROR: compare.py did not produce compare_DataTau for ${era}"
    return 1
  fi

  mv compare_DataTau "${outdir}"

  if [[ -f missing_leaves.txt ]]; then
    cp missing_leaves.txt "${outdir}/missing_leaves.txt"
  fi

  tar -czf "${tarfile}" -C "$(dirname "${outdir}")" "$(basename "${outdir}")"

  echo "[ok] plots: ${outdir}"
  echo "[ok] tar:   ${tarfile}"
  echo "[ok] log:   ${logfile}"

  echo "PNG count:"
  find "${outdir}" -name "*.png" | wc -l

  return 0
}

STATUS="${BASE}/status_DataTau.tsv"
echo -e "era\tstatus\ttarget_dataset\tref_dataset\ttarget_root\tref_root\tplots" > "${STATUS}"

for ERA in "${ERAS[@]}"; do
  echo
  echo "========================================================================================"
  echo "DataTau era ${ERA}"
  echo "========================================================================================"

  mapfile -t TARGET_CANDS < <(list_datatau_datasets "${TARGET_REL}" "${ERA}" "${TARGET_GT}")
  rc_target_pick=$?

  mapfile -t REF_CANDS < <(list_datatau_datasets "${REF_REL}" "${ERA}" "${REF_GT}")
  rc_ref_pick=$?

  if [[ "${rc_target_pick}" -ne 0 || "${rc_ref_pick}" -ne 0 || "${#TARGET_CANDS[@]}" -eq 0 || "${#REF_CANDS[@]}" -eq 0 ]]; then
    echo "ERROR: dataset discovery failed for ${ERA}"
    echo -e "${ERA}\tFAILED_DISCOVERY\t\t\t\t\t" >> "${STATUS}"
    continue
  fi

  echo
  echo "Ranked target candidates for ${ERA}:"
  printf '  %s\n' "${TARGET_CANDS[@]}"

  echo
  echo "Ranked reference candidates for ${ERA}:"
  printf '  %s\n' "${REF_CANDS[@]}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[dry-run] not producing"

    DRY_TARGET_DS="${TARGET_CANDS[0]}"
    DRY_REF_DS="$(pick_ref_matching_target "${DRY_TARGET_DS}" "${REF_CANDS[@]}")"

    echo
    echo "[dry-run] chosen datasets after lumi matching:"
    echo "  TARGET: ${DRY_TARGET_DS}"
    echo "  REF:    ${DRY_REF_DS}"

    if datasets_lumi_match "${DRY_TARGET_DS}" "${DRY_REF_DS}"; then
      DRY_STATUS="DRY_RUN_LUMI_MATCH"
    else
      DRY_STATUS="DRY_RUN_LUMI_MISMATCH"
    fi

    echo -e "${ERA}\t${DRY_STATUS}\t${DRY_TARGET_DS}\t${DRY_REF_DS}\t\t\t" >> "${STATUS}"
    continue
  fi

  ORIG_TARGET="${ROOT_DIR}/Myroot_${TARGET_REL}_${TARGET_GT}_DataTau_${ERA}.root"
  ORIG_REF="${ROOT_DIR}/Myroot_${REF_REL}_${REF_GT}_DataTau_${ERA}.root"

  MC_TARGET="${MCROOT_DIR}/target_DataTau_${ERA}_mccompare.root"
  MC_REF="${MCROOT_DIR}/ref_DataTau_${ERA}_mccompare.root"

  OUTDIR="${PLOT_DIR}/compare_DataTau_${ERA}_officialMCstyle"

  TARGET_DS="$(produce_with_fallback "target" "${TARGET_REL}" "${ERA}" "${TARGET_CANDS[@]}" | tail -1)"
  ok_target=$?

  if [[ "${ok_target}" -ne 0 ]]; then
    echo "ERROR: target production failed for ${ERA}"
    echo -e "${ERA}\tFAILED_TARGET_PRODUCTION\t${TARGET_DS:-}\t\t${ORIG_TARGET}\t${ORIG_REF}\t" >> "${STATUS}"
    continue
  fi

  MATCHED_REF_DS="$(pick_ref_matching_target "${TARGET_DS}" "${REF_CANDS[@]}")"

  REF_ORDERED=("${MATCHED_REF_DS}")
  for ds in "${REF_CANDS[@]}"; do
    if [[ "${ds}" != "${MATCHED_REF_DS}" ]]; then
      REF_ORDERED+=("${ds}")
    fi
  done

  echo
  echo "Reference candidates reordered by lumi match for ${ERA}:"
  printf '  %s\n' "${REF_ORDERED[@]}"

  REF_DS="$(produce_with_fallback "reference" "${REF_REL}" "${ERA}" "${REF_ORDERED[@]}" | tail -1)"
  ok_ref=$?

  if [[ "${ok_target}" -ne 0 || "${ok_ref}" -ne 0 ]]; then
    echo "ERROR: production failed for ${ERA}"
    echo -e "${ERA}\tFAILED_PRODUCTION\t${TARGET_DS:-}\t${REF_DS:-}\t${ORIG_TARGET}\t${ORIG_REF}\t" >> "${STATUS}"
    continue
  fi

  if ! datasets_lumi_match "${TARGET_DS}" "${REF_DS}"; then
    echo "ERROR: chosen target/reference lumi sets do not match for ${ERA}"
    echo "  TARGET: ${TARGET_DS}"
    echo "  REF:    ${REF_DS}"
    echo -e "${ERA}\tFAILED_LUMI_MISMATCH\t${TARGET_DS}\t${REF_DS}\t${ORIG_TARGET}\t${ORIG_REF}\t" >> "${STATUS}"
    continue
  fi

  echo
  echo "Chosen working datasets for ${ERA}:"
  echo "  TARGET: ${TARGET_DS}"
  echo "  REF:    ${REF_DS}"

  quick_check_root "${ERA}" "${ORIG_TARGET}" "${ORIG_REF}"

  convert_one "target" "${ERA}" "${ORIG_TARGET}" "${MC_TARGET}"
  ok_conv_target=$?

  convert_one "reference" "${ERA}" "${ORIG_REF}" "${MC_REF}"
  ok_conv_ref=$?

  if [[ "${ok_conv_target}" -ne 0 || "${ok_conv_ref}" -ne 0 ]]; then
    echo "ERROR: conversion failed for ${ERA}"
    echo -e "${ERA}\tFAILED_CONVERSION\t${TARGET_DS}\t${REF_DS}\t${ORIG_TARGET}\t${ORIG_REF}\t" >> "${STATUS}"
    continue
  fi

  quick_check_root "${ERA}" "${MC_TARGET}" "${MC_REF}"

  run_compare "${ERA}" "${MC_TARGET}" "${MC_REF}"
  ok_compare=$?

  if [[ "${ok_compare}" -ne 0 ]]; then
    echo -e "${ERA}\tFAILED_COMPARE\t${TARGET_DS}\t${REF_DS}\t${ORIG_TARGET}\t${ORIG_REF}\t${OUTDIR}" >> "${STATUS}"
    continue
  fi

  echo -e "${ERA}\tOK\t${TARGET_DS}\t${REF_DS}\t${ORIG_TARGET}\t${ORIG_REF}\t${OUTDIR}" >> "${STATUS}"
done

echo
echo "============================================================"
echo "Final DataTau summary"
echo "============================================================"

column -t -s $'\t' "${STATUS}"

echo
echo "Plot folders:"
find "${PLOT_DIR}" -maxdepth 1 -type d -name "compare_DataTau_*_officialMCstyle" | sort

echo
echo "Total PNGs:"
find "${PLOT_DIR}" -path "*compare_DataTau_*_officialMCstyle*" -name "*.png" | wc -l

echo
echo "Tarballs:"
ls -lh "${TAR_DIR}"/compare_DataTau_*_officialMCstyle.tar.gz 2>/dev/null || true
