cd /eos/home-s/smeriano/UCLouvain/TAU_RELVAL/CMSSW_17_0_0_pre1/src/TauReleaseValidation

# If not already done in this shell:
cmsenv

# Sanity check that fallback patch is there
python3 -m py_compile tau_relval_auto_compare.py
grep -n "dataset_version\|candidate fallback pairs\|Attempt .*for\|fallback" tau_relval_auto_compare.py
grep -n "DEFAULT_REJECT" tau_relval_auto_compare.py

# Dry-run first: check which pairs it will try
python3 tau_relval_auto_compare.py \
  --target-release CMSSW_17_0_0_pre1 \
  --ref-release CMSSW_16_0_0_pre4 \
  --runtype ZMM ZEE ZTT TTbar \
  --pileups PU \
  --target-contains mcRun3 \
  --ref-contains mcRun3 \
  --dry-run \
  --outdir tau_relval_auto_outputs_MC_Run3_noPU_fallback_test

# Real run: produce ROOT files and plots. 
 python3 tau_relval_auto_compare.py \
  --target-release CMSSW_17_0_0_pre1 \
  --ref-release CMSSW_16_0_0_pre4 \
  --runtype ZMM ZEE ZTT TTbar \
  --pileups PU \
  --target-contains mcRun3 \
  --ref-contains mcRun3 \
  --keep-going \
  --outdir tau_relval_auto_outputs_MC_Run3

# Summary
echo
echo "============================================================"
echo "Status"
echo "============================================================"
column -t -s $'\t' tau_relval_auto_outputs_MC_Run3/status.tsv

echo
echo "============================================================"
echo "Plot folders"
echo "============================================================"
find tau_relval_auto_outputs_MC_Run3/plots -maxdepth 1 -type d | sort

echo
echo "============================================================"
echo "PNG count"
echo "============================================================"
find tau_relval_auto_outputs_MC_Run3/plots -name "*.png" | wc -l

echo
echo "============================================================"
echo "Tarballs"
echo "============================================================"
ls -lh tau_relval_auto_outputs_MC_Run3/tars/*.tar.gz 2>/dev/null || true