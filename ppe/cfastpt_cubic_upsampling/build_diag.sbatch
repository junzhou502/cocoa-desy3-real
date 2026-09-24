#!/bin/bash
#SBATCH --job-name=fptup_build_diag
#SBATCH --output=build_diag_%j.out
#SBATCH --error=build_diag_%j.err
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --partition=build
#SBATCH --account=pi-chihway
#
# Task cfastpt-cubic-upsampling-20260924: OUT-OF-TREE DIAGNOSTIC builds, same sources and
# checks as build_dev.sbatch (job 59497542), different compiler flags, to localise why the
# -O0 DEBUG build and the default -O3 build differ in the TATT vectors (job 59498280):
#   chains/build_diag_<job>/nofma  default flags + -ffp-contract=off (no fused multiply-add)
#   chains/build_diag_<job>/asan   -O1 -g + AddressSanitizer and UndefinedBehaviorSanitizer
#                                  (run with LD_PRELOAD=libasan.so, see run_knobs.sbatch)
# Only the copied MakefileCosmolike line "COMMON_FLAGS += -O3 -march=native ..." is edited.
# Use a build with   export PYTHONPATH=<folder>:$PYTHONPATH   after start_cocoa.sh.
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
BUILD=${WORK}/chains/build_diag_${SLURM_JOB_ID}
VARIANTS="nofma asan"
echo "DES_ROOT=${DES_ROOT}"; echo "COCOA_ROOT=${COCOA_ROOT}"; echo "BUILD=${BUILD}"
[[ -e "${BUILD}" ]] && fail "build folder exists: ${BUILD}"
for d in ${VARIANTS}; do mkdir -p "${BUILD}/${d}" || fail "mkdir ${BUILD}/${d}"; done

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
OPTLINE='COMMON_FLAGS += -O3 -march=native -fno-fast-math -fno-associative-math -frounding-math'
[[ $(grep -c -F "${OPTLINE}" "${DES_ROOT}/interface/MakefileCosmolike") -eq 1 ]] || fail "optimisation line not found once"
for d in ${VARIANTS}; do
  cp "${DES_ROOT}/interface/interface.cpp" "${DES_ROOT}/interface/interface.hpp" \
     "${DES_ROOT}/interface/MakefileCosmolike" "${BUILD}/${d}/" || fail "copy sources to ${d}"
done
sed -i "s|${OPTLINE}|${OPTLINE} -ffp-contract=off|" "${BUILD}/nofma/MakefileCosmolike"
sed -i "s|${OPTLINE}|COMMON_FLAGS += -O1 -g -march=native -fno-omit-frame-pointer -fsanitize=address,undefined -fsanitize-recover=all -fno-fast-math -fno-associative-math -frounding-math|" "${BUILD}/asan/MakefileCosmolike"
for d in ${VARIANTS}; do echo "--- ${d}: MakefileCosmolike vs the source ---"; diff "${DES_ROOT}/interface/MakefileCosmolike" "${BUILD}/${d}/MakefileCosmolike"; done
sha256sum "${BUILD}"/*/interface.cpp "${BUILD}"/*/interface.hpp "${BUILD}"/*/MakefileCosmolike

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
for d in ${VARIANTS}; do
  cd "${BUILD}/${d}" || fail "cd ${BUILD}/${d}"
  T0=$(date +%s)
  make -j "${SLURM_CPUS_PER_TASK}" -f MakefileCosmolike all > make.out.log 2> make.err.log
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
ASAN_LIB=$(${C_COMPILER} -print-file-name=libasan.so); echo "ASAN_LIB=${ASAN_LIB}"
for d in ${VARIANTS}; do
  PRE=""; [[ ${d} == asan ]] && PRE="${ASAN_LIB}"
  LD_PRELOAD="${PRE}" ASAN_OPTIONS=detect_leaks=0:halt_on_error=0 PYTHONPATH="${BUILD}/${d}:${PYTHONPATH}" python - "${BUILD}/${d}" <<'PY'
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
