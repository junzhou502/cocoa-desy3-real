#!/bin/bash
#SBATCH --job-name=desy3_compile
#SBATCH --output=compile_des_y3_%j.out
#SBATCH --error=compile_des_y3_%j.err
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --partition=build
#SBATCH --account=pi-chihway
#
# Task desy3-ellprefactor-growthk-20260924: copy of ppe/desy3_pointmass/compile_des_y3.sbatch
# (validated, job 59476962); only the work folder and the import check (new binding
# set_growth_ia) differ. That script was a copy of ppe/desy3_maglim/compile_des_y3.sbatch
# (validated, job 59474023).
# Template: compile the des_y3 CosmoLike interface (cosmolike_des_y3_interface.so)
# with CoCoA's own project compile script, capturing the full make output.
# Submit from this folder:   cd projects/des_y3/ppe/desy3_ellprefactor_growthk && sbatch compile_des_y3.sbatch
# The .so is built with -O3 -march=native: build and run only on Gold 6248R
# (Cascade Lake: kicp, caslake, build, bigmem).
# For kicp use: --partition=kicp --account=kicp --qos=kicp

set -o pipefail   # never set -u (conda activate breaks); set +e around CoCoA scripts

CONDA_BASE=${CONDA_BASE:-/project/chihway/junzhou/miniconda3}

fail () { echo "RESULT: FAILED $*"; exit 1; }

echo "Date:        $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Host:        $(hostname)"
echo "CPU:         $(grep -m1 'model name' /proc/cpuinfo)"
echo "Job:         ${SLURM_JOB_ID} partition=${SLURM_JOB_PARTITION} cpus=${SLURM_CPUS_PER_TASK}"
grep -q 'Gold 6248R' /proc/cpuinfo || { echo "RESULT: FAILED not a Gold 6248R node"; exit 3; }

# --- paths (derived from the submit folder, which must be ppe/desy3_ellprefactor_growthk) --
case "${SLURM_SUBMIT_DIR}" in
  */projects/des_y3/ppe/desy3_ellprefactor_growthk) ;;
  *) fail "submit from projects/des_y3/ppe/desy3_ellprefactor_growthk (got ${SLURM_SUBMIT_DIR})" ;;
esac
WORK=${SLURM_SUBMIT_DIR}
DES_ROOT=$(cd "${WORK}/../.." && pwd -P)
COCOA_ROOT=$(cd "${DES_ROOT}/../.." && pwd -P)
ROOT=$(cd "${COCOA_ROOT}/../.." && pwd -P)
SO=${DES_ROOT}/interface/cosmolike_des_y3_interface.so
MAKE_OUT=${WORK}/compile_des_y3_${SLURM_JOB_ID}.make.out.log
MAKE_ERR=${WORK}/compile_des_y3_${SLURM_JOB_ID}.make.err.log
echo "DES_ROOT=${DES_ROOT}"; echo "COCOA_ROOT=${COCOA_ROOT}"; echo "ROOT=${ROOT}"
for f in "${MAKE_OUT}" "${MAKE_ERR}"; do
  [[ -e "$f" ]] && fail "log exists: $f"
done

source "${CONDA_BASE}/etc/profile.d/conda.sh" || fail "conda.sh"
conda activate cocoa || fail "conda activate cocoa"

echo "=== CODE STATE (before) ==="
python "${ROOT}/python_scripts/repo_tools/snapshot_repos.py"
echo "--- des_y3 status ---";  git -C "${DES_ROOT}" status --short
echo "--- cocoa status (must be empty) ---"; COCOA_ST_BEFORE=$(git -C "${ROOT}/cocoa" status --porcelain); echo "${COCOA_ST_BEFORE}"
if [[ -e "${SO}" ]]; then
  echo "pre-existing .so (will be replaced by the compile script):"
  ls -la --time-style=full-iso "${SO}"; sha256sum "${SO}"
fi

# --- CoCoA environment -------------------------------------------------------
unset ROOTDIR          # a stale ROOTDIR makes start_cocoa.sh source stop_cocoa.sh
cd "${COCOA_ROOT}" || fail "cd ${COCOA_ROOT}"
set +e
source start_cocoa.sh
RC_START=$?
set +e
echo "START_COCOA_RC=${RC_START}  ROOTDIR=${ROOTDIR}"
[[ -n "${ROOTDIR}" ]] || fail "start_cocoa.sh did not set ROOTDIR"
echo "IGNORE_COSMOLIKE_LSSTY1_CODE='${IGNORE_COSMOLIKE_LSSTY1_CODE}' (des_y3 v4.05 compile gate; must be empty)"
echo "IGNORE_COSMOLIKE_DES_Y3_CODE='${IGNORE_COSMOLIKE_DES_Y3_CODE}'"

