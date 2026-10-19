// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @title ILighterCoreEntrypoint - Lighter EvmToCoreEntrypoint predeploy interface.
/// @dev Only the methods exposed by the Rigoblock adapter are included; signatures match
///  Lighter's predeploy exactly (see docs/lighter/INTEGRATION.md).
/// @dev `changePubKey` is deliberately NOT exposed: registering an API key would allow
///  off-chain trading in markets the pool cannot track on-chain, breaking NAV integrity.
///  See docs/lighter/API_KEYS.md.
interface ILighterCoreEntrypoint {
    /// @notice Creates an order on LighterCore. The immediate EVM caller is treated as the authority.
    function createOrder(
        uint48 accountIndex,
        uint16 marketIndex,
        uint48 clientOrderIndex,
        uint8 orderType,
        uint8 timeInForce,
        uint64 orderExpiry,
        uint48 amount,
        uint32 price,
        bool isAsk,
        bool reduceOnly,
        uint32 triggerPrice
    ) external returns (uint64 reqId);

    /// @notice Cancels an open order. `orderIndex` below 2^48 is treated as a clientOrderIndex.
    function cancelOrder(uint48 accountIndex, uint64 orderIndex) external returns (uint64 reqId);

    /// @notice Cancels all open orders of the account.
    function cancelAllOrders(uint48 accountIndex) external returns (uint64 reqId);
}
