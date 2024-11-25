module.exports = {
    skipFiles: [
        './examples',
        './tokens',
        './utils',
        'protocol/extensions/adapters/AUniswapRouter.sol'
    ],
    mocha: {
        grep: "@skip-on-coverage", // Find everything with this tag
        invert: true               // Run the grep's inverse set.
    },
    configureYulOptimizer: true,
    viaIR: true,
    details: {
      yulDetails: {
        optimizerSteps:"u",
      },
    },
    solcOptimizerDetails: {
      peephole: false,
      jumpdestRemover: false,
      orderLiterals: true,
      deduplicate: false,
      cse: false,
      constantOptimizer: false,
      yul: true
    }
};
