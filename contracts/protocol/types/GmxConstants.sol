// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {IGmxExchangeRouter} from "../../utils/exchanges/gmx/IGmxSynthetics.sol";

/// @title GmxConstants
/// @notice Chain-specific GMX v2 constants shared across the protocol.
///  Kept in a types library so both NAV (`GmxLib`) and adapter (`GmxAdapterLib`)
///  code can use them without creating a circular dependency.
library GmxConstants {
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;
    address internal constant WRAPPED_NATIVE = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    IGmxExchangeRouter internal constant GMX_ROUTER = IGmxExchangeRouter(0x1C3fa76e6E1088bCE750f23a5BFcffa1efEF6A41);

    address internal constant _GMX_READER = 0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789;
    address internal constant _GMX_DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address internal constant _GMX_ROLE_STORE = 0x3c3d99FD298f679DBC2CEcd132b4eC4d0F5e6e72;
    address internal constant _GMX_REFERRAL_STORAGE = 0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d;
    address internal constant _GMX_CHAINLINK_PRICE_FEED = 0x38B8dB61b724b51e42A88Cb8eC564CD685a0f53B;
    uint256 internal constant _MAX_GMX_POSITIONS = 32;

    bytes32 internal constant _KEY_FEE_BASE = keccak256(abi.encode("ESTIMATED_GAS_FEE_BASE_AMOUNT_V2_1"));
    bytes32 internal constant _KEY_FEE_PER_ORACLE = keccak256(abi.encode("ESTIMATED_GAS_FEE_PER_ORACLE_PRICE"));
    bytes32 internal constant _POSITION_SIZE_IN_USD_KEY = keccak256(abi.encode("SIZE_IN_USD"));
    bytes32 internal constant _KEY_FEE_MULTIPLIER = keccak256(abi.encode("ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR"));
    bytes32 internal constant _KEY_INCREASE_ORDER_GAS = keccak256(abi.encode("INCREASE_ORDER_GAS_LIMIT"));
    bytes32 internal constant _KEY_DECREASE_ORDER_GAS = keccak256(abi.encode("DECREASE_ORDER_GAS_LIMIT"));
    uint256 internal constant _FLOAT_PRECISION = 1e30;
    uint256 internal constant _FALLBACK_HEARTBEAT = 24 hours;

    uint256 internal constant _ORDER_ORACLE_PRICE_COUNT = 3;
}
