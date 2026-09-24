#!/bin/bash
#SBATCH --job-name=desy3_maglim_eval
#SBATCH --output=evaluate_maglim_%j.out
#SBATCH --error=evaluate_maglim_%j.err
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=24
#SBATCH --partition=kicp
#SBATCH --account=kicp
#SBATCH --qos=kicp
#
# Template: run CoCoA des_y3 evaluates and check them.
#   1. maglim_dv_baseline_evaluate   (legacy chi2 1.9186007, Slurm 57931356)
#   2. maglim_dv_cambmatch_evaluate  (legacy chi2 1.5646796, Slurm 57931356)
#   3. example_evaluate1             (des_y3 v4.05 EXAMPLE_EVALUATE1, sanity)
# Submit from this folder:
#   sbatch [--export=ALL,LEGACY_CHAINS=<legacy des_y3 chains dir>] evaluate_maglim.sbatch
# LEGACY_CHAINS (read only) enables the element-wise model-vector regression.
# Output folders under chains/ must not exist; the job refuses to reuse them.
# CoCoA .so files are built with -march=native: Gold 6248R nodes only.

set -o pipefail   # never set -u (conda activate breaks); set +e around CoCoA scripts

CONDA_BASE=${CONDA_BASE:-/project/chihway/junzhou/miniconda3}
REF_CHI2_BASELINE=${REF_CHI2_BASELINE:-1.9186007}
REF_CHI2_CAMBMATCH=${REF_CHI2_CAMBMATCH:-1.5646796}
CHI2_TOL=${CHI2_TOL:-1e-3}
RUNS="maglim_dv_baseline_evaluate maglim_dv_cambmatch_evaluate example_evaluate1"

fail () { echo "RESULT: FAILED $*"; exit 1; }

echo "Date:        $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Host:        $(hostname)"
echo "CPU:         $(grep -m1 'model name' /proc/cpuinfo)"
echo "Job:         ${SLURM_JOB_ID} partition=${SLURM_JOB_PARTITION} cpus=${SLURM_CPUS_PER_TASK}"
grep -q 'Gold 6248R' /proc/cpuinfo || { echo "RESULT: FAILED not a Gold 6248R node"; exit 3; }

case "${SLURM_SUBMIT_DIR}" in
  */projects/des_y3/ppe/desy3_maglim) ;;
  *) fail "submit from projects/des_y3/ppe/desy3_maglim (got ${SLURM_SUBMIT_DIR})" ;;
esac
WORK=${SLURM_SUBMIT_DIR}
DES_ROOT=$(cd "${WORK}/../.." && pwd -P)
COCOA_ROOT=$(cd "${DES_ROOT}/../.." && pwd -P)
ROOT=$(cd "${COCOA_ROOT}/../.." && pwd -P)
SO=${DES_ROOT}/interface/cosmolike_des_y3_interface.so
CHAINS=${WORK}/chains
echo "DES_ROOT=${DES_ROOT}"; echo "LEGACY_CHAINS=${LEGACY_CHAINS:-<none>}"

# Never reuse an output folder.
for r in ${RUNS}; do
  [[ -e "${CHAINS}/${r}" ]] && fail "output folder exists: ${CHAINS}/${r}"
done
[[ -s "${SO}" ]] || fail "missing ${SO} (run compile_des_y3.sbatch first)"
[[ -s "${DES_ROOT}/data/maglim_cov.txt" ]] || fail "missing data/maglim_cov.txt (run build_maglim_inputs.sbatch first)"

