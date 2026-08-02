// @voxgig/omni-js - shared multi-language test runner.

const runner = require('./runner')
const util = require('./util')

module.exports = { ...runner, ...util }
