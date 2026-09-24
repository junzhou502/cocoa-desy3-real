#!/bin/bash
#SBATCH --job-name=desy3_pm_eval
#SBATCH --output=evaluate_runs_%j.out
#SBATCH --error=evaluate_runs_%j.err
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --partition=kicp
#SBATCH --account=kicp
#SBATCH --qos=kicp
#
# Task desy3-ellprefactor-growthk-20260924: copy of ppe/desy3_pointmass/evaluate_runs.sbatch
# (validated, jobs 59476923/59477071); only the work folder and the set_growth_ia
# interface check differ. That script (task desy3-pointmass-comparison-20260924) is a
# copy of ppe/desy3_maglim/evaluate_maglim.sbatch (validated, job 59474070) with the run list, the expected interface API and the
# reference checks passed in by environment variables:
#   RUNS          space-separated yaml stems in this folder (required); each writes chains/<stem>/
#   EXPECT_PMM    1 if ci.init_point_mass_model must exist (after the port), 0 if it must not
#   BITWISE_PAIRS space-separated <stem>:<reference modelvector path>; must be byte-identical
#   REF_CHI2      space-separated <stem>:<chi2>; |chi2 - ref| must be 0 at the printed precision
# Submit from this folder, e.g.
#   sbatch --export=ALL,RUNS="a b",EXPECT_PMM=0,BITWISE_PAIRS="a:/path/x.modelvector" evaluate_runs.sbatch
# Output folders under chains/ must not exist; the job refuses to reuse them.
# CoCoA .so files are built with -march=native: Gold 6248R nodes only.

set -o pipefail   # never set -u (conda activate breaks); set +e around CoCoA scripts

CONDA_BASE=${CONDA_BASE:-/project/chihway/junzhou/miniconda3}

fail () { echo "RESULT: FAILED $*"; exit 1; }

echo "Date:        $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Host:        $(hostname)"
echo "CPU:         $(grep -m1 'model name' /proc/cpuinfo)"
echo "Job:         ${SLURM_JOB_ID} partition=${SLURM_JOB_PARTITION} cpus=${SLURM_CPUS_PER_TASK}"
grep -q 'Gold 6248R' /proc/cpuinfo || { echo "RESULT: FAILED not a Gold 6248R node"; exit 3; }

case "${SLURM_SUBMIT_DIR}" in
  */projects/des_y3/ppe/desy3_ellprefactor_growthk) ;;
  *) fail "submit from projects/des_y3/ppe/desy3_ellprefactor_growthk (got ${SLURM_SUBMIT_DIR})" ;;
esac
[[ -n "${RUNS}" ]] || fail "RUNS not set"
[[ "${EXPECT_PMM}" == 0 || "${EXPECT_PMM}" == 1 ]] || fail "EXPECT_PMM must be 0 or 1"
WORK=${SLURM_SUBMIT_DIR}
DES_ROOT=$(cd "${WORK}/../.." && pwd -P)
COCOA_ROOT=$(cd "${DES_ROOT}/../.." && pwd -P)
ROOT=$(cd "${COCOA_ROOT}/../.." && pwd -P)
SO=${DES_ROOT}/interface/cosmolike_des_y3_interface.so
CHAINS=${WORK}/chains
echo "DES_ROOT=${DES_ROOT}"
echo "RUNS=${RUNS}"; echo "EXPECT_PMM=${EXPECT_PMM}"
echo "BITWISE_PAIRS=${BITWISE_PAIRS:-<none>}"; echo "REF_CHI2=${REF_CHI2:-<none>}"

# Never reuse an output folder.
for r in ${RUNS}; do
  [[ -s "${WORK}/${r}.yaml" ]] || fail "missing ${WORK}/${r}.yaml"
  [[ -e "${CHAINS}/${r}" ]] && fail "output folder exists: ${CHAINS}/${r}"
done
[[ -s "${SO}" ]] || fail "missing ${SO}"
[[ -s "${DES_ROOT}/data/maglim_cov.txt" ]] || fail "missing data/maglim_cov.txt"

REFS=()
for p in ${BITWISE_PAIRS}; do REFS+=( "${p#*:}" ); done
for f in "${REFS[@]}"; do
  [[ "$f" == "${CHAINS}/"* ]] && continue      # produced earlier in this same job
  [[ -s "$f" ]] || fail "missing reference ${f}"
