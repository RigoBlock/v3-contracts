// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

// Tests that mintWithToken's minimum-order guard is checked against the gross input
// value expressed in the base token's decimals, not the input token's decimals.
//
// Before the fix, _assertBiggerThanMinimum was called before converting amountIn to
// base units, causing a decimal mismatch for any token whose decimals differ from the
// base token. After the fix, the gross input is converted to base units and checked
// against the minimum before the spread is deducted. The remaining amount is then
// converted to base units a second time to compute the minted pool tokens. Two oracle
// conversions are required because the minimum must be evaluated on the gross value
// while the minted amount is calculated from the net value.

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Constants} from "../../contracts/test/Constants.sol";
import {RealDeploymentFixture} from "../fixtures/RealDeploymentFixture.sol";
import {IERC20} from "../../contracts/protocol/interfaces/IERC20.sol";
import {ISmartPool} from "../../contracts/protocol/ISmartPool.sol";

error PoolAmountSmallerThanMinimum(uint16 minimumOrderDivisor);

contract MintWithTokenMinimumGuardTest is Test, RealDeploymentFixture {
    /// @notice Test the high-impact direction: base token has more decimals than tokenIn.
    ///  Before the fix, any realistic USDC mint into a WETH-based pool reverted because
    ///  the threshold was expressed in 18-decimal WETH units while amountIn was in 6-decimal
    ///  USDC units. After the fix, the threshold applies to the gross USDC value once
    ///  converted to WETH, so normal order sizes succeed and only dust-sized orders revert.
    function test_UsdcIntoWethBase_RealisticAmountSucceeds() public {
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = Constants.ETH_WETH;
        deployFixture(baseTokens);
        vm.selectFork(mainnetForkId);

        address poolAddr = ethereum.pool;

        vm.prank(poolOwner);
        ISmartPool(payable(poolAddr)).setAcceptableMintToken(Constants.ETH_USDC, true);

        // 100,000 USDC is far above the 0.001 WETH economic minimum at a normal ETH/USD price.
        uint256 amountIn = 100_000 * 1e6;
        deal(Constants.ETH_USDC, user, amountIn);

        vm.startPrank(user);
        IERC20(Constants.ETH_USDC).approve(poolAddr, type(uint256).max);
        uint256 minted = ISmartPool(payable(poolAddr)).mintWithToken(user, amountIn, 0, Constants.ETH_USDC);
        vm.stopPrank();

        assertGt(minted, 0, "realistic USDC mint into WETH base must mint pool tokens");
        console2.log("minted pool tokens for 100k USDC:", minted);
    }

    /// @notice Test the mirror direction: base token has fewer decimals than tokenIn.
    ///  Before the fix, 1,000 wei of WETH cleared the guard for a USDC-based pool and
    ///  minted 0 pool tokens. After the fix, the guard is checked against the gross
    ///  converted USDC value, so the same dust order reverts on the minimum check.
    function test_WethIntoUsdcBase_DustAmountReverts() public {
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = Constants.ETH_USDC;
        deployFixture(baseTokens);
        vm.selectFork(mainnetForkId);

        address poolAddr = ethereum.pool;

        vm.prank(poolOwner);
        ISmartPool(payable(poolAddr)).setAcceptableMintToken(Constants.ETH_WETH, true);

        // 1,000 wei of WETH converts to far less than the 1,000 USDC-unit minimum.
        uint256 amountIn = 1000;
        deal(Constants.ETH_WETH, user, amountIn);

        vm.startPrank(user);
        IERC20(Constants.ETH_WETH).approve(poolAddr, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PoolAmountSmallerThanMinimum.selector, uint16(1000)));
        ISmartPool(payable(poolAddr)).mintWithToken(user, amountIn, 0, Constants.ETH_WETH);
        vm.stopPrank();
    }

    /// @notice A realistic WETH amount into a USDC base pool should mint a positive number
    ///  of pool tokens.
    function test_WethIntoUsdcBase_RealisticAmountSucceeds() public {
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = Constants.ETH_USDC;
        deployFixture(baseTokens);
        vm.selectFork(mainnetForkId);

        address poolAddr = ethereum.pool;

        vm.prank(poolOwner);
        ISmartPool(payable(poolAddr)).setAcceptableMintToken(Constants.ETH_WETH, true);

        // 0.01 WETH is worth well above the 0.001 USDC minimum at a normal ETH/USD price.
        uint256 amountIn = 0.01 ether;
        deal(Constants.ETH_WETH, user, amountIn);

        vm.startPrank(user);
        IERC20(Constants.ETH_WETH).approve(poolAddr, type(uint256).max);
        uint256 minted = ISmartPool(payable(poolAddr)).mintWithToken(user, amountIn, 0, Constants.ETH_WETH);
        vm.stopPrank();

        assertGt(minted, 0, "realistic WETH mint into USDC base must mint pool tokens");
        console2.log("minted pool tokens for 0.01 WETH:", minted);
    }

    /// @notice USDC amounts that convert to less than 0.001 WETH must still revert.
    function test_UsdcIntoWethBase_DustAmountReverts() public {
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = Constants.ETH_WETH;
        deployFixture(baseTokens);
        vm.selectFork(mainnetForkId);

        address poolAddr = ethereum.pool;

        vm.prank(poolOwner);
        ISmartPool(payable(poolAddr)).setAcceptableMintToken(Constants.ETH_USDC, true);

        // 0.001 USDC converts to far less than 0.001 WETH.
        uint256 amountIn = 0.001 * 1e6;
        deal(Constants.ETH_USDC, user, amountIn);

        vm.startPrank(user);
        IERC20(Constants.ETH_USDC).approve(poolAddr, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(PoolAmountSmallerThanMinimum.selector, uint16(1000)));
        ISmartPool(payable(poolAddr)).mintWithToken(user, amountIn, 0, Constants.ETH_USDC);
        vm.stopPrank();
    }

    /// @notice The spread must always be deducted in the input token, not converted to
    ///  base units. This test verifies the token jar receives the correct USDC amount.
    function test_UsdcIntoWethBase_SpreadIsDeductedInUsdc() public {
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = Constants.ETH_WETH;
        deployFixture(baseTokens);
        vm.selectFork(mainnetForkId);

        address poolAddr = ethereum.pool;

        vm.prank(poolOwner);
        ISmartPool(payable(poolAddr)).setAcceptableMintToken(Constants.ETH_USDC, true);

        uint256 amountIn = 100_000 * 1e6;
        deal(Constants.ETH_USDC, user, amountIn);

        uint16 spread = ISmartPool(payable(poolAddr)).getPoolParams().spread;
        uint256 expectedSpread = (amountIn * spread) / 10_000;

        uint256 tokenJarBefore = IERC20(Constants.ETH_USDC).balanceOf(Constants.TOKEN_JAR);
        uint256 poolBefore = IERC20(Constants.ETH_USDC).balanceOf(poolAddr);

        vm.startPrank(user);
        IERC20(Constants.ETH_USDC).approve(poolAddr, type(uint256).max);
        ISmartPool(payable(poolAddr)).mintWithToken(user, amountIn, 0, Constants.ETH_USDC);
        vm.stopPrank();

        uint256 tokenJarAfter = IERC20(Constants.ETH_USDC).balanceOf(Constants.TOKEN_JAR);
        uint256 poolAfter = IERC20(Constants.ETH_USDC).balanceOf(poolAddr);

        assertEq(tokenJarAfter - tokenJarBefore, expectedSpread, "spread must be paid in USDC");
        assertEq(poolAfter - poolBefore, amountIn - expectedSpread, "pool must receive USDC net of spread");
    }

    /// @notice Mirror spread check: when WETH is the input token into a USDC base pool,
    ///  the spread is paid in WETH, not USDC.
    function test_WethIntoUsdcBase_SpreadIsDeductedInWeth() public {
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = Constants.ETH_USDC;
        deployFixture(baseTokens);
        vm.selectFork(mainnetForkId);

        address poolAddr = ethereum.pool;

        vm.prank(poolOwner);
        ISmartPool(payable(poolAddr)).setAcceptableMintToken(Constants.ETH_WETH, true);

        uint256 amountIn = 0.01 ether;
        deal(Constants.ETH_WETH, user, amountIn);

        uint16 spread = ISmartPool(payable(poolAddr)).getPoolParams().spread;
        uint256 expectedSpread = (amountIn * spread) / 10_000;

        uint256 tokenJarBefore = IERC20(Constants.ETH_WETH).balanceOf(Constants.TOKEN_JAR);
        uint256 poolBefore = IERC20(Constants.ETH_WETH).balanceOf(poolAddr);

        vm.startPrank(user);
        IERC20(Constants.ETH_WETH).approve(poolAddr, type(uint256).max);
        ISmartPool(payable(poolAddr)).mintWithToken(user, amountIn, 0, Constants.ETH_WETH);
        vm.stopPrank();

        uint256 tokenJarAfter = IERC20(Constants.ETH_WETH).balanceOf(Constants.TOKEN_JAR);
        uint256 poolAfter = IERC20(Constants.ETH_WETH).balanceOf(poolAddr);

        assertEq(tokenJarAfter - tokenJarBefore, expectedSpread, "spread must be paid in WETH");
        assertEq(poolAfter - poolBefore, amountIn - expectedSpread, "pool must receive WETH net of spread");
    }

    /// @notice Sanity check: plain base-token mint still works after the guard move.
    function test_Control_BaseMintStillSucceeds() public {
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = Constants.ETH_WETH;
        deployFixture(baseTokens);
        vm.selectFork(mainnetForkId);

        address poolAddr = ethereum.pool;

        vm.startPrank(user);
        IERC20(Constants.ETH_WETH).approve(poolAddr, type(uint256).max);
        uint256 minted = ISmartPool(payable(poolAddr)).mint(user, 1 ether, 0);
        vm.stopPrank();

        assertGt(minted, 0, "base mint must still succeed");
        console2.log("control: minted pool tokens for 1 WETH:", minted);
    }
}
