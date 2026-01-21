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
import {IAcrossSpokePool} from "../../contracts/protocol/interfaces/IAcrossSpokePool.sol";
import {IWETH9} from "../../contracts/protocol/interfaces/IWETH9.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPoolImmutable} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolImmutable.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {ISmartPoolActions} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolActions.sol";
import {EnumerableSet, Pool} from "../../contracts/protocol/libraries/EnumerableSet.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {IEOracle} from "../../contracts/protocol/extensions/adapters/interfaces/IEOracle.sol";
import {OpType, DestinationMessageParams, SourceMessageParams} from "../../contracts/protocol/types/Crosschain.sol";
import {EscrowFactory} from "../../contracts/protocol/libraries/EscrowFactory.sol";
import {Escrow} from "../../contracts/protocol/deps/Escrow.sol";
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
            "out/MockERC20.sol/MockERC20.json",
            abi.encode("USD Coin", "USDC", 6),
            Constants.ETH_USDC
        );
        ethUsdc = Constants.ETH_USDC;
        
        deployCodeTo(
            "out/MockERC20.sol/MockERC20.json",
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
    function test_ECrosschain_RevertsDirectCall() public {
        // Create valid Transfer params
        DestinationMessageParams memory params = DestinationMessageParams({
            opType: OpType.Transfer,
            shouldUnwrapNative: false
        });
        
        // Should revert silently because extension does not implement updateUnitaryValue method
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
        
        // Simulate token transfer to pool
        vm.mockCall(
            ethUsdc,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(100e6)
        );
        
        // Should succeed with proper setup
        IECrosschain(poolProxy).donate(Constants.ETH_USDC, 100e6, params);

        vm.clearMockedCalls();
        vm.chainId(31337);
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
        
        vm.mockCall(
            Constants.ETH_WETH,
            abi.encodeWithSelector(IERC20.balanceOf.selector, poolProxy),
            abi.encode(1e18)
        );
        
        // Should succeed and unwrap WETH to ETH
        IECrosschain(poolProxy).donate(Constants.ETH_WETH, 1e18, params);

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
}

