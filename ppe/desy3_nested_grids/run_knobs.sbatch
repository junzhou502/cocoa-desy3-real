#!/bin/bash
#SBATCH --job-name=ng_runs
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --partition=kicp
#SBATCH --account=kicp
#SBATCH --qos=kicp
#SBATCH --output=/project/chihway/junzhou/Project-Projection-Effect/cocoa/Cocoa/projects/des_y3/ppe/desy3_nested_grids/chains/%x_%j.out
#SBATCH --error=/project/chihway/junzhou/Project-Projection-Effect/cocoa/Cocoa/projects/des_y3/ppe/desy3_nested_grids/chains/%x_%j.err
#
# Task desy3-nested-grids-convergence-20260924: copy of ppe/cfastpt_cubic_upsampling/run_knobs.sbatch
# (validated, jobs 59498861/59499413/59500675); only the job name, the output folder and the {W}
# placeholder differ. CoCoA DES Y3 MagLim evaluations listed in a run list, then byte checks. Environment, threading and protected-file checks copied from
# python_scripts/desy3_tatt_crosspipeline/run_cocoa_points.sbatch (validated, jobs
# 59486353/59486354) and python_scripts/cocoa_multieval_bug/run_proof.sbatch (job 59493095).
#   RUNLIST=<file>   one run per line ('#' comments):
#       knobs    <name> <threads> <run_knobs.py args>       (python_scripts/cfastpt_cubic_upsampling)
#       knobsdbg <name> <threads> <run_knobs.py args>       same, with the DEBUG build of SO_DIR/../debug
#       knobsso  <name> <so folder> <threads> <run_knobs.py args>   same, with the .so of <so folder>
#       knobsasan <name> <so folder> <threads> <run_knobs.py args>  same, sanitizer build: LD_PRELOAD=libasan.so,
#                ASAN_OPTIONS=detect_leaks=0:halt_on_error=0, UBSAN_OPTIONS=print_stacktrace=1
#       diag     <name> <yaml> <plan>                       (python_scripts/cocoa_multieval_bug/diag_multieval.py)
#     placeholders: {YDIR} = ppe/desy3_ellprefactor_growthk, {TXP} = python_scripts/desy3_tatt_crosspipeline,
#                   {TX} = python_scripts/cfastpt_cubic_upsampling, {MEV} = python_scripts/cocoa_multieval_bug,
#                   {W} = ppe/desy3_nested_grids
#   CHECKS=<file>    check_bytes.py checks file ({J} = this job's folder)
#   SO_DIR=<folder>  optional: a build folder put first on PYTHONPATH (out-of-tree .so); the
#                    job fails unless the interface imported is that one. Empty = production .so.
# Outputs (ignored by des_y3 `chains/`): ppe/desy3_nested_grids/chains/<job>_<id>/<name>/.
# ONE CoCoA job at a time (stop_cocoa.sh removes the project links of other jobs, STATE.md C15).
set -o pipefail   # never set -u; set +e around CoCoA scripts

ROOT=/project/chihway/junzhou/Project-Projection-Effect
COCOA_ROOT=$ROOT/cocoa/Cocoa
DES_ROOT=$COCOA_ROOT/projects/des_y3
TX=$ROOT/python_scripts/cfastpt_cubic_upsampling
TXP=$ROOT/python_scripts/desy3_tatt_crosspipeline
MEV=$ROOT/python_scripts/cocoa_multieval_bug
YDIR=$DES_ROOT/ppe/desy3_ellprefactor_growthk
SO=$DES_ROOT/interface/cosmolike_des_y3_interface.so
JOBDIR=$DES_ROOT/ppe/desy3_nested_grids/chains/${SLURM_JOB_NAME}_${SLURM_JOB_ID}

