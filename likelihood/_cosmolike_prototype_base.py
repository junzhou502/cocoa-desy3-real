# Python 2/3 compatibility - must be first line
from __future__ import absolute_import, division, print_function
import os
import numpy as np
import scipy
import sys
import time

# Local
from cobaya.likelihoods.base_classes import DataSetLikelihood
from cobaya.log import LoggedError
from getdist import IniFile

from scipy.interpolate import interp1d
from scipy.interpolate import CubicSpline as _CubicSpline
import euclidemu2 as ee2
import math

import cosmolike_des_y3_interface as ci

survey = "DES"

# ---------------------------------------------------------------------------
# Wavenumber of the growth factor used by the INTRINSIC-ALIGNMENT terms
# (likelihood option ia_growth_k_hmpc; ported from legacy des_y3 019f3bc and
# 7156eba, now scoped to IA only through ci.set_growth_ia).
#
# By default CosmoLike takes the growth for everything (IA, non-Limber w(theta)
# D and f, Limber RSD f) from one table measured at k = 5e-4 1/Mpc (G_growth in
# set_cosmo_related, unchanged). CosmoSIS uses two different rules:
#   * TATT IA (intrinsic_alignments/tatt/tatt_interface.py:286-287):
#       ind = np.where(k_lin > 0.03)[0][0]; Dz = sqrt(p_lin[:, ind]/p_lin[0, ind])
#     on the matter_power_lin k_h grid, i.e. the FIRST GRID POINT ABOVE
#     0.03 h/Mpc (not 0.3 h/Mpc);
#   * exact w(theta) (structure/projection/project_2d.py:112,142): the grid point
#     nearest 1e-3 h/Mpc.
# Only the first is replicated here, and only for the IA terms.
#
# The CosmoSIS k_h grid (boltzmann/camb/camb_interface.py:644-649) is
#     k = np.logspace(np.log10(kcalc[0]), np.log10(max(kmax, kmax_extrapolate)), nk)
# with kcalc[0] = CAMB's lowest transfer k/h = float32(5e-5 / h) (CAMB amin =
# 5e-5 1/Mpc, stored in single precision), nk = 700 and kmax_extrapolate = 500
# from the [camb] section of cosmosis/des_y3/des-y3.ini. CAVEAT: "cosmosis" mode
# hard-codes that construction and silently breaks if nk, kmax_extrapolate or the
# CAMB version change. Checked 2026-09-24 against the CosmoSIS 3.25.2 / CAMB
# 1.6.5 block dump at h = 0.69: grid identical, ind = 268,
# k = 0.030350713668324276 h/Mpc.
# ---------------------------------------------------------------------------
CS_CAMB_TRANSFER_KMIN_INVMPC = 5e-5    # CAMB amin
CS_CAMB_NK = 700                       # [camb] nk in des-y3.ini
CS_CAMB_KMAX_POWER_HMPC = 500.0        # max(kmax, kmax_extrapolate) in des-y3.ini
CS_TATT_K_THRESHOLD_HMPC = 0.03        # tatt_interface.py:286, `k_lin > 0.03`

def cosmosis_ia_growth_k_hmpc(h):
  """k (h/Mpc) and grid index of CosmoSIS's k_lin[np.where(k_lin > 0.03)[0][0]]."""
  kcalc0_hmpc = float(np.float32(CS_CAMB_TRANSFER_KMIN_INVMPC / h))
  k_hmpc = np.logspace(np.log10(kcalc0_hmpc), np.log10(CS_CAMB_KMAX_POWER_HMPC),
                       CS_CAMB_NK)
  above = np.where(k_hmpc > CS_TATT_K_THRESHOLD_HMPC)[0]
  if above.size == 0:
    raise ValueError("CosmoSIS IA growth grid has no point above %g h/Mpc (h = %g)"
                     % (CS_TATT_K_THRESHOLD_HMPC, h))
  ind = int(above[0])
  return k_hmpc[ind], ind

