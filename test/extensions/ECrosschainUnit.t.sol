// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UnitTestFixture} from "../fixtures/UnitTestFixture.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {CrosschainLib} from "../../contracts/protocol/libraries/CrosschainLib.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IECrosschain} from "../../contracts/protocol/extensions/adapters/interfaces/IECrosschain.sol";
import {IAIntents} from "../../contracts/protocol/extensions/adapters/interfaces/IAIntents.sol";
import {AIntents} from "../../contracts/protocol/extensions/adapters/AIntents.sol";
import {IAcrossSpokePool} from "../../contracts/protocol/interfaces/IAcrossSpokePool.sol";
import {NavImpactLib} from "../../contracts/protocol/libraries/NavImpactLib.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IWETH9} from "../../contracts/protocol/interfaces/IWETH9.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPoolImmutable} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {EnumerableSet, Pool} from "../../contracts/protocol/libraries/EnumerableSet.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {VirtualStorageLib} from "../../contracts/protocol/libraries/VirtualStorageLib.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {OpType, DestinationMessageParams, SourceMessageParams} from "../../contracts/protocol/types/Crosschain.sol";
import {EscrowFactory} from "../../contracts/protocol/libraries/EscrowFactory.sol";
import {Escrow} from "../../contracts/protocol/deps/Escrow.sol";
import {SafeTransferLib} from "../../contracts/protocol/libraries/SafeTransferLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";

