// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Constants} from "../../contracts/test/Constants.sol";

import {AUniswap} from "../../contracts/protocol/extensions/adapters/AUniswap.sol";
import {EApps} from "../../contracts/protocol/extensions/EApps.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {ENavView} from "../../contracts/protocol/extensions/ENavView.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IOwnedUninitialized} from "../../contracts/utils/owned/IOwnedUninitialized.sol";
import {IPoolRegistry} from "../../contracts/protocol/interfaces/IPoolRegistry.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {IAUniswap} from "../../contracts/protocol/extensions/adapters/interfaces/IAUniswap.sol";
import {IMinimumVersion} from "../../contracts/protocol/extensions/adapters/interfaces/IMinimumVersion.sol";
import {DeploymentParams, Extensions, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";

/// @title AUniswapForkTest — Fork tests for the AUniswap wrap/unwrap adapter.
/// @dev Uses a mainnet fork so WETH is deployed at the canonical address.
contract AUniswapForkTest is Test {
    address private constant AUTHORITY = Constants.AUTHORITY;
    address private constant FACTORY = Constants.FACTORY;
    address private constant TOKEN_JAR = Constants.TOKEN_JAR;
    address private constant WETH = Constants.ETH_WETH;

    address private poolOwner;
    address private pool;
    AUniswap private aUniswap;

    function setUp() public {
        vm.createSelectFork("mainnet", Constants.MAINNET_BLOCK);

        poolOwner = makeAddr("poolOwner");

        aUniswap = new AUniswap(WETH);

        _setupPool();
    }

    // =========================================================================
    // Tests — requiredVersion
    // =========================================================================

    /// @notice requiredVersion is callable directly (no delegatecall guard).
    function test_RequiredVersion() public view {
        assertEq(IMinimumVersion(address(aUniswap)).requiredVersion(), "4.0.0");
    }

    // =========================================================================
    // Tests — wrapETH
    // =========================================================================

    /// @notice wrapETH converts native ETH held by the pool to WETH.
    function test_WrapETH_ConvertsNativeToWeth() public {
        uint256 amount = 1 ether;
        deal(pool, amount);

        uint256 wethBefore = IERC20(WETH).balanceOf(pool);

        vm.prank(poolOwner);
        IAUniswap(pool).wrapETH(amount);

        assertEq(pool.balance, 0, "native ETH must be zero after wrap");
        assertEq(IERC20(WETH).balanceOf(pool), wethBefore + amount, "WETH balance must increase by wrapped amount");
    }

    /// @notice wrapETH with value == 0 is a no-op (covers the if-branch false path).
    function test_WrapETH_ZeroValue_NoOp() public {
        uint256 ethBefore = pool.balance;
        uint256 wethBefore = IERC20(WETH).balanceOf(pool);

        vm.prank(poolOwner);
        IAUniswap(pool).wrapETH(0);

        assertEq(pool.balance, ethBefore, "ETH balance must not change on wrapETH(0)");
        assertEq(IERC20(WETH).balanceOf(pool), wethBefore, "WETH balance must not change on wrapETH(0)");
    }

    // =========================================================================
    // Tests — unwrapWETH9 (single-argument overload)
    // =========================================================================

    /// @notice unwrapWETH9(uint256) converts WETH held by the pool back to native ETH.
    function test_UnwrapWETH9_SingleArg_ConvertsWethToNative() public {
        uint256 amount = 1 ether;
        // Fund pool with WETH.
        deal(WETH, pool, amount);

        uint256 ethBefore = pool.balance;

        vm.prank(poolOwner);
        IAUniswap(pool).unwrapWETH9(amount);

        assertEq(IERC20(WETH).balanceOf(pool), 0, "WETH balance must be zero after unwrap");
        assertEq(pool.balance, ethBefore + amount, "native ETH balance must increase by unwrapped amount");
    }

    // =========================================================================
    // Tests — unwrapWETH9 (two-argument overload)
    // =========================================================================

    /// @notice unwrapWETH9(uint256,address) ignores the recipient and always sends ETH to pool.
    function test_UnwrapWETH9_TwoArg_RecipientIgnored() public {
        uint256 amount = 1 ether;
        deal(WETH, pool, amount);

        address rogue = makeAddr("rogue");
        uint256 rogueEthBefore = rogue.balance;

        vm.prank(poolOwner);
        IAUniswap(pool).unwrapWETH9(amount, rogue);

        // Rogue address must NOT have received ETH.
        assertEq(rogue.balance, rogueEthBefore, "recipient arg must be ignored: no ETH to rogue");
        // Pool must have received the ETH.
        assertGt(pool.balance, 0, "pool must hold the unwrapped ETH");
    }

    // =========================================================================
    // Private helpers
    // =========================================================================

    function _setupPool() private {
        EApps eApps = new EApps(EAppsParams({grgStakingProxy: Constants.GRG_STAKING, univ4Posm: Constants.UNISWAP_V4_POSM}));
        EOracle eOracle = new EOracle(Constants.ORACLE, WETH);
        EUpgrade eUpgrade = new EUpgrade(FACTORY);
        ENavView eNavView = new ENavView(EAppsParams({grgStakingProxy: Constants.GRG_STAKING, univ4Posm: Constants.UNISWAP_V4_POSM}));
        ECrosschain eCrosschain = new ECrosschain();

        ExtensionsMapDeployer mapDeployer = new ExtensionsMapDeployer();
        DeploymentParams memory params = DeploymentParams({
            extensions: Extensions({
                eApps: address(eApps),
                eOracle: address(eOracle),
                eUpgrade: address(eUpgrade),
                eNavView: address(eNavView),
                eCrosschain: address(eCrosschain)
            }),
            wrappedNative: WETH
        });
        bytes32 salt = keccak256(abi.encodePacked("AUNISWAP_FORK_TEST", block.chainid));
        address extensionsMapAddr = mapDeployer.deployExtensionsMap(params, salt);

        SmartPool impl = new SmartPool(AUTHORITY, extensionsMapAddr, TOKEN_JAR);

        address registry = IRigoblockPoolProxyFactory(FACTORY).getRegistry();
        address rigoblockDao = IPoolRegistry(registry).rigoblockDao();
        vm.prank(rigoblockDao);
        IRigoblockPoolProxyFactory(FACTORY).setImplementation(address(impl));

        // Create pool with native ETH as base token (address(0)).
        vm.prank(poolOwner);
        (pool,) = IRigoblockPoolProxyFactory(FACTORY).createPool("UniswapForkPool", "UNIFP", address(0));

        // Register AUniswap in Authority. Selectors may already be mapped to a
        // previously deployed AUniswap instance (mainnet fork), so remove them first.
        address authorityOwner = IOwnedUninitialized(AUTHORITY).owner();
        vm.startPrank(authorityOwner);
        IAuthority(AUTHORITY).setAdapter(address(aUniswap), true);
        if (!IAuthority(AUTHORITY).isWhitelister(authorityOwner)) {
            IAuthority(AUTHORITY).setWhitelister(authorityOwner, true);
        }
        _addMethodForceUpdate(IAUniswap.wrapETH.selector);
        _addMethodForceUpdate(bytes4(keccak256("unwrapWETH9(uint256)")));
        _addMethodForceUpdate(bytes4(keccak256("unwrapWETH9(uint256,address)")));
        vm.stopPrank();

        // Mint pool tokens so totalSupply > 0 (required for oracle-based operations).
        deal(poolOwner, 2 ether);
        vm.prank(poolOwner);
        (bool ok,) = payable(pool).call{value: 1 ether}(
            abi.encodeWithSignature("mint(address,uint256,uint256)", poolOwner, 1 ether, 0)
        );
        require(ok, "mint failed");
    }

    /// @dev Remove any existing mapping for `selector` then register it to `aUniswap`.
    ///      Must be called while pranking the authority owner/whitelister.
    function _addMethodForceUpdate(bytes4 selector) private {
        address existing = IAuthority(AUTHORITY).getApplicationAdapter(selector);
        if (existing != address(0)) {
            IAuthority(AUTHORITY).removeMethod(selector, existing);
        }
        IAuthority(AUTHORITY).addMethod(selector, address(aUniswap));
    }
}