class _cosmolike_prototype_base(DataSetLikelihood):

  def initialize(self, probe):
    ini = IniFile(os.path.normpath(os.path.join(self.path, self.data_file)))
    self.probe = probe
    self.data_vector_file = ini.relativeFileName('data_file')
    self.cov_file = ini.relativeFileName('cov_file')
    self.mask_file = ini.relativeFileName('mask_file')
    self.lens_file = ini.relativeFileName('nz_lens_file')
    self.source_file = ini.relativeFileName('nz_source_file')
    self.lens_ntomo = ini.int("lens_ntomo") #5
    self.source_ntomo = ini.int("source_ntomo") #4
    self.ntheta = ini.int("n_theta")
    self.theta_min_arcmin = ini.float("theta_min_arcmin")
    self.theta_max_arcmin = ini.float("theta_max_arcmin")

    # ------------------------------------------------------------------------   
    # Nested grids (options nested_z_grids, nested_k_grid; default False = the
    # historical grids). CosmoLike interpolates its P(k,z), growth and distance
    # tables LINEARLY between exactly the nodes handed to it here. Linear
    # interpolation leaves a sawtooth error that vanishes at the nodes, so two
    # grids that do not share nodes disagree by the full sawtooth amplitude.
    # The historical node counts grow additively with accuracyboost (e.g.
    # min(120 + 20*boost, 250) z nodes), so every boost moves the nodes and
    # re-phases the sawtooth instead of shrinking it. With nesting, each
    # uniform block keeps its boost-1 end points and its boost-1 interval count
    # is multiplied by m = 2^ceil(log2(boost)) (capped at 16): every coarser
    # grid is a subset of every finer one, the error falls like 1/m^2, and
    # boost 1 reproduces the historical grids exactly. CAMB's transfer module
    # accepts at most 256 redshifts, so with nested z grids the Pk_interpolator
    # request stays at the boost-1 z grid (z_interp_2D_camb, 140 nodes) and the
    # finer nodes re-evaluate cobaya's spline in z (as upstream des_y3 v4.11.2).
    # Measured on DES Y3 MagLim (ppe/desy3_nested_grids, accuracyboost 1, 2, 4,
    # 8): with nested z grids the IA-free and NLA-only vectors converge. Their
    # step chi2 (462 cut points) falls 3-13x per doubling, to 3e-6 (Omega_m 0.3)
    # and 6e-3 (Omega_m 0.8) at 4 -> 8, against 2.5e-4 and 0.24 before. The TATT
    # vectors do not converge: their cFASTPT terms carry a numerical noise
    # floor. Nested z and k grids cost 1.1 s instead of 0.3 s per IA-only
    # evaluation at accuracyboost 8.
    nest_z = bool(getattr(self, "nested_z_grids", False))
    nest_k = bool(getattr(self, "nested_k_grid", False))
    m = int(min(2**np.ceil(np.log2(max(1.0, self.accuracyboost))), 16))
    if nest_z:
      tmp1 = int(1000 + 250*1.0)   # the boost-1 counts of the formulas below
      tmp2 = int(min(120 + 20*1.0, 250))
      n1 = [max(100,int(0.80*tmp1)), max(100,int(0.40*tmp1)), max(50,int(0.10*tmp1))]
      n2 = [max(50,int(0.75*tmp2)), max(30,int(0.25*tmp2))]
      self.z_interp_1D = np.concatenate((np.linspace(0.0,3.0,(n1[0]-1)*m+1),
                                         np.linspace(3.0,50.1,(n1[1]-1)*m+1),
                                         np.linspace(1070,1100,(n1[2]-1)*m+1)),axis=0)
      self.z_interp_2D = np.concatenate((np.linspace(0,3.0,(n2[0]-1)*m+1),
                                         np.linspace(3.01,50.0,(n2[1]-1)*m+1)),axis=0)
      self.z_interp_2D_camb = np.concatenate((np.linspace(0,3.0,n2[0]),
                                              np.linspace(3.01,50.0,n2[1])),axis=0)
    else:
      tmp=int(1000 + 250*self.accuracyboost)
      self.z_interp_1D = np.concatenate((np.linspace(0.0,3.0,max(100,int(0.80*tmp))),
                                         np.linspace(3.0,50.1,max(100,int(0.40*tmp))),
                                         np.linspace(1070,1100,max(50,int(0.10*tmp)))),axis=0)
      tmp=int(min(120 + 20*self.accuracyboost,250))
      self.z_interp_2D = np.concatenate((np.linspace(0,3.0,max(50,int(0.75*tmp))), 
                                         np.linspace(3.01,50.0,max(30,int(0.25*tmp)))),axis=0)
      self.z_interp_2D_camb = self.z_interp_2D
    self.len_z_interp_1D = len(self.z_interp_1D)
    self.len_z_interp_2D = len(self.z_interp_2D)
    # CAMB's transfer-grid minimum rises above 10**-4.99 in young-universe
    # prior corners, so keep the requested grid inside the validated range.
    if nest_k:
      self.log10k_interp_2D = np.linspace(-4.90,2.0,(int(1250+250*1.0)-1)*m+1)
    else:
      self.log10k_interp_2D = np.linspace(-4.90,2.0,int(1250+250*self.accuracyboost))
    self.len_log10k_interp_2D = len(self.log10k_interp_2D)
    self.log.info('grids: nested_z_grids %s nested_k_grid %s (m = %d): z_1D %d, z_2D %d '
                  '(CAMB request %d), log10k %d nodes', nest_z, nest_k, m,
                  self.len_z_interp_1D, self.len_z_interp_2D, len(self.z_interp_2D_camb),
                  self.len_log10k_interp_2D)
    # ------------------------------------------------------------------------

    ci.initial_setup()
    ci.init_probes(possible_probes=self.probe)
    ci.init_binning(self.ntheta, self.theta_min_arcmin, self.theta_max_arcmin)

    # gamma_t point-mass kernel. 0 (default) keeps the historical
    # CosmoLike/y3_production kernel; 1 selects the CosmoSIS-matched kernel of
    # shear/point_mass/add_gammat_point_mass.py. See PointMass::get_pm in
    # cosmolike_core/cosmolike/generic_interface.cpp. It only matters when a
    # DES_PM* amplitude is non-zero.
    self.point_mass_model = int(getattr(self, "point_mass_model", 0))
    ci.init_point_mass_model(point_mass_model=self.point_mass_model)
    self.log.info('point_mass_model = %d', self.point_mass_model)

    # Growth wavenumber of the intrinsic-alignment terms (see the block at the
    # top of this file). In h/Mpc, converted to 1/Mpc with the live h.
    #   null / unset / <= 0 : default. No IA-specific growth is set, so the IA
    #                         terms use the shared table at 5e-4 1/Mpc (bitwise
    #                         the historical behaviour).
    #   <float> > 0         : fixed k in h/Mpc for the IA growth only
    #                         (0.030350713668324276 = CosmoSIS TATT at h = 0.69).
    #   "cosmosis"          : CosmoSIS's rule at the live h.
    _gk = getattr(self, "ia_growth_k_hmpc", None)
    if _gk is None or (isinstance(_gk, str) and _gk.strip().lower()
                       in ("", "none", "null", "legacy")):
      self.ia_growth_k_mode, self.ia_growth_k_hmpc = "legacy", None
    elif isinstance(_gk, str) and _gk.strip().lower() == "cosmosis":
      self.ia_growth_k_mode, self.ia_growth_k_hmpc = "cosmosis", None
    elif float(_gk) <= 0.0:
      self.ia_growth_k_mode, self.ia_growth_k_hmpc = "legacy", None
    else:
      self.ia_growth_k_mode, self.ia_growth_k_hmpc = "fixed", float(_gk)
    self._ia_growth_k_logged = False
    self.log.info('ia_growth_k_hmpc mode = %s%s', self.ia_growth_k_mode,
                  "" if self.ia_growth_k_hmpc is None
                  else " (%.12g h/Mpc)" % self.ia_growth_k_hmpc)

    if self.debug:
      ci.set_log_level_debug()
    else:
      ci.set_log_level_info()
      
    if self.use_emulator:
      ci.init_redshift_distributions_from_files(
          lens_multihisto_file=self.lens_file,
          lens_ntomo=int(self.lens_ntomo), 
          source_multihisto_file=self.source_file,
          source_ntomo=int(self.source_ntomo))
      ci.init_data_real(self.cov_file, self.mask_file, self.data_vector_file)  
      ci.init_accuracy_boost(accuracy_boost=0.35, 
                             integration_accuracy=-1) # seems enough to compute PM
    else:
      ci.init_ntable_lmax(lmax=int(self.lmax))
      ci.init_accuracy_boost(accuracy_boost=self.accuracyboost, 
                             integration_accuracy=int(self.integration_accuracy))
      ci.init_cosmo_runmode(is_linear=False)

      if self.external_nz_modeling: 
        (self.lens_nz, self.source_nz) = ci.read_redshift_distributions(
            lens_multihisto_file=self.lens_file,
            lens_ntomo=int(self.lens_ntomo), 
            source_multihisto_file=self.source_file,
            source_ntomo=int(self.source_ntomo)) 
        ci.init_lens_sample_size(int(self.lens_ntomo))
        ci.init_source_sample_size(int(self.source_ntomo))
        ci.init_ntomo_powerspectra() # must be called after set_source/lens_size  
      else:
        ci.init_redshift_distributions_from_files(
          lens_multihisto_file=self.lens_file,
          lens_ntomo=int(self.lens_ntomo), 
          source_multihisto_file=self.source_file,
          source_ntomo=int(self.source_ntomo))  

      ci.init_data_real(self.cov_file, self.mask_file, self.data_vector_file)
      ci.init_IA(ia_model = int(self.IA_model), 
                 ia_redshift_evolution = int(self.IA_redshift_evolution))
      if self.probe not in ("xi", "3x2pt_ss_sk_sk", "2x2pt_ss_sk"):
        # (b1, b2, bs2, b3, bmag). 0 = one amplitude per bin
        ci.init_bias(bias_model=self.bias_model)

      if self.non_linear_emul == 1:
        self.emulator = ee2.PyEuclidEmulator()

      if self.create_baryon_pca:
        self.use_baryon_pca = False
        self.allsims = ini.relativeFileName('all_sims_hdf5_file')
      else:
        if self.add_baryons_on_dv:
          sim = self.which_bsims_add_on_dv
          self.allsims = ini.relativeFileName('all_sims_hdf5_file')
          ci.init_baryons_contamination(sim = sim, allsims=allsims)

    # Up-sampling factor U of CosmoLike's TATT FAST-PT table (get_FPT_IA in
    # cosmolike_core/cosmolike/pt_cfastpt.c). FAST-PT runs on 270 + 200*(int
    # accuracyboost - 1) ln k nodes and the Limber integrals interpolate the
    # table linearly. U > 1 resamples it once per cosmology with a cubic spline
    # onto U times more nodes. 1 (default) = off, bitwise the historical table.
    # Measured on DES Y3 MagLim (ppe/cfastpt_cubic_upsampling): U = 32 is
    # converged (within chi2 = 1.1e-5 of U = 64 at Omega_m = 0.3) and costs no
    # measurable time. It does not make the TATT vector converge in
    # accuracyboost: FAST-PT's own output changes more than that.
    _u = getattr(self, "fptia_upsampling", 1)
    self.fptia_upsampling = 1 if _u is None else int(_u)
    ci.init_FPTIA_upsampling(factor=self.fptia_upsampling)
    self.log.info('fptia_upsampling = %d', self.fptia_upsampling)
    # Base node count of that FAST-PT table: 270 + 200*int(accuracyboost - 1)
    # nodes by default; fptia_base_nodes replaces the 270 (upstream CosmoLike
    # core v4.11.7 uses 1100). Default 270 = bitwise the historical table.
    _nb = getattr(self, "fptia_base_nodes", 270)
    self.fptia_base_nodes = 270 if _nb is None else int(_nb)
    ci.init_FPTIA_base_nodes(nodes=self.fptia_base_nodes)
    self.log.info('fptia_base_nodes = %d', self.fptia_base_nodes)
    # fptia_nested_nodes: True gives that table base*m nodes, m = 2^ceil(log2(
    # accuracyboost)) as for the nested grids above (capped at 16), a nested
    # refinement; False (default) keeps base + 200*int(accuracyboost - 1).
    self.fptia_nested_nodes = bool(getattr(self, "fptia_nested_nodes", False))
    if self.fptia_nested_nodes:
      _m = int(min(2**np.ceil(np.log2(max(1.0, self.accuracyboost))), 16))
      ci.init_FPTIA_nested_nodes(m=_m)
      self.log.info('fptia_nested_nodes = True: %d x %d FAST-PT nodes', self.fptia_base_nodes, _m)

    if self.use_baryon_pca:
      baryon_pca_file = ini.relativeFileName('baryon_pca_file')
      self.npcs = 4
      ci.set_baryon_pcs(eigenvectors = np.loadtxt(baryon_pca_file))
      self.log.info('use_baryon_pca = True')
      self.log.info('baryon_pca_file = %s loaded', baryon_pca_file)
    else:
      self.log.info('use_baryon_pca = False')

    # logp passes the raw Python list from compute_data_vector_masked to
    # ci.compute_chi2. carma's arma::Col caster converts the list into a
    # temporary NumPy array, borrows its memory without owning it, and the
    # temporary is freed before IP::get_chi2 reads it, so the first four
    # theory elements are read as allocator bookkeeping (~0). The error is
    # deterministic, not random. Cache the initialized likelihood arrays and
    # evaluate the same quadratic form as IP::get_chi2 in NumPy instead.
    self._active_data_mask = np.asarray(ci.get_mask(), dtype=bool)
    self._active_data_vector = np.asarray(
      ci.get_dv_masked(), dtype=np.float64)[self._active_data_mask]
    inverse_covariance = np.asarray(ci.get_inv_cov_masked(), dtype=np.float64)
    self._active_inverse_covariance = inverse_covariance[
      np.ix_(self._active_data_mask, self._active_data_mask)]

  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------

  def get_requirements(self):
    if self.use_emulator:
      if self.probe == "xi":
        return {
          'cosmic_shear': None
        }
      elif self.probe == "3x2pt":
        return {
          "H0": None,
          'cosmic_shear': None,
          'ggl': None,
          'wtheta': None,
          'comoving_radial_distance': {
            "z": self.z_interp_1D 
          } # in Mpc
        }
      elif self.probe == "xi_gg":
        return {
          'cosmic_shear': None,
          'wtheta': None
        }
      elif self.probe == "xi_ggl":
        return {
          "H0": None,
          'cosmic_shear': None,
          'ggl': None,
          'comoving_radial_distance': {
            "z": self.z_interp_1D
          } # in Mpc
        }
      elif self.probe == "2x2pt":
        return {
          "H0": None,
          'ggl': None,
          'wtheta': None,
          'comoving_radial_distance': {
            "z": self.z_interp_1D 
          } # in Mpc
        }     
    else:
      res = {}
      if self.non_linear_emul == 1:
        res.update({"wa": None, "w": None, "mnu": None, "omegab": None})
      res.update({
          "As": None,
          "H0": None,
          "omegam": None,
          "Pk_interpolator": {
            "z": self.z_interp_2D_camb,
            "k_max": self.kmax_boltzmann * self.accuracyboost,
            "nonlinear": (True,False),
            "vars_pairs": ([("delta_tot", "delta_tot")])
          },
          "comoving_radial_distance": {
            "z": self.z_interp_1D
          }, # in Mpc
          "Cl": { # DONT REMOVE THIS - SOME WEIRD BEHAVIOR IN CAMB WITHOUT WANTS_CL
            'tt': 0
          }
        })
      return res

  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------

  def set_cosmo_related(self):
    h = self.provider.get_param("H0")/100.0
    if not self.use_emulator:
      PKL  = self.provider.get_Pk_interpolator(("delta_tot", "delta_tot"),
                                               nonlinear=False,
                                               extrap_kmin=1e-6,
                                               extrap_kmax=2.5e2*self.accuracyboost)
      lnPL = PKL.logP(self.z_interp_2D,
                      np.power(10.0,self.log10k_interp_2D)).flatten(order='F')+np.log(h**3)

      if self.non_linear_emul == 1:
        params = {
          'Omm'  : self.provider.get_param("omegam"),
          'As'   : self.provider.get_param("As"),
          'Omb'  : self.provider.get_param("omegab"),
          'ns'   : self.provider.get_param("ns"),
          'h'    : h,
          'mnu'  : self.provider.get_param("mnu"), 
          'w'    : self.provider.get_param("w"),
          'wa'   : self.provider.get_param("wa"),
        }
        # Euclid Emulator only works on z<10.0
        kbt, tmp_bt = ee2.get_boost2(params, 
                                     self.z_interp_2D[self.z_interp_2D < 10.0], 
                                     self.emulator, 
                                     10**np.linspace(-2.0589,0.973,self.len_log10k_interp_2D))
        bt = np.array(tmp_bt, dtype='float64')
        tmp = interp1d(np.log10(kbt), 
                       np.log(bt), 
                       axis=1,
                       kind='linear', 
                       fill_value='extrapolate', 
                       assume_sorted=True)(self.log10k_interp_2D-np.log10(h)) #h/Mpc
        tmp[:,10**(self.log10k_interp_2D-np.log10(h)) < 8.73e-3] = 0.0
        lnbt = np.zeros((self.len_z_interp_2D, self.len_log10k_interp_2D))
        lnbt[self.z_interp_2D < 10.0, :] = tmp
        # Use Halofit first that works on all redshifts
        lnPNL = self.provider.get_Pk_interpolator(("delta_tot", "delta_tot"),
          nonlinear=True, extrap_kmin=1e-6,
          extrap_kmax=2.5e2*self.accuracyboost).logP(self.z_interp_2D,
          np.power(10.0,self.log10k_interp_2D)).flatten(order='F')+np.log(h**3) 
        # on z < 10.0, replace it with EE2
        lnPNL = np.where(
          (self.z_interp_2D<10)[:,None], 
          lnPL.reshape(self.len_z_interp_2D,self.len_log10k_interp_2D,order='F') + lnbt, 
          lnPNL.reshape(self.len_z_interp_2D,self.len_log10k_interp_2D,order='F')).ravel(order='F')
      elif self.non_linear_emul == 2:
        lnPNL = self.provider.get_Pk_interpolator(("delta_tot", "delta_tot"),
          nonlinear=True, extrap_kmin=1e-6,
          extrap_kmax =2.5e2*self.accuracyboost).logP(self.z_interp_2D,
          np.power(10.0,self.log10k_interp_2D)).flatten(order='F')+np.log(h**3)   
      else:
        raise LoggedError(self.log, "non_linear_emul = %d is an invalid option", non_linear_emul)

      G_growth = np.sqrt(PKL.P(self.z_interp_2D,0.0005)/PKL.P(0,0.0005))*(1+self.z_interp_2D)
      G_growth /= G_growth[-1]

      ci.set_cosmology(
        omegam=self.provider.get_param("omegam"),
        H0=self.provider.get_param("H0"),
        log10k_2D=self.log10k_interp_2D-np.log10(h), #h/Mpc
        z_2D=self.z_interp_2D,
        lnP_linear=lnPL, 
        lnP_nonlinear=lnPNL, 
        G=G_growth,
        z_1D=self.z_interp_1D,
        chi=self.provider.get_comoving_radial_distance(self.z_interp_1D)*h # convert to Mpc/h
      )

      # Optional growth for the intrinsic-alignment terms only (default: none,
      # the IA terms then use G_growth above). Same construction as G_growth,
      # at the IA wavenumber.
      if getattr(self, "ia_growth_k_mode", "legacy") != "legacy":
        if self.ia_growth_k_mode == "cosmosis":
          _k_hmpc, _ind = cosmosis_ia_growth_k_hmpc(h)
        else:
          _k_hmpc, _ind = self.ia_growth_k_hmpc, -1
        k_ia = _k_hmpc * h                                # h/Mpc -> 1/Mpc
        G_ia = np.sqrt(PKL.P(self.z_interp_2D,k_ia)/PKL.P(0,k_ia))*(1+self.z_interp_2D)
        G_ia /= G_ia[-1]
        ci.set_growth_ia(z=self.z_interp_2D, G=G_ia)
        if not self._ia_growth_k_logged:
          self.log.info('IA growth wavenumber: %.17g h/Mpc = %.17g 1/Mpc (h = %.10g, '
                        'mode = %s, CosmoSIS grid index = %d); other growth uses '
                        'stay at 5e-4 1/Mpc', _k_hmpc, k_ia, h, self.ia_growth_k_mode, _ind)
          self._ia_growth_k_logged = True
    else:
      ci.set_distances(
        z=self.z_interp_1D,
        chi=self.provider.get_comoving_radial_distance(self.z_interp_1D)*h
      )

  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------

  def set_source_related(self, **params):
    ntomo = self.source_ntomo
    ci.set_nuisance_shear_calib(
      M=[params.get(p,0) for p in [survey+"_M"+str(i+1) for i in range(ntomo)]]
    )
    if not self.use_emulator:
      if self.external_nz_modeling: 
        # here we send n(z) at every point in the chain as the user may
        # modify it using an external function (example: adding outliers)
       
        # to modify it
        # (1) deep copy the numpy array (so we keep track of the fiducial
        # (2) modify the copy
        # (3) call set_source_sample
        source_nz_local = self.source_nz.copy()

        # insert mod function here <-
        #source_nz_local = f(source_nz_local, nuisance parameters)

        ci.set_source_sample(source_nz_local)

        # user may choose to still add photo-z bias or not (here we ad)
        ci.set_nuisance_shear_photoz(
          bias=[params.get(p,0) for p in [survey+"_DZ_S"+str(i+1) for i in range(ntomo)]]
        )
      else:
        ci.set_nuisance_shear_photoz(
          bias=[params.get(p,0) for p in [survey+"_DZ_S"+str(i+1) for i in range(ntomo)]]
        )
      ci.set_nuisance_ia(
        A1=[params.get(p,0) for p in [survey+"_A1_"+str(i+1) for i in range(ntomo)]],
        A2=[params.get(p,0) for p in [survey+"_A2_"+str(i+1) for i in range(ntomo)]],
        B_TA=[params.get(p,0) for p in [survey+"_BTA_"+str(i+1) for i in range(ntomo)]]
      )

  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------

  def set_lens_related(self, **params):
    ntomo = self.lens_ntomo
    ci.set_point_mass(
      PMV = [params.get(p, 0) for p in [survey+"_PM"+str(i+1) for i in range(ntomo)]]
    )
    if not self.use_emulator:
      ci.set_nuisance_bias(
        B1=[params.get(p,1) for p in [survey+"_B1_"+str(i+1) for i in range(ntomo)]],
        B2=[params.get(p,0) for p in [survey+"_B2_"+str(i+1) for i in range(ntomo)]],
        B_MAG=[params.get(p,0) for p in [survey+"_BMAG_"+str(i+1) for i in range(ntomo)]]
      )
      if self.external_nz_modeling: 
        # here we send n(z) at every point in the chain as the user may
        # modify it using an external function (example: adding outliers)
       
        # to modify it
        # (1) deep copy the numpy array (so we keep track of the fiducial
        # (2) modify the copy
        # (3) call set_source_sample
        lens_nz_local = self.lens_nz.copy()

        # insert mod function here <-
        #lens_nz_local = f(lens_nz_local, nuisance parameters)

        ci.set_lens_sample(lens_nz_local)

        # user may choose to still add photo-z bias or not (here we ad)
        ci.set_nuisance_clustering_photoz(
          bias=[params.get(p,0) for p in [survey+"_DZ_L"+str(i+1) for i in range(ntomo)]]
        )
        # Lens photo-z stretch (width). CosmoLike defaults photoz[1][1][i] to
        # 1.0, so the default here MUST be 1.0 and not 0 (pf_photoz divides by
        # this value).
        ci.set_nuisance_clustering_photoz_stretch(
          stretch=[params.get(p,1.0) for p in [survey+"_STRETCH_L"+str(i+1) for i in range(ntomo)]]
        )
      else:
        ci.set_nuisance_clustering_photoz(
          bias=[params.get(p,0) for p in [survey+"_DZ_L"+str(i+1) for i in range(ntomo)]]
        )
        # Lens photo-z stretch (width). CosmoLike defaults photoz[1][1][i] to
        # 1.0, so the default here MUST be 1.0 and not 0 (pf_photoz divides by
        # this value).
        ci.set_nuisance_clustering_photoz_stretch(
          stretch=[params.get(p,1.0) for p in [survey+"_STRETCH_L"+str(i+1) for i in range(ntomo)]]
        )

  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------

  def compute_logp(self, datavector):
    theory = np.asarray(datavector, dtype=np.float64)[self._active_data_mask]
    residual = theory - self._active_data_vector
    return -0.5 * residual @ self._active_inverse_covariance @ residual

  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------

  def logp(self, **params_values):
    datavector = self.internal_get_datavector(**params_values)
    return self.compute_logp(datavector)

  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------

  def get_datavector(self, **params):        
    if self.use_emulator:
      dv = self.internal_get_datavector_emulator(**params)
    else:
      dv = self.internal_get_datavector(**params)
    return np.array(dv,dtype='float64')

  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------

  def internal_get_datavector_emulator(self, **params):
    # ---------------------------------------------------------------
    # fast parameters: m's and pm's are never emulated
    PM = [params.get(p,0) for p in [survey+"_PM"+str(i+1) for i in range(self.lens_ntomo)]]
    if self.probe not in ("xi", "xi_gg") and not all(v == 0 for v in PM):
      self.set_lens_related(**params)
      self.set_cosmo_related()
    self.set_source_related(**params)
    # ---------------------------------------------------------------

    sizes = ci.compute_data_vector_3x2pt_real_sizes()
    total_size = int(np.sum(sizes))
    dv = np.zeros(total_size, dtype='float64') 
    
    if self.probe == "xi":
      tmp = self.provider.get_cosmic_shear()
      if (len(tmp) != sizes[0]):
        raise ValueError(f'Incompatible Sizes (Emulator Cosmic Shear)')
      dv[0:sizes[0]] = tmp[0:sizes[0]]
    elif self.probe == "xi_ggl":
      tmp1 = self.provider.get_cosmic_shear()
      tmp2 = self.provider.get_ggl()
      if (len(tmp1) != sizes[0] or 
          len(tmp2) != sizes[1]):
        raise ValueError(f'Incompatible Sizes (Emulator xi_ggl)')
      istart = 0
      iend = sizes[0]
      dv[istart:iend] = tmp1[0:sizes[0]]
      
      istart = sizes[0]
      iend = sizes[0]+sizes[1]
      dv[istart:iend] = tmp2[0:sizes[1]]
    elif self.probe == "3x2pt":
      tmp1 = self.provider.get_cosmic_shear()
      tmp2 = self.provider.get_ggl()
      tmp3 = self.provider.get_wtheta()
      if (len(tmp1) != sizes[0] or 
          len(tmp2) != sizes[1] or
          len(tmp3) != sizes[2]):
        raise ValueError(f'Incompatible Sizes (Emulator 3x2pt)')
      istart = 0
      iend = sizes[0]
      dv[istart:iend] = tmp1[0:sizes[0]]
      
      istart = sizes[0]
      iend = sizes[0]+sizes[1]
      dv[istart:iend] = tmp2[0:sizes[1]]
      
      istart = sizes[0]+sizes[1]
      iend = sizes[0]+sizes[1]+sizes[2]
      dv[istart:iend] = tmp3[0:sizes[2]]
    elif self.probe == "xi_gg":
      tmp1 = self.provider.get_cosmic_shear()
      tmp3 = self.provider.get_wtheta()
      if (len(tmp1) != sizes[0] or 
          len(tmp3) != sizes[2]):
        raise ValueError(f'Incompatible Sizes (Emulator 3x2pt)')
      istart = 0
      iend = sizes[0]
      dv[istart:iend] = tmp1[0:sizes[0]]
      
      istart = sizes[0]+sizes[1]
      iend = sizes[0]+sizes[1]+sizes[2]
      dv[istart:iend] = tmp3[0:sizes[2]]
    elif self.probe == "2x2pt": 
      tmp2 = self.provider.get_ggl()
      tmp3 = self.provider.get_wtheta()
      if (len(tmp2) != sizes[1] or
          len(tmp3) != sizes[2]):
        raise ValueError(f'Incompatible Sizes (Emulator 3x2pt)')
      istart = sizes[0]
      iend = sizes[0]+sizes[1]
      dv[istart:iend] = tmp2[0:sizes[1]]
      
      istart = sizes[0]+sizes[1]
      iend = sizes[0]+sizes[1]+sizes[2]
      dv[istart:iend] = tmp3[0:sizes[2]]
    else:
      raise ValueError(f'Unknown probe')

    if not self.use_baryon_pca: 
      if not all(v == 0 for v in PM):
        dv = ci.compute_add_fpm_3x2pt_real_any_order(datavector=dv,
                                                     force_exclude_pm=0)
      else:
        dv = ci.compute_add_fpm_3x2pt_real_any_order(datavector=dv,
                                                     force_exclude_pm=1)
    else:
      Q = [params.get(p,0) for p in [survey+"_BARYON_Q"+str(i+1) for i in range(self.npcs)]]
      if not all(v == 0 for v in PM):
        dv = ci.compute_add_fpm_3x2pt_real_any_order_with_pcs(datavector=dv,
                                                              Q=Q,
                                                              force_exclude_pm=0)
      else:
        dv = ci.compute_add_fpm_3x2pt_real_any_order_with_pcs(datavector=dv,
                                                              Q=Q,
                                                              force_exclude_pm=1)
    dv = np.array(dv, dtype='float64')
    
    if self.print_datavector:
      size = len(dv)
      out = np.zeros(shape=(size, 2))
      out[:,0] = np.arange(0, size)
      out[:,1] = dv
      # Preserve a float64 round trip. DES covariance inversion amplifies the
      # rounding error from the historical eight-digit output format.
      fmt = '%d', '%1.17e'
      np.savetxt(self.print_datavector_file, out, fmt = fmt)
    return dv
    
  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------

  def internal_get_datavector(self, **params):
    self.set_cosmo_related()
    if self.probe != "xi":
        self.set_lens_related(**params)
    self.set_source_related(**params)
    
    if self.create_baryon_pca:
      pcs = ci.compute_baryon_pcas(scenarios=self.baryon_pca_select_sims, allsims=self.allsims)
      np.savetxt(self.filename_baryon_pca, pcs)
      datavector = ci.compute_data_vector_masked()
    elif self.use_baryon_pca: 
      Q = [params.get(p,0) for p in [survey+"_BARYON_Q"+str(i+1) for i in range(self.npcs)]]     
      datavector = ci.compute_data_vector_masked_with_baryon_pcs(Q=Q)
    else:  
      datavector = ci.compute_data_vector_masked()

    if self.print_datavector:
      size = len(datavector)
      out = np.zeros(shape=(size, 2))
      out[:,0] = np.arange(0, size)
      out[:,1] = datavector
      fmt = '%d', '%1.17e'
      np.savetxt(self.print_datavector_file, out, fmt = fmt)
    return datavector