done
PROTECTED=( "${SO}" "${DES_ROOT}"/data/maglim_* "${DES_ROOT}"/likelihood/*.py "${DES_ROOT}"/likelihood/*.yaml
            "${DES_ROOT}"/ppe/desy3_maglim/*.yaml "${DES_ROOT}"/ppe/desy3_maglim/chains/*/*
            "${WORK}"/*.yaml )
for f in "${REFS[@]}"; do [[ "$f" == "${CHAINS}/"* ]] || PROTECTED+=( "$f" ); done
SHA_BEFORE=$(sha256sum "${PROTECTED[@]}")
echo "=== SHA256 OF INPUTS (before) ==="; echo "${SHA_BEFORE}"
ls -la --time-style=full-iso "${SO}"

source "${CONDA_BASE}/etc/profile.d/conda.sh" || fail "conda.sh"
conda activate cocoa || fail "conda activate cocoa"
echo "=== CODE STATE ==="
python "${ROOT}/python_scripts/repo_tools/snapshot_repos.py"
echo "--- des_y3 status ---"; git -C "${DES_ROOT}" status --short
echo "--- cocoa status (must be empty) ---"; COCOA_ST_BEFORE=$(git -C "${ROOT}/cocoa" status --porcelain); echo "${COCOA_ST_BEFORE}"

unset ROOTDIR
cd "${COCOA_ROOT}" || fail "cd ${COCOA_ROOT}"
set +e
source start_cocoa.sh
echo "START_COCOA_RC=$?  ROOTDIR=${ROOTDIR}"
set +e
[[ -n "${ROOTDIR}" ]] || fail "start_cocoa.sh did not set ROOTDIR"

# Same threading as the reference jobs 57931356 / 59474070.
export OMP_PROC_BIND=close
export OMP_PLACES=cores
export OMP_DYNAMIC=FALSE
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK}
echo "OMP_NUM_THREADS=${OMP_NUM_THREADS}  affinity: $(taskset -pc $$)"

echo "=== INTERFACE CHECK ==="
python - "${SO}" "${EXPECT_PMM}" <<'PY'
import os, sys
import cosmolike_des_y3_interface as ci
ok = os.path.realpath(ci.__file__) == os.path.realpath(sys.argv[1])
has = hasattr(ci, "init_point_mass_model")
print("INTERFACE_SO", os.path.realpath(ci.__file__), "is_expected", ok)
print("HAS_STRETCH_SETTER", hasattr(ci, "set_nuisance_clustering_photoz_stretch"))
print("HAS_INIT_POINT_MASS_MODEL", has, "expected", bool(int(sys.argv[2])))
print("HAS_SET_GROWTH_IA", hasattr(ci, "set_growth_ia"), "expected True")
sys.exit(0 if (ok and has == bool(int(sys.argv[2])) and hasattr(ci, "set_growth_ia")) else 1)
PY
[[ $? -eq 0 ]] || fail "interface check failed"

STATUS=OK; WHY=""
for r in ${RUNS}; do
  echo; echo "############ EVALUATE ${r} ############"
  mkdir -p "${CHAINS}/${r}"
  T0=$(date +%s)
  cobaya-run "./projects/des_y3/ppe/desy3_ellprefactor_growthk/${r}.yaml" 2>&1 | tee "${CHAINS}/${r}/cobaya_run.log"
  RC=$?
  echo "EVALUATE_${r}_RC=${RC}  ($(( $(date +%s) - T0 )) s)"
  [[ ${RC} -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} ${r} rc=${RC};"; }
  HARD=$(grep -E -c 'ERROR|Traceback|LoggedError|Segmentation|Illegal instruction' "${CHAINS}/${r}/cobaya_run.log")
  echo "LOG_HARD_ERROR_LINES_${r}=${HARD}"
  [[ ${HARD} -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} ${r} log has ${HARD} error lines;"; }
  echo "--- soft pattern lines (review: Error|nan|inf|not found) ---"
  grep -n -E 'Error|\bnan\b|\binf\b|not found' "${CHAINS}/${r}/cobaya_run.log" | cut -c1-200
  echo "--- point_mass_model lines ---"
  grep -n 'point_mass_model' "${CHAINS}/${r}/cobaya_run.log" "${CHAINS}/${r}/cobaya.updated.yaml" | cut -c1-200
done

echo; echo "############ CHECKS ############"
python - "${CHAINS}" "${DES_ROOT}/data" "${RUNS}" "${BITWISE_PAIRS}" "${REF_CHI2}" <<'PY'
import filecmp, os, sys
import numpy as np
chains, data, runs, pairs, refs = sys.argv[1], sys.argv[2], sys.argv[3].split(), sys.argv[4].split(), sys.argv[5].split()
ok = True
c = np.loadtxt(os.path.join(data, "maglim_cov.txt"))
n = int(c[:, 0].max()) + 1
cov = np.zeros((n, n)); cov[c[:, 0].astype(int), c[:, 1].astype(int)] = c[:, 2]
sig = np.sqrt(np.diag(cov))
ref_dv = np.loadtxt(os.path.join(data, "maglim_cosmosis_dv.txt"))[:, 1]
chi2s = {}
for run in runs:
    txt = os.path.join(chains, run, "cobaya.1.txt")
    with open(txt) as f:
        head = f.readline().lstrip("#").split()
    row = np.atleast_1d(np.loadtxt(txt)).ravel()
    d = dict(zip(head, row))
    chi2s[run] = d.get("chi2", np.nan)
    mvp = os.path.join(chains, run, run + ".modelvector")
    mv = np.loadtxt(mvp)
    th = mv[:, 1]
    fin = bool(np.all(np.isfinite(th))) and bool(np.all(np.isfinite(list(d.values()))))
    ok &= fin and mv.shape == (n, 2) and np.isfinite(chi2s[run])
    r = th - ref_dv
    print("RUN %-16s chi2 %.10g  n=%d  finite=%s  NumPy chi2 vs maglim_cosmosis_dv %.10g"
          % (run, chi2s[run], len(th), fin, float(r @ np.linalg.solve(cov, r))))
for p in pairs:
    run, ref = p.split(":", 1)
    new = os.path.join(chains, run, run + ".modelvector")
    same = filecmp.cmp(new, ref, shallow=False)
    a, b = np.loadtxt(new)[:, 1], np.loadtxt(ref)[:, 1]
    dd = a - b
    print("BITWISE %-16s vs %s : byte_identical=%s  n_diff=%d  max|d|/sigma=%.3e"
          % (run, ref, same, int(np.count_nonzero(dd)), float(np.max(np.abs(dd) / sig))))
    ok &= same
for p in refs:
    run, val = p.split(":", 1)
    diff = chi2s[run] - float(val)
    passed = diff == 0.0
    print("REF_CHI2 %-16s new %.10g ref %s diff %+.3e -> %s" % (run, chi2s[run], val, diff, "PASS" if passed else "FAIL"))
    ok &= passed
print("CHECKS_PASSED", ok)
sys.exit(0 if ok else 1)
PY
[[ $? -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} checks failed;"; }

echo; echo "=== SHA256 OF INPUTS (after) ==="
SHA_AFTER=$(sha256sum "${PROTECTED[@]}")
if [[ "${SHA_BEFORE}" == "${SHA_AFTER}" ]]; then echo "PROTECTED_UNCHANGED yes"; else
  echo "PROTECTED_UNCHANGED NO"; diff <(echo "${SHA_BEFORE}") <(echo "${SHA_AFTER}")
  STATUS=FAILED; WHY="${WHY} protected inputs changed;"; fi
COCOA_ST_AFTER=$(git -C "${ROOT}/cocoa" status --porcelain)
echo "--- cocoa status (must be empty) ---"; echo "${COCOA_ST_AFTER}"
[[ -z "${COCOA_ST_AFTER}" && -z "${COCOA_ST_BEFORE}" ]] || { STATUS=FAILED; WHY="${WHY} cocoa repo not clean;"; }
echo "--- des_y3 status ---"; git -C "${DES_ROOT}" status --short

echo "=== SHA256 OF PRODUCTS ==="
for r in ${RUNS}; do find "${CHAINS}/${r}" -type f -print0 | sort -z | xargs -0 sha256sum; done

set +e
source "${COCOA_ROOT}/stop_cocoa.sh" >/dev/null 2>&1
echo "End:         $(date '+%Y-%m-%d %H:%M:%S %Z')"
if [[ ${STATUS} == OK ]]; then echo "RESULT: OK"; exit 0; else echo "RESULT: FAILED${WHY}"; exit 1; fi