# CoCoA sends make output to OUT1/OUT2 = /dev/null by default: send it to files.
export OUT1="${MAKE_OUT}"
export OUT2="${MAKE_ERR}"
export MNT=${SLURM_CPUS_PER_TASK}

T0=$(date +%s)
set +e
source ./projects/des_y3/scripts/compile_des_y3.sh
RC_BUILD=$?
set +e
echo "COMPILE_DES_Y3_RC=${RC_BUILD}  ($(( $(date +%s) - T0 )) s)"
cd "${COCOA_ROOT}" || fail "cd ${COCOA_ROOT}"

echo "=== make stdout: ${MAKE_OUT} ($(wc -l < "${MAKE_OUT}") lines) ==="
tail -5 "${MAKE_OUT}" | cut -c1-400
echo "=== make stderr: ${MAKE_ERR} ($(wc -l < "${MAKE_ERR}") lines) ==="
tail -40 "${MAKE_ERR}" | cut -c1-400

STATUS=OK; WHY=""
[[ ${RC_BUILD} -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} compile rc=${RC_BUILD};"; }
[[ -s "${MAKE_OUT}" ]] || { STATUS=FAILED; WHY="${WHY} empty make log;"; }
NERR=$(grep -E -c 'error:|Error [0-9]+|undefined reference|No rule to make target|fatal' "${MAKE_OUT}" "${MAKE_ERR}" | awk -F: '{s+=$NF} END{print s+0}')
echo "MAKE_ERROR_LINES=${NERR}"
[[ ${NERR} -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} ${NERR} error lines in make logs;"; }
NWARN=$(grep -c 'warning:' "${MAKE_ERR}")
echo "MAKE_WARNING_LINES=${NWARN}"

if [[ -e "${SO}" ]]; then
  echo "=== BUILD ARTIFACT ==="
  ls -la --time-style=full-iso "${SO}"
  SO_MTIME=$(stat -c %Y "${SO}")
  [[ ${SO_MTIME} -ge ${T0} ]] || { STATUS=FAILED; WHY="${WHY} .so older than this build;"; }
  echo "=== IMPORT CHECK ==="
  export OMP_NUM_THREADS=1
  python - "${SO}" <<'PY'
import os, sys
import cosmolike_des_y3_interface as ci
so = os.path.realpath(sys.argv[1])
print("INTERFACE_SO", os.path.realpath(ci.__file__))
print("INTERFACE_SO_IS_BUILT_ONE", os.path.realpath(ci.__file__) == so)
print("HAS_STRETCH_SETTER", hasattr(ci, "set_nuisance_clustering_photoz_stretch"))
print("HAS_INIT_POINT_MASS_MODEL", hasattr(ci, "init_point_mass_model"))
print("HAS_SET_GROWTH_IA", hasattr(ci, "set_growth_ia"))
ok = (os.path.realpath(ci.__file__) == so and hasattr(ci, "set_nuisance_clustering_photoz_stretch")
      and hasattr(ci, "init_point_mass_model") and hasattr(ci, "set_growth_ia"))
sys.exit(0 if ok else 1)
PY
  RC_IMPORT=$?
  echo "IMPORT_RC=${RC_IMPORT}"
  [[ ${RC_IMPORT} -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} import check failed;"; }
else
  STATUS=FAILED; WHY="${WHY} .so not produced;"
fi

echo "=== CODE STATE (after) ==="
COCOA_ST_AFTER=$(git -C "${ROOT}/cocoa" status --porcelain)
echo "--- cocoa status (must be empty) ---"; echo "${COCOA_ST_AFTER}"
[[ -z "${COCOA_ST_AFTER}" && -z "${COCOA_ST_BEFORE}" ]] || { STATUS=FAILED; WHY="${WHY} cocoa repo not clean;"; }
echo "--- des_y3 status ---"; git -C "${DES_ROOT}" status --short

echo "=== SHA256 ==="
sha256sum "${SO}" "${MAKE_OUT}" "${MAKE_ERR}" 2>&1

set +e
source "${COCOA_ROOT}/stop_cocoa.sh" >/dev/null 2>&1
echo "End:         $(date '+%Y-%m-%d %H:%M:%S %Z')"
if [[ ${STATUS} == OK ]]; then
  echo "RESULT: OK"
  exit 0
else
  echo "RESULT: FAILED${WHY}"
  exit 1
fi
