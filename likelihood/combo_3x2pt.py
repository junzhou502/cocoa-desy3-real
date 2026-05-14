from cobaya.likelihoods.desy3_real._cosmolike_prototype_base import _cosmolike_prototype_base, survey
import cosmolike_des_y3_interface as ci
import numpy as np

class combo_3x2pt(_cosmolike_prototype_base):
  def initialize(self):
    super(combo_3x2pt,self).initialize(probe="3x2pt")
