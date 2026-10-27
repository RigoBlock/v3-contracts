// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";

import {SmartPool} from "../../contracts/protocol/SmartPool.sol";
import {ExtensionsMapDeployer} from "../../contracts/protocol/deps/ExtensionsMapDeployer.sol";
import {EAppsLighter} from "../../contracts/protocol/extensions/EAppsLighter.sol";
import {EOracle} from "../../contracts/protocol/extensions/EOracle.sol";
import {EUpgrade} from "../../contracts/protocol/extensions/EUpgrade.sol";
import {ECrosschain} from "../../contracts/protocol/extensions/ECrosschain.sol";
import {EERC20} from "../../contracts/protocol/extensions/EERC20.sol";
import {ALighter} from "../../contracts/protocol/extensions/adapters/ALighter.sol";
import {IALighter} from "../../contracts/protocol/extensions/adapters/interfaces/IALighter.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";
import {LighterRouteType, ILighterInteropManager} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/ILighterInteropManager.sol";
import {ILighterCoreEntrypoint} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/ILighterCoreEntrypoint.sol";
import {LighterTypes} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/LighterTypes.sol";
import {LighterLib} from "../../contracts/protocol/libraries/LighterLib.sol";
import {LighterConstants} from "../../contracts/protocol/types/LighterConstants.sol";
import {IAuthority} from "../../contracts/protocol/interfaces/IAuthority.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {Applications, LighterViewData} from "../../contracts/protocol/types/Applications.sol";
import {ExternalApp} from "../../contracts/protocol/types/ExternalApp.sol";
import {DeploymentParams, Extensions, EAppsParams} from "../../contracts/protocol/types/DeploymentParams.sol";

/// @notice USDC stand-in etched at the LighterEVM USDC predeploy address. `decimals` is a
///  constant so it survives the etch (no storage slot).
contract MockUSDC {
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Records interop-manager transfer args and returns increasing request ids.
/// @dev Does not pull tokens, mirroring the mocked-sendToCore approach of ALighterUnit.t.sol.
contract MockInteropManager {
    uint64 public reqIdCounter;

    function sendToCore(
        uint32 assetIndex,
        address to,
        bool isL1Account,
        uint256 amount,
        LighterRouteType routeType
    ) external payable returns (uint64 reqId) {
        reqId = ++reqIdCounter;
    }

    function sendToEvm(
        uint48 accountIndex,
        uint32 assetIndex,
        address evmRecipient,
        LighterRouteType routeType,
        uint64 baseAmount
    ) external returns (uint64 reqId) {
        reqId = ++reqIdCounter;
    }
}

/// @notice Returns increasing request ids for Core order writes.
contract MockCoreEntrypoint {
    uint64 public reqIdCounter;

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
    ) external returns (uint64 reqId) {
        reqId = ++reqIdCounter;
    }

    function cancelOrder(uint48 accountIndex, uint64 orderIndex) external returns (uint64 reqId) {
        reqId = ++reqIdCounter;
    }

    function cancelAllOrders(uint48 accountIndex) external returns (uint64 reqId) {
        reqId = ++reqIdCounter;
    }
}

