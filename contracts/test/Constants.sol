// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {CrosschainTokens} from "../protocol/types/CrosschainTokens.sol";

/// @title Constants - Shared constants for testing and deployment
/// @notice Centralizes hardcoded values used across tests to reduce duplication and RPC load
library Constants {
    /*//////////////////////////////////////////////////////////////
                                BLOCK NUMBERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mainnet block number after oracle deployment (22,425,175)
    /// @dev Use this for tests requiring oracle price feeds
    uint256 internal constant MAINNET_BLOCK = 24_000_000;

    /// @notice Base chain block number for fork tests
    uint256 internal constant BASE_BLOCK = 39521323;

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
    address internal constant BASE_GRG_TOKEN = 0x09188484e1Ab980DAeF53a9755241D759C5B7d60;

    /// @notice GRG Staking Proxy on Ethereum
    address internal constant GRG_STAKING = 0x730dDf7b602dB822043e0409d8926440395e07fE;
    address internal constant BASE_GRG_STAKING = 0xc758Ea84d6D978fe86Ee29c1fbD47B4F302F1992;
    address internal constant POLYGON_GRG_STAKING = 0xC87d1B952303ae3A9218727692BAda6723662dad;

    /// @notice Rigoblock Governance Proxy
    address internal constant GOV_PROXY = 0x5F8607739c2D2d0b57a4292868C368AB1809767a;

    /// @notice Oracle contract on Ethereum
    address internal constant ORACLE = 0xB13250f0Dc8ec6dE297E81CDA8142DB51860BaC4;
    address internal constant BASE_ORACLE = 0x59f39091Fd6f47e9D0bCB466F74e305f1709BAC4;
    address internal constant POLYGON_ORACLE = 0x1D8691A1A7d53B60DeDd99D8079E026cB0E5bac4;

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
                        ACROSS MULTICALL HANDLERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Across Protocol Multicall Handler (standard address across chains)
    address internal constant ETH_MULTICALL_HANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
    address internal constant ARB_MULTICALL_HANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
    address internal constant OPT_MULTICALL_HANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
    address internal constant BASE_MULTICALL_HANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
    address internal constant POLY_MULTICALL_HANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
    address internal constant UNI_MULTICALL_HANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;
    address internal constant BSC_MULTICALL_HANDLER = 0xAC537C12fE8f544D712d71ED4376a502EEa944d7;

    /*//////////////////////////////////////////////////////////////
                            UNISWAP V4 
    //////////////////////////////////////////////////////////////*/

    /// @notice Uniswap V4 Position Manager on Ethereum
    address internal constant UNISWAP_V4_POSM = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant BASE_UNISWAP_V4_POSM = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant POLYGON_UNISWAP_V4_POSM = 0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9;

    /*//////////////////////////////////////////////////////////////
                            TOKENS - SHARED FROM CrosschainTokens
    //////////////////////////////////////////////////////////////*/

    // Ethereum mainnet - use shared constants
    address internal constant ETH_USDC = CrosschainTokens.ETH_USDC;
    address internal constant ETH_USDT = CrosschainTokens.ETH_USDT;
    address internal constant ETH_WETH = CrosschainTokens.ETH_WETH;
    address internal constant ETH_WBTC = CrosschainTokens.ETH_WBTC;

    // Arbitrum - use shared constants
    address internal constant ARB_USDC = CrosschainTokens.ARB_USDC;
    address internal constant ARB_USDT = CrosschainTokens.ARB_USDT;
    address internal constant ARB_WETH = CrosschainTokens.ARB_WETH;
    address internal constant ARB_WBTC = CrosschainTokens.ARB_WBTC;

    // Optimism - use shared constants
    address internal constant OPT_USDC = CrosschainTokens.OPT_USDC;
    address internal constant OPT_USDT = CrosschainTokens.OPT_USDT;
    address internal constant OPT_WETH = CrosschainTokens.OPT_WETH;
    address internal constant OPT_WBTC = CrosschainTokens.OPT_WBTC;

    // Base - use shared constants
    address internal constant BASE_USDC = CrosschainTokens.BASE_USDC;
    address internal constant BASE_USDT = CrosschainTokens.BASE_USDT;
    address internal constant BASE_WETH = CrosschainTokens.BASE_WETH;

    // Polygon - use shared constants
    address internal constant POLY_USDC = CrosschainTokens.POLY_USDC;
    address internal constant POLY_USDT = CrosschainTokens.POLY_USDT;
    address internal constant POLY_WETH = CrosschainTokens.POLY_WETH;
    address internal constant POLY_WBTC = CrosschainTokens.POLY_WBTC;

    // BSC - use shared constants
    address internal constant BSC_USDC = CrosschainTokens.BSC_USDC;
    address internal constant BSC_USDT = CrosschainTokens.BSC_USDT;
    address internal constant BSC_WETH = CrosschainTokens.BSC_WETH;

    // Unichain - use shared constants
    address internal constant UNI_USDC = CrosschainTokens.UNI_USDC;
    address internal constant UNI_WETH = CrosschainTokens.UNI_WETH;

    // Additional tokens not in crosschain lib (chain-specific)
    address internal constant POLY_WPOL = 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6;
    address internal constant BSC_WBNB = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;

    /*//////////////////////////////////////////////////////////////
                        STORAGE SLOTS (ERC-7201)
    //////////////////////////////////////////////////////////////*/

    /// @notice Standard implementation slot for proxies
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice Pool initialization storage slot
    bytes32 internal constant POOL_INIT_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;

    /// @notice Virtual balances for cross-chain NAV management
    bytes32 internal constant VIRTUAL_BALANCES_SLOT =
        0x19797d8be84f650fe18ebccb97578c2adb7abe9b7c86852694a3ceb69073d1d1;

    /// @notice Chain NAV spreads storage slot
    bytes32 internal constant CHAIN_NAV_SPREADS_SLOT =
        0x1effae8a79ec0c3b88754a639dc07316aa9c4de89b6b9794fb7c1d791c43492d;

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
