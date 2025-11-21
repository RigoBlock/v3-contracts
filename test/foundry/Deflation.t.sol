// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Deflation} from "../../contracts/rigoToken/inflation/Deflation.sol";
import {ERC20} from "@openzeppelin-legacy/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MockOracle {
    mapping(address => mapping(address => int256)) public conversionRates;

    function setConversionRate(address from, address to, int256 rate) external {
        conversionRates[from][to] = rate;
    }

    function convertTokenAmount(
        address token,
        int256 amount,
        address targetToken
    ) external view returns (int256) {
        int256 rate = conversionRates[token][targetToken];
        if (rate == 0) return 0;
        return (amount * rate) / 1e18;
    }
}

contract DeflationTest is Test {
    Deflation public deflation;
    MockERC20 public grg;
    MockERC20 public token1;
    MockOracle public oracle;
    
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    
    uint256 constant MAX_DISCOUNT = 8000;
    uint256 constant AUCTION_DURATION = 2 weeks;
    uint256 constant BASIS_POINTS = 10000;
    address constant ETH_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    event TokenPurchased(
        address indexed buyer,
        address indexed token,
        uint256 tokenAmount,
        uint256 grgPaid,
        uint256 discount
    );

    function setUp() public {
        grg = new MockERC20("RigoBlock", "GRG");
        token1 = new MockERC20("Token1", "TK1");
        oracle = new MockOracle();
        
        deflation = new Deflation(address(grg), address(oracle));
        
        // Mint some GRG to users
        grg.mint(user1, 1000e18);
        grg.mint(user2, 1000e18);
        
        // Mint some token1 to deflation contract
        token1.mint(address(deflation), 100e18);
        
        // Set up conversion rate: 1 token1 = 2 GRG
        oracle.setConversionRate(address(token1), address(grg), 2e18);

        // Pre-approve GRG for both users (convenience)
        vm.prank(user1);
        grg.approve(address(deflation), type(uint256).max);
        vm.prank(user2);
        grg.approve(address(deflation), type(uint256).max);
    }

    function testConstructor() public view {
        assertEq(address(deflation.GRG()), address(grg));
        assertEq(address(deflation.oracle()), address(oracle));
        assertEq(deflation.MAX_DISCOUNT(), MAX_DISCOUNT);
        assertEq(deflation.AUCTION_DURATION(), AUCTION_DURATION);
        assertEq(deflation.BASIS_POINTS(), BASIS_POINTS);
    }

    function testReceiveETH() public {
        uint256 balanceBefore = address(deflation).balance;
        
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        (bool success,) = address(deflation).call{value: 1 ether}("");
        
        assertTrue(success);
        assertEq(address(deflation).balance, balanceBefore + 1 ether);
    }

    function testGetCurrentDiscountInitial() public view {
        uint256 discount = deflation.getCurrentDiscount(address(token1));
        assertEq(discount, 0);
    }

    function testGetCurrentDiscountAfterMaxDuration() public {
        deflation.kickstartAuction(address(token1)); // <-- added
        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        
        uint256 discount = deflation.getCurrentDiscount(address(token1));
        assertEq(discount, MAX_DISCOUNT);
    }

    function testGetCurrentDiscountHalfway() public {
        deflation.kickstartAuction(address(token1)); // <-- added
        vm.warp(block.timestamp + AUCTION_DURATION / 2);
        
        uint256 discount = deflation.getCurrentDiscount(address(token1));
        assertApproxEqAbs(discount, MAX_DISCOUNT / 2, 10);
    }

    function testBuyTokenRevertsOnZeroAmount() public {
        deflation.kickstartAuction(address(token1)); // <-- added
        vm.prank(user1);
        vm.expectRevert("Amount must be greater than 0");
        deflation.buyToken(address(token1), 0);
    }

    function testBuyTokenRevertsOnZeroAddress() public {
        deflation.kickstartAuction(address(token1)); // <-- added (doesn't hurt)
        vm.prank(user1);
        vm.expectRevert("Invalid token address");
        deflation.buyToken(address(0), 1e18);
    }

    function testBuyTokenRevertsOnInvalidConversion() public {
        MockERC20 token2 = new MockERC20("Token2", "TK2");
        token2.mint(address(deflation), 10e18);
        deflation.kickstartAuction(address(token2)); // <-- added
        
        vm.prank(user1);
        vm.expectRevert(Deflation.InvalidConvertedAmount.selector);
        deflation.buyToken(address(token2), 1e18);
    }

    function testBuyTokenSuccess() public {
        deflation.kickstartAuction(address(token1)); // <-- added
        
        uint256 amountOut = 5e18;
        
        vm.startPrank(user1);
        uint256 grgBalanceBefore = grg.balanceOf(user1);
        uint256 token1BalanceBefore = token1.balanceOf(user1);
        
        uint256 amountIn = deflation.buyToken(address(token1), amountOut);
        
        uint256 grgBalanceAfter = grg.balanceOf(user1);
        uint256 token1BalanceAfter = token1.balanceOf(user1);
        vm.stopPrank();
        
        assertEq(grgBalanceBefore - grgBalanceAfter, amountIn);
        assertEq(token1BalanceAfter - token1BalanceBefore, amountOut);
    }

    function testBuyTokenEmitsEvent() public {
        deflation.kickstartAuction(address(token1)); // <-- added
        
        uint256 amountOut = 1e18;
        uint256 discount = deflation.getCurrentDiscount(address(token1));
        uint256 expectedGrg = (amountOut * 2e18 / 1e18) * (BASIS_POINTS - discount) / BASIS_POINTS;
        
        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true); // changed to true for data check
        emit TokenPurchased(user1, address(token1), amountOut, expectedGrg, discount);
        deflation.buyToken(address(token1), amountOut);
        vm.stopPrank();
    }

    function testBuyTokenWithDiscount() public {
        deflation.kickstartAuction(address(token1)); // <-- added

        uint256 amountOut = 1e18;
        
        // First purchase (0% discount)
        vm.prank(user1);
        uint256 amountIn1 = deflation.buyToken(address(token1), amountOut);
        
        // Fast forward
        vm.warp(block.timestamp + AUCTION_DURATION / 2);
        
        // Second purchase (should be cheaper)
        vm.prank(user1);
        uint256 amountIn2 = deflation.buyToken(address(token1), amountOut);
        
        assertTrue(amountIn2 < amountIn1);
    }

    function testBuyTokenUpdatesLastPurchaseTime() public {
        assertEq(deflation.lastPurchaseTime(address(token1)), 0);
        
        deflation.kickstartAuction(address(token1)); // <-- added
        
        vm.prank(user1);
        deflation.buyToken(address(token1), 1e18);
        
        assertEq(deflation.lastPurchaseTime(address(token1)), block.timestamp);
    }

    function testBuyTokenResetsDiscount() public {
        deflation.kickstartAuction(address(token1)); // <-- added
        
        vm.prank(user1);
        deflation.buyToken(address(token1), 1e18);
        
        vm.warp(block.timestamp + AUCTION_DURATION / 2);
        uint256 discountBefore = deflation.getCurrentDiscount(address(token1));
        assertTrue(discountBefore > 0);
        
        vm.prank(user1);
        deflation.buyToken(address(token1), 1e18);
        
        uint256 discountAfter = deflation.getCurrentDiscount(address(token1));
        assertEq(discountAfter, 0);
    }

    function testBuyTokenETH() public {
        vm.deal(address(deflation), 10 ether);
        oracle.setConversionRate(ETH_TOKEN, address(grg), 2000e18);
        deflation.kickstartAuction(ETH_TOKEN); // <-- added
        
        vm.startPrank(user1);
        uint256 ethBalanceBefore = user1.balance;
        
        uint256 amountOut = 1 ether;
        deflation.buyToken(ETH_TOKEN, amountOut);
        
        uint256 ethBalanceAfter = user1.balance;
        vm.stopPrank();
        
        assertEq(ethBalanceAfter - ethBalanceBefore, amountOut);
    }

    function testBuyTokenMultipleTokensIndependent() public {
        MockERC20 token2 = new MockERC20("Token2", "TK2");
        token2.mint(address(deflation), 100e18);
        oracle.setConversionRate(address(token2), address(grg), 3e18);
        
        deflation.kickstartAuction(address(token1)); // <-- added
        
        vm.prank(user1);
        deflation.buyToken(address(token1), 1e18);
        
        vm.warp(block.timestamp + AUCTION_DURATION / 2);
        
        uint256 discount1 = deflation.getCurrentDiscount(address(token1));
        uint256 discount2 = deflation.getCurrentDiscount(address(token2));
        
        assertTrue(discount1 > 0);
        assertEq(discount2, 0);
    }

    function testBuyTokenRevertsOnNullGrgAmount() public {
        oracle.setConversionRate(address(token1), address(grg), 1);
        deflation.kickstartAuction(address(token1)); // <-- added
        
        vm.prank(user1);
        vm.expectRevert(Deflation.GrgAmountIsNull.selector);
        deflation.buyToken(address(token1), 1);
    }

    function testFuzzBuyToken(uint256 amountOut) public {
        amountOut = bound(amountOut, 1e15, 10e18);
        deflation.kickstartAuction(address(token1)); // <-- added
        
        vm.startPrank(user1);
        
        uint256 grgBefore = grg.balanceOf(user1);
        uint256 tokenBefore = token1.balanceOf(user1);
        
        uint256 amountIn = deflation.buyToken(address(token1), amountOut);
        
        uint256 grgAfter = grg.balanceOf(user1);
        uint256 tokenAfter = token1.balanceOf(user1);
        vm.stopPrank();
        
        assertEq(grgBefore - grgAfter, amountIn);
        assertEq(tokenAfter - tokenBefore, amountOut);
    }

    function testFuzzGetCurrentDiscount(uint256 timeElapsed) public {
        timeElapsed = bound(timeElapsed, 0, AUCTION_DURATION * 2);
        
        deflation.kickstartAuction(address(token1)); // <-- added
        
        vm.warp(block.timestamp + timeElapsed);
        
        uint256 discount = deflation.getCurrentDiscount(address(token1));
        
        assertLe(discount, MAX_DISCOUNT);
        
        if (timeElapsed >= AUCTION_DURATION) {
            assertEq(discount, MAX_DISCOUNT);
        } else {
            uint256 expectedDiscount = (timeElapsed * MAX_DISCOUNT) / AUCTION_DURATION;
            assertEq(discount, expectedDiscount);
        }
    }
}