/// @title EAppsLighterUnitTest
/// @notice Offline coverage for EAppsLighter (constructor + _handleApplication) and the
///  EApps.getLighterTrackedMarkets client view. The fork suite (ALighterFork.t.sol) exercises
///  the same paths against the real devnet, but an offline duplicate keeps this coverage
///  hermetic: it runs in every profile (including coverage), needs no RPC, and is immune to
///  devnet resets. It deploys the full pool offline on a spoofed LighterEVM chainid with the
///  predeploy addresses etched to mocks, exactly like ALighterUnit.t.sol.
contract EAppsLighterUnitTest is Test {
    address internal constant USDC = LighterConstants.USDC;
    address internal constant READ_CORE = LighterConstants.READ_CORE;
    address internal constant MANAGER = LighterConstants.EVM_INTEROP_MANAGER;
    address internal constant ENTRYPOINT = LighterConstants.CORE_ENTRYPOINT;
    address internal constant WETH = 0x660000000000000000000000000000000000000c;

    address internal factory;
    address internal authority;
    address internal pool;
    address internal poolOwner;
    address internal user;

    function setUp() public {
        vm.chainId(Constants.LIGHTEREVM_CHAIN_ID);

        // Etch mocks at the Lighter predeploy addresses (USDC + write precompiles).
        MockUSDC usdc = new MockUSDC();
        MockInteropManager manager = new MockInteropManager();
        MockCoreEntrypoint entrypoint = new MockCoreEntrypoint();
        vm.etch(USDC, address(usdc).code);
        vm.etch(MANAGER, address(manager).code);
        vm.etch(ENTRYPOINT, address(entrypoint).code);

        // READ_CORE is a native precompile Foundry cannot execute; revert every read by default
        // and mock the specific selectors per test (same approach as ALighterUnit.t.sol).
        bytes memory anyCalldata = hex"";
        vm.mockCallRevert(READ_CORE, anyCalldata, new bytes(0));

        poolOwner = makeAddr("poolOwner");
        user = makeAddr("user");

        // Local Authority/Registry/Factory (Authority is 0.8.17, so deploy via artifacts).
        authority = deployCode("out/Authority.sol/Authority.json", abi.encode(address(this)));
        IAuthority(authority).setWhitelister(address(this), true);
        address registry = deployCode("out/PoolRegistry.sol/PoolRegistry.json", abi.encode(authority, address(this)));
        factory = deployCode(
            "out/RigoblockPoolProxyFactory.sol/RigoblockPoolProxyFactory.json",
            abi.encode(address(0x1), registry)
        );
        IAuthority(authority).setFactory(factory, true);

        // Extensions + implementation (no Uniswap V4 / staking / oracle on LighterEVM: zeros).
        EAppsLighter eApps = new EAppsLighter(EAppsParams({grgStakingProxy: address(0), univ4Posm: address(0)}));
        EOracle eOracle = new EOracle(address(0), WETH);
        EUpgrade eUpgrade = new EUpgrade(factory);
        ECrosschain eCrosschain = new ECrosschain();
        EERC20 eErc20 = new EERC20();

        Extensions memory extensions = Extensions({
            eApps: address(eApps),
            eOracle: address(eOracle),
            eUpgrade: address(eUpgrade),
            eCrosschain: address(eCrosschain),
            eGmxCallback: address(0),
            eErc20: address(eErc20)
        });
        ExtensionsMapDeployer mapDeployer = new ExtensionsMapDeployer();
        bytes32 salt = keccak256(abi.encodePacked("EAPPS_LIGHTER_UNIT_MAP", block.chainid));
        address extensionsMap = mapDeployer.deployExtensionsMap(
            DeploymentParams({extensions: extensions, wrappedNative: WETH}),
            salt
        );

        address implementation = address(new SmartPool(authority, extensionsMap, Constants.TOKEN_JAR));
        IRigoblockPoolProxyFactory(factory).setImplementation(implementation);

        vm.prank(poolOwner);
        (pool, ) = IRigoblockPoolProxyFactory(factory).createPool("Lighter Unit", "LUNIT", USDC);

        // Authorize the ALighter adapter (5 selectors).
        address aLighter = address(new ALighter());
        IAuthority(authority).setAdapter(aLighter, true);
        IAuthority(authority).addMethod(ILighterInteropManager.sendToCore.selector, aLighter);
        IAuthority(authority).addMethod(ILighterInteropManager.sendToEvm.selector, aLighter);
        IAuthority(authority).addMethod(ILighterCoreEntrypoint.createOrder.selector, aLighter);
        IAuthority(authority).addMethod(ILighterCoreEntrypoint.cancelOrder.selector, aLighter);
        IAuthority(authority).addMethod(ILighterCoreEntrypoint.cancelAllOrders.selector, aLighter);

        // Fund the pool and give it non-zero supply/NAV.
        MockUSDC(USDC).mint(user, 1_000_000e6);
        vm.startPrank(user);
        MockUSDC(USDC).approve(pool, type(uint256).max);
        ISmartPool(payable(pool)).mint(user, 100_000e6, 0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        READ_CORE MOCK HELPERS
    //////////////////////////////////////////////////////////////*/

    function _wrap(bytes memory data) internal pure returns (bytes memory) {
        return abi.encode(true, data);
    }

    function _mockAccountInfo(address account, LighterTypes.AccountInfo memory info) internal {
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_ACCOUNT_INFO, account, false),
            _wrap(abi.encode(info))
        );
    }

    function _accountInfo(int128 collateral) internal view returns (LighterTypes.AccountInfo memory) {
        return
            LighterTypes.AccountInfo({
                accountType: 0,
                accountIndex: 7,
                masterAccountIndex: 7,
                l1Address: address(0),
                evmAddress: pool,
                collateralBaseAmount: collateral
            });
    }

    function _mockEvmAccountIndex(address account, uint48 index) internal {
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_EVM_ACCOUNT_INDEX, account),
            _wrap(abi.encode(index))
        );
    }

    /// @dev The 0x0000 tx-status read is the one read without the (bool found, bytes) envelope.
    function _mockTxStatus(uint64 reqId, uint8 status) internal {
        vm.mockCall(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_TX_STATUS, reqId), abi.encode(status, bytes("")));
    }

    function _mockMarketInfo(uint16 marketId, LighterTypes.MarketInfo memory info) internal {
        vm.mockCall(READ_CORE, abi.encodePacked(LighterLib._SELECTOR_MARKET_INFO, marketId), _wrap(abi.encode(info)));
    }

    /// @dev Perp market (marketType 0) with indexPrice == markPrice.
    function _marketInfo(uint64 markPrice) internal pure returns (LighterTypes.MarketInfo memory) {
        return
            LighterTypes.MarketInfo({
                marketType: 0,
                baseAssetId: 0,
                quoteAssetId: 0,
                takerFee: 0,
                makerFee: 0,
                minBaseAmount: 0,
                minQuoteAmount: 0,
                liquidationFee: 0,
                indexPrice: markPrice,
                markPrice: markPrice
            });
    }

    function _mockPosition(address account, uint16 marketId, LighterTypes.Position memory position) internal {
        vm.mockCall(
            READ_CORE,
            abi.encodePacked(LighterLib._SELECTOR_POSITION, account, false, marketId),
            _wrap(abi.encode(position))
        );
    }

    /// @notice GRG_STAKING is always queried by getAppTokenBalances (ApplicationsLib), so the
    ///  Lighter entry is located by appType, not by position.
    function _findLighterApp(ExternalApp[] memory apps) internal pure returns (ExternalApp memory lighterApp) {
        for (uint256 i; i < apps.length; i++) {
            if (apps[i].appType == uint256(Applications.LIGHTER_PERPS)) {
                return apps[i];
            }
        }
        revert("Lighter application should be returned");
    }

    /// @notice Deposits USDC to Core perps through the adapter and settles the window.
    function _depositAndSettle(uint256 amount) internal {
        _mockAccountInfo(pool, _accountInfo(0));
        _mockEvmAccountIndex(pool, 7);
        vm.prank(poolOwner);
        IALighter(pool).sendToCore(3, pool, false, amount, LighterRouteType.Perps);
        // Exit the settlement window so NAV reads are allowed and in-flight drops out.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 17 seconds);
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The LIGHTER_PERPS branch of _handleApplication values the Core account collateral.
    function testHandleApplication_LighterBranch() public {
        uint256 deposit = 10_000e6;
        _depositAndSettle(deposit);
        _mockAccountInfo(pool, _accountInfo(int128(uint128(deposit))));

        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(1 << uint256(Applications.LIGHTER_PERPS));
        ExternalApp memory lighterApp = _findLighterApp(apps);
        assertEq(lighterApp.balances.length, 1, "Lighter app should report one balance");
        assertEq(lighterApp.balances[0].token, USDC, "Balance token should be USDC");
        assertEq(lighterApp.balances[0].amount, int256(deposit), "Balance should be the Core collateral");
    }

    /// @notice Non-Lighter application types fall through to the base EApps implementation.
    function testHandleApplication_FallsThroughToBase() public {
        uint256 deposit = 10_000e6;
        _depositAndSettle(deposit);
        _mockAccountInfo(pool, _accountInfo(int128(uint128(deposit))));

        uint256 mask = (1 << uint256(Applications.GRG_STAKING)) | (1 << uint256(Applications.LIGHTER_PERPS));
        ExternalApp[] memory apps = IEApps(pool).getAppTokenBalances(mask);
        assertEq(apps.length, 2, "GRG is always queried, plus the masked LIGHTER app");
        assertEq(apps[0].appType, uint256(Applications.GRG_STAKING));
        assertEq(apps[0].balances.length, 0, "GRG staking proxy is unset: empty balances");
        assertEq(_findLighterApp(apps).balances[0].amount, int256(deposit));
    }

    /// @notice NAV = collateral + unrealized PnL valued at the Core mark price.
    /// @dev Mirrors the live-verified formula in LighterLib._positionValueUsdc: a 2.0-lot long
    ///  (size 20_000 at sizeDecimals 4) entered at $5_000 (entryQuote 10_000e6) marked at $6_000
    ///  (markPrice 600_000 at priceDecimals 2) is worth 12_000e6, i.e. +2_000e6 PnL.
    function testHandleApplication_ValuesTrackedPositionPnl() public {
        uint256 deposit = 10_000e6;
        _depositAndSettle(deposit);

        vm.startPrank(poolOwner);
        _mockMarketInfo(0, _marketInfo(600_000));
        _mockEvmAccountIndex(pool, 7);
        IALighter(pool).createOrder(0, 0, 0, 0, 0, 0, 20_000, 600_000, false, false, 0);
        vm.stopPrank();

        _mockAccountInfo(pool, _accountInfo(int128(uint128(deposit))));
        _mockPosition(
            pool,
            0,
            LighterTypes.Position({
                size: 20_000,
                entryQuote: 10_000e6,
                initialMarginFraction: 0,
                totalOrderCount: 0,
                totalPositionTiedOrderCount: 0,
                marginMode: 0,
                allocatedMargin: 0
            })
        );

        ExternalApp memory lighterApp = _findLighterApp(
            IEApps(pool).getAppTokenBalances(1 << uint256(Applications.LIGHTER_PERPS))
        );
        assertEq(lighterApp.balances[0].amount, 12_000e6, "Balance should be collateral plus mark-to-market PnL");
    }

    /// @notice NAV reads revert inside the settlement window and succeed after it.
    function testHandleApplication_SettlementLock() public {
        _mockAccountInfo(pool, _accountInfo(0));
        _mockEvmAccountIndex(pool, 7);
        vm.prank(poolOwner);
        IALighter(pool).sendToCore(3, pool, false, 10_000e6, LighterRouteType.Perps);

        // Same block: allowed (in-flight covers the lagging Core read); the write is
        //  successful, so the in-flight amount is not added back.
        _mockAccountInfo(pool, _accountInfo(0));
        _mockTxStatus(1, 1);
        IEApps(pool).getAppTokenBalances(1 << uint256(Applications.LIGHTER_PERPS));

        // Next block within the window: locked.
        vm.roll(block.number + 1);
        _mockAccountInfo(pool, _accountInfo(0));
        vm.expectRevert(LighterLib.NavLocked.selector);
        IEApps(pool).getAppTokenBalances(1 << uint256(Applications.LIGHTER_PERPS));

        // After the window: allowed again.
        vm.warp(block.timestamp + 17 seconds);
        _mockAccountInfo(pool, _accountInfo(10_000e6));
        ExternalApp memory lighterApp = _findLighterApp(
            IEApps(pool).getAppTokenBalances(1 << uint256(Applications.LIGHTER_PERPS))
        );
        assertEq(lighterApp.balances[0].amount, 10_000e6);
    }

    /// @notice getLighterTrackedMarkets reports tracked markets, their release-time decimal
    ///  scales, and the in-flight ledger; a fresh pool reports an empty view.
    function testGetLighterTrackedMarkets() public {
        uint256 deposit = 10_000e6;
        _depositAndSettle(deposit);

        vm.startPrank(poolOwner);
        _mockMarketInfo(0, _marketInfo(500_000));
        _mockMarketInfo(2, _marketInfo(100_000));
        _mockEvmAccountIndex(pool, 7);
        IALighter(pool).createOrder(0, 0, 0, 0, 0, 0, 20_000, 500_000, false, false, 0);
        IALighter(pool).createOrder(0, 2, 0, 0, 0, 0, 30_000, 100_000, true, false, 0);
        vm.stopPrank();

        LighterViewData memory viewData = IEApps(pool).getLighterTrackedMarkets();
        assertEq(viewData.marketIds.length, 2, "Two markets should be tracked");
        assertEq(viewData.marketIds[0], 0, "ETH-PERP");
        assertEq(viewData.marketIds[1], 2, "SOL-PERP");
        assertEq(viewData.sizeDecimals[0], 4, "ETH-PERP sizeDecimals from LighterConstants table");
        assertEq(viewData.priceDecimals[0], 2, "ETH-PERP priceDecimals from LighterConstants table");
        assertEq(viewData.sizeDecimals[1], 3, "SOL-PERP sizeDecimals from LighterConstants table");
        assertEq(viewData.priceDecimals[1], 3, "SOL-PERP priceDecimals from LighterConstants table");
        assertEq(viewData.inFlightAmount, int128(uint128(deposit)), "Deposit in-flight amount recorded");
        assertEq(viewData.lastReqId, 1, "Only transfers record an action; the two orders do not");
        assertTrue(viewData.lastActionTimestamp > 0, "Action timestamp recorded");

        // A fresh pool with no Lighter activity reports the empty view.
        vm.prank(poolOwner);
        (address pool2, ) = IRigoblockPoolProxyFactory(factory).createPool("Lighter Unit 2", "LU2", USDC);
        LighterViewData memory empty = IEApps(pool2).getLighterTrackedMarkets();
        assertEq(empty.marketIds.length, 0);
        assertEq(empty.inFlightAmount, 0);
        assertEq(empty.lastReqId, 0);
        assertEq(empty.lastActionTimestamp, 0);
    }
}
