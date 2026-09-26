// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {UnitTestFixture} from "../fixtures/UnitTestFixture.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {AIntents} from "../../contracts/protocol/extensions/adapters/AIntents.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {NavImpactLib} from "../../contracts/protocol/libraries/NavImpactLib.sol";
import {OpType, SourceMessageParams} from "../../contracts/protocol/types/Crosschain.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title AIntentsNavImpactUnit - NavImpact tolerance validation in AIntents.depositV3 (Sync mode)
/// @notice Migrated from ECrosschainUnit.t.sol, which referenced the deprecated MockAcrossSpokePool
///         artifact via deployCode. Moved to a standalone file: editing ECrosschainUnit tipped its
///         borderline legacy-codegen stack usage into "stack too deep" under solc 0.8.37. NavImpact
///         validation completes before the SpokePool interaction matters, so a no-op stub suffices;
///         fork tests exercise the real SpokePool.
contract AIntentsNavImpactUnitTest is Test, UnitTestFixture {
    function setUp() public {
        deployFixture();
    }

    /// @notice Deploy an AIntents adapter wired to a no-op SpokePool stand-in and register it
    function _deployAndRegisterAdapter() internal returns (AIntents aIntentsAdapter) {
        aIntentsAdapter = new AIntents(address(new SpokePoolStub()));
        IAuthority(deployment.authority).setAdapter(address(aIntentsAdapter), true);
        IAuthority(deployment.authority).addMethod(IAIntents.depositV3.selector, address(aIntentsAdapter));
    }

    /// @notice Initialize the mock oracle price feed for WETH
    function _initializeWethOracle() internal {
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_WETH),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
    }

    /// @notice Create an ETH-based pool funded with 100 ETH of supply and activate WETH on it
    function _setupEthPoolWithWeth() internal returns (address ethPool) {
        (ethPool, ) = IRigoblockPoolProxyFactory(deployment.factory).createPool("eth pool", "ETH", address(0));
        vm.deal(ethPool, 100 ether);
        vm.deal(address(this), 300 ether);
        ISmartPoolActions(ethPool).mint{value: 100 ether}(address(this), 100 ether, 0);
        _setupActiveToken(ethPool, Constants.ETH_WETH);
        deployCodeTo("out/MockERC20.sol/MockERC20.json", abi.encode("Wrapped Ether", "WETH", 18), Constants.ETH_WETH);
    }

    /// @notice Build Sync-mode AcrossParams bridging WETH with a 10% NAV tolerance
    function _buildSyncParams(
        uint256 transferAmount,
        uint256 slippage
    ) internal view returns (IAIntents.AcrossParams memory) {
        return
            IAIntents.AcrossParams({
                depositor: address(this),
                recipient: address(0),
                inputToken: Constants.ETH_WETH,
                outputToken: Constants.ETH_WETH,
                inputAmount: transferAmount,
                outputAmount: transferAmount - slippage,
                destinationChainId: 8453, // Base
                exclusiveRelayer: address(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: 0,
                exclusivityDeadline: 0,
                message: abi.encode(
                    SourceMessageParams({
                        opType: OpType.Sync,
                        navTolerance: 1000, // 10% tolerance in bps
                        sourceNativeAmount: 0,
                        shouldUnwrapOnDestination: false
                    })
                )
            });
    }

    /// @notice Helper to setup active token using vm.store
    function _setupActiveToken(address pool, address token) internal {
        // Use the correct slot value from the protocol
        bytes32 tokenRegistrySlot = 0x3dcde6752c7421366e48f002bbf8d6493462e0e43af349bebb99f0470a12300d;

        // Read current array length
        uint256 currentLength = uint256(vm.load(pool, tokenRegistrySlot));

        // Check if token already exists
        bytes32 mappingBaseSlot = bytes32(uint256(tokenRegistrySlot) + 1);
        bytes32 positionSlot = keccak256(abi.encode(token, mappingBaseSlot));
        uint256 existingPosition = uint256(vm.load(pool, positionSlot));

        if (existingPosition > 0) {
            return;
        }

        // Add new token
        uint256 newLength = currentLength + 1;
        vm.store(pool, tokenRegistrySlot, bytes32(newLength));

        // Set the new element in the array (at keccak256(tokenRegistrySlot) + currentLength)
        bytes32 arrayElementSlot = bytes32(uint256(keccak256(abi.encode(tokenRegistrySlot))) + currentLength);
        vm.store(pool, arrayElementSlot, bytes32(uint256(uint160(token))));

        // Set position for this token (1-based index)
        vm.store(pool, positionSlot, bytes32(newLength));
    }

    /// @notice Test that AIntents.depositV3 with Sync mode reverts with NavImpactTooHigh when impact exceeds tolerance
    /// @dev This tests the actual revert path in NavImpactLib.validateNavImpact
    ///      Transfer 50 WETH on a ~100 ETH pool = 50% impact, exceeds the 10% tolerance
    function test_AIntents_SyncMode_RevertsWithNavImpactTooHigh() public {
        vm.warp(block.timestamp + 100);
        _deployAndRegisterAdapter();
        _initializeWethOracle();

        address ethPool = _setupEthPoolWithWeth();
        assertGt(ISmartPoolState(ethPool).getPoolTokens().totalSupply, 0, "Pool should have supply");
        assertGt(ISmartPoolState(ethPool).getPoolTokens().unitaryValue, 0, "Pool should have NAV");

        uint256 transferAmount = 50 ether;
        MockERC20(Constants.ETH_WETH).mint(ethPool, transferAmount);

        // Set chainId to Ethereum (1) so CrosschainLib.isAllowedCrosschainToken passes
        vm.chainId(1);
        IAIntents.AcrossParams memory params = _buildSyncParams(transferAmount, 1e16);

        // Should revert with NavImpactTooHigh because 50% > 10% tolerance
        vm.expectRevert(NavImpactLib.NavImpactTooHigh.selector);
        IAIntents(ethPool).depositV3(params);

        // Reset chainId
        vm.chainId(31337);
    }

    /// @notice Test that AIntents.depositV3 with Sync mode succeeds when impact is within tolerance
    /// @dev 5% transfer on ~100 ETH pool is within the 10% tolerance, so depositV3 succeeds
    ///      (the stub accepts depositV3 without a real transfer)
    function test_AIntents_SyncMode_PassesNavImpactCheckWithinTolerance() public {
        vm.warp(block.timestamp + 100);
        _deployAndRegisterAdapter();
        _initializeWethOracle();

        address ethPool = _setupEthPoolWithWeth();

        uint256 transferAmount = 5 ether;
        MockERC20(Constants.ETH_WETH).mint(ethPool, transferAmount);

        // Set chainId to Ethereum (1) so CrosschainLib.isAllowedCrosschainToken passes
        vm.chainId(1);
        IAIntents.AcrossParams memory params = _buildSyncParams(transferAmount, 1e14);

        vm.expectEmit(false, false, false, false);
        emit IAIntents.CrossChainTransferInitiated(
            address(this),
            8453,
            Constants.ETH_WETH,
            transferAmount,
            uint8(OpType.Sync),
            address(0)
        );
        IAIntents(ethPool).depositV3(params);

        // Reset chainId
        vm.chainId(31337);
    }
}

/// @notice Minimal stand-in for the Across SpokePool used in unit tests.
/// @dev NavImpact validation in AIntents.depositV3 completes before the SpokePool call matters,
///      and depositV3 returns nothing, so a bare fallback accepting the call suffices; fork tests
///      exercise the real SpokePool. The explicit 12-param depositV3 signature is avoided on
///      purpose: solc 0.8.37 legacy codegen deterministically reports a bogus stack-too-deep for
///      functions with 12 discrete params incl. calldata bytes.
contract SpokePoolStub {
    fallback() external payable {}
}
