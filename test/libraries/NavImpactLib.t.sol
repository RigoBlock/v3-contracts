// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {NavImpactLib} from "../../contracts/protocol/libraries/NavImpactLib.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";

/// @dev NavImpactLib.validateNavImpact() runs in the pool's execution context
///      (via delegatecall): `address(this)` is the pool.  This harness replicates
///      that by letting the library call `address(this)` for external interfaces
///      and reading its own storage for pool parameters.
///
///      Pool storage is initialised in the constructor using the real StorageLib
///      accessors so the Solidity compiler generates correct struct layout writes.
///
///      The test then mocks `ISmartPoolState(harness).getPoolTokens()` and
///      `IEOracle(harness).convertTokenAmount(...)` via vm.mockCall.
///
///      VirtualSupply is set by a dedicated setter that writes to the exact
///      storage slot used by VirtualStorageLib at runtime.
contract NavImpactLibHarness {
    constructor(address baseToken, uint8 decimals) {
        StorageLib.pool().baseToken = baseToken;
        StorageLib.pool().decimals = decimals;
    }

    function validateNavImpact(
        address token,
        uint256 amount,
        uint256 toleranceBps
    ) external view {
        NavImpactLib.validateNavImpact(token, amount, toleranceBps);
    }

    function validateSupply(uint256 totalSupply, int256 virtualSupply) external pure {
        NavImpactLib.validateSupply(totalSupply, virtualSupply);
    }

    /// @dev Writes virtual supply to the slot read by VirtualStorageLib at runtime.
    function setVirtualSupplyForTest(int256 vs) external {
        bytes32 slot = VirtualStorageLib.VIRTUAL_SUPPLY_SLOT;
        assembly {
            sstore(slot, vs)
        }
    }
}