PROTECTED=( "${SO}" "${DES_ROOT}"/data/maglim_* "${DES_ROOT}/data/des_y3_real.dataset"
            "${DES_ROOT}/data/des_y3_unblinded_final.txt" "${DES_ROOT}/data/des_y3_cov_unblinded_final.txt"
            "${DES_ROOT}/data/3x2pt_baseline.mask" "${DES_ROOT}/data/des_y3_lens.nz" "${DES_ROOT}/data/des_y3_source.nz"
            "${DES_ROOT}"/likelihood/*.py "${DES_ROOT}"/likelihood/*.yaml "${WORK}"/*.yaml )
if [[ -n "${LEGACY_CHAINS}" ]]; then
  PROTECTED+=( "${LEGACY_CHAINS}"/maglim_dv_baseline_evaluate/* "${LEGACY_CHAINS}"/maglim_dv_cambmatch_evaluate/* )
fi
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

# Same threading as the legacy reference job 57931356.
export OMP_PROC_BIND=close
export OMP_PLACES=cores
export OMP_DYNAMIC=FALSE
export OMP_NUM_THREADS=${SLURM_CPUS_PER_TASK}
echo "OMP_NUM_THREADS=${OMP_NUM_THREADS}  affinity: $(taskset -pc $$)"

echo "=== INTERFACE CHECK ==="
python - "${SO}" <<'PY'
import os, sys
import cosmolike_des_y3_interface as ci
ok = os.path.realpath(ci.__file__) == os.path.realpath(sys.argv[1])
print("INTERFACE_SO", os.path.realpath(ci.__file__), "is_expected", ok)
print("HAS_STRETCH_SETTER", hasattr(ci, "set_nuisance_clustering_photoz_stretch"))
sys.exit(0 if ok else 1)
PY
[[ $? -eq 0 ]] || fail "interface .so is not the des_y3 one"

STATUS=OK; WHY=""
for r in ${RUNS}; do
  echo; echo "############ EVALUATE ${r} ############"
  mkdir -p "${CHAINS}/${r}"
  T0=$(date +%s)
  cobaya-run "./projects/des_y3/ppe/desy3_maglim/${r}.yaml" 2>&1 | tee "${CHAINS}/${r}/cobaya_run.log"
  RC=$?
  echo "EVALUATE_${r}_RC=${RC}  ($(( $(date +%s) - T0 )) s)"
  [[ ${RC} -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} ${r} rc=${RC};"; }
  HARD=$(grep -E -c 'ERROR|Traceback|LoggedError|Segmentation|Illegal instruction' "${CHAINS}/${r}/cobaya_run.log")
  echo "LOG_HARD_ERROR_LINES_${r}=${HARD}"
  [[ ${HARD} -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} ${r} log has ${HARD} error lines;"; }
  echo "--- soft pattern lines (review: Error|nan|inf|not found) ---"
  grep -n -E 'Error|\bnan\b|\binf\b|not found' "${CHAINS}/${r}/cobaya_run.log" | cut -c1-200
done

echo; echo "############ CHECKS ############"
python - "${CHAINS}" "${DES_ROOT}/data" "${LEGACY_CHAINS}" \
         "${REF_CHI2_BASELINE}" "${REF_CHI2_CAMBMATCH}" "${CHI2_TOL}" <<'PY'
import os, sys
import numpy as np
chains, data, legacy = sys.argv[1], sys.argv[2], sys.argv[3]
refs = {"maglim_dv_baseline_evaluate": float(sys.argv[4]),
        "maglim_dv_cambmatch_evaluate": float(sys.argv[5])}
tol = float(sys.argv[6])
mvname = {"maglim_dv_baseline_evaluate": "maglim_theory_baseline.modelvector",
          "maglim_dv_cambmatch_evaluate": "maglim_theory_cambmatch.modelvector"}
ok = True

def chi2_of(run):
    txt = os.path.join(chains, run, "cobaya.1.txt")
    with open(txt) as f:
        head = f.readline().lstrip("#").split()
    row = np.atleast_1d(np.loadtxt(txt)).ravel()
    return dict(zip(head, row))

# MagLim covariance, "i j value"
c = np.loadtxt(os.path.join(data, "maglim_cov.txt"))
n = int(c[:, 0].max()) + 1
cov = np.zeros((n, n)); cov[c[:, 0].astype(int), c[:, 1].astype(int)] = c[:, 2]
sig = np.sqrt(np.diag(cov))
ref_dv = np.loadtxt(os.path.join(data, "maglim_cosmosis_dv.txt"))[:, 1]

for run in ["maglim_dv_baseline_evaluate", "maglim_dv_cambmatch_evaluate", "example_evaluate1"]:
    d = chi2_of(run)
    chi2 = d.get("chi2", np.nan)
    print("CHI2 %-30s %.10g  (all columns finite: %s)" % (run, chi2,
          bool(np.all(np.isfinite(list(d.values()))))))
    for k, v in d.items():
        if k.startswith("chi2__"):
            print("     %s = %.10g" % (k, v))
    if not np.isfinite(chi2):
        ok = False; print("FAIL non-finite chi2", run)
    if run in refs:
        diff = chi2 - refs[run]
        passed = abs(diff) <= tol
        ok &= passed
        print("REGRESSION %-30s new %.7f ref %.7f diff %+.3e tol %.0e -> %s"
              % (run, chi2, refs[run], diff, tol, "PASS" if passed else "FAIL"))
        mv = np.loadtxt(os.path.join(chains, run, mvname[run]))
        th = mv[:, 1]
        print("   modelvector n=%d finite=%s" % (len(th), bool(np.all(np.isfinite(th)))))
        ok &= bool(np.all(np.isfinite(th))) and len(th) == n
        r = th - ref_dv
        chi2_np = float(r @ np.linalg.solve(cov, r))
        print("   independent NumPy chi2 of (modelvector - maglim_cosmosis_dv) = %.10g (rel diff to likelihood %.2e)"
              % (chi2_np, abs(chi2_np - chi2) / chi2))
        if legacy:
            old = np.loadtxt(os.path.join(legacy, run, mvname[run]))[:, 1]
            dd = th - old
            print("   vs LEGACY modelvector: bitwise_identical=%s  n_diff=%d  max|d|=%.3e  "
                  "max|d|/|old|=%.3e  max|d|/sigma=%.3e  chi2(d)=%.3e"
                  % (bool(np.array_equal(th, old)), int(np.count_nonzero(dd)),
                     np.abs(dd).max(), (np.abs(dd) / np.maximum(np.abs(old), 1e-300)).max(),
                     (np.abs(dd) / sig).max(), float(dd @ np.linalg.solve(cov, dd))))
            for name, i, j in (("xip", 0, 200), ("xim", 200, 400), ("gammat", 400, 880), ("wtheta", 880, 1000)):
                print("      %-7s max|d|/sigma %.3e  max|d| %.3e" % (name, (np.abs(dd[i:j]) / sig[i:j]).max(), np.abs(dd[i:j]).max()))
print("CHECKS_PASSED", ok)
sys.exit(0 if ok else 1)
PY
[[ $? -eq 0 ]] || { STATUS=FAILED; WHY="${WHY} regression/finite checks failed;"; }

if [[ -n "${LEGACY_CHAINS}" ]]; then
  echo; echo "=== cobaya.updated.yaml vs legacy (paths normalised) ==="
  for r in maglim_dv_baseline_evaluate maglim_dv_cambmatch_evaluate; do
    echo "--- ${r}"
    diff <(sed 's#ppe/desy3_maglim/##' "${LEGACY_CHAINS}/${r}/cobaya.updated.yaml") \
         <(sed 's#ppe/desy3_maglim/##' "${CHAINS}/${r}/cobaya.updated.yaml") && echo "IDENTICAL"
  done
fi

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
find "${CHAINS}" -type f \( -path "*maglim_dv_baseline_evaluate*" -o -path "*maglim_dv_cambmatch_evaluate*" -o -path "*example_evaluate1*" \) \
  -newer "${SO}" -print0 | sort -z | xargs -0 sha256sum

set +e
source "${COCOA_ROOT}/stop_cocoa.sh" >/dev/null 2>&1
echo "End:         $(date '+%Y-%m-%d %H:%M:%S %Z')"
if [[ ${STATUS} == OK ]]; then echo "RESULT: OK"; exit 0; else echo "RESULT: FAILED${WHY}"; exit 1; fi
