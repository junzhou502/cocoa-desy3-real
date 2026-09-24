#!/usr/bin/env python
"""Build the CoCoA/CosmoLike input files for the DES Y3 MagLim lens sample.

Ported from the legacy projection-effect branch (commit 42a8bf0). The file
contents written are unchanged; the hard-coded paths were replaced by
command-line options and each product can be requested separately.

Sources
-------
--release : the official DES Y3 MagLim 2pt release FITS file
            (cosmosis-standard-library/likelihood/des-y3/
            2pt_NG_final_2ptunblind_02_26_21_wnz_maglim_covupdate.fits).
            Supplies the template (unshifted, unstretched) n(z) for lenses and
            sources and the 1000x1000 3x2pt covariance.
--sim     : optional. The noiseless CosmoSIS theory vector generated at the
            truth point (a 2pt FITS file). Only its VALUE columns are used, as
            the reference vector against which the CoCoA prediction is
            compared. Needed only for the ``dv`` product.

Products (written into --outdir, default: the des_y3 data/ folder; an
existing file is never overwritten)
----------------------------------------------------------------------
lens_nz    maglim_lens.nz          159 rows: Z_LOW, BIN1..BIN6
source_nz  maglim_source.nz        300 rows: Z_LOW, BIN1..BIN4
cov        maglim_cov.txt          1_000_000 rows: "i j value", 0-indexed
mask       maglim_all.mask         1000 rows: "i 1.0"   (nothing masked)
dv         maglim_cosmosis_dv.txt  1000 rows: "i value" (CosmoSIS vector,
                                   CosmoLike order; needs --sim)

maglim_cov.txt (~32 MB) is not tracked by git; regenerate it with

  python scripts/build_maglim_inputs.py --release <release.fits> \
      --products cov

Format notes
------------
* CosmoLike's ``pf_histo_n`` (redshift_spline.c) infers the histogram bin width
  from ``(z[n-1] - z[0]) / (n-1)`` and indexes with ``floor((z - z[0]) / dz)``.
  It therefore treats column 0 as the LEFT bin edge, which is exactly the FITS
  ``Z_LOW`` column.  Z_MID must NOT be used and no extra half-bin shift may be
  applied.
* The CosmoLike 3x2pt real-space vector and the FITS extensions use the same
  element order, so the reference vector is a straight concatenation of the
  four VALUE columns.
"""
import argparse
import os
import numpy as np
from astropy.io import fits

DEFAULT_OUTDIR = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data"))

NDATA = 1000
BLOCKS = (("xip", 200), ("xim", 200), ("gammat", 480), ("wtheta", 120))
ALL_PRODUCTS = ("lens_nz", "source_nz", "cov", "mask", "dv")


def refuse_overwrite(path):
    if os.path.exists(path):
        raise SystemExit("refusing to overwrite existing file: %s" % path)
    return path


def write_nz(fh, extname, nbin, out):
    d = fh[extname].data
    zlow = np.asarray(d["Z_LOW"], dtype=np.float64)
    cols = ["BIN%d" % (i + 1) for i in range(nbin)]
    arr = np.column_stack([zlow] + [np.asarray(d[c], dtype=np.float64)
                                    for c in cols])
    dz = np.diff(zlow)
    assert np.allclose(dz, dz[0], rtol=0, atol=1e-12), "non-uniform Z_LOW grid"
    # CosmoLike recomputes dz as (z[-1]-z[0])/(n-1); prove that equals the grid.
    dz_cl = (zlow[-1] - zlow[0]) / (len(zlow) - 1.0)
    assert abs(dz_cl - dz[0]) < 1e-12
    np.savetxt(refuse_overwrite(out), arr, fmt="%.17e")
    return arr, dz[0]


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--release", required=True,
                   help="DES Y3 MagLim release 2pt FITS file")
    p.add_argument("--sim", default=None,
                   help="noiseless CosmoSIS 2pt FITS (only for product dv)")
    p.add_argument("--outdir", default=DEFAULT_OUTDIR,
                   help="output folder (default: %(default)s)")
    p.add_argument("--products", nargs="+", default=None,
                   choices=ALL_PRODUCTS,
                   help="products to write (default: all; dv only with --sim)")
    return p.parse_args()


def main():
    args = parse_args()
    products = args.products
    if products is None:
        products = [x for x in ALL_PRODUCTS if x != "dv" or args.sim]
    if "dv" in products and not args.sim:
        raise SystemExit("product dv needs --sim")
    out = lambda name: os.path.join(args.outdir, name)
    # Refuse before writing anything, so a partial run never happens.
    names = {"lens_nz": "maglim_lens.nz", "source_nz": "maglim_source.nz",
             "cov": "maglim_cov.txt", "mask": "maglim_all.mask",
             "dv": "maglim_cosmosis_dv.txt"}
    for prod in products:
        refuse_overwrite(out(names[prod]))

    rel = fits.open(args.release)

    if "lens_nz" in products:
        lens, dz_l = write_nz(rel, "nz_lens", 6, out(names["lens_nz"]))
        print("maglim_lens.nz   rows=%d cols=%d dz=%.17g" % (
            lens.shape[0], lens.shape[1], dz_l))
        for i in range(3):
            print("   row %d:" % i, " ".join("%.12e" % v for v in lens[i]))
    if "source_nz" in products:
        src, dz_s = write_nz(rel, "nz_source", 4, out(names["source_nz"]))
        print("maglim_source.nz rows=%d cols=%d dz=%.17g" % (
            src.shape[0], src.shape[1], dz_s))
        for i in range(3):
            print("   row %d:" % i, " ".join("%.12e" % v for v in src[i]))

    if "cov" in products:
        cov = np.asarray(rel["COVMAT"].data, dtype=np.float64)
        assert cov.shape == (NDATA, NDATA), cov.shape
        asym = np.max(np.abs(cov - cov.T))
        ev = np.linalg.eigvalsh(cov)
        print("COVMAT shape=%s  max|C-C^T|=%.3e  min eig=%.6e  max eig=%.6e"
              % (cov.shape, asym, ev.min(), ev.max()))
        ii, jj = np.meshgrid(np.arange(NDATA), np.arange(NDATA), indexing="ij")
        tab = np.column_stack([ii.ravel(), jj.ravel(), cov.ravel()])
        np.savetxt(refuse_overwrite(out(names["cov"])), tab, fmt="%d %d %.17e")

    if "mask" in products:
        mask = np.column_stack([np.arange(NDATA), np.ones(NDATA)])
        np.savetxt(refuse_overwrite(out(names["mask"])), mask, fmt="%d %.1f")

    if "dv" in products:
        sim = fits.open(args.sim)
        parts = []
        for name, n in BLOCKS:
            v = np.asarray(sim[name].data["VALUE"], dtype=np.float64)
            assert len(v) == n, (name, len(v), n)
            parts.append(v)
        dv = np.concatenate(parts)
        assert dv.shape == (NDATA,)
        np.savetxt(refuse_overwrite(out(names["dv"])),
                   np.column_stack([np.arange(NDATA), dv]), fmt="%d %.17e")
        print("maglim_cosmosis_dv.txt  n=%d  finite=%s  L2=%.12e"
              % (len(dv), bool(np.all(np.isfinite(dv))), np.linalg.norm(dv)))
        sim.close()

    rel.close()


if __name__ == "__main__":
    main()
