#!/bin/bash
#SBATCH --job-name=fptup_build_dev
#SBATCH --output=build_dev_%j.out
#SBATCH --error=build_dev_%j.err
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --partition=build
#SBATCH --account=pi-chihway
#
# Task cfastpt-cubic-upsampling-20260924: OUT-OF-TREE development builds of the des_y3
# CosmoLike interface from the working tree (uncommitted core + interface edits), so the
# production interface/cosmolike_des_y3_interface.so is not touched (operator memory
# feedback_debug_so_shadowing.md). Environment and checks copied from
# ppe/desy3_ellprefactor_growthk/compile_des_y3.sbatch (validated, job 59485356); instead
# of scripts/compile_des_y3.sh (which builds in interface/), make runs on copies of
# interface.cpp, interface.hpp and MakefileCosmolike in two folders:
#   chains/build_dev_<job>/opt    default flags (-O3 -march=native, strict IEEE)
#   chains/build_dev_<job>/debug  COSMOLIKE_DEBUG_MODE=1 (-O0 -g -W -Wall -Wextra -pedantic)
# Use a build with   export PYTHONPATH=<folder>:$PYTHONPATH   after start_cocoa.sh.
# The working-tree diffs used are saved next to the builds (cocoa.diff, des_y3.diff).
# Submit from this folder. Gold 6248R only (-march=native).

set -o pipefail   # never set -u (conda activate breaks); set +e around CoCoA scripts

CONDA_BASE=${CONDA_BASE:-/project/chihway/junzhou/miniconda3}

fail () { echo "RESULT: FAILED $*"; exit 1; }

echo "Date:        $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Host:        $(hostname)"
echo "CPU:         $(grep -m1 'model name' /proc/cpuinfo)"
echo "Job:         ${SLURM_JOB_ID} partition=${SLURM_JOB_PARTITION} cpus=${SLURM_CPUS_PER_TASK}"
grep -q 'Gold 6248R' /proc/cpuinfo || { echo "RESULT: FAILED not a Gold 6248R node"; exit 3; }

case "${SLURM_SUBMIT_DIR}" in
  */projects/des_y3/ppe/cfastpt_cubic_upsampling) ;;
  *) fail "submit from projects/des_y3/ppe/cfastpt_cubic_upsampling (got ${SLURM_SUBMIT_DIR})" ;;
esac
WORK=${SLURM_SUBMIT_DIR}
DES_ROOT=$(cd "${WORK}/../.." && pwd -P)
COCOA_ROOT=$(cd "${DES_ROOT}/../.." && pwd -P)
ROOT=$(cd "${COCOA_ROOT}/../.." && pwd -P)
SO=${DES_ROOT}/interface/cosmolike_des_y3_interface.so
BUILD=${WORK}/chains/build_dev_${SLURM_JOB_ID}
echo "DES_ROOT=${DES_ROOT}"; echo "COCOA_ROOT=${COCOA_ROOT}"; echo "BUILD=${BUILD}"
[[ -e "${BUILD}" ]] && fail "build folder exists: ${BUILD}"
mkdir -p "${BUILD}/opt" "${BUILD}/debug" || fail "mkdir ${BUILD}"

source "${CONDA_BASE}/etc/profile.d/conda.sh" || fail "conda.sh"
conda activate cocoa || fail "conda activate cocoa"

echo "=== CODE STATE ==="
python "${ROOT}/python_scripts/repo_tools/snapshot_repos.py"
echo "--- cocoa status ---";  git -C "${ROOT}/cocoa" status --short
echo "--- des_y3 status ---"; git -C "${DES_ROOT}" status --short
git -C "${ROOT}/cocoa" diff > "${BUILD}/cocoa.diff"
git -C "${DES_ROOT}" diff > "${BUILD}/des_y3.diff"
sha256sum "${BUILD}/cocoa.diff" "${BUILD}/des_y3.diff"
echo "production .so (must not change):"; ls -la --time-style=full-iso "${SO}"; SO_SHA_BEFORE=$(sha256sum "${SO}"); echo "${SO_SHA_BEFORE}"
for d in opt debug; do
  cp "${DES_ROOT}/interface/interface.cpp" "${DES_ROOT}/interface/interface.hpp" \
     "${DES_ROOT}/interface/MakefileCosmolike" "${BUILD}/${d}/" || fail "copy sources to ${d}"
done
sha256sum "${BUILD}"/opt/interface.cpp "${BUILD}"/opt/interface.hpp "${BUILD}"/opt/MakefileCosmolike

unset ROOTDIR
cd "${COCOA_ROOT}" || fail "cd ${COCOA_ROOT}"
set +e
source start_cocoa.sh
RC_START=$?
set +e
echo "START_COCOA_RC=${RC_START}  ROOTDIR=${ROOTDIR}"
[[ -n "${ROOTDIR}" ]] || fail "start_cocoa.sh did not set ROOTDIR"
ls -la "${ROOTDIR}/external_modules/code/" | grep -E 'cosmolike|cfastpt|cfftlog|log.c'
echo "C_COMPILER=${C_COMPILER} CXX_COMPILER=${CXX_COMPILER}"

