#!/usr/bin/env bash
set -uo pipefail

TARGET_REL="CMSSW_17_0_0"
REF_REL="CMSSW_17_0_0_pre7"

TARGET_GT="160X_mcRun3_2026_realistic_v6"
REF_GT="160X_mcRun3_2026_realistic_v6"

DRY_OUTDIR="tau_relval_auto_outputs_17_0_0_vs_pre7_Run3_2026_dryrun"
OUTDIR="tau_relval_auto_outputs_MC_17_0_0_vs_pre7_Run3_2026"

DRY_RUN="${DRY_RUN:-1}"
FORCE="${FORCE:-0}"

RUNTYPES=(ZMM ZEE ZTT TTbar)
PILEUPS=(noPU PU)

MVAIDS=(
  deepTauIDv2p5VSe
  deepTauIDv2p5VSmu
  deepTauIDv2p5VSjet
)

FORCE_ARGS=()
if [[ "${FORCE}" == "1" ]]; then
  FORCE_ARGS+=(--force)
fi

case "${DRY_RUN}" in
  0|1) ;;
  *)
    echo "ERROR: DRY_RUN must be 0 or 1." >&2
    exit 1
    ;;
esac

cd "/eos/user/s/smeriano/UCLouvain/TAU_RELVAL/${TARGET_REL}/src/TauReleaseValidation_MC2026" || exit 1

RUNTIME="$(scram runtime -sh)" || exit 1
eval "${RUNTIME}" || exit 1

if [[ "${CMSSW_VERSION:-}" != "${TARGET_REL}" ]]; then
  echo "ERROR: expected ${TARGET_REL}, found ${CMSSW_VERSION:-unset}" >&2
  exit 1
fi

python3 -m py_compile tau_relval_auto_compare.py || exit 1

echo "Target: ${TARGET_REL}"
echo "Reference: ${REF_REL}"
echo "Target GT: ${TARGET_GT}"
echo "Reference GT: ${REF_GT}"
echo "Dry-run only: ${DRY_RUN}"
echo "Force regeneration: ${FORCE}"

COMMON_ARGS=(
  --target-release "${TARGET_REL}"
  --ref-release "${REF_REL}"
  --runtype "${RUNTYPES[@]}"
  --pileups "${PILEUPS[@]}"
  --data-format MINIAODSIM
  --target-contains "${TARGET_GT}"
  --ref-contains "${REF_GT}"
  --produce-gt "${TARGET_GT}"
  --reject-contains GPUvsCPU G4VECGEOM FastSIM FastSim ReHLT RecoOnly HIN BPH
  --mvaid "${MVAIDS[0]}"
  --mvaid "${MVAIDS[1]}"
  --mvaid "${MVAIDS[2]}"
)

# Dry run
python3 tau_relval_auto_compare.py \
  "${COMMON_ARGS[@]}" \
  --dry-run \
  --outdir "${DRY_OUTDIR}"

DRY_STATUS=$?
if [[ "${DRY_STATUS}" -ne 0 ]]; then
  echo "Dry-run failed; stopping." >&2
  exit "${DRY_STATUS}"
fi

column -t -s $'\t' "${DRY_OUTDIR}/status.tsv"

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "Dry-run complete. Inspect the selected pairs before production."
  exit 0
fi

# Production
python3 tau_relval_auto_compare.py \
  "${COMMON_ARGS[@]}" \
  --keep-going \
  "${FORCE_ARGS[@]}" \
  --outdir "${OUTDIR}"

RUN_STATUS=$?

# Summary
if [[ -f "${OUTDIR}/status.tsv" ]]; then
  echo
  echo "Status:"
  column -t -s $'\t' "${OUTDIR}/status.tsv"
fi

if [[ -d "${OUTDIR}/plots" ]]; then
  echo
  echo "Plot folders:"
  find "${OUTDIR}/plots" -maxdepth 1 -type d | sort

  echo
  echo "PNG count:"
  find "${OUTDIR}/plots" -name '*.png' | wc -l
fi

echo
echo "Tarballs:"
ls -lh "${OUTDIR}/tars/"*.tar.gz 2>/dev/null || true

exit "${RUN_STATUS}"