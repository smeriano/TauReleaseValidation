cd /eos/home-s/smeriano/UCLouvain/TAU_RELVAL/CMSSW_17_0_0_pre2/src/TauReleaseValidation

# If not already done in this shell:
cmsenv

# ============================================================
# Campaign configuration
# ============================================================

TARGET_REL="CMSSW_17_0_0_pre2"
REF_REL="CMSSW_17_0_0_pre1"

TARGET_GT="150X_mcRun4_realistic_v1"
REF_GT="150X_mcRun4_realistic_v1"

GEOM="D121"

DRY_OUTDIR="tau_relval_auto_outputs_D121_noPU_fallback_test"
OUTDIR="tau_relval_auto_outputs_MC_D121"

RUNTYPES=(ZMM ZEE ZTT TTbar)
PILEUPS=(noPU PU)

echo
echo "============================================================"
echo "Campaign configuration"
echo "============================================================"
echo "Target release:    ${TARGET_REL}"
echo "Reference release: ${REF_REL}"
echo "Target GT:         ${TARGET_GT}"
echo "Reference GT:      ${REF_GT}"
echo "Geometry:          ${GEOM}"
echo "Dry-run outdir:    ${DRY_OUTDIR}"
echo "Real-run outdir:   ${OUTDIR}"

# ============================================================
# Sanity checks
# ============================================================

python3 -m py_compile tau_relval_auto_compare.py

grep -n "dataset_version\|candidate fallback pairs\|Attempt .*for\|fallback" tau_relval_auto_compare.py
grep -n "DEFAULT_REJECT" tau_relval_auto_compare.py

# ============================================================
# Dry-run first: check which pairs it will try
# ============================================================

python3 tau_relval_auto_compare.py \
  --target-release "${TARGET_REL}" \
  --ref-release "${REF_REL}" \
  --runtype "${RUNTYPES[@]}" \
  --pileups "${PILEUPS[@]}" \
  --target-contains "${GEOM}" \
  --ref-contains "${GEOM}" \
  --dry-run \
  --outdir "${DRY_OUTDIR}"

# ============================================================
# Real run: produce ROOT files and plots
# ============================================================

python3 tau_relval_auto_compare.py \
  --target-release "${TARGET_REL}" \
  --ref-release "${REF_REL}" \
  --runtype "${RUNTYPES[@]}" \
  --pileups "${PILEUPS[@]}" \
  --target-contains "${GEOM}" \
  --ref-contains "${GEOM}" \
  --keep-going \
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
grep -E "${TARGET_REL}|${REF_REL}|${TARGET_GT}|${REF_GT}|${GEOM}|MINIAODSIM" "${OUTDIR}/status.tsv" || true