fail () { echo "RESULT: FAILED $*"; exit 1; }
echo "Date:        $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Host:        $(hostname)"
echo "CPU:         $(grep -m1 'model name' /proc/cpuinfo)"
echo "Job:         ${SLURM_JOB_ID} partition=${SLURM_JOB_PARTITION} cpus=${SLURM_CPUS_PER_TASK}"
grep -q 'Gold 6248R' /proc/cpuinfo || { echo "RESULT: FAILED not a Gold 6248R node"; exit 3; }
[[ -s "${RUNLIST}" ]] || fail "RUNLIST not set or empty"
[[ -z "${CHECKS}" || -s "${CHECKS}" ]] || fail "CHECKS file missing: ${CHECKS}"
echo "RUNLIST=${RUNLIST}"; echo "CHECKS=${CHECKS}"; echo "SO_DIR=${SO_DIR}"
[[ -e "${JOBDIR}" ]] && fail "output folder exists: ${JOBDIR}"
if [[ -n "${SO_DIR}" ]]; then [[ -s "${SO_DIR}/cosmolike_des_y3_interface.so" ]] || fail "no .so in ${SO_DIR}"; fi
echo "=== RUNLIST ==="; cat "${RUNLIST}"

PROTECTED=( "${SO}" "${DES_ROOT}"/data/maglim_* "${DES_ROOT}"/likelihood/*.py "${DES_ROOT}"/likelihood/*.yaml
            "${YDIR}"/*.yaml "${YDIR}"/chains/*/*.modelvector "${TX}"/*.py "${TX}"/*.json "${TX}"/plans/*.json "${TXP}"/*.py "${TXP}"/*.json
            "${MEV}"/*.py "${MEV}"/plans/*.json "${RUNLIST}"
            "${DES_ROOT}"/ppe/desy3_tatt_crosspipeline/chains/tx_ccG1_59486353/F*/*/*.modelvector
            "${DES_ROOT}"/ppe/desy3_tatt_crosspipeline/chains/tx_ccG2_59486354/*/*/*.modelvector )
[[ -n "${CHECKS}" ]] && PROTECTED+=( "${CHECKS}" )
[[ -n "${SO_DIR}" ]] && PROTECTED+=( "${SO_DIR}/cosmolike_des_y3_interface.so" )
PROTECTED+=( "${DES_ROOT}"/ppe/desy3_nested_grids/chains/build_*/*/cosmolike_des_y3_interface.so )
SHA_BEFORE=$(sha256sum "${PROTECTED[@]}")
echo "=== SHA256 OF INPUTS (before; $(echo "${SHA_BEFORE}" | wc -l) files) ==="; echo "${SHA_BEFORE}" | grep -v -E '/tx_ccG[12]_|chains/[^/]*/[^/]*\.modelvector$'
echo "(reference model vectors: $(echo "${SHA_BEFORE}" | grep -c -E '/tx_ccG[12]_|chains/[^/]*/[^/]*\.modelvector$') files, digest $(echo "${SHA_BEFORE}" | sha256sum | cut -c1-16))"

source /project/chihway/junzhou/miniconda3/etc/profile.d/conda.sh || fail "conda.sh"
conda activate cocoa || fail "conda activate cocoa"
echo "=== CODE STATE ==="
python "${ROOT}/python_scripts/repo_tools/snapshot_repos.py"
COCOA_ST_BEFORE=$(git -C "${ROOT}/cocoa" status --porcelain); DES_ST_BEFORE=$(git -C "${DES_ROOT}" status --porcelain)
echo "--- cocoa status ---"; echo "${COCOA_ST_BEFORE}"
echo "--- des_y3 status ---"; echo "${DES_ST_BEFORE}"
echo "cocoa diff sha256 $(git -C "${ROOT}/cocoa" diff | sha256sum | cut -c1-64)"
echo "des_y3 diff sha256 $(git -C "${DES_ROOT}" diff | sha256sum | cut -c1-64)"

