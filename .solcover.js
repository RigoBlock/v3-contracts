module.exports = {
    skipFiles: [
        './examples',
        './tokens',
        './utils'
    ],
    mocha: {
        grep: "@skip-on-coverage", // Find everything with this tag
        invert: true               // Run the grep's inverse set.
    },
    configureYulOptimizer: true,
    solcOptimizerDetails: {
      peephole: false,
      inliner: false,
      jumpdestRemover: false,
      orderLiterals: true,
      deduplicate: false,
      cse: false,
      constantOptimizer: false,
      yul: false
    }
};
