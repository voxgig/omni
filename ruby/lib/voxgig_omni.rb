# voxgig_omni - shared multi-language test runner.

require_relative 'voxgig_omni/util'
require_relative 'voxgig_omni/runner'

module VoxgigOmni
  module_function

  def make_runner(specref, provider = nil)
    Runner.make_runner(specref, provider)
  end
end