unset ROOTDIR
cd "${COCOA_ROOT}" || fail "cd ${COCOA_ROOT}"
set +e
source start_cocoa.sh
echo "START_COCOA_RC=$?  ROOTDIR=${ROOTDIR}"
set +e
[[ -n "${ROOTDIR}" ]] || fail "start_cocoa.sh did not set ROOTDIR"
export OMP_PROC_BIND=close OMP_PLACES=cores OMP_DYNAMIC=FALSE
export PYTHONDONTWRITEBYTECODE=1
BASE_PYTHONPATH=${PYTHONPATH}
[[ -n "${SO_DIR}" ]] && export PYTHONPATH=${SO_DIR}:${BASE_PYTHONPATH}
echo "affinity: $(taskset -pc $$)  PYTHONPATH=${PYTHONPATH}"
EXPECT_SO=${SO}; [[ -n "${SO_DIR}" ]] && EXPECT_SO=${SO_DIR}/cosmolike_des_y3_interface.so
python - "${EXPECT_SO}" <<'PY' || fail "interface check"
import os, sys
import cosmolike_des_y3_interface as ci
f = os.path.realpath(ci.__file__)
print("INTERFACE_SO", f, "expected", os.path.realpath(sys.argv[1]), "HAS_init_FPTIA_upsampling", hasattr(ci, "init_FPTIA_upsampling"))
sys.exit(0 if f == os.path.realpath(sys.argv[1]) and hasattr(ci, "init_FPTIA_upsampling") else 1)
PY

