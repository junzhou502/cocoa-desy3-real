#!/bin/bash
#SBATCH --job-name=desy3_maglim_inputs
#SBATCH --output=build_maglim_inputs_%j.out
#SBATCH --error=build_maglim_inputs_%j.err
#SBATCH --time=00:30:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --partition=kicp
#SBATCH --account=kicp
#SBATCH --qos=kicp
#
# Regenerate every DES Y3 MagLim input with scripts/build_maglim_inputs.py
# into node-local /tmp, compare each file with the tracked copy in data/ and,
# if given, with a reference folder (REFDIR, e.g. the legacy data/ folder),
# then install data/maglim_cov.txt (untracked, ~32 MB) if it is absent.
# Submit from this folder:
#   sbatch --export=ALL,RELEASE=<release.fits>,SIM=<noiseless.fits>,REFDIR=<dir> build_maglim_inputs.sbatch
# RELEASE is required; SIM (for maglim_cosmosis_dv.txt) and REFDIR are optional.

set -o pipefail   # never set -u (conda activate breaks)

CONDA_BASE=${CONDA_BASE:-/project/chihway/junzhou/miniconda3}
fail () { echo "RESULT: FAILED $*"; exit 1; }

echo "Date:        $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Host:        $(hostname)"
echo "CPU:         $(grep -m1 'model name' /proc/cpuinfo)"
echo "Job:         ${SLURM_JOB_ID} partition=${SLURM_JOB_PARTITION} cpus=${SLURM_CPUS_PER_TASK}"

case "${SLURM_SUBMIT_DIR}" in
  */projects/des_y3/ppe/desy3_maglim) ;;
  *) fail "submit from projects/des_y3/ppe/desy3_maglim (got ${SLURM_SUBMIT_DIR})" ;;
esac
WORK=${SLURM_SUBMIT_DIR}
DES_ROOT=$(cd "${WORK}/../.." && pwd -P)
ROOT=$(cd "${DES_ROOT}/../../../.." && pwd -P)
DATA=${DES_ROOT}/data
[[ -n "${RELEASE}" && -s "${RELEASE}" ]] || fail "RELEASE fits not given or missing: '${RELEASE}'"
echo "RELEASE=${RELEASE}"; echo "SIM=${SIM:-<none>}"; echo "REFDIR=${REFDIR:-<none>}"
sha256sum "${RELEASE}" ${SIM:+"${SIM}"}

source "${CONDA_BASE}/etc/profile.d/conda.sh" || fail "conda.sh"
conda activate cocoa || fail "conda activate cocoa"
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK} OPENBLAS_NUM_THREADS=${SLURM_CPUS_PER_TASK} MKL_NUM_THREADS=${SLURM_CPUS_PER_TASK}
python -c "import sys, numpy, astropy; print('python', sys.version.split()[0], 'numpy', numpy.__version__, 'astropy', astropy.__version__)"

echo "=== CODE STATE ==="
python "${ROOT}/python_scripts/repo_tools/snapshot_repos.py"
git -C "${DES_ROOT}" status --short

TMPOUT=$(mktemp -d "/tmp/maglim_inputs_${SLURM_JOB_ID}_XXXX") || fail "mktemp"
echo "TMPOUT=${TMPOUT}"
python "${DES_ROOT}/scripts/build_maglim_inputs.py" --release "${RELEASE}" \
    ${SIM:+--sim "${SIM}"} --outdir "${TMPOUT}"
RC_BUILD=$?
echo "BUILD_RC=${RC_BUILD}"
[[ ${RC_BUILD} -eq 0 ]] || fail "build_maglim_inputs.py rc=${RC_BUILD}"

STATUS=OK; WHY=""
echo "=== COMPARISON ==="
for f in maglim_lens.nz maglim_source.nz maglim_all.mask maglim_cov.txt maglim_cosmosis_dv.txt; do
  NEW=${TMPOUT}/$f
  [[ -e "${NEW}" ]] || { echo "SKIP $f (not generated)"; continue; }
  H_NEW=$(sha256sum "${NEW}" | cut -d' ' -f1)
  echo "NEW   $f sha256=${H_NEW} size=$(stat -c %s "${NEW}")"
  for REF in "${DATA}/$f" ${REFDIR:+"${REFDIR}/$f"}; do
    if [[ -e "${REF}" ]]; then
      H_REF=$(sha256sum "${REF}" | cut -d' ' -f1)
      if [[ "${H_NEW}" == "${H_REF}" ]]; then
        echo "  MATCH    ${REF}"
      else
        echo "  MISMATCH ${REF} sha256=${H_REF}"
        python - "${NEW}" "${REF}" <<'PY'
import sys, numpy as np
a, b = np.loadtxt(sys.argv[1]), np.loadtxt(sys.argv[2])
print("   shapes", a.shape, b.shape)
if a.shape == b.shape:
    d = np.abs(a - b)
    print("   max_abs_diff %.3e  max_rel_diff %.3e" % (d.max(), (d / np.maximum(np.abs(b), 1e-300)).max()))
PY
        STATUS=FAILED; WHY="${WHY} $f differs from ${REF};"
      fi
    else
      echo "  (no file ${REF})"
    fi
  done
done

echo "=== INSTALL data/maglim_cov.txt ==="
if [[ -e "${DATA}/maglim_cov.txt" ]]; then
  echo "data/maglim_cov.txt exists: not touched"
elif [[ ${STATUS} == OK && -s "${TMPOUT}/maglim_cov.txt" ]]; then
  cp -n "${TMPOUT}/maglim_cov.txt" "${DATA}/maglim_cov.txt" || fail "cp cov"
  cmp "${TMPOUT}/maglim_cov.txt" "${DATA}/maglim_cov.txt" || fail "cov copy differs"
  echo "installed ${DATA}/maglim_cov.txt"
else
  echo "NOT installed (status ${STATUS})"
fi
git -C "${DES_ROOT}" status --short
git -C "${DES_ROOT}" check-ignore -v "${DATA}/maglim_cov.txt" || { STATUS=FAILED; WHY="${WHY} maglim_cov.txt not git-ignored;"; }

# Clean up only the files this job wrote into its own node-local temp folder.
for f in maglim_lens.nz maglim_source.nz maglim_all.mask maglim_cov.txt maglim_cosmosis_dv.txt; do
  rm -f "${TMPOUT}/$f"
done
rmdir "${TMPOUT}"

echo "=== SHA256 ==="
sha256sum "${DATA}"/maglim_*
echo "End:         $(date '+%Y-%m-%d %H:%M:%S %Z')"
if [[ ${STATUS} == OK ]]; then echo "RESULT: OK"; exit 0; else echo "RESULT: FAILED${WHY}"; exit 1; fi
