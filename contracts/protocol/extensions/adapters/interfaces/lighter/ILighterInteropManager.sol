// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @notice Core balance routes for EVM<->Core transfers. Mirrors Lighter's RouteType enum.
enum LighterRouteType {
    Perps,
    Spot
}

/// @title ILighterInteropManager - Lighter EvmInteropManager predeploy interface.
/// @dev Only the methods exposed by the Rigoblock adapter are included; signatures match
///  Lighter's predeploy exactly (see docs/lighter/INTEGRATION.md).
interface ILighterInteropManager {
    /// @notice Sends tokens/ETH from LighterEVM to a LighterCore account.
    /// @dev The first transfer to a fresh account creates the Core master account (+146k gas).
    function sendToCore(
        uint32 assetIndex,
        address to,
        bool isL1Account,
        uint256 amount,
        LighterRouteType routeType
    ) external payable returns (uint64 reqId);

    /// @notice Sends tokens from a LighterCore account to an LighterEVM address.
    /// @dev Must be called by the controlling EVM address of the Core account (the pool).
    function sendToEvm(
        uint48 accountIndex,
        uint32 assetIndex,
        address evmRecipient,
        LighterRouteType routeType,
        uint64 baseAmount
    ) external returns (uint64 reqId);
}
