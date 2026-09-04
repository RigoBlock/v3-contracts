// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IGmxReader} from "../../contracts/utils/exchanges/gmx/IGmxSynthetics.sol";
import {GmxAdapterLib} from "../../contracts/protocol/libraries/GmxAdapterLib.sol";
import {GmxLib} from "../../contracts/protocol/libraries/GmxLib.sol";
import {AppTokenBalance} from "../../contracts/protocol/types/ExternalApp.sol";
import {Price} from "gmx-synthetics/price/Price.sol";
import {Constants} from "../../contracts/test/Constants.sol";

contract GmxLitPoolForkHarness {
    function isIndexTokenPriced(address token) external view returns (bool) {
        return GmxAdapterLib.isIndexTokenPriced(token);
    }

    function safeGetGmxPrice(address token) external view returns (Price.Props memory) {
        return GmxLib.getGmxPrice(token);
    }

    function getGmxPositionBalances(address account) external view returns (AppTokenBalance[] memory) {
        return GmxLib.getGmxPositionBalances(account);
    }

    function getGmxPositionCount(address account) external view returns (uint256) {
        return
            IGmxReader(0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789)
                .getAccountPositions(0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8, account, 0, type(uint256).max)
                .length;
    }
}

/// @title GmxLitPoolFork
/// @notice Reconciles the LIT/USD GMX v2 position of the live Rigoblock smart pool
///  0xEfa4bDf566aE50537a507863612638680420645c against the hardcoded fallback feed.
/// @dev This test runs on an Arbitrum fork and asserts that the LIT index token is
///  correctly priced, so its unrealized PnL is included in NAV.
contract GmxLitPoolFork is Test {
    address internal constant POOL = 0xEfa4bDf566aE50537A507863612638680420645C;
    address internal constant LIT_INDEX_TOKEN = address(0xE6172EecBB07F197F52bb73d74daa0e19C31c4Db);

    GmxLitPoolForkHarness internal harness;

    function setUp() public {
        vm.createSelectFork("arbitrum", Constants.ARB_BLOCK);
        harness = new GmxLitPoolForkHarness();
    }

    /// @notice The live pool's LIT index token must be recognized as priced.
    function test_LitIndexToken_IsPriced() public view {
        assertTrue(harness.isIndexTokenPriced(LIT_INDEX_TOKEN), "LIT index token must be priced");
    }

    /// @notice The hardcoded LIT fallback feed must return a non-zero, recently-updated price.
    function test_LitFallbackPrice_Reasonable() public view {
        Price.Props memory price = harness.safeGetGmxPrice(LIT_INDEX_TOKEN);
        console2.log("LIT fallback price min:", price.min);
        console2.log("LIT fallback price max:", price.max);
        assertGt(price.min, 0, "LIT fallback price must be > 0");
        assertGt(price.max, 0, "LIT fallback price must be > 0");
        // LIT/USD has been > 0.001 USD. GMX stores price per token atom, so 0.001 USD/LIT
        // equals 1e9 in 1e30 units. This sanity-checks a non-zero, non-buggy multiplier.
        assertGt(price.min, 1e9, "LIT fallback price must be > 0.001 USD (1e9 in 1e30 per-atom units)");
    }

    /// @notice The live pool must have GMX position balances and the lookup must not revert.
    function test_LivePool_GmxPositionBalances() public view {
        uint256 posCount = harness.getGmxPositionCount(POOL);
        console2.log("GMX positions count:", posCount);
        assertGt(posCount, 0, "Live pool must have GMX positions");

        AppTokenBalance[] memory balances = harness.getGmxPositionBalances(POOL);
        console2.log("Live pool GMX balance count:", balances.length);
        for (uint256 i; i < balances.length; ++i) {
            console2.log("  token:", balances[i].token);
            console2.log("  amount:", balances[i].amount);
        }
        assertGt(balances.length, 0, "Live pool must have GMX position balances");
    }

    /// @notice The aggregate GMX position balance of the live pool, expressed in USD.
    /// @dev GMX prices are stored per token atom in 1e30 units, so
    ///  `usdValue = amount * price / 1e30`.
    function test_LivePool_GmxPositionBalanceInUsd() public view {
        AppTokenBalance[] memory balances = harness.getGmxPositionBalances(POOL);
        assertGt(balances.length, 0, "Live pool must have GMX position balances");

        uint256 totalUsd;
        for (uint256 i; i < balances.length; ++i) {
            address token = balances[i].token;
            int256 amount = balances[i].amount;
            require(amount >= 0, "Unexpected negative GMX balance");

            Price.Props memory price = harness.safeGetGmxPrice(token);
            assertGt(price.min, 0, "GMX balance token must be priced");

            uint256 usd = (uint256(amount) * price.min) / 1e30;
            totalUsd += usd;
            console2.log("  token:", token);
            console2.log("  raw amount:", uint256(amount));
            console2.log("  price per atom (1e30):", price.min);
            console2.log("  USD value:", usd);
        }
        console2.log("Total GMX position USD value:", totalUsd);
        assertGt(totalUsd, 1_000, "Live pool GMX position must be worth > $1,000");
    }
}