STATUS=OK; WHY=""
for d in opt debug; do
  cd "${BUILD}/${d}" || fail "cd ${BUILD}/${d}"
  T0=$(date +%s)
  if [[ ${d} == debug ]]; then
    COSMOLIKE_DEBUG_MODE=1 make -j "${SLURM_CPUS_PER_TASK}" -f MakefileCosmolike all > make.out.log 2> make.err.log
  else
    make -j "${SLURM_CPUS_PER_TASK}" -f MakefileCosmolike all > make.out.log 2> make.err.log
  fi
  RC=$?
  echo "MAKE_${d}_RC=${RC}  ($(( $(date +%s) - T0 )) s)"
  echo "--- ${d} make stdout ($(wc -l < make.out.log) lines), last lines ---"; tail -3 make.out.log | cut -c1-300
  echo "--- ${d} make stderr ($(wc -l < make.err.log) lines), last lines ---"; tail -20 make.err.log | cut -c1-300
  [[ ${RC} -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} make ${d} rc=${RC};"; }
  NERR=$(grep -E -c 'error:|Error [0-9]+|undefined reference|No rule to make target|fatal' make.out.log make.err.log | awk -F: '{s+=$NF} END{print s+0}')
  echo "MAKE_${d}_ERROR_LINES=${NERR}  MAKE_${d}_WARNING_LINES=$(grep -c 'warning:' make.err.log)"
  [[ ${NERR} -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} ${NERR} error lines (${d});"; }
  echo "--- ${d}: warnings in the changed files (pt_cfastpt.c, generic_interface.cpp init_FPTIA_upsampling, interface.cpp) ---"
  grep -n -E 'pt_cfastpt\.c|init_FPTIA_upsampling|FPTupsample' make.err.log | cut -c1-300
  [[ -s cosmolike_des_y3_interface.so ]] || { STATUS=FAILED; WHY="${WHY} no .so (${d});"; }
  ls -la --time-style=full-iso cosmolike_des_y3_interface.so 2>&1
done
cd "${COCOA_ROOT}" || fail "cd ${COCOA_ROOT}"

echo "=== IMPORT CHECKS (each build shadowing the production .so) ==="
export OMP_NUM_THREADS=1
for d in opt debug; do
  PYTHONPATH="${BUILD}/${d}:${PYTHONPATH}" python - "${BUILD}/${d}" <<'PY'
import os, subprocess, sys
import cosmolike_des_y3_interface as ci
d = os.path.realpath(sys.argv[1])
f = os.path.realpath(ci.__file__)
print("INTERFACE_SO", f)
ok = os.path.dirname(f) == d
print("INTERFACE_SO_IS_THIS_BUILD", ok)
for name in ("init_FPTIA_upsampling", "set_growth_ia", "init_point_mass_model", "set_nuisance_clustering_photoz_stretch"):
    print("HAS", name, hasattr(ci, name)); ok &= hasattr(ci, name)
ci.init_FPTIA_upsampling(factor=1)
ci.init_FPTIA_upsampling(factor=8)
ci.init_FPTIA_upsampling(factor=1)
print("init_FPTIA_upsampling(1, 8, 1) returned")
# factor 0 must be rejected (critical message + exit 1), in a child process
code = "import cosmolike_des_y3_interface as ci; ci.init_FPTIA_upsampling(factor=0); print('NOT REJECTED')"
p = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
print("factor=0 -> exit code", p.returncode, "| stdout", p.stdout.strip()[-200:], "| stderr", p.stderr.strip()[-300:])
ok &= p.returncode != 0 and "NOT REJECTED" not in p.stdout
# a float must be refused by the binding (noconvert)
try:
    ci.init_FPTIA_upsampling(factor=2.0)
    print("float accepted"); ok = False
except TypeError as e:
    print("float refused: TypeError")
sys.exit(0 if ok else 1)
PY
  RC=$?
  echo "IMPORT_${d}_RC=${RC}"
  [[ ${RC} -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} import check ${d};"; }
done

echo "=== PRODUCTION .so ==="
SO_SHA_AFTER=$(sha256sum "${SO}"); echo "${SO_SHA_AFTER}"
[[ "${SO_SHA_BEFORE}" == "${SO_SHA_AFTER}" ]] && echo "PRODUCTION_SO_UNCHANGED yes" || { echo "PRODUCTION_SO_UNCHANGED NO"; STATUS=FAILED; WHY="${WHY} production .so changed;"; }
echo "=== SHA256 ==="
sha256sum "${BUILD}"/*/cosmolike_des_y3_interface.so "${BUILD}"/*/make.*.log 2>&1

set +e
source "${COCOA_ROOT}/stop_cocoa.sh" >/dev/null 2>&1
echo "End:         $(date '+%Y-%m-%d %H:%M:%S %Z')"
if [[ ${STATUS} == OK ]]; then echo "RESULT: OK"; exit 0; else echo "RESULT: FAILED${WHY}"; exit 1; fi
