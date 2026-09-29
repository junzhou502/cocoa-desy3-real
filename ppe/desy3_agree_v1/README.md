# ppe/desy3_agree_v1: the "agree-v1" CoCoA configuration (tag ppe-desy3-agree-v1)

`agree_v1_evaluate.yaml` is the DES Y3 MagLim 3x2pt evaluate template at the truth point (every parameter fixed,
point masses DES_PM1..6 = 0) with every option of the CoCoA configuration that agrees with CosmoSIS. The
CosmoSIS side is `cosmosis/des_y3/desy3_agree_v1/agree-v1.ini` in the root repo (junzhou502/Project-Projection-Effect).
Frozen by task freeze-agree-v1-20260929 (2026-09-29) from the campaign desy3-convergence-campaign-20260928 and the
check tag-config-check-20260929. Run from `cocoa/Cocoa` with `start_cocoa.sh` sourced, on a Cascade Lake node:

    cobaya-run ./projects/des_y3/ppe/desy3_agree_v1/agree_v1_evaluate.yaml

The output folder `chains/agree_v1_evaluate/` must not exist (or use `cobaya-run -f`, or change `output:`).
`chains/` is git-ignored. For chains, copy the yaml, free the parameters and add priors; keep the likelihood and
theory blocks as they are.

## Settings

Base: `ppe/desy3_ellprefactor_growthk/g_gk_cosmosis.yaml` (cambmatch CAMB settings), unchanged outside the
likelihood block. c0 = truth cosmology (Omega_m 0.3, 1e9 A_s 2.19), c5 = (0.8, 4.5); "HD" = A1 5, A2 -5, alpha
-5, bias_ta 2; chi2 over the 462 scale-cut elements with the release MagLim COVMAT.

| Option | Value | What it is | Why |
|---|---|---|---|
| `accuracyboost` | 2.0 | CosmoLike's interpolation grids (N_a, N_ell, z and log10 k grids of P(k)) | cost (chains of ~500k points); b 1 -> 2 moves HD by 0.016, b 2 -> 4 by 1.1e-3 at c0 |
| `integration_accuracy` | 4 | 40 + 40 x 4 Gauss-Legendre nodes in the Limber C_ss (and more nodes in other integrals) | 0 leaves the II term off by up to 6% per bin pair; 1 moves HD by 1.5 and doubles the HD disagreement; 4 -> 8 moves every named point by <= 2.8e-3 |
| `kmax_boltzmann` | 7.5 | the likelihood's default: CAMB k_max = max(7.5 x 2, the theory's `extra_args.kmax` 50) = 50/Mpc (cobaya `camb.py:487-488`) | CAMB at 400/Mpc (setting K) costs 4.6 s more per cosmology change and changes the c0 vectors by <= 3e-5 |
| `nested_z_grids`, `nested_k_grid` | False | the historical grids (not the nested boost-1 refinements) | user decision (2026-09-29); changes the c0 vectors by <= 1.1e-2 (HD), CoCoA - CosmoSIS HD 6.75 -> 6.33 |
| `fptia_kmin` | 0.05 | lower end in k (c/H0) of cFASTPT's TATT table (upstream core v4.11.7) | 1e-5 made the TATT terms rounding-noise dominated |
| `fptia_fixed_nodes` | 1100 | exactly 1100 cFASTPT nodes at every accuracyboost (option added for this freeze, default null) | = upstream's 1100; the campaign held the nodes fixed with `run_knobs.py --fpt-nodes-fixed 1100` |
| `fptia_base_nodes` | 1100 | replaced by `fptia_fixed_nodes` (kept equal for clarity) | - |
| `fptia_nested_nodes` | False | excluded by `fptia_fixed_nodes` | - |
| `fptia_upsampling` | 32 | cubic up-sampling of the TATT table in ln k, once per cosmology | costs nothing; U 1 worsens the HD agreement by 0.23 |
| `ia_growth_k_hmpc` | "cosmosis" | IA growth at the first CAMB k above 0.03 h/Mpc (CosmoSIS TATT rule) | model alignment |
| `ia_c1rhocrit` | 0.01389 | CoCoA's TATT constant (default; CosmoSIS uses 0.013873073650776856) | user decision: the CosmoSIS value only helps together with a unit-integral n(z), which agree-v1 does not use |
| `point_mass_model` | 1 | CosmoSIS `add_gammat_point_mass` kernel with exact G/c^2; amplitudes DES_PM1..6 (1e13 Msun/h) | model alignment; at PM = 0 byte-identical to model 0 |
| native n(z) | - | CosmoLike's own n(z) (no unit renormalisation) | user decision |

`fptia_fixed_nodes` (likelihood/_cosmolike_prototype_base.py, default `null` in the five likelihood yamls) calls
`init_FPTIA_base_nodes(N)` and `init_FPTIA_nested_nodes(1)`, i.e. what `--fpt-nodes-fixed N` did. With the
existing options the same 1100 nodes arise only at accuracyboost 2 (`fptia_base_nodes: 900`, since the default
rule is base + 200 x int(accuracyboost - 1)); both give byte-identical vectors (job 59723259, 40 points).

## Validation (task freeze-agree-v1-20260929; kicp, Gold 6248R)

- CoCoA job 59723259 (`chains/fz_val_59723259.out`, 170 byte checks OK):
  - the defaults (g_reg_baseline, g_reg_cambmatch, g_gk_cosmosis, g_noia_gk, fresh FID/HA/N0) are byte-identical
    with the new option present;
  - `cobaya-run agree_v1_evaluate.yaml`: chi2 = 1.8317198 against `maglim_3x2pt.dataset` (the noiseless CosmoSIS
    vector of `data/`), model vector = the runner's FID vector byte for byte;
  - this yaml with no driver flags = the settings given as `run_knobs.py --lik-set ... --fpt-nodes-fixed 1100`,
    byte for byte at 40 points (c0), 10 (c5) and with DES_PM1..4 = 2, -1.5, 1, -0.8 (c0, c5);
  - 4 and 24 threads, and two passes, give identical vectors.
- Change against the reference of the tag check (T0: U 32, b 2, n 4, nested grids, CAMB k_max 400), c0: N0 6.0e-5,
  FID 5.3e-5, HA 1.5e-4, HB 2.3e-4, HD 1.07e-2, LN 1.1e-4, S01-S30 <= 6.8e-4 (HC 1.6e-4). c5: HD 4.8e3, HA 19, FID 0.47.
- CoCoA - CosmoSIS agree-v1 (chi2_cut): c0 N0 0.214, FID 0.215, HA 0.265, HB 0.370, HD 6.33, LN 0.242, S01-S30
  median 0.246, max 2.50 (S26), HC 631; with the point masses N0 0.340 (lens bin 2 point-mass term 0.8-4.3% larger
  in CoCoA, mostly the lens n(z)). c5: N0 35.7, FID 189, HD 3.9e6 (not converged in either code at c5).

## Cost (whole Gold 6248R node, paired design of 8 cosmologies, median; job 59723259)

| Threads | per cosmology change (wall) | of which CAMB | likelihood | per IA-only change |
|---|---|---|---|---|
| 24 | 2.06 s | 1.50 s | 0.57 s | 0.22 s |
| 4 | 4.92 s | 2.67 s | 2.26 s | 1.19 s |

(Setting K with CAMB k_max 400 and nested grids: 6.63 s at 24 threads.) Model setup: 5.6 s once per process.