/// @title NavImpactLibTest
/// @notice Non-fork unit tests for NavImpactLib.
contract NavImpactLibTest is Test {
    address internal constant BASE_TOKEN = address(0xBEEF);
    address internal constant OTHER_TOKEN = address(0xCAFE);

    NavImpactLibHarness internal harness;

    function setUp() public {
        harness = new NavImpactLibHarness(BASE_TOKEN, 18);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _mockPoolTokens(uint256 unitaryValue, uint256 totalSupply) internal {
        ISmartPoolState.PoolTokens memory pt =
            ISmartPoolState.PoolTokens({unitaryValue: unitaryValue, totalSupply: totalSupply});
        vm.mockCall(
            address(harness),
            abi.encodeWithSelector(ISmartPoolState.getPoolTokens.selector),
            abi.encode(pt)
        );
    }

    function _setVirtualSupply(int256 vs) internal {
        harness.setVirtualSupplyForTest(vs);
    }

    // =========================================================================
    // validateNavImpact — base-token path
    // =========================================================================

    function test_ValidateNavImpact_BaseToken_WithinTolerance() public {
        _mockPoolTokens(1e18, 100e18);
        _setVirtualSupply(0);
        // totalAssetsValue = 1e18 * 100e18 / 1e18 = 100e18
        // transferValue = 1e18 → impactBps = 100
        harness.validateNavImpact(BASE_TOKEN, 1e18, 500); // 100 <= 500 → pass
    }

    function test_ValidateNavImpact_BaseToken_ExceedsTolerance_Reverts() public {
        _mockPoolTokens(1e18, 100e18);
        _setVirtualSupply(0);
        // impactBps = 2000; tolerance = 1000 → revert
        vm.expectRevert(NavImpactLib.NavImpactTooHigh.selector);
        harness.validateNavImpact(BASE_TOKEN, 20e18, 1000);
    }

    function test_ValidateNavImpact_ZeroEffectiveSupply_AllowsAnyTransfer() public {
        _mockPoolTokens(1e18, 0);
        _setVirtualSupply(0); // effectiveSupply = 0 + 0 = 0 → early return
        harness.validateNavImpact(BASE_TOKEN, type(uint256).max, 0);
    }

    function test_ValidateNavImpact_NegativeEffectiveSupply_AllowsAnyTransfer() public {
        _mockPoolTokens(1e18, 100e18);
        _setVirtualSupply(-int256(200e18)); // effectiveSupply = 100e18 - 200e18 < 0
        harness.validateNavImpact(BASE_TOKEN, type(uint256).max, 0);
    }

    function test_ValidateNavImpact_ZeroUnitaryValue_AllowsAnyTransfer() public {
        _mockPoolTokens(0, 100e18);
        _setVirtualSupply(0);
        // totalAssetsValue = 0 * 100e18 / 1e18 = 0 → early return
        harness.validateNavImpact(BASE_TOKEN, type(uint256).max, 0);
    }

    function test_ValidateNavImpact_PositiveVirtualSupply_LowerImpact() public {
        _mockPoolTokens(1e18, 100e18);
        _setVirtualSupply(int256(100e18)); // effectiveSupply = 200e18
        // totalAssetsValue = 200e18; impactBps = 10e18 * 10000 / 200e18 = 500
        harness.validateNavImpact(BASE_TOKEN, 10e18, 500); // 500 <= 500 → pass
    }

    function test_ValidateNavImpact_ExactBoundary_Passes() public {
        _mockPoolTokens(1e18, 100e18);
        _setVirtualSupply(0);
        // impactBps = 1000; tolerance = 1000 → 1000 <= 1000 → pass
        harness.validateNavImpact(BASE_TOKEN, 10e18, 1000);
    }

    // =========================================================================
    // validateNavImpact — EOracle path (non-base token)
    // =========================================================================

    function test_ValidateNavImpact_NonBaseToken_OraclePath_WithinTolerance() public {
        _mockPoolTokens(1e18, 100e18);
        _setVirtualSupply(0);
        // Mock harness.convertTokenAmount(OTHER_TOKEN, 10e18, BASE_TOKEN) → 10e18
        vm.mockCall(
            address(harness),
            abi.encodeWithSelector(
                IEOracle.convertTokenAmount.selector, OTHER_TOKEN, int256(10e18), BASE_TOKEN
            ),
            abi.encode(int256(10e18))
        );
        // impactBps = 1000; tolerance = 2000 → pass
        harness.validateNavImpact(OTHER_TOKEN, 10e18, 2000);
    }

    function test_ValidateNavImpact_NonBaseToken_ExceedsTolerance_Reverts() public {
        _mockPoolTokens(1e18, 100e18);
        _setVirtualSupply(0);
        vm.mockCall(
            address(harness),
            abi.encodeWithSelector(
                IEOracle.convertTokenAmount.selector, OTHER_TOKEN, int256(50e18), BASE_TOKEN
            ),
            abi.encode(int256(50e18))
        );
        // impactBps = 5000; tolerance = 4999 → revert
        vm.expectRevert(NavImpactLib.NavImpactTooHigh.selector);
        harness.validateNavImpact(OTHER_TOKEN, 50e18, 4999);
    }

    // =========================================================================
    // validateSupply
    // =========================================================================

    function test_ValidateSupply_ZeroVirtualSupply_Passes() public view {
        harness.validateSupply(100e18, 0);
    }

    function test_ValidateSupply_PositiveVirtualSupply_Passes() public view {
        harness.validateSupply(100e18, int256(50e18));
    }

    /// @notice 87.5e18 * 8 = 700e18 == 100e18 * 7 → NOT strictly greater → pass.
    function test_ValidateSupply_NegativeVS_AtExactThreshold_Passes() public view {
        // -87.5e18 = -875e17; 875e17 * 8 = 700e18 = 100e18 * 7 → equal → NOT > → pass
        harness.validateSupply(100e18, -int256(875e17));
    }

    /// @notice 88e18 * 8 = 704e18 > 100e18 * 7 = 700e18 → revert.
    function test_ValidateSupply_NegativeVS_BeyondThreshold_Reverts() public {
        vm.expectRevert(NavImpactLib.EffectiveSupplyTooLow.selector);
        harness.validateSupply(100e18, -int256(88e18));
    }

    function test_ValidateSupply_NegativeVS_FullDrain_Reverts() public {
        vm.expectRevert(NavImpactLib.EffectiveSupplyTooLow.selector);
        harness.validateSupply(100e18, -int256(100e18));
    }

    function test_ValidateSupply_ZeroTotalAndZeroVS_Passes() public view {
        harness.validateSupply(0, 0);
    }
}