mkdir -p "${JOBDIR}" || fail "mkdir ${JOBDIR}"
STATUS=OK; WHY=""
WDIR=${DES_ROOT}/ppe/desy3_nested_grids
sub () { local s=$1; s=${s//\{YDIR\}/${YDIR}}; s=${s//\{TXP\}/${TXP}}; s=${s//\{TX\}/${TX}}; s=${s//\{MEV\}/${MEV}}; s=${s//\{W\}/${WDIR}}; echo "$s"; }
ASAN_LIB=$(${C_COMPILER} -print-file-name=libasan.so)
while read -r LINE; do
  LINE=${LINE%%#*}; [[ -z "${LINE// /}" ]] && continue
  read -r KIND NAME REST <<< "${LINE}"
  REST=$(sub "${REST}")
  T0=$(date +%s)
  case "${KIND}" in
    knobs|knobsdbg)
      read -r THREADS ARGS <<< "${REST}"
      PP=${PYTHONPATH}
      [[ ${KIND} == knobsdbg ]] && PP=${SO_DIR}/../debug:${BASE_PYTHONPATH}
      echo "############ ${NAME}: OMP_NUM_THREADS=${THREADS} run_knobs.py ${ARGS}"
      # shellcheck disable=SC2086
      OMP_NUM_THREADS=${THREADS} PYTHONPATH=${PP} python "${TX}/run_knobs.py" --outdir "${JOBDIR}/${NAME}" --label "${NAME}" ${ARGS} \
        > "${JOBDIR}/${NAME}.log" 2>&1 < /dev/null
      RC=$? ;;
    knobsso|knobsasan)
      read -r SOD THREADS ARGS <<< "${REST}"
      [[ -s "${SOD}/cosmolike_des_y3_interface.so" ]] || { echo "no .so in ${SOD}"; RC=98; }
      PRE=""; [[ ${KIND} == knobsasan ]] && PRE=${ASAN_LIB}
      echo "############ ${NAME}: .so ${SOD} LD_PRELOAD=${PRE} OMP_NUM_THREADS=${THREADS} run_knobs.py ${ARGS}"
      # shellcheck disable=SC2086
      LD_PRELOAD=${PRE} ASAN_OPTIONS=detect_leaks=0:halt_on_error=0 UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=0 \
      OMP_NUM_THREADS=${THREADS} PYTHONPATH=${SOD}:${BASE_PYTHONPATH} python "${TX}/run_knobs.py" --outdir "${JOBDIR}/${NAME}" \
        --label "${NAME}" ${ARGS} > "${JOBDIR}/${NAME}.log" 2>&1 < /dev/null
      RC=$?
      grep -q "interface ${SOD}/cosmolike_des_y3_interface.so" "${JOBDIR}/${NAME}.log" || { echo "wrong interface in ${NAME}"; RC=97; }
      echo "SANITIZER_${NAME}: AddressSanitizer $(grep -c 'ERROR: AddressSanitizer' "${JOBDIR}/${NAME}.log") | runtime error $(grep -c 'runtime error' "${JOBDIR}/${NAME}.log")"
      ;;
    diag)
      read -r YAML PLAN <<< "${REST}"
      echo "############ ${NAME}: diag_multieval.py --yaml ${YAML} --plan ${PLAN}"
      OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK} python "${MEV}/diag_multieval.py" --yaml "${YAML}" --plan "${PLAN}" \
        --outdir "${JOBDIR}/${NAME}" > "${JOBDIR}/${NAME}.log" 2>&1 < /dev/null
      RC=$? ;;
    *) echo "unknown run kind ${KIND}"; RC=99 ;;
  esac
  echo "RUN_${NAME}_RC=${RC}  ($(( $(date +%s) - T0 )) s)  $(grep -h '^SUMMARY' "${JOBDIR}/${NAME}.log" | cut -c1-200)"
  [[ ${RC} -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} ${NAME} rc=${RC};"; tail -20 "${JOBDIR}/${NAME}.log"; }
done < "${RUNLIST}"

echo; echo "=== log scan ==="
HARD=$(cat "${JOBDIR}"/*.log | grep -E -c 'ERROR|Traceback|LoggedError|Segmentation|Illegal instruction|core dumped')
echo "HARD_ERROR_LINES=${HARD}"
[[ ${HARD} -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} hard error lines;"; grep -n -E 'ERROR|Traceback|LoggedError|Segmentation|Illegal' "${JOBDIR}"/*.log | head; }
echo "--- soft pattern lines (Error|nan|inf|not found|warn), unique ---"
cat "${JOBDIR}"/*.log | grep -E -i 'error|\bnan\b|\binf\b|not found|warn' | sort | uniq -c | head -20
echo "--- fptia_upsampling lines, unique ---"
cat "${JOBDIR}"/*.log | grep -o 'fptia_upsampling = [0-9]*' | sort | uniq -c

if [[ -n "${CHECKS}" ]]; then
  echo; echo "############ BYTE CHECKS ############"
  python "${TX}/check_bytes.py" "${CHECKS}" "${JOBDIR}" | tee "${JOBDIR}/byte_checks.txt"
  grep -q "BYTE_CHECKS_ALL_OK True" "${JOBDIR}/byte_checks.txt" || { STATUS=FAILED; WHY="${WHY} byte checks;"; }
fi

echo; echo "=== SHA256 OF INPUTS (after) ==="
SHA_AFTER=$(sha256sum "${PROTECTED[@]}")
if [[ "${SHA_BEFORE}" == "${SHA_AFTER}" ]]; then echo "PROTECTED_UNCHANGED yes"; else
  echo "PROTECTED_UNCHANGED NO"; diff <(echo "${SHA_BEFORE}") <(echo "${SHA_AFTER}"); STATUS=FAILED; WHY="${WHY} protected changed;"; fi
COCOA_ST_AFTER=$(git -C "${ROOT}/cocoa" status --porcelain); DES_ST_AFTER=$(git -C "${DES_ROOT}" status --porcelain)
[[ "${COCOA_ST_AFTER}" == "${COCOA_ST_BEFORE}" && "${DES_ST_AFTER}" == "${DES_ST_BEFORE}" ]] && echo "REPO_STATUS_UNCHANGED yes" \
  || { echo "REPO_STATUS_UNCHANGED NO"; STATUS=FAILED; WHY="${WHY} repo status changed;"; }
echo "files: $(find "${JOBDIR}" -type f | wc -l)"
sha256sum "${JOBDIR}"/*.log "${JOBDIR}"/*.txt 2>/dev/null | sed "s|${JOBDIR}/||"
set +e
source "${COCOA_ROOT}/stop_cocoa.sh" >/dev/null 2>&1
echo "End:         $(date '+%Y-%m-%d %H:%M:%S %Z')"
if [[ ${STATUS} == OK ]]; then echo "RESULT: OK"; exit 0; else echo "RESULT: FAILED${WHY}"; exit 1; fi
