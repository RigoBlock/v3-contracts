// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

error UnknownMarket(uint16 marketId);

/// @title LighterConstants
/// @notice Predeploy addresses and protocol constants for the LighterEVM integration.
/// @dev The `0x6600...` predeploy layout and the EVM chain ID are stable protocol properties.
///  The USDC token address and asset index are devnet values and are expected to change on future
///  public testnet/mainnet deployments. Verified against the Lighter docs (apidocs.lighter.xyz)
///  and the elliottech/lighter-contracts repo (lighter-evm-devnet branch); see docs/lighter/INTEGRATION.md.
library LighterConstants {
    /// @notice LighterEVM chain ID (19_529 = 0x4C49 = "LI").
    uint256 internal constant LIGHTEREVM_CHAIN_ID = 19_529;

    /// @notice READ_CORE precompile: synchronous reads of LighterCore state.
    address internal constant READ_CORE = 0x6600000000000000000000000000000000000000;

    /// @notice EvmInteropManager predeploy: user-facing EVM<->Core token transfers (deposit/withdraw).
    address internal constant EVM_INTEROP_MANAGER = 0x6600000000000000000000000000000000000001;

    /// @notice EvmToCoreEntrypoint predeploy: user-facing Core account/order writes.
    address internal constant CORE_ENTRYPOINT = 0x6600000000000000000000000000000000000009;

    /// @notice USDC token on LighterEVM (protocol-linked representation, devnet).
    address internal constant USDC = 0xf2A5728d366c6d0f764Af612cD47F3608E2B4d5B;

    /// @notice USDC asset index in LighterCore (devnet).
    uint32 internal constant USDC_ASSET_INDEX = 3;

    /// @notice Native ETH asset index in LighterCore.
    uint32 internal constant ETH_ASSET_INDEX = 1;

    /// @notice Core balance route: perps (margin) collateral.
    uint8 internal constant ROUTE_TYPE_PERPS = 0;

    /// @notice Perp market IDs occupy the 0-254 range; spot markets start at 2048.
    uint16 internal constant FIRST_SPOT_MARKET_ID = 2048;

    /// @notice Maximum number of perp markets tracked in pool storage for NAV valuation.
    /// @dev Bounds the NAV read loop: each tracked market costs ~2 READ_CORE calls (~40-50k gas),
    ///  so 32 markets stay well within the 4.25M LighterEVM block gas target. See docs/lighter/INTEGRATION.md.
    uint256 internal constant MAX_TRACKED_MARKETS = 32;

    /// @notice Returns the (sizeDecimals, priceDecimals) scale of a whitelisted perp market.
    /// @dev These scales are NOT readable on-chain (READ_CORE market info does not expose them;
    ///  the Lighter docs direct integrators to the Core `orderBookDetails` API). They are
    ///  protocol-level per-market constants, so a wrong value would distort pool NAV for every
    ///  token holder — therefore they can never be caller input and must come from this table.
    ///  Values fetched 2026-10-20 from `GET /api/v1/orderBookDetails?market_id=N` on Lighter
    ///  mainnet (devnet exposes no public Core API; devnet markets 0-3 mirror mainnet configs).
    ///  Add new markets here at release time. See docs/lighter/INTEGRATION.md ("Market decimals").
    function marketDecimals(uint16 marketId) internal pure returns (uint8 sizeDecimals, uint8 priceDecimals) {
        if (marketId == 0) return (4, 2); // ETH-PERP
        if (marketId == 1) return (5, 1); // BTC-PERP
        if (marketId == 2) return (3, 3); // SOL-PERP
        if (marketId == 3) return (0, 6); // DOGE-PERP
        revert UnknownMarket(marketId);
    }
}