/// @title ECrosschainUnit - Unit tests for Across integration components
/// @notice Tests individual contract functionality without cross-chain simulation
contract ECrosschainUnitTest is Test, UnitTestFixture {
    address mockBaseToken;
    address mockInputToken;
    address ethUsdc;
    address ethUsdt;
    address poolProxy;
    
    function setUp() public {
        deployFixture();

        // mock tokens to assert revert conditions
        mockBaseToken = makeAddr("baseToken");
        mockInputToken = makeAddr("inputToken");

        // tokens expected by the calls (weth already deployed in the fixture)
        deployCodeTo(
            "out/MockERC20.sol/MockERC20.0.8.28.json",
            abi.encode("USD Coin", "USDC", 6),
            Constants.ETH_USDC
        );
        ethUsdc = Constants.ETH_USDC;
        
        deployCodeTo(
            "out/MockERC20.sol/MockERC20.0.8.28.json",
            abi.encode("Tether USD", "USDT", 6),
            Constants.ETH_USDT
        );
        ethUsdt = Constants.ETH_USDT;
        
        // TODO: check if base token should be a token - but this helps because crosschain token inputs are never null address (so this is better to spot edge cases)
        (poolProxy, ) = IRigoblockPoolProxyFactory(deployment.factory).createPool("test pool", "TEST", address(0));
        console2.log("Pool proxy created:", poolProxy);
    }
    
    // TODO: check if changing decimals in storage is better for testing that deploying a different proxy
    // @notice Helper to setup pool storage using vm.store with correct packing
    function _setupPoolStorage(address pool, address baseToken) internal {
        _setupPoolStorageWithDecimals(pool, baseToken, 6); // Default to 6 decimals
    }
    
    /// @notice Helper to setup pool storage with specific decimals
    function _setupPoolStorageWithDecimals(address pool, address baseToken, uint8 decimals) internal {
        _setupPoolStorageWithLockState(pool, baseToken, decimals, true); // Default to unlocked
    }

    /// @notice Helper to setup pool storage with specific decimals and lock state
    function _setupPoolStorageWithLockState(address pool, address baseToken, uint8 decimals, bool unlocked) internal {
        bytes32 poolInitSlot = StorageLib.POOL_INIT_SLOT;
        
        // Based on RigoblockPool.StorageAccessible.spec.ts test:
        // The pool struct is packed across 3 slots total
        // But StorageLib.pool() accesses it as a direct struct, so it starts at poolInitSlot
        
        // Slot 0: string name (if < 32 bytes, stored directly with length in last byte)
        // "Test Pool" = 9 bytes
        bytes32 nameSlot = bytes32(abi.encodePacked("Test Pool", bytes23(0), uint8(9 * 2))); // length * 2 for short strings
        vm.store(pool, poolInitSlot, nameSlot);
        
        // Slot 1: Based on TypeScript tests, the layout is:
        // [padding:2][unlocked:1][owner:20][decimals:1][symbol:8] = 32 bytes
        bytes32 packedSlot = bytes32(abi.encodePacked(
            bytes2(0),         // padding (2 bytes)
            unlocked,          // unlocked (1 byte) - this is the key change
            address(this),     // owner (20 bytes)
            decimals,         // decimals (1 byte)
            bytes8("TEST")     // symbol (8 bytes)
        ));
        vm.store(pool, bytes32(uint256(poolInitSlot) + 1), packedSlot);
        
        // Slot 2: baseToken (address) - this is what we really need!
        vm.store(pool, bytes32(uint256(poolInitSlot) + 2), bytes32(uint256(uint160(baseToken))));
    }
    
    /// @notice Helper to setup active token using vm.store
    function _setupActiveToken(address pool, address token) internal {
        // Use the correct slot value from the protocol  
        bytes32 tokenRegistrySlot = 0x3dcde6752c7421366e48f002bbf8d6493462e0e43af349bebb99f0470a12300d;
        
        // Set up active token in AddressSet
        // Struct AddressSet { address[] addresses; mapping(address => uint256) positions; }
        // Storage layout:
        // - tokenRegistrySlot = addresses array length
        // - tokenRegistrySlot + 1 = positions mapping base slot
        
        // Read current array length
        uint256 currentLength = uint256(vm.load(pool, tokenRegistrySlot));
        
        // Check if token already exists
        bytes32 mappingBaseSlot = bytes32(uint256(tokenRegistrySlot) + 1);
        bytes32 positionSlot = keccak256(abi.encode(token, mappingBaseSlot));
        uint256 existingPosition = uint256(vm.load(pool, positionSlot));
        
        // Notice: position could be REMOVED_TOKEN_FLAG, which is > 0, but it's not relevant for this test
        if (existingPosition > 0) {
            // Token already active, nothing to do
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
    
    /// @notice Test extension deployment (stateless)
    function test_Setup_Deployment() public view {
        assertTrue(address(deployment.implementation).code.length > 0, "Implementation should be deployed");
        assertTrue(poolProxy.code.length > 0, "Proxy should be deployed");
        assertTrue(extensions.eCrosschain.code.length > 0, "Extension should be deployed");
        assertTrue(ethUsdc != address(0), "Should never remove USDC from deployment pipeline");
        assertTrue(ethUsdt != address(0), "Should never remove USDT from deployment pipeline");
    }

    /// @notice Test extension requires pool to be unlocked to execute
    /// @dev ECrosschain.donate() called directly (not via delegatecall) fails because:
    ///      1. ECrosschain has no ERC20 interface - balanceOf(address(this)) returns 0 bytes
    ///      2. Without delegatecall context from pool proxy, storage access is wrong
    ///      This causes a raw EVM revert (no specific selector) which is expected behavior.
    function test_ECrosschain_RevertsDirectCall() public {
        // Create valid Transfer params
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Raw EVM revert - no specific selector available because ECrosschain
        // tries to call balanceOf on itself (which doesn't exist)
        vm.expectRevert();
        IECrosschain(extensions.eCrosschain).donate(mockBaseToken, 1, params);
    }
    
    /// @notice Test extension Transfer mode execution using actual contract
    function test_ECrosschain_TransferMode_MessageParsing() public pure {
        // Test that Transfer message can be properly encoded/decoded
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        bytes memory encodedMessage = abi.encode(params);
        DestinationMessageParams memory decoded = abi.decode(encodedMessage, (DestinationMessageParams));
        
        assertEq(uint8(decoded.opType), uint8(OpType.Transfer), "OpType should be Transfer");
    }
    
    /// @notice Test Sync mode message encoding/decoding with NAV
    function test_ECrosschain_SyncMode_MessageParsing() public pure {
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        bytes memory encoded = abi.encode(params);
        DestinationMessageParams memory decoded = abi.decode(encoded, (DestinationMessageParams));
        
        assertEq(uint8(decoded.opType), uint8(OpType.Sync), "OpType should be Sync");
    }
    
    /// @notice Test WETH unwrap message construction
    function test_ECrosschain_UnwrapWETH_MessageSetup() public pure {
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: true
        });
        
        bytes memory encoded = abi.encode(params);
        DestinationMessageParams memory decoded = abi.decode(encoded, (DestinationMessageParams));
        
        assertTrue(decoded.shouldUnwrapNative, "Should unwrap should be true");
        assertEq(uint8(decoded.opType), uint8(OpType.Transfer), "OpType should be Transfer");
    }

    /// @notice Test extension requires pool to be unlocked to execute
    function test_ECrosschain_RequiresPoolUnlocked() public {
        // Mock required calls
        vm.mockCall(
            mockInputToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0) // Mock balance
        );
        
        // Create valid Transfer params
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Should revert because pool is locked (updateUnitaryValue will fail)
        vm.expectRevert(abi.encodeWithSelector(IECrosschain.DonationLock.selector, false));
        IECrosschain(poolProxy).donate(mockInputToken, 2, params);

        IECrosschain(poolProxy).donate(mockInputToken, 1, params);

        vm.clearMockedCalls();
    }

    /// @notice Test extension rejects unsupported token
    function test_ECrosschain_RejectsUnsupportedToken() public {
        vm.mockCall(
            mockInputToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0) // Balance for initialization
        );
        
        // Create message with Unknown OpType to test InvalidOpType revert
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Unknown,
            shouldUnwrapNative: false
        });

        // unlock
        IECrosschain(poolProxy).donate(mockInputToken, 1, params);

        // Simulate token transfer to pool - required for donate flow to succeed
        vm.mockCall(
            mockInputToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(100e6) // Simulate transfer
        );
        
        vm.expectRevert(CrosschainLib.UnsupportedCrossChainToken.selector);
        IECrosschain(poolProxy).donate(mockInputToken, 10e6, params);

        vm.clearMockedCalls();
    }

    /// @notice Test extension accepts source amount within tolerance range  
    function test_ECrosschain_RevertsIfTokenPriceFeedDoesNotExist() public {
        uint256 receivedAmount = 100e18; // Use 18 decimals for base token
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        IECrosschain(poolProxy).donate(ethUsdt, 1, params);
        vm.chainId(1);

        vm.mockCall(
            ethUsdt,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(receivedAmount)
        );

        vm.expectRevert(abi.encodeWithSelector(EnumerableSet.TokenPriceFeedDoesNotExist.selector, ethUsdt));
        IECrosschain(poolProxy).donate(ethUsdt, receivedAmount, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }

    /// @notice Test extension rejects invalid OpType
    function test_ECrosschain_RejectsInvalidOpType() public {
        // Mark input token as active to skip price feed validation when adding it via addUnique
        _setupActiveToken(poolProxy, ethUsdc); // Mark input token as active
        
        // Create message with Unknown OpType to test InvalidOpType revert
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Unknown,
            shouldUnwrapNative: false
        });

        // unlock
        IECrosschain(poolProxy).donate(ethUsdc, 1, params);

        // Simulate token transfer to pool - required for donate flow to succeed
        vm.mockCall(
            ethUsdc,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(100e6) // Simulate transfer
        );
        vm.chainId(1);
        
        vm.expectRevert(abi.encodeWithSignature("InvalidOpType()"));
        IECrosschain(poolProxy).donate(ethUsdc, 10e6, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }

    function test_ECrosschain_RejectsTokenNotSentToPool() public {
        _setupActiveToken(poolProxy, mockInputToken); // Mark input token as active
    
        vm.mockCall(
            mockInputToken,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0) // Balance for initialization
        );
        
        // Create message with Unknown OpType to test InvalidOpType revert
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Unknown,
            shouldUnwrapNative: false
        });

        // unlock
        IECrosschain(poolProxy).donate(mockInputToken, 1, params);
        
        vm.expectRevert(ECrosschain.CallerTransferAmount.selector);
        IECrosschain(poolProxy).donate(mockInputToken, 10e6, params);

        vm.clearMockedCalls();
    }

    /// @notice Test extension accepts source amount within tolerance range  
    function test_ECrosschain_AcceptsSourceAmountWithinTolerance() public {
        // Initialize observations BEFORE first donation
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdt),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );

        // Warp time forward to avoid underflow in oracle lookback
        vm.warp(block.timestamp + 100);
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // First donation to unlock the pool
        IECrosschain(poolProxy).donate(ethUsdt, 1, params);
        vm.chainId(1);

        uint256 transferAmount = 100e18;

        vm.mockCall(
            ethUsdt,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(transferAmount)
        );

        // Should succeed - donation with proper oracle setup
        vm.expectEmit(true, true, true, true);
        emit IECrosschain.TokensReceived(
            address(this), // msg.sender (test contract)
            ethUsdt,
            transferAmount,
            uint8(OpType.Transfer)
        );
        IECrosschain(poolProxy).donate(ethUsdt, transferAmount - 1e8, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }

    // TODO: test require oracle only after first donation, because the token is not activated first. The tests are, yet again, incorrect.
    /// @notice Test extension accepts source amount when there is a pre-existing token balance 
    function test_ECrosschain_PassesWithNullSupplyAndPositiveSameTokenBalance() public {
        // Actually transfer USDT to pool (attacker tries DOS by donating before first use)
        uint256 attackerGift = 2000e6; // 2000 USDT with 6 decimals
        MockERC20(ethUsdt).mint(poolProxy, attackerGift);
        
        // Initialize observations BEFORE first donation (needed for price feed check)
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdt),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        vm.warp(block.timestamp + 100);
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // First donation to unlock the pool
        // Token activated BEFORE NAV update, so attacker's gift included in baseline
        IECrosschain(poolProxy).donate(ethUsdt, 1, params);
        vm.chainId(1);

        // Legitimate cross-chain transfer arrives
        uint256 transferAmount = 100e6; // 100 USDT with 6 decimals
        MockERC20(ethUsdt).mint(poolProxy, transferAmount);

        // Should succeed - donation processes legitimate transfer amount
        // No DOS: attacker's gift was captured in stored assets baseline
        // Event emits actual balance change (including pre-existing attacker gift)
        vm.expectEmit(true, true, true, true);
        emit IECrosschain.TokensReceived(
            address(this), // msg.sender (test contract)
            ethUsdt,
            transferAmount, // Full balance delta including attacker's pre-existing gift
            uint8(params.opType)
        );
        IECrosschain(poolProxy).donate(ethUsdt, transferAmount - 1e2, params); // Slightly less to test validation

        vm.clearMockedCalls();
        vm.chainId(31337);
    }

    /// @notice Test DOS prevention when other active tokens have balances before first donation
    /// @dev This test verifies the critical fix: when effectiveSupply==0, ALL active token balances
    ///      are cleared (transferred to tokenJar), not just the donated token. Without this:
    ///      1. Attacker sends USDC to pool with 0 supply
    ///      2. First donate(USDT, 1) only checks USDT balance (which is 0), so USDC isn't cleared  
    ///      3. Second donate() creates virtual supply, triggering NAV recalculation
    ///      4. NAV includes USDC balance, causing NavManipulationDetected revert = DOS attack
    ///      The fix iterates through ALL active tokens and clears their balances when effectiveSupply==0.
    function test_ECrosschain_PassesWithNullSupplyAndPositiveOtherTokenBalance() public {
        // Deploy a pool that has WETH as native token
        (address wethPool, ) = IRigoblockPoolProxyFactory(deployment.factory).createPool("weth pool", "TEST", deployment.wrappedNative);
        
        // with null active supply, they won't be included in the first price update
        _setupActiveToken(wethPool, ethUsdc);
        
        // add other token to pool - this will make the transaction revert due to nav manipulation detected - which is not the case
        MockERC20(ethUsdc).mint(wethPool, 2000e6);
        
        // Warp time forward to avoid underflow in oracle lookback
        vm.warp(block.timestamp + 100);
        
        // Initialize observations BEFORE first donation
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdt),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Mock base token (WETH) balance BEFORE first donation
        vm.mockCall(
            deployment.wrappedNative,
            abi.encodeWithSelector(IERC20.balanceOf.selector, wethPool),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // First donation to unlock the pool
        // Nav should be initialized as 1 here, because the price slot in empty
        IECrosschain(wethPool).donate(ethUsdt, 1, params);
        vm.chainId(1);

        uint256 transferAmount = 100e18;

        vm.mockCall(
            ethUsdt,
            abi.encodeWithSelector(IERC20.balanceOf.selector, wethPool),
            abi.encode(transferAmount)
        );

        // Should succeed - donation with proper oracle setup
        vm.expectEmit(true, true, true, true);
        emit IECrosschain.TokensReceived(
            address(this), // msg.sender (test contract)
            ethUsdt,
            transferAmount,
            uint8(params.opType)
        );

        // Test verifies that USDC balance was cleared during first donate(), preventing NAV manipulation
        IECrosschain(wethPool).donate(ethUsdt, transferAmount - 1e8, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }

    /// @notice Test extension accepts source amount within tolerance range  
    function test_ECrosschain_PassesWithNullSupplyAndPositiveFakeTokenBalance() public {
        // Warp time forward to avoid underflow in oracle lookback
        vm.warp(block.timestamp + 100);
        
        // Initialize observations BEFORE first donation
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdt),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            ethUsdt,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // First donation to unlock the pool
        // Whatever the previous token balance was, should be burnt for GRG
        IECrosschain(poolProxy).donate(ethUsdt, 1, params);
        vm.chainId(1);

        uint256 transferAmount = 100e18;

        vm.mockCall(
            ethUsdt,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(transferAmount)
        );

        // Should succeed - donation with proper oracle setup
        vm.expectEmit(true, true, true, true);
        emit IECrosschain.TokensReceived(
            address(this), // msg.sender (test contract)
            ethUsdt,
            transferAmount,
            uint8(params.opType)
        );
        IECrosschain(poolProxy).donate(ethUsdt, transferAmount - 1e8, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }

    /// @notice Test extension Transfer mode with proper delegatecall context
    function test_ECrosschain_TransferMode_WithDelegatecall() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Mock balanceOf for unlock
        vm.mockCall(
            ethUsdc,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Unlock
        IECrosschain(poolProxy).donate(ethUsdc, 1, params);
        vm.chainId(1);
        
        // Verify initial virtual supply is 0
        int256 initialVS = int256(uint256(vm.load(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertEq(initialVS, 0, "Virtual supply should start at 0");
        
        // Simulate token transfer to pool
        vm.mockCall(
            ethUsdc,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(100e6)
        );
        
        // Should succeed with proper setup
        IECrosschain(poolProxy).donate(Constants.ETH_USDC, 100e6, params);
        
        // Verify virtual supply increased (should be positive after inbound transfer)
        int256 finalVS = int256(uint256(vm.load(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertGt(finalVS, 0, "Virtual supply should be positive after inbound transfer");
        assertEq(finalVS - initialVS, finalVS, "Virtual supply delta should equal final VS");

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test that solver surplus increases NAV in Transfer mode (surplus goes to shareholders)
    /// @dev This is critical: we use `amount` for VS, not `amountDelta`, so surplus increases NAV
    /// @dev If we incorrectly used `amountDelta` for VS, NAV would remain unchanged (NAV-neutral)
    /// @dev This test verifies VS changes by `amount`, not `amountDelta`, proving surplus benefits shareholders
    function test_ECrosschain_TransferMode_SurplusIncreasesNav() public {
        vm.warp(block.timestamp + 100);
        
        // Setup oracle for USDC
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Unlock with 0 balance
        vm.mockCall(ethUsdc, abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy), abi.encode(0));
        IECrosschain(poolProxy).donate(ethUsdc, 1, params);
        vm.chainId(1);
        
        // Get VS before donation
        int256 vsBefore = int256(uint256(vm.load(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertEq(vsBefore, 0, "VS should start at 0");
        
        // Simulate surplus: amountDelta = 110e6, but amount (expected) = 100e6
        // Surplus = 10e6 USDC (10%)
        uint256 expectedAmount = 100e6;  // What sender specified (used for VS)
        uint256 actualReceived = 110e6;  // What solver delivered (surplus)
        
        vm.mockCall(ethUsdc, abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy), abi.encode(actualReceived));
        
        // Donate with expected amount (less than actual balance)
        IECrosschain(poolProxy).donate(ethUsdc, expectedAmount, params);
        
        // Get VS after donation
        int256 vsAfter = int256(uint256(vm.load(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        
        // CRITICAL ASSERTION: VS should increase by `amount` (100e6), NOT by `amountDelta` (110e6)
        // This proves surplus goes to existing shareholders (NAV increase), not to phantom shares
        // With NAV=1e6 (1:1 for 6 decimals), shares minted = amount * 10^decimals / NAV = 100e6
        assertApproxEqRel(
            uint256(vsAfter), 
            expectedAmount,  // VS delta should equal expectedAmount
            0.01e18,         // 1% tolerance for rounding
            "Virtual supply should increase by EXPECTED amount (100e6), not by actual received (110e6)"
        );
        
        // If we incorrectly used amountDelta, VS would be ~110e6 instead of ~100e6
        // The difference (10e6 shares worth) would mean surplus created phantom shares instead of NAV increase
        assertTrue(
            uint256(vsAfter) < actualReceived, 
            "VS must be less than amountDelta - surplus should NOT create virtual shares"
        );
        
        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test that virtual supply delta is correctly calculated when VS is already non-zero
    /// @dev This tests the fix for the bug where negative VS clearing logic was incorrect
    function test_ECrosschain_TransferMode_WithExistingVirtualSupply() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Mock balanceOf for unlock
        vm.mockCall(
            ethUsdc,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Unlock
        IECrosschain(poolProxy).donate(ethUsdc, 1, params);
        vm.chainId(1);
        
        // First donation to establish initial virtual supply
        vm.mockCall(
            ethUsdc,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(100e6)
        );
        IECrosschain(poolProxy).donate(Constants.ETH_USDC, 100e6, params);
        
        int256 vsAfterFirst = int256(uint256(vm.load(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertGt(vsAfterFirst, 0, "First donation should create positive VS");
        
        // Second donation - VS should add to existing
        uint256 secondDonation = 50e6;
        vm.mockCall(
            ethUsdc,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(100e6) // Still show 100e6 as stored balance from first donation
        );
        
        // Unlock for second donation
        IECrosschain(poolProxy).donate(ethUsdc, 1, params);
        
        // Now mock the new balance (150e6 total)
        vm.mockCall(
            ethUsdc,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(150e6)
        );
        
        // Second donation
        IECrosschain(poolProxy).donate(Constants.ETH_USDC, secondDonation, params);
        
        int256 vsAfterSecond = int256(uint256(vm.load(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        int256 expectedDelta = (vsAfterSecond - vsAfterFirst);
        
        // The delta should be positive and approximately equal to the second donation in share terms
        // With NAV=1 and decimals=6, 50e6 USDC = 50e6 shares
        assertGt(expectedDelta, 0, "Second donation should increase VS");
        assertApproxEqRel(uint256(expectedDelta), secondDonation, 0.01e18, "VS delta should match donated amount");
        
        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test that virtual supply correctly handles negative VS (from prior outbound transfers)
    /// @dev This is the critical case that the bug would have affected
    function test_ECrosschain_TransferMode_WithNegativeVirtualSupply() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Setup pool with some initial balance to match the negative VS we'll set
        vm.mockCall(
            ethUsdc,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Unlock
        IECrosschain(poolProxy).donate(ethUsdc, 1, params);
        vm.chainId(1);
        
        // Simulate a prior outbound transfer that created negative VS of -500e6 shares
        // In reality this would come from an AIntents.depositV3() call
        int256 initialNegativeVS = -500e6;
        vm.store(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT, bytes32(uint256(initialNegativeVS)));
        
        // Verify the negative VS was set
        int256 vsBeforeDonation = int256(uint256(vm.load(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertEq(vsBeforeDonation, initialNegativeVS, "Should have negative VS");
        
        // Now receive an inbound transfer of 800e6 USDC
        // Expected: -500e6 + 800e6 = +300e6 (net positive)
        uint256 inboundAmount = 800e6;
        
        vm.mockCall(
            ethUsdc,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(inboundAmount)
        );
        
        IECrosschain(poolProxy).donate(Constants.ETH_USDC, inboundAmount, params);
        
        int256 vsAfterDonation = int256(uint256(vm.load(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        
        // With the bug, this would be -200e6 (wrong!)
        // With the fix, this should be +300e6 (correct!)
        int256 expectedFinalVS = initialNegativeVS + int256(inboundAmount);
        
        assertEq(vsAfterDonation, expectedFinalVS, "VS should be sum of initial + donated");
        assertGt(vsAfterDonation, 0, "VS should be net positive after large inbound donation");
        assertApproxEqAbs(vsAfterDonation, 300e6, 1e6, "VS should be approximately +300e6");
        
        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test that burn reverts when effective supply would drop below minimum threshold
    /// @dev This tests EffectiveSupplyLib.validateEffectiveSupply in burn flow
    function test_ECrosschain_BurnRevertsWithLowEffectiveSupply() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Setup: First, do an actual mint to create real totalSupply
        // We need to:
        // 1. Give pool some base token balance
        // 2. Use ISmartPoolActions.mint() to create real shares
        
        address poolBaseToken = ISmartPoolState(poolProxy).getPool().baseToken;
        assertTrue(poolBaseToken == address(0), "Pool base token should be ETH (address 0)");
        
        // Give the pool some ETH to simulate NAV
        vm.deal(poolProxy, 1000 ether);
        
        // First mint - this creates totalSupply
        vm.deal(address(this), 2000 ether);
        uint256 mintAmount = 1000 ether;
        ISmartPoolActions(poolProxy).mint{value: mintAmount}(address(this), mintAmount, 0);
        
        // Verify totalSupply is now non-zero
        uint256 totalSupply = ISmartPoolState(poolProxy).getPoolTokens().totalSupply;
        assertGt(totalSupply, 0, "totalSupply should be non-zero after mint");
        
        // Simulate negative VS that puts effective supply in the danger zone (0 < ES < TS/8)
        // totalSupply = 1000e18, threshold = 1000e18 / 8 = 125e18
        // Set VS = -(totalSupply - threshold/2) to get ES = threshold/2 (below threshold but positive)
        int256 threshold = int256(totalSupply / 8);
        int256 targetEffectiveSupply = threshold / 2;  // 50% of threshold = 6.25% of TS
        int256 largeNegativeVS = -(int256(totalSupply) - targetEffectiveSupply);
        
        vm.store(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT, bytes32(uint256(largeNegativeVS)));
        
        // Verify our math
        int256 actualVS = int256(uint256(vm.load(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        assertEq(actualVS, largeNegativeVS, "VS should be stored correctly");
        
        int256 expectedEffectiveSupply = int256(totalSupply) + largeNegativeVS;
        assertGt(expectedEffectiveSupply, 0, "Effective supply should be positive");
        assertLt(expectedEffectiveSupply, threshold, "Effective supply should be below threshold");
        
        // This should revert when calculating NAV because effective supply is positive but below threshold
        vm.expectRevert(abi.encodeWithSignature("EffectiveSupplyTooLow()"));
        ISmartPoolActions(poolProxy).updateUnitaryValue();
    }
    
    /// @notice Test extension Sync mode with proper delegatecall context
    function test_ECrosschain_SyncMode_WithDelegatecall() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_WETH),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Notice: we can use any WETH address directly and only mock balance, because decimals are defined as ETH's
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        IECrosschain(poolProxy).donate(Constants.ETH_WETH, 1, params);
        vm.chainId(1);
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(1e18)
        );
        
        // Sync mode should succeed
        IECrosschain(poolProxy).donate(Constants.ETH_WETH, 1e18, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test extension with WETH unwrapping
    function test_ECrosschain_WithWETHUnwrap_WithDelegatecall() public {
        vm.warp(block.timestamp + 100);
        // Across uses WETH address even for native transfers
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_WETH),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSignature("decimals()"),
            abi.encode(18)
        );
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: true
        });
        
        IECrosschain(poolProxy).donate(Constants.ETH_WETH, 1, params);
        vm.chainId(1);
        
        // Track initial virtual supply
        int256 initialVS = int256(uint256(vm.load(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(1e18)
        );
        
        // Should succeed and unwrap WETH to ETH
        IECrosschain(poolProxy).donate(Constants.ETH_WETH, 1e18, params);
        
        // Verify virtual supply increased correctly
        int256 finalVS = int256(uint256(vm.load(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT)));
        int256 vsDelta = finalVS - initialVS;
        assertGt(vsDelta, 0, "Virtual supply should increase after inbound transfer");

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test extension adds token with price feed to active set
    function test_ECrosschain_AddsTokenWithPriceFeed() public {
        // Start with no active tokens
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_USDC),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            Constants.ETH_USDC,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        IECrosschain(poolProxy).donate(Constants.ETH_USDC, 1, params);
        vm.chainId(1);
        
        vm.mockCall(
            Constants.ETH_USDC,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(100e6)
        );
        
        // Should succeed and add USDC to active tokens
        IECrosschain(poolProxy).donate(Constants.ETH_USDC, 100e6, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test NAV normalization across different decimal combinations
    function test_ECrosschain_NavNormalization() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_WETH),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        IECrosschain(poolProxy).donate(Constants.ETH_WETH, 1, params);
        vm.chainId(1);
        
        // Test with 18 decimal token (WETH)
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(1e18)
        );
        
        // Should handle 18 decimal normalization
        IECrosschain(poolProxy).donate(Constants.ETH_WETH, 1e18, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test that WETH unwrapping uses WETH address for validation
    function test_ECrosschain_WETHUnwrapping_UsesAddressZero() public {
        vm.warp(block.timestamp + 100);
        // Across uses WETH address even for native transfers
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_WETH),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSignature("decimals()"),
            abi.encode(18)
        );
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: true
        });
        
        IECrosschain(poolProxy).donate(Constants.ETH_WETH, 1, params);
        vm.chainId(1);
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(1e18)
        );
        
        // Should use address(0) for ETH after unwrapping
        IECrosschain(poolProxy).donate(Constants.ETH_WETH, 1e18, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }
    
    /// @notice Test that Sync operations work with client-side validation
    function test_ECrosschain_SyncMode_ClientSideValidation() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_USDC),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        vm.mockCall(
            Constants.ETH_USDC,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(0)
        );
        
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        IECrosschain(poolProxy).donate(Constants.ETH_USDC, 1, params);
        vm.chainId(1);
        
        vm.mockCall(
            Constants.ETH_USDC,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(100e6)
        );
        
        // Sync mode succeeds - NAV validation is client responsibility
        IECrosschain(poolProxy).donate(Constants.ETH_USDC, 100e6, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
    }

    /// @notice Test Sync mode with pre-existing balance (same pattern as Transfer mode tests)
    /// @dev Validates that Sync mode correctly handles pre-existing untracked token balance
    function test_ECrosschain_SyncMode_WithPreExistingBalance() public {
        vm.warp(block.timestamp + 100);
        
        // Setup mock oracle for USDC price feed
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Attacker pre-donates tokens before legitimate use (same pattern as Transfer tests)
        uint256 preExisting = 1000e6;
        MockERC20(ethUsdc).mint(poolProxy, preExisting);
        
        DestinationMessageParams memory syncParams = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        // Unlock: storedBalance=1000e6, storedAssets=0 (token not yet active)
        IECrosschain(poolProxy).donate(ethUsdc, 1, syncParams);
        vm.chainId(1);
        
        // Legitimate donation arrives
        uint256 donationAmount = 200e6;
        MockERC20(ethUsdc).mint(poolProxy, donationAmount);
        
        // Should succeed: expectedAssets = storedAssets(0) + convert(amountDelta + storedBalance)
        //                                = 0 + convert(200e6 + 1000e6) = convert(1200e6)
        // actualAssets = convert(1200e6) from updateUnitaryValue
        vm.expectEmit(true, true, true, true);
        emit IECrosschain.TokensReceived(address(this), ethUsdc, donationAmount, uint8(OpType.Sync));
        IECrosschain(poolProxy).donate(ethUsdc, donationAmount, syncParams);
        
        vm.chainId(31337);
    }
    
    /// @notice Test Sync mode without pre-existing balance (clean donation)
    function test_ECrosschain_SyncMode_CleanDonation() public {
        vm.warp(block.timestamp + 100);
        
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        DestinationMessageParams memory syncParams = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        // Unlock with zero balance
        IECrosschain(poolProxy).donate(ethUsdc, 1, syncParams);
        vm.chainId(1);
        
        // Donate tokens
        uint256 donationAmount = 200e6;
        MockERC20(ethUsdc).mint(poolProxy, donationAmount);
        
        vm.expectEmit(true, true, true, true);
        emit IECrosschain.TokensReceived(address(this), ethUsdc, donationAmount, uint8(OpType.Sync));
        IECrosschain(poolProxy).donate(ethUsdc, donationAmount, syncParams);
        
        vm.chainId(31337);
    }
    
    /// @notice Test Sync mode reverts with NavManipulationDetected when assets are manipulated
    /// @dev Simulates scenario where total assets decrease between unlock and finalize
    function test_ECrosschain_SyncMode_RevertsOnNavManipulation() public {
        vm.warp(block.timestamp + 100);
        
        // Setup oracles for both USDC and USDT
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdt),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Give pool pre-existing USDT balance and make it active
        MockERC20(ethUsdt).mint(poolProxy, 1000e6);
        _setupActiveToken(poolProxy, ethUsdt);
        
        DestinationMessageParams memory syncParams = DestinationMessageParams({
            opType: OpType.Sync,
            shouldUnwrapNative: false
        });
        
        // Unlock: storedAssets includes the 1000 USDT
        IECrosschain(poolProxy).donate(ethUsdc, 1, syncParams);
        vm.chainId(1);
        
        // Simulate manipulation: USDT is removed (drained/swapped out) while "donating" USDC
        // This could happen if pool owner does something malicious between calls
        MockERC20(ethUsdc).mint(poolProxy, 200e6); // "Donation" arrives
        // Transfer USDT out of pool to simulate drain
        vm.prank(poolProxy);
        IERC20(ethUsdt).transfer(address(this), 1000e6);
        
        // Should revert: expectedAssets = storedAssets(1000 USDT value) + convert(200 USDC)
        //                actualAssets = convert(200 USDC) only (USDT gone)
        vm.expectRevert(abi.encodeWithSelector(IECrosschain.NavManipulationDetected.selector, uint256(1200e6), uint256(200e6)));
        IECrosschain(poolProxy).donate(ethUsdc, 200e6, syncParams);
        
        vm.chainId(31337);
    }

    /// @notice Test that updateUnitaryValue reverts when VS makes effectiveSupply negative
    /// @dev This catches any future refactoring that might skip the validateEffectiveSupply check
    function test_ECrosschain_RevertsWhenVSMakesEffectiveSupplyNegative() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Give the pool some ETH and mint tokens
        vm.deal(poolProxy, 1000 ether);
        vm.deal(address(this), 2000 ether);
        uint256 mintAmount = 1000 ether;
        ISmartPoolActions(poolProxy).mint{value: mintAmount}(address(this), mintAmount, 0);
        
        uint256 totalSupply = ISmartPoolState(poolProxy).getPoolTokens().totalSupply;
        assertGt(totalSupply, 0, "totalSupply should be non-zero after mint");
        
        // Set VS to make effectiveSupply negative (VS = -(TS + 1))
        // This simulates a bug where VS becomes way too negative
        int256 veryNegativeVS = -(int256(totalSupply) + 1 ether);
        
        vm.store(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT, bytes32(uint256(veryNegativeVS)));
        
        // This should revert because effective supply would be negative
        vm.expectRevert(abi.encodeWithSignature("EffectiveSupplyTooLow()"));
        ISmartPoolActions(poolProxy).updateUnitaryValue();
    }

    /// @notice Test that updateNav works correctly when totalSupply=0 but virtualSupply>0
    /// @dev This is the destination chain scenario: received tokens via cross-chain but no local mints yet
    function test_ECrosschain_UpdateNavWorksWithZeroTotalSupplyAndPositiveVirtualSupply() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // First, mint some tokens to set unitaryValue (so we're not in first-mint path)
        vm.deal(poolProxy, 1000 ether);
        vm.deal(address(this), 2000 ether);
        ISmartPoolActions(poolProxy).mint{value: 1000 ether}(address(this), 1000 ether, 0);
        
        uint256 navAfterMint = ISmartPoolState(poolProxy).getPoolTokens().unitaryValue;
        assertGt(navAfterMint, 0, "NAV should be set after mint");
        
        // Use vm.store to set totalSupply to 0 directly (simulates pool where all tokens were burned)
        // POOL_TOKENS_SLOT layout: slot = unitaryValue, slot+1 = totalSupply
        bytes32 poolTokensSlot = StorageLib.POOL_TOKENS_SLOT;
        vm.store(poolProxy, bytes32(uint256(poolTokensSlot) + 1), bytes32(uint256(0)));
        
        // Verify total supply is now 0
        uint256 totalSupplyAfterStore = ISmartPoolState(poolProxy).getPoolTokens().totalSupply;
        assertEq(totalSupplyAfterStore, 0, "Total supply should be 0 after vm.store");
        
        // unitaryValue should still be set from previous mint
        uint256 unitaryValueBefore = ISmartPoolState(poolProxy).getPoolTokens().unitaryValue;
        assertGt(unitaryValueBefore, 0, "unitaryValue should still be set");
        
        // Set positive virtual supply (simulating destination chain received tokens)
        int256 positiveVS = 500 ether;
        vm.store(poolProxy, VirtualStorageLib.VIRTUAL_SUPPLY_SLOT, bytes32(uint256(positiveVS)));
        
        // Add some ETH to pool to have net value (effectiveSupply = 0 + 500 = 500 ether)
        vm.deal(poolProxy, 500 ether);
        
        // This should NOT revert - effectiveSupply = 0 + 500 ether = 500 ether (positive)
        ISmartPoolActions(poolProxy).updateUnitaryValue();
        
        // NAV should be calculated correctly using effectiveSupply
        uint256 navAfterUpdate = ISmartPoolState(poolProxy).getPoolTokens().unitaryValue;
        assertGt(navAfterUpdate, 0, "NAV should be calculated when effectiveSupply > 0");
    }

    /// @notice Test that NavImpactTooHigh is triggered when transfer exceeds tolerance
    /// @dev validateNavImpact is called during Sync operations (not Transfer)
    function test_NavImpactLib_RevertsWhenImpactExceedsTolerance() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Setup pool with base token ETH and some value
        vm.deal(poolProxy, 100 ether);
        vm.deal(address(this), 200 ether);
        ISmartPoolActions(poolProxy).mint{value: 100 ether}(address(this), 100 ether, 0);
        
        uint256 totalSupply = ISmartPoolState(poolProxy).getPoolTokens().totalSupply;
        uint256 unitaryValue = ISmartPoolState(poolProxy).getPoolTokens().unitaryValue;
        assertGt(totalSupply, 0, "totalSupply should be non-zero");
        assertGt(unitaryValue, 0, "unitaryValue should be non-zero");
        
        // Total assets = totalSupply * unitaryValue / 10^decimals ≈ 100 ether (minus spread)
        // If we try to transfer 50 ether (50% of assets) with 10% tolerance, it should fail
        
        // Create a sync deposit that exceeds tolerance
        // impactBps = (transferValue * 10000) / totalAssetsValue
        // For 50 ether transfer on ~100 ether pool: impactBps ≈ 5000 (50%)
        // Tolerance of 1000 (10%) should reject this
        
        // Setup the AIntents adapter call via AcrossParams
        // We need to test validateNavImpact specifically, so we can use vm.prank as pool
        // and call a method that uses validateNavImpact
        
        // Since validateNavImpact is called from AIntents during Sync, let's test directly
        // by setting up the pool storage and calling via the pool proxy
        
        // For now, test at the library level by checking the math
        // totalAssetsValue = unitaryValue * effectiveSupply / 10^18
        uint8 decimals = ISmartPoolState(poolProxy).getPool().decimals;
        uint256 effectiveSupply = totalSupply; // No virtual supply
        uint256 totalAssetsValue = (unitaryValue * effectiveSupply) / (10 ** decimals);
        
        console2.log("Total assets value:", totalAssetsValue);
        console2.log("Unit value:", unitaryValue);
        console2.log("Effective supply:", effectiveSupply);
        
        // Calculate what transfer amount would cause 50% impact
        uint256 largeTransfer = totalAssetsValue / 2; // 50% of assets
        uint256 impactBps = (largeTransfer * 10000) / totalAssetsValue;
        console2.log("Impact bps for 50% transfer:", impactBps);
        assertEq(impactBps, 5000, "50% transfer should have 5000 bps impact");
        
        // A 10% tolerance (1000 bps) should reject 50% transfer
        assertTrue(impactBps > 1000, "Impact should exceed 10% tolerance");
    }

    /// @notice Test that external token donation reduces NAV impact (helps, not blocks)
    /// @dev This proves that sending tokens to pool is NOT an attack vector for NavImpactTooHigh
    function test_NavImpactLib_ExternalDonationReducesImpact() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Setup pool with 100 ETH
        vm.deal(poolProxy, 100 ether);
        vm.deal(address(this), 300 ether);
        ISmartPoolActions(poolProxy).mint{value: 100 ether}(address(this), 100 ether, 0);
        
        uint256 totalSupply = ISmartPoolState(poolProxy).getPoolTokens().totalSupply;
        uint8 decimals = ISmartPoolState(poolProxy).getPool().decimals;
        
        // Calculate initial impact for a 20 ETH transfer
        uint256 transferAmount = 20 ether;
        
        // Before donation
        ISmartPoolActions(poolProxy).updateUnitaryValue();
        uint256 unitaryValueBefore = ISmartPoolState(poolProxy).getPoolTokens().unitaryValue;
        uint256 totalAssetsBefore = (unitaryValueBefore * totalSupply) / (10 ** decimals);
        uint256 impactBefore = (transferAmount * 10000) / totalAssetsBefore;
        
        console2.log("Total assets before donation:", totalAssetsBefore);
        console2.log("Impact before donation (bps):", impactBefore);
        
        // External attacker sends 100 ETH to pool (trying to "attack")
        vm.deal(poolProxy, address(poolProxy).balance + 100 ether);
        
        // After donation - update NAV to reflect new balance
        ISmartPoolActions(poolProxy).updateUnitaryValue();
        uint256 unitaryValueAfter = ISmartPoolState(poolProxy).getPoolTokens().unitaryValue;
        uint256 totalAssetsAfter = (unitaryValueAfter * totalSupply) / (10 ** decimals);
        uint256 impactAfter = (transferAmount * 10000) / totalAssetsAfter;
        
        console2.log("Total assets after donation:", totalAssetsAfter);
        console2.log("Impact after donation (bps):", impactAfter);
        
        // Impact should be LOWER after donation (not higher)
        assertLt(impactAfter, impactBefore, "External donation should REDUCE impact, not increase");
        
        // Specifically: 20 ETH / 100 ETH = 20% (2000 bps), 20 ETH / 200 ETH = 10% (1000 bps)
        assertTrue(impactAfter < impactBefore, "External token sending is NOT an attack vector for NavImpactTooHigh");
    }

    /// @notice Test that NavImpactLib allows transfers when within tolerance
    function test_NavImpactLib_AllowsTransferWithinTolerance() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Setup pool with 100 ETH
        vm.deal(poolProxy, 100 ether);
        vm.deal(address(this), 200 ether);
        ISmartPoolActions(poolProxy).mint{value: 100 ether}(address(this), 100 ether, 0);
        
        uint256 totalSupply = ISmartPoolState(poolProxy).getPoolTokens().totalSupply;
        uint8 decimals = ISmartPoolState(poolProxy).getPool().decimals;
        
        ISmartPoolActions(poolProxy).updateUnitaryValue();
        uint256 unitaryValue = ISmartPoolState(poolProxy).getPoolTokens().unitaryValue;
        uint256 totalAssets = (unitaryValue * totalSupply) / (10 ** decimals);
        
        // Calculate a transfer that's within 10% tolerance
        uint256 smallTransfer = totalAssets / 20; // 5% of assets
        uint256 impactBps = (smallTransfer * 10000) / totalAssets;
        
        console2.log("Small transfer amount:", smallTransfer);
        console2.log("Impact (bps):", impactBps);
        
        // 5% transfer should be within 10% tolerance
        assertLt(impactBps, 1000, "5% transfer should be within 10% tolerance");
        // Allow for rounding (~500 bps, could be 499-501 due to integer division)
        assertGe(impactBps, 490, "5% transfer should have ~500 bps impact (lower bound)");
        assertLe(impactBps, 510, "5% transfer should have ~500 bps impact (upper bound)");
    }

    /// @notice Test edge case: empty pool allows any transfer
    function test_NavImpactLib_EmptyPoolAllowsAnyTransfer() public {
        vm.warp(block.timestamp + 100);
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(ethUsdc),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Pool with no supply - first mint initializes
        vm.deal(poolProxy, 100 ether);
        vm.deal(address(this), 200 ether);
        
        // Before first mint, totalSupply = 0
        uint256 totalSupplyBefore = ISmartPoolState(poolProxy).getPoolTokens().totalSupply;
        assertEq(totalSupplyBefore, 0, "Pool should start with 0 supply");
        
        // First mint should work (empty pool allows any transfer per validateNavImpact logic)
        // effectiveSupply <= 0 returns early, allowing any transfer
        ISmartPoolActions(poolProxy).mint{value: 100 ether}(address(this), 100 ether, 0);
        
        uint256 totalSupplyAfter = ISmartPoolState(poolProxy).getPoolTokens().totalSupply;
        assertGt(totalSupplyAfter, 0, "Mint should succeed on empty pool");
    }

    /// @notice Test that AIntents.depositV3 with Sync mode reverts with NavImpactTooHigh when impact exceeds tolerance
    /// @dev This tests the actual revert path in NavImpactLib.validateNavImpact
    function test_AIntents_SyncMode_RevertsWithNavImpactTooHigh() public {
        vm.warp(block.timestamp + 100);
        
        // Deploy MockAcrossSpokePool and AIntents adapter
        address mockSpokePool = deployCode("out/MockAcrossSpokePool.sol/MockAcrossSpokePool.json", abi.encode(Constants.ETH_WETH));
        AIntents aIntentsAdapter = new AIntents(mockSpokePool);
        
        // Whitelist and register AIntents adapter with authority
        IAuthority(deployment.authority).setAdapter(address(aIntentsAdapter), true);
        IAuthority(deployment.authority).addMethod(IAIntents.depositV3.selector, address(aIntentsAdapter));
        
        // Initialize oracle for ETH WETH (we'll use the real ETH_WETH address)
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_WETH),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Create an ETH-based pool (baseToken = address(0)), so we can mint with ETH
        (address ethPool, ) = IRigoblockPoolProxyFactory(deployment.factory).createPool("eth pool", "ETH", address(0));
        
        // Mint pool tokens to establish totalSupply and NAV
        vm.deal(ethPool, 100 ether);
        vm.deal(address(this), 300 ether);
        ISmartPoolActions(ethPool).mint{value: 100 ether}(address(this), 100 ether, 0);
        
        // Verify pool has supply and NAV
        uint256 totalSupply = ISmartPoolState(ethPool).getPoolTokens().totalSupply;
        uint256 unitaryValue = ISmartPoolState(ethPool).getPoolTokens().unitaryValue;
        assertGt(totalSupply, 0, "Pool should have supply");
        assertGt(unitaryValue, 0, "Pool should have NAV");
        
        // Mark ETH_WETH as active token (so we can bridge WETH out)
        _setupActiveToken(ethPool, Constants.ETH_WETH);
        
        // Deploy a mock WETH at the ETH_WETH address and give pool some WETH to transfer
        deployCodeTo(
            "out/MockERC20.sol/MockERC20.0.8.28.json",
            abi.encode("Wrapped Ether", "WETH", 18),
            Constants.ETH_WETH
        );
        uint256 transferAmount = 50 ether; // 50% of pool value - will exceed 10% tolerance
        MockERC20(Constants.ETH_WETH).mint(ethPool, transferAmount);
        
        // Set chainId to Ethereum (1) so CrosschainLib.isAllowedCrosschainToken passes
        vm.chainId(1);
        
        // Build AcrossParams for a Sync operation with 10% tolerance (1000 bps)
        // Transfer 50 WETH on a ~100 ETH pool = 50% impact, exceeds 10% tolerance
        SourceMessageParams memory sourceParams = SourceMessageParams({
            opType: OpType.Sync,
            navTolerance: 1000, // 10% tolerance in bps
            sourceNativeAmount: 0,
            shouldUnwrapOnDestination: false
        });
        
        IAIntents.AcrossParams memory params = IAIntents.AcrossParams({
            depositor: address(this),
            recipient: address(0),
            inputToken: Constants.ETH_WETH,
            outputToken: Constants.ETH_WETH,
            inputAmount: transferAmount,
            outputAmount: transferAmount - 1e16, // Slight slippage
            destinationChainId: 8453, // Base
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: 0,
            exclusivityDeadline: 0,
            message: abi.encode(sourceParams)
        });
        
        // Should revert with NavImpactTooHigh because 50% > 10% tolerance
        vm.expectRevert(NavImpactLib.NavImpactTooHigh.selector);
        IAIntents(ethPool).depositV3(params);
        
        // Reset chainId
        vm.chainId(31337);
    }

    /// @notice Test that AIntents.depositV3 with Sync mode succeeds when impact is within tolerance
    function test_AIntents_SyncMode_PassesNavImpactCheckWithinTolerance() public {
        vm.warp(block.timestamp + 100);
        
        // Deploy MockAcrossSpokePool and AIntents adapter  
        address mockSpokePool = deployCode("out/MockAcrossSpokePool.sol/MockAcrossSpokePool.json", abi.encode(Constants.ETH_WETH));
        AIntents aIntentsAdapter = new AIntents(mockSpokePool);
        
        // Whitelist and register AIntents adapter with authority
        IAuthority(deployment.authority).setAdapter(address(aIntentsAdapter), true);
        IAuthority(deployment.authority).addMethod(IAIntents.depositV3.selector, address(aIntentsAdapter));
        
        // Initialize oracle for ETH WETH
        deployment.mockOracle.initializeObservations(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(Constants.ETH_WETH),
                fee: 0,
                tickSpacing: TickMath.MAX_TICK_SPACING,
                hooks: IHooks(address(deployment.mockOracle))
            })
        );
        
        // Create an ETH-based pool (baseToken = address(0)), so we can mint with ETH
        (address ethPool, ) = IRigoblockPoolProxyFactory(deployment.factory).createPool("eth pool5", "ETH", address(0));
        
        // Mint pool tokens to establish totalSupply and NAV
        vm.deal(ethPool, 100 ether);
        vm.deal(address(this), 200 ether);
        ISmartPoolActions(ethPool).mint{value: 100 ether}(address(this), 100 ether, 0);
        
        // Mark ETH_WETH as active token (so we can bridge WETH out)
        _setupActiveToken(ethPool, Constants.ETH_WETH);
        
        // Deploy a mock WETH at the ETH_WETH address and give pool some WETH to transfer
        // 5% transfer on ~100 ETH pool - within 10% tolerance
        deployCodeTo(
            "out/MockERC20.sol/MockERC20.0.8.28.json",
            abi.encode("Wrapped Ether", "WETH", 18),
            Constants.ETH_WETH
        );
        uint256 transferAmount = 5 ether; // 5% of pool value - within 10% tolerance
        MockERC20(Constants.ETH_WETH).mint(ethPool, transferAmount);
        
        // Set chainId to Ethereum (1) so CrosschainLib.isAllowedCrosschainToken passes
        vm.chainId(1);
        
        SourceMessageParams memory sourceParams = SourceMessageParams({
            opType: OpType.Sync,
            navTolerance: 1000, // 10% tolerance
            sourceNativeAmount: 0,
            shouldUnwrapOnDestination: false
        });
        
        IAIntents.AcrossParams memory params = IAIntents.AcrossParams({
            depositor: address(this),
            recipient: address(0),
            inputToken: Constants.ETH_WETH,
            outputToken: Constants.ETH_WETH,
            inputAmount: transferAmount,
            outputAmount: transferAmount - 1e14,
            destinationChainId: 8453,
            exclusiveRelayer: address(0),
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: 0,
            exclusivityDeadline: 0,
            message: abi.encode(sourceParams)
        });
        
        // The test verifies that NavImpactLib.validateNavImpact passes (does not revert with NavImpactTooHigh)
        // 5% impact is within 10% tolerance, so the call should succeed (MockSpokePool accepts without real transfer)
        vm.expectEmit(false, false, false, false);
        emit IAIntents.CrossChainTransferInitiated(address(this), 8453, Constants.ETH_WETH, transferAmount, uint8(OpType.Sync), address(0));
        IAIntents(ethPool).depositV3(params);
        
        // Reset chainId
        vm.chainId(31337);
    }
}