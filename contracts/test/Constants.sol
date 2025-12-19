// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

/// @title Constants - Shared constants for testing and deployment
/// @notice Centralizes hardcoded values used across tests to reduce duplication and RPC load
library Constants {
    /*//////////////////////////////////////////////////////////////
                                BLOCK NUMBERS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Mainnet block number after oracle deployment (22,425,175)
    /// @dev Use this for tests requiring oracle price feeds
    uint256 internal constant MAINNET_BLOCK_RECENT = 22_600_000;
    
    /// @notice Legacy mainnet block before oracle deployment
    /// @dev Use only for tests that don't need price feeds (reduces RPC load)
    uint256 internal constant MAINNET_BLOCK_LEGACY = 21_000_000;
    
    /// @notice Base chain block number for fork tests
    uint256 internal constant BASE_BLOCK = 35521323;
    
    /*//////////////////////////////////////////////////////////////
                            CHAIN IDs
    //////////////////////////////////////////////////////////////*/
    
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;
    uint256 internal constant OPTIMISM_CHAIN_ID = 10;
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant POLYGON_CHAIN_ID = 137;
    uint256 internal constant BSC_CHAIN_ID = 56;
    uint256 internal constant UNICHAIN_CHAIN_ID = 1301;
    
    /*//////////////////////////////////////////////////////////////
                        RIGOBLOCK INFRASTRUCTURE
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Rigoblock Authority contract (same across all chains)
    address internal constant AUTHORITY = 0xe35129A1E0BdB913CF6Fd8332E9d3533b5F41472;
    
    /// @notice Rigoblock Pool Factory (same across all chains)
    address internal constant FACTORY = 0x8DE8895ddD702d9a216E640966A98e08c9228f24;
    
    /// @notice Rigoblock Registry (same across all chains)  
    address internal constant REGISTRY = 0x06767e8090bA5c4Eca89ED00C3A719909D503ED6;
    
    /// @notice GRG Token on Ethereum
    address internal constant GRG_TOKEN = 0x4FbB350052Bca5417566f188eB2EBCE5b19BC964;
    
    /// @notice GRG Staking Proxy on Ethereum
    address internal constant GRG_STAKING = 0x730dDf7b602dB822043e0409d8926440395e07fE;
    
    /// @notice Rigoblock Governance Proxy
    address internal constant GOV_PROXY = 0x5F8607739c2D2d0b57a4292868C368AB1809767a;
    
    /// @notice Oracle contract on Ethereum
    address internal constant ORACLE = 0xB13250f0Dc8ec6dE297E81CDA8142DB51860BaC4;
    
    /// @notice ExtensionsMapDeployer on Ethereum  
    address internal constant EXTENSIONS_MAP_DEPLOYER = 0x5A69bBe7f8F9dbDBFEa35CeFf33e093C6690d437;
    
    /// @notice Test pool address with cross-chain assets
    address internal constant TEST_POOL = 0xEfa4bDf566aE50537A507863612638680420645C;
    
    /*//////////////////////////////////////////////////////////////
                            ACROSS SPOKE POOLS
    //////////////////////////////////////////////////////////////*/
    
    address internal constant ETH_SPOKE_POOL = 0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5;
    address internal constant ARB_SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
    address internal constant OPT_SPOKE_POOL = 0x6f26Bf09B1C792e3228e5467807a900A503c0281;
    address internal constant BASE_SPOKE_POOL = 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64;
    
    /*//////////////////////////////////////////////////////////////
                            UNISWAP V4 
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Uniswap V4 Position Manager on Ethereum
    address internal constant UNISWAP_V4_POSM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    
    /*//////////////////////////////////////////////////////////////
                            TOKENS - ETHEREUM
    //////////////////////////////////////////////////////////////*/
    
    address internal constant ETH_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ETH_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ETH_WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    
    /*//////////////////////////////////////////////////////////////
                            TOKENS - ARBITRUM
    //////////////////////////////////////////////////////////////*/
    
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address internal constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant ARB_WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
    
    /*//////////////////////////////////////////////////////////////
                            TOKENS - OPTIMISM
    //////////////////////////////////////////////////////////////*/
    
    address internal constant OPT_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant OPT_USDT = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address internal constant OPT_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant OPT_WBTC = 0x68f180fcCe6836688e9084f035309E29Bf0A2095;
    
    /*//////////////////////////////////////////////////////////////
                            TOKENS - BASE
    //////////////////////////////////////////////////////////////*/
    
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    // Note: No WBTC on Base in CrosschainLib
    
    /*//////////////////////////////////////////////////////////////
                            TOKENS - POLYGON
    //////////////////////////////////////////////////////////////*/
    
    address internal constant POLY_USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address internal constant POLY_USDT = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;
    address internal constant POLY_WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address internal constant POLY_WBTC = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;
    
    /*//////////////////////////////////////////////////////////////
                            TOKENS - BSC
    //////////////////////////////////////////////////////////////*/
    
    address internal constant BSC_USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant BSC_WETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    // Note: No WBTC on BSC in CrosschainLib
    
    /*//////////////////////////////////////////////////////////////
                            TOKENS - UNICHAIN  
    //////////////////////////////////////////////////////////////*/
    
    address internal constant UNI_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant UNI_WETH = 0x4200000000000000000000000000000000000006;
    
    /*//////////////////////////////////////////////////////////////
                        STORAGE SLOTS (ERC-7201)
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Standard implementation slot for proxies
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    
    /// @notice Pool initialization storage slot
    bytes32 internal constant POOL_INIT_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;
    
    /// @notice Virtual balances for cross-chain NAV management
    bytes32 internal constant VIRTUAL_BALANCES_SLOT = 0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1;
    
    /// @notice Chain NAV spreads storage slot
    bytes32 internal constant CHAIN_NAV_SPREADS_SLOT = 0x1effae8a79ec0c3b88754a639dc07316aa9c4de89b6b9794fb7c1d791c43492d;
    
    /// @notice Active tokens registry slot
    bytes32 internal constant ACTIVE_TOKENS_SLOT = 0xbd68f1d41a93565ce29970ec13a2bc56a87c8bdd0b31366d8baa7620f41eb6cb;
    
    /// @notice Applications storage slot (from MixinConstants.sol)
    bytes32 internal constant APPLICATIONS_SLOT = 0xdc487a67cca3fd0341a90d1b8834103014d2a61e6a212e57883f8680b8f9c831;
    
    /// @notice Pool variables storage slot  
    bytes32 internal constant POOL_VARIABLES_SLOT = 0xe3ed9e7d534645c345f2d15f0c405f8de0227b60eb37bbeb25b26db462415dec;
    
    /// @notice Pool tokens storage slot
    bytes32 internal constant POOL_TOKENS_SLOT = 0xf46fb7ff9ff9a406787c810524417c818e45ab2f1997f38c2555c845d23bb9f6;
    
    /// @notice Pool accounts storage slot
    bytes32 internal constant POOL_ACCOUNTS_SLOT = 0xfd7547127f88410746fb7969b9adb4f9e9d8d2436aa2d2277b1103542deb7b8e;
    
    /// @notice Token registry storage slot
    bytes32 internal constant TOKEN_REGISTRY_SLOT = 0x3dcde6752c7421366e48f002bbf8d6493462e0e43af349bebb99f0470a12300d;
    
    /// @notice UniswapV4 token IDs storage slot
    bytes32 internal constant UNIV4_TOKEN_IDS_SLOT = 0xd87266b00c1e82928c0b0200ad56e2ee648a35d4e9b273d2ac9533471e3b5d3c;
    
    /*//////////////////////////////////////////////////////////////
                            TEST HELPERS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Standard decimals for USDC/USDT
    uint8 internal constant STABLECOIN_DECIMALS = 6;
    
    /// @notice Standard decimals for WETH/WBTC
    uint8 internal constant STANDARD_DECIMALS = 18;
    
    /// @notice Max tick spacing for Uniswap V4 pools
    int24 internal constant MAX_TICK_SPACING = 32767;
    
    /*//////////////////////////////////////////////////////////////
                            GOVERNANCE CONSTANTS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Minimum proposal threshold floor (20k GRG)
    uint256 internal constant PROPOSAL_THRESHOLD_FLOOR_MIN = 20_000e18;
    
    /// @notice Maximum proposal threshold cap (100k GRG)
    uint256 internal constant PROPOSAL_THRESHOLD_CAP_MIN = 100_000e18;
    
    /// @notice Minimum quorum floor (100k GRG)
    uint256 internal constant QUORUM_FLOOR_MIN = 100_000e18;
    
    /// @notice Maximum quorum cap (400k GRG)  
    uint256 internal constant QUORUM_CAP_MIN = 400_000e18;
}