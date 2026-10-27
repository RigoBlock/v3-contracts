// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {LighterTypes} from "../../contracts/protocol/extensions/adapters/interfaces/lighter/LighterTypes.sol";
import {LighterConstants} from "../../contracts/protocol/types/LighterConstants.sol";
import {Applications, LighterViewData} from "../../contracts/protocol/types/Applications.sol";
import {ExternalApp} from "../../contracts/protocol/types/ExternalApp.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";

/// @title ALighterLiveTest
/// @notice Live-RPC tests against the LighterEVM devnet: real READ_CORE precompile responses,
///  no mocks and no fork.
/// @dev READ_CORE (0x6600...0000) is a native precompile with no on-chain code, so Foundry forks
///  cannot execute it; these tests call the live devnet RPC through vm.rpc instead. The devnet
///  RPC may only support "latest", so no block tag is ever passed.
/// @dev Requires LIGHTER_RPC_URL; a missing URL fails at the first vm.rpc call, and a URL
///  pointing at the wrong chain fails the setUp chainid guard — the suite never runs against
///  an unintended LighterEVM deployment (e.g. a mainnet endpoint swapped into the CI secret
///  without updating the devnet chainid pinned here).
/// @dev testLive_NavExactness compares against "latest" state and is skipped inside the
///  16-second settlement window after a Core write; see its @dev for the bracketed-price
///  retry policy and the observed-skew fallback bound.
contract ALighterLiveTest is Test {
    /// @notice A live funded Rigoblock pool on LighterEVM devnet (chain 19529) with a Core
    ///  account and an open perp position. Re-created after the devnet 1.1.0 reset (create tx
    ///  0xf336c9335af1236291b319120c1470e664b39b5e1adb9dbd5075ab45033ddf4a); the NAV exactness
    ///  test skips while the pool controls no Core account (i.e. until it is funded with USDC).
    address internal constant TESTER_POOL = 0x0CD1eb6ACc12F24aD190a2708a7FEe3f23389adc;

    /// @notice The post-action settlement window, mirroring LighterLib._SETTLEMENT_WINDOW.
    uint256 internal constant _SETTLEMENT_WINDOW = 16 seconds;

    function setUp() public {
        // Chain guard: this suite is written against the LighterEVM devnet (chain 19529). A
        //  misconfigured secret pointing at any other chain (e.g. a future mainnet endpoint)
        //  must fail here, not run the assertions against the wrong deployment. vm.rpc returns
        //  the minimal-byte quantity (0x4c49), not an ABI-encoded uint256.
        bytes memory res = vm.rpc("lighter", "eth_chainId", "[]");
        uint256 chainId = uint256(bytes32(res)) >> (8 * (32 - res.length));
        require(chainId == LighterConstants.LIGHTEREVM_CHAIN_ID, "LIGHTER_RPC_URL is not the LighterEVM devnet");
    }

    /*//////////////////////////////////////////////////////////////
                        LIVE RPC HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice eth_call against the live devnet RPC (always "latest"); hex results come back
    ///  hex-decoded from vm.rpc.
    function _ethCall(address to, bytes memory data) internal returns (bytes memory result) {
        string memory params = string.concat('[{"to":"', vm.toString(to), '","data":"', vm.toString(data), '"}]');
        result = vm.rpc("lighter", "eth_call", params);
    }

    function _readCore(bytes memory payload) internal returns (bytes memory) {
        return _ethCall(LighterConstants.READ_CORE, payload);
    }

    /// @notice Unwraps the documented abi.encode(bool found, bytes data) envelope every read
    ///  except tx status returns; reverts when Core reports the account/asset/market absent.
    function _readCoreData(bytes memory payload) internal returns (bytes memory data) {
        bool found;
        (found, data) = abi.decode(_readCore(payload), (bool, bytes));
        require(found, "READ_CORE reported not-found");
    }

    function _readAccountInfo(address account) internal returns (LighterTypes.AccountInfo memory) {
        return abi.decode(_readCoreData(abi.encodePacked(uint16(0x0001), account, false)), (LighterTypes.AccountInfo));
    }

    function _readPosition(address account, uint16 marketId) internal returns (LighterTypes.Position memory) {
        return
            abi.decode(
                _readCoreData(abi.encodePacked(uint16(0x0007), account, false, marketId)),
                (LighterTypes.Position)
            );
    }

    function _readMarketInfo(uint16 marketId) internal returns (LighterTypes.MarketInfo memory) {
        return abi.decode(_readCoreData(abi.encodePacked(uint16(0x0005), marketId)), (LighterTypes.MarketInfo));
    }

    /// @notice True when the tester pool controls an existing Core account (envelope found flag).
    function _poolHasCoreAccount() internal returns (bool) {
        bytes memory ret = _readCore(abi.encodePacked(uint16(0x0001), TESTER_POOL, false));
        (bool found, ) = abi.decode(ret, (bool, bytes));
        return found;
    }

    /// @notice Timestamp of the devnet's latest block. The object result of
    ///  eth_getBlockByNumber arrives ABI-encoded from vm.rpc with each hex-string field as a
    ///  dynamic bytes element; the timestamp is the only 4-byte value in the plausible epoch
    ///  range, stored left-aligned after its length word.
    function _latestTimestamp() internal returns (uint256 timestamp) {
        bytes memory res = vm.rpc("lighter", "eth_getBlockByNumber", '["latest",false]');
        for (uint256 i = 1; i < res.length / 32; ++i) {
            bytes32 word;
            bytes32 prev;
            for (uint256 j; j < 32; ++j) {
                word |= bytes32(uint256(uint8(res[i * 32 + j]))) << (8 * (31 - j));
                prev |= bytes32(uint256(uint8(res[i * 32 + j - 32]))) << (8 * (31 - j));
            }
            if (prev == bytes32(uint256(4))) {
                uint256 candidate = uint256(word) >> 224;
                if (candidate > 1_600_000_000 && candidate < 2_100_000_000) return candidate;
            }
        }
        revert("timestamp not found");
    }

    /*//////////////////////////////////////////////////////////////
                                  TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Locks the documented READ_CORE response formats against the live precompile:
    ///  every read is decoded through the (bool found, bytes data) envelope with the exact
    ///  Solidity tuple type the protocol relies on. Pool-dependent checks are skipped while the
    ///  tester pool controls no Core account (e.g. right after a devnet reset, before funding).
    function testLive_ReadCoreFormats() public {
        // 0x0002 asset decimals: USDC (asset index 3) has 6 decimals.
        uint8 decimals = abi.decode(_readCoreData(abi.encodePacked(uint16(0x0002), uint32(3))), (uint8));
        assertEq(decimals, 6);

        // 0x0004 asset address: asset index 3 resolves to the USDC token.
        address asset = abi.decode(_readCoreData(abi.encodePacked(uint16(0x0004), uint32(3))), (address));
        assertEq(asset, LighterConstants.USDC);

        // 0x0005 market info: market 0 is a perp with a positive mark price.
        LighterTypes.MarketInfo memory market = _readMarketInfo(0);
        assertEq(market.marketType, 0);
        assertGt(market.markPrice, 0);

        // 0x0000 tx status: an unknown reqId reads as pending (status 0); the read never fails.
        (uint8 status, ) = abi.decode(_readCore(abi.encodePacked(uint16(0x0000), uint64(999_999_999))), (uint8, bytes));
        assertEq(status, 0);

        if (!_poolHasCoreAccount()) {
            console2.log("Tester pool has no Core account yet; skipping pool-dependent format checks");
            return;
        }

        // 0x0001 account info: the tester pool controls an existing Core account.
        LighterTypes.AccountInfo memory account = _readAccountInfo(TESTER_POOL);
        assertEq(account.evmAddress, TESTER_POOL);
        assertGe(account.collateralBaseAmount, 0);

        // 0x0009 EVM account index: nonzero and consistent with the account-info master index.
        uint48 accountIndex = abi.decode(_readCoreData(abi.encodePacked(uint16(0x0009), TESTER_POOL)), (uint48));
        assertGt(uint256(accountIndex), 0);
        assertEq(uint256(accountIndex), uint256(account.masterAccountIndex));

        // 0x0007 position on market 0: an open position carries a nonzero entry notional.
        LighterTypes.Position memory position = _readPosition(TESTER_POOL, 0);
        if (position.size != 0) {
            assertGt(position.entryQuote, 0);
        }
    }

    /// @notice Independently recomputes the tester pool's Lighter NAV from live precompile reads
    ///  and asserts it equals the pool's on-chain getAppTokenBalances valuation.
    /// @dev The formula mirrors LighterLib: collateral plus per-market PnL (mark value minus the
    ///  signed entry notional, isolated margin added back at 1e6) — see LighterTypes for the
    ///  field scales. Outside the settlement window the in-flight term is zero on both sides,
    ///  so it is omitted here.
    /// @dev Race: each eth_call resolves "latest" independently, the devnet produces blocks
    ///  fast enough that almost every attempt straddles a Core snapshot boundary, and the devnet
    ///  RPC rejects pinned-block eth_call ("live Core only serves blocks on the chain tip"), so
    ///  pinning is not possible. An attempt therefore brackets the pool's getAppTokenBalances
    ///  read with two mark-price reads (one set before, one after) and the test passes as soon
    ///  as the pool's valuation matches the recomputation at one of the two observed price
    ///  sets, within 1 unit per tracked market for truncation.
    /// @dev Retry policy: up to 8 attempts, each re-reading everything fresh. A passing attempt
    ///  proves NAV agreement between this independent recomputation and the pool's on-chain
    ///  path at an observed Core snapshot — the primary assertion.
    /// @dev Fallback: if no attempt matches either bracket, the test asserts the diff against
    ///  the closer bracket is at most the observed skew bound: the pool's mark price lies
    ///  between the attempt's two bracket reads (up to 2 raw price units of bracket
    ///  oscillation), so per tracked market with nonzero size the diff is bounded by
    ///  (deltaTicks_i + 2) * contribution_i + 1, where deltaTicks_i is the observed raw
    ///  mark-price movement between the brackets and contribution_i = |size_i| * 1e6 /
    ///  10^scale_i is the per-raw-unit NAV sensitivity.
    function testLive_NavExactness() public {
        if (!_poolHasCoreAccount()) {
            console2.log("Skipping: tester pool has no Core account (fund it with a deposit first)");
            vm.skip(true);
        }

        NavAttempt memory attempt;
        for (uint256 round = 1; round <= 8; ++round) {
            attempt = _attemptNavComparison();
            uint256 tolerance = attempt.nonzeroMarkets;
            if (
                _within(attempt.actual, attempt.expectedBefore, tolerance) ||
                _within(attempt.actual, attempt.expectedAfter, tolerance)
            ) {
                console2.log("NAV confirmed against a bracketed price set on attempt", round);
                return;
            }
            console2.log("Attempt", round, "matched neither bracket; retrying");
            console2.logInt(attempt.expectedBefore);
            console2.logInt(attempt.actual);
            console2.logInt(attempt.expectedAfter);
        }
        uint256 diffBefore = _absDiff(attempt.actual, attempt.expectedBefore);
        uint256 diffAfter = _absDiff(attempt.actual, attempt.expectedAfter);
        uint256 diff = diffBefore < diffAfter ? diffBefore : diffAfter;
        console2.log("No attempt matched a bracket; asserting the observed-skew bound");
        console2.log("diff:", diff);
        console2.log("skewBound:", attempt.skewBound);
        assertLe(
            diff,
            attempt.skewBound,
            string.concat(
                "NAV mismatch exceeds the observed bracket skew: diff=",
                vm.toString(diff),
                ", skewBound=",
                vm.toString(attempt.skewBound)
            )
        );
    }

    /// @notice Result of one testLive_NavExactness attempt: the independent recomputation at
    ///  the bracket mark prices read before and after the pool's valuation, the pool's
    ///  valuation itself, the observed-skew fallback bound, and the number of tracked markets
    ///  carrying a nonzero position (the truncation tolerance).
    struct NavAttempt {
        int256 expectedBefore;
        int256 expectedAfter;
        int256 actual;
        uint256 skewBound;
        uint256 nonzeroMarkets;
    }

    /// @notice One attempt of testLive_NavExactness: positions and the first mark-price bracket
    ///  are read as late as possible, the pool's own getAppTokenBalances read is issued
    ///  immediately after, and the second mark-price bracket is read immediately after that.
    ///  Positions and collateral are static during the test (only the pool owner can write to
    ///  Core), so the only value that can change between brackets is the mark price.
    function _attemptNavComparison() internal returns (NavAttempt memory attempt) {
        LighterViewData memory viewData = abi.decode(
            _ethCall(TESTER_POOL, abi.encodeCall(IEApps.getLighterTrackedMarkets, ())),
            (LighterViewData)
        );

        if (_latestTimestamp() < uint256(viewData.lastActionTimestamp) + _SETTLEMENT_WINDOW) {
            console2.log("Skipping: pool is inside the settlement window of a recent Core write");
            vm.skip(true);
        }

        uint256 marketCount = viewData.marketIds.length;
        LighterTypes.Position[] memory positions = new LighterTypes.Position[](marketCount);
        uint64[] memory markBefore = new uint64[](marketCount);
        uint256[] memory contribution = new uint256[](marketCount);
        uint8[] memory scale = new uint8[](marketCount);

        int256 collateral = int256(_readAccountInfo(TESTER_POOL).collateralBaseAmount);

        for (uint256 i; i < marketCount; ++i) {
            positions[i] = _readPosition(TESTER_POOL, viewData.marketIds[i]);
            markBefore[i] = _readMarketInfo(viewData.marketIds[i]).markPrice;
            scale[i] = viewData.sizeDecimals[i] + viewData.priceDecimals[i];
            uint256 absSize = positions[i].size < 0
                ? uint256(-int256(positions[i].size))
                : uint256(int256(positions[i].size));
            contribution[i] = (absSize * 1e6) / (10 ** scale[i]);
        }

        // Issued immediately after the bracket above; the second bracket follows immediately.
        ExternalApp[] memory apps = abi.decode(
            _ethCall(
                TESTER_POOL,
                abi.encodeCall(IEApps.getAppTokenBalances, (1 << uint256(Applications.LIGHTER_PERPS)))
            ),
            (ExternalApp[])
        );

        uint64[] memory markAfter = new uint64[](marketCount);
        for (uint256 i; i < marketCount; ++i) {
            markAfter[i] = _readMarketInfo(viewData.marketIds[i]).markPrice;
        }

        attempt.expectedBefore = collateral;
        attempt.expectedAfter = collateral;
        for (uint256 i; i < marketCount; ++i) {
            LighterTypes.Position memory position = positions[i];
            if (position.size == 0) continue;
            attempt.nonzeroMarkets++;
            int256 entryValue = position.size > 0
                ? int256(uint256(position.entryQuote))
                : -int256(uint256(position.entryQuote));
            // Devnet 1.1.0: allocatedMargin is already Core USDC base units (1e6 per USDC).
            int256 isolated = position.marginMode == 1 ? int256(position.allocatedMargin) : int256(0);
            attempt.expectedBefore +=
                ((int256(position.size) * int256(uint256(markBefore[i])) * 1e6) / int256(10 ** scale[i])) -
                entryValue +
                isolated;
            attempt.expectedAfter +=
                ((int256(position.size) * int256(uint256(markAfter[i])) * 1e6) / int256(10 ** scale[i])) -
                entryValue +
                isolated;

            uint256 deltaTicks = markAfter[i] >= markBefore[i]
                ? uint256(markAfter[i] - markBefore[i])
                : uint256(markBefore[i] - markAfter[i]);
            // The pool's mark sits between the brackets up to 2 raw units of oscillation;
            // truncation toward zero adds at most 1 unit on top.
            attempt.skewBound += contribution[i] * (deltaTicks + 2) + 1;
        }

        bool found;
        for (uint256 i; i < apps.length; ++i) {
            if (apps[i].appType == uint256(Applications.LIGHTER_PERPS)) {
                found = true;
                assertEq(apps[i].balances.length, 1, "Lighter app should report one balance");
                assertEq(apps[i].balances[0].token, LighterConstants.USDC);
                attempt.actual = apps[i].balances[0].amount;
            }
        }
        assertTrue(found, "Lighter application should be returned");
    }

    function _within(int256 a, int256 b, uint256 tolerance) internal pure returns (bool) {
        return _absDiff(a, b) <= tolerance;
    }

    function _absDiff(int256 a, int256 b) internal pure returns (uint256) {
        return a >= b ? uint256(a - b) : uint256(b - a);
    }
}
