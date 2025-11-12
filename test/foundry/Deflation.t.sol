// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../contracts/rigoToken/inflation/Deflation.sol";
import "../../contracts/tokens/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) {
        _name = name;
        _symbol = symbol;
        _decimals = 18;
    }

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
    
    address public user1;
    address public user2;
    
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
        user1 = address(0x1);
        user2 = address(0x2);
        
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
    }

    function testConstructor() public {
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

    function testGetCurrentDiscountInitial() public {
        uint256 discount = deflation.getCurrentDiscount(address(token1));
        assertEq(discount, 0);
    }

    function testGetCurrentDiscountAfterMaxDuration() public {
        // Make a purchase to set lastPurchaseTime
        vm.startPrank(user1);
        grg.approve(address(deflation), 10e18);
        deflation.buyToken(address(token1), 1e18);
        vm.stopPrank();
        
        // Fast forward past auction duration
        vm.warp(block.timestamp + AUCTION_DURATION + 1);
        
        uint256 discount = deflation.getCurrentDiscount(address(token1));
        assertEq(discount, MAX_DISCOUNT);
    }

    function testGetCurrentDiscountHalfway() public {
        // Make a purchase to set lastPurchaseTime
        vm.startPrank(user1);
        grg.approve(address(deflation), 10e18);
        deflation.buyToken(address(token1), 1e18);
        vm.stopPrank();
        
        // Fast forward halfway through auction
        vm.warp(block.timestamp + AUCTION_DURATION / 2);
        
        uint256 discount = deflation.getCurrentDiscount(address(token1));
        // Should be approximately half of max discount
        assertApproxEqAbs(discount, MAX_DISCOUNT / 2, 10);
    }

    function testBuyTokenRevertsOnZeroAmount() public {
        vm.prank(user1);
        vm.expectRevert("Amount must be greater than 0");
        deflation.buyToken(address(token1), 0);
    }

    function testBuyTokenRevertsOnZeroAddress() public {
        vm.prank(user1);
        vm.expectRevert("Invalid token address");
        deflation.buyToken(address(0), 1e18);
    }

    function testBuyTokenRevertsOnInvalidConversion() public {
        // Create a token without conversion rate
        MockERC20 token2 = new MockERC20("Token2", "TK2");
        token2.mint(address(deflation), 10e18);
        
        vm.prank(user1);
        vm.expectRevert(Deflation.InvalidConvertedAmount.selector);
        deflation.buyToken(address(token2), 1e18);
    }

    function testBuyTokenSuccess() public {
        uint256 amountOut = 5e18;
        
        vm.startPrank(user1);
        uint256 grgBalanceBefore = grg.balanceOf(user1);
        uint256 token1BalanceBefore = token1.balanceOf(user1);
        
        grg.approve(address(deflation), 100e18);
        uint256 amountIn = deflation.buyToken(address(token1), amountOut);
        
        uint256 grgBalanceAfter = grg.balanceOf(user1);
        uint256 token1BalanceAfter = token1.balanceOf(user1);
        vm.stopPrank();
        
        // User should have spent GRG
        assertEq(grgBalanceBefore - grgBalanceAfter, amountIn);
        // User should have received token1
        assertEq(token1BalanceAfter - token1BalanceBefore, amountOut);
    }

    function testBuyTokenEmitsEvent() public {
        uint256 amountOut = 1e18;
        uint256 discount = deflation.getCurrentDiscount(address(token1));
        
        vm.startPrank(user1);
        grg.approve(address(deflation), 100e18);
        
        vm.expectEmit(true, true, false, false);
        emit TokenPurchased(user1, address(token1), amountOut, 0, discount);
        deflation.buyToken(address(token1), amountOut);
        vm.stopPrank();
    }

    function testBuyTokenWithDiscount() public {
        uint256 amountOut = 1e18;
        
        vm.startPrank(user1);
        grg.approve(address(deflation), 100e18);
        
        // First purchase with no discount
        uint256 amountIn1 = deflation.buyToken(address(token1), amountOut);
        vm.stopPrank();
        
        // Fast forward to build discount
        vm.warp(block.timestamp + AUCTION_DURATION / 2);
        
        vm.startPrank(user1);
        // Second purchase should cost less
        uint256 amountIn2 = deflation.buyToken(address(token1), amountOut);
        vm.stopPrank();
        
        assertTrue(amountIn2 < amountIn1);
    }

    function testBuyTokenUpdatesLastPurchaseTime() public {
        assertEq(deflation.lastPurchaseTime(address(token1)), 0);
        
        vm.startPrank(user1);
        grg.approve(address(deflation), 10e18);
        deflation.buyToken(address(token1), 1e18);
        vm.stopPrank();
        
        assertEq(deflation.lastPurchaseTime(address(token1)), block.timestamp);
    }

    function testBuyTokenResetsDiscount() public {
        // First purchase
        vm.startPrank(user1);
        grg.approve(address(deflation), 100e18);
        deflation.buyToken(address(token1), 1e18);
        vm.stopPrank();
        
        // Build up discount
        vm.warp(block.timestamp + AUCTION_DURATION / 2);
        uint256 discountBefore = deflation.getCurrentDiscount(address(token1));
        assertTrue(discountBefore > 0);
        
        // Another purchase
        vm.startPrank(user1);
        deflation.buyToken(address(token1), 1e18);
        vm.stopPrank();
        
        // Discount should be reset
        uint256 discountAfter = deflation.getCurrentDiscount(address(token1));
        assertEq(discountAfter, 0);
    }

    function testBuyTokenETH() public {
        // Fund deflation with ETH
        vm.deal(address(deflation), 10 ether);
        
        // Set conversion rate for ETH
        oracle.setConversionRate(ETH_TOKEN, address(grg), 2000e18);
        
        vm.startPrank(user1);
        uint256 ethBalanceBefore = user1.balance;
        grg.approve(address(deflation), 10000e18);
        
        uint256 amountOut = 1 ether;
        deflation.buyToken(ETH_TOKEN, amountOut);
        
        uint256 ethBalanceAfter = user1.balance;
        vm.stopPrank();
        
        assertEq(ethBalanceAfter - ethBalanceBefore, amountOut);
    }

    function testBuyTokenMultipleTokensIndependent() public {
        // Set up second token
        MockERC20 token2 = new MockERC20("Token2", "TK2");
        token2.mint(address(deflation), 100e18);
        oracle.setConversionRate(address(token2), address(grg), 3e18);
        
        // Buy token1
        vm.startPrank(user1);
        grg.approve(address(deflation), 100e18);
        deflation.buyToken(address(token1), 1e18);
        vm.stopPrank();
        
        // Fast forward
        vm.warp(block.timestamp + AUCTION_DURATION / 2);
        
        // token1 should have discount, token2 should not
        uint256 discount1 = deflation.getCurrentDiscount(address(token1));
        uint256 discount2 = deflation.getCurrentDiscount(address(token2));
        
        assertTrue(discount1 > 0);
        assertEq(discount2, 0);
    }

    function testBuyTokenRevertsOnNullGrgAmount() public {
        // Set very low conversion rate
        oracle.setConversionRate(address(token1), address(grg), 1);
        
        vm.startPrank(user1);
        grg.approve(address(deflation), 100e18);
        
        vm.expectRevert(Deflation.GrgAmountIsNull.selector);
        deflation.buyToken(address(token1), 1);
        vm.stopPrank();
    }

    function testFuzzBuyToken(uint256 amountOut) public {
        // Bound the amount to reasonable values
        amountOut = bound(amountOut, 1e15, 10e18);
        
        vm.startPrank(user1);
        grg.approve(address(deflation), type(uint256).max);
        
        uint256 grgBefore = grg.balanceOf(user1);
        uint256 tokenBefore = token1.balanceOf(user1);
        
        uint256 amountIn = deflation.buyToken(address(token1), amountOut);
        
        uint256 grgAfter = grg.balanceOf(user1);
        uint256 tokenAfter = token1.balanceOf(user1);
        vm.stopPrank();
        
        // Verify balances changed correctly
        assertEq(grgBefore - grgAfter, amountIn);
        assertEq(tokenAfter - tokenBefore, amountOut);
    }

    function testFuzzGetCurrentDiscount(uint256 timeElapsed) public {
        // Bound time to reasonable range
        timeElapsed = bound(timeElapsed, 0, AUCTION_DURATION * 2);
        
        // Make a purchase
        vm.startPrank(user1);
        grg.approve(address(deflation), 10e18);
        deflation.buyToken(address(token1), 1e18);
        vm.stopPrank();
        
        // Fast forward
        vm.warp(block.timestamp + timeElapsed);
        
        uint256 discount = deflation.getCurrentDiscount(address(token1));
        
        // Discount should never exceed MAX_DISCOUNT
        assertLe(discount, MAX_DISCOUNT);
        
        // Discount should be proportional to time elapsed up to max
        if (timeElapsed >= AUCTION_DURATION) {
            assertEq(discount, MAX_DISCOUNT);
        } else {
            uint256 expectedDiscount = (timeElapsed * MAX_DISCOUNT) / AUCTION_DURATION;
            assertEq(discount, expectedDiscount);
        }
    }
}
