// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {CrosschainTokens} from "../protocol/types/CrosschainTokens.sol";
import {ForkBlocks} from "./ForkBlocks.sol";

/// @title Constants - Shared constants for testing and deployment
/// @notice Centralizes hardcoded values used across tests to reduce duplication and RPC load
library Constants {
    /*//////////////////////////////////////////////////////////////
                                BLOCK NUMBERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mainnet block number after oracle deployment (22,425,175)
    /// @dev Use this for tests requiring oracle price feeds
    /// @dev Re-exported from ForkBlocks for backward compatibility
    uint256 internal constant MAINNET_BLOCK = ForkBlocks.MAINNET_BLOCK;

    /// @notice Base chain block number for fork tests
    /// @dev Re-exported from ForkBlocks for backward compatibility
    uint256 internal constant BASE_BLOCK = ForkBlocks.BASE_BLOCK;

    /// @notice Polygon chain block number for fork tests
    /// @dev Re-exported from ForkBlocks for backward compatibility
    uint256 internal constant POLYGON_BLOCK = ForkBlocks.POLYGON_BLOCK;

    /// @notice Unichain block number for fork tests
    /// @dev Re-exported from ForkBlocks for backward compatibility
    uint256 internal constant UNICHAIN_BLOCK = ForkBlocks.UNICHAIN_BLOCK;

    /// @notice Arbitrum One block number for fork tests (GMX adapter)
    /// @dev Re-exported from ForkBlocks for backward compatibility
    uint256 internal constant ARB_BLOCK = ForkBlocks.ARB_BLOCK;

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
    address internal constant UNI_ORACLE = 0x54bd666eA7FD8d5404c0593Eab3Dcf9b6E2A3aC4;

    /// @notice Rigoblock token jar (same across all chains)
    /// @dev Receives spread fees accrued from pool operations
    address internal constant TOKEN_JAR = 0xA0F9C380ad1E1be09046319fd907335B2B452B37;

    /// @notice Test pool address with cross-chain assets
    address internal constant TEST_POOL = 0xEfa4bDf566aE50537A507863612638680420645C;

    /*//////////////////////////////////////////////////////////////
                        0x SWAP AGGREGATOR
    //////////////////////////////////////////////////////////////*/

    /// @notice 0x AllowanceHolder (Cancun version, same on all supported chains)
    address internal constant ZERO_EX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    /// @notice 0x Deployer/Registry (same on all chains)
    address internal constant ZERO_EX_DEPLOYER = 0x00000000000004533Fe15556B1E086BB1A72cEae;

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

    /*//////////////////////////////////////////////////////////////
                            GMX v2 — ARBITRUM
    //////////////////////////////////////////////////////////////*/

    /// @dev Rigoblock oracle hook on Arbitrum (EOracle constructor arg).
    address internal constant ARB_ORACLE = 0x3043e182047F8696dFE483535785ed1C3681baC4;

    /// @dev GRG staking proxy on Arbitrum.
    address internal constant ARB_GRG_STAKING = 0xD495296510257DAdf0d74846a8307bf533a0fB48;

    /// @dev Uniswap v4 PositionManager on Arbitrum.
    address internal constant ARB_UNISWAP_V4_POSM = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;

    /// @notice GMX v2 ExchangeRouter on Arbitrum.
    address internal constant ARB_GMX_EXCHANGE_ROUTER = 0x1C3fa76e6E1088bCE750f23a5BFcffa1efEF6A41;

    /// @notice GMX v2 DataStore on Arbitrum.
    address internal constant ARB_GMX_DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;

    /// @notice GMX v2 Reader on Arbitrum.
    address internal constant ARB_GMX_READER = 0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789;

    /// @notice GMX v2 Chainlink price feed provider on Arbitrum.
    address internal constant ARB_GMX_CHAINLINK_PRICE_FEED = 0x38B8dB61b724b51e42A88Cb8eC564CD685a0f53B;

    /// @notice GMX v2 referral storage on Arbitrum (gmx-contracts ReferralStorage).
    address internal constant ARB_GMX_REFERRAL_STORAGE = 0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d;

    /// @notice GMX v2 RoleStore on Arbitrum — used in fork tests to look up keeper addresses.
    address internal constant ARB_GMX_ROLE_STORE = 0x3c3d99FD298f679DBC2CEcd132b4eC4d0F5e6e72;

    /// @notice GMX v2 ETH/USD market token (GM:ETH-USDC) on Arbitrum.
    address internal constant ARB_GMX_ETH_USD_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;

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
