# ============================================================
# Campaign configuration
# ============================================================

TARGET_REL="CMSSW_17_0_0_pre3"
REF_REL="CMSSW_17_0_0_pre2"

TARGET_GT="160X_mcRun3_2026_realistic_v6"
REF_GT="160X_mcRun3_2026_realistic_v6"

DRY_OUTDIR="tau_relval_auto_outputs_Run3_2026_dryrun"
OUTDIR="tau_relval_auto_outputs_MC_Run3_2026"

DRY_RUN="${DRY_RUN:-1}"

RUNTYPES=(ZMM ZEE ZTT TTbar)
PILEUPS=(noPU PU)

MVAIDS=(
  deepTauIDv2p5VSe
  deepTauIDv2p5VSmu
  deepTauIDv2p5VSjet
)

# Set FORCE=1 to regenerate ROOT files made before all three IDs were enabled.
FORCE="${FORCE:-0}"
FORCE_ARGS=()
if [[ "${FORCE}" == "1" ]]; then
  FORCE_ARGS+=(--force)
fi

echo
echo "============================================================"
echo "Campaign configuration"
echo "============================================================"
echo "Target release:    ${TARGET_REL}"
echo "Reference release: ${REF_REL}"
echo "Target GT:         ${TARGET_GT}"
echo "Reference GT:      ${REF_GT}"
echo "Dry-run outdir:    ${DRY_OUTDIR}"
echo "Real-run outdir:   ${OUTDIR}"
echo "DeepTau IDs:       ${MVAIDS[*]}"
echo "Force regeneration: ${FORCE}"

# ============================================================
# Move into the target release area and set up the environment
# ============================================================

cd /eos/user/s/smeriano/UCLouvain/TAU_RELVAL/${TARGET_REL}/src/TauReleaseValidation

# If not already done in this shell:
cmsenv

# ============================================================
# Sanity checks
# ============================================================

python3 -m py_compile tau_relval_auto_compare.py

# grep -n "dataset_version\|candidate fallback pairs\|Attempt .*for\|fallback" tau_relval_auto_compare.py
# grep -n "DEFAULT_REJECT" tau_relval_auto_compare.py

# ============================================================
# Dry-run first: check which pairs it will try
# ============================================================

python3 tau_relval_auto_compare.py \
  --target-release "${TARGET_REL}" \
  --ref-release "${REF_REL}" \
  --runtype "${RUNTYPES[@]}" \
  --pileups "${PILEUPS[@]}" \
  --data-format MINIAODSIM \
  --target-contains "${TARGET_GT}" \
  --ref-contains "${REF_GT}" \
  --produce-gt "${TARGET_GT}" \
  --reject-contains GPUvsCPU G4VECGEOM FastSIM FastSim ReHLT RecoOnly HIN BPH \
  --mvaid "${MVAIDS[0]}" \
  --mvaid "${MVAIDS[1]}" \
  --mvaid "${MVAIDS[2]}" \
  --dry-run \
  --outdir "${DRY_OUTDIR}"

DRY_STATUS=$?
if [[ "${DRY_STATUS}" -ne 0 ]]; then
  echo "Dry-run failed; stopping." >&2
  exit "${DRY_STATUS}"
fi

column -t -s $'\t' "${DRY_OUTDIR}/status.tsv"

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "Dry-run complete. Inspect the selected dataset pairs before production."
  exit 0
fi

# ============================================================
# Real run: produce ROOT files and plots
# ============================================================

python3 tau_relval_auto_compare.py \
  --target-release "${TARGET_REL}" \
  --ref-release "${REF_REL}" \
  --runtype "${RUNTYPES[@]}" \
  --pileups "${PILEUPS[@]}" \
  --data-format MINIAODSIM \
  --target-contains "${TARGET_GT}" \
  --ref-contains "${REF_GT}" \
  --produce-gt "${TARGET_GT}" \
  --reject-contains GPUvsCPU G4VECGEOM FastSIM FastSim ReHLT RecoOnly HIN BPH \
  --mvaid "${MVAIDS[0]}" \
  --mvaid "${MVAIDS[1]}" \
  --mvaid "${MVAIDS[2]}" \
  --keep-going \
  "${FORCE_ARGS[@]}" \
  --outdir "${OUTDIR}"

# ============================================================
# Summary
# ============================================================

echo
echo "============================================================"
echo "Status"
echo "============================================================"
column -t -s $'\t' "${OUTDIR}/status.tsv"

echo
echo "============================================================"
echo "Plot folders"
echo "============================================================"
find "${OUTDIR}/plots" -maxdepth 1 -type d | sort

echo
echo "============================================================"
echo "PNG count"
echo "============================================================"
find "${OUTDIR}/plots" -name "*.png" | wc -l

echo
echo "============================================================"
echo "Tarballs"
echo "============================================================"
ls -lh "${OUTDIR}/tars"/*.tar.gz 2>/dev/null || true

echo
echo "============================================================"
echo "Check that chosen datasets contain the expected GT and geometry"
echo "============================================================"
grep -E \
  "${TARGET_REL}|${REF_REL}|${TARGET_GT}|${REF_GT}|MINIAODSIM" \
  "${OUTDIR}/status.tsv" || true