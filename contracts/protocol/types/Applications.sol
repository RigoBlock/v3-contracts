pragma solidity ^0.8.0;

/// @notice Supported Applications.
/// @dev Preserve order when adding new applications, last one is the counter.
enum Applications {
    GRG_STAKING,
    UNIV3_LIQUIDITY,
    UNIV4_LIQUIDITY,
    // append new applications here, up to a total of 31
    COUNT
}