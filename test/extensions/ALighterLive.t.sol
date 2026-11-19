// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {LighterTypes} from "../../contracts/protocol/types/LighterTypes.sol";
import {LighterConstants} from "../../contracts/protocol/types/LighterConstants.sol";
import {Applications} from "../../contracts/protocol/types/Applications.sol";
import {StorageLib} from "../../contracts/protocol/libraries/StorageLib.sol";
import {ExternalApp} from "../../contracts/protocol/types/ExternalApp.sol";
import {IEApps} from "../../contracts/protocol/extensions/adapters/interfaces/IEApps.sol";

/// @title ALighterLiveTest
/// @notice Live-RPC tests against the LighterEVM devnet: real READ_CORE precompile responses,
///  no mocks and no fork.
/// @dev READ_CORE (0x6600...0000) is a native precompile with no on-chain code, so Foundry forks
///  cannot execute it; these tests call the live devnet RPC through vm.rpc instead. The devnet
///  RPC may only support "latest", so no block tag is ever passed.
/// @dev Requires LIGHTER_DEVNET_RPC_URL; a missing URL fails at the first vm.rpc call, and a URL
///  pointing at the wrong chain fails the setUp chainid guard — the suite never runs against
///  an unintended LighterEVM deployment (e.g. a mainnet endpoint swapped into the CI secret
///  without updating the devnet chainid pinned here).
/// @dev testLive_NavExactness compares against "latest" state; see its @dev for the
///  bracketed-price retry policy and the observed-skew fallback bound.
contract ALighterLiveTest is Test {
    /// @notice A live funded Rigoblock pool on LighterEVM devnet (chain 19529) with a Core
    ///  account and an open perp position. Re-created after the devnet 1.1.0 reset (create tx
    ///  0xf336c9335af1236291b319120c1470e664b39b5e1adb9dbd5075ab45033ddf4a); the NAV exactness
    ///  test skips while the pool controls no Core account (i.e. until it is funded with USDC).
    address internal constant TESTER_POOL = 0x0CD1eb6ACc12F24aD190a2708a7FEe3f23389adc;

    function setUp() public {
        // Chain guard: this suite is written against the LighterEVM devnet (chain 19529). A
        //  misconfigured secret pointing at any other chain (e.g. a future mainnet endpoint)
        //  must fail here, not run the assertions against the wrong deployment. vm.rpc returns
        //  the minimal-byte quantity (0x4c49), not an ABI-encoded uint256.
        bytes memory res = vm.rpc("lighter", "eth_chainId", "[]");
        uint256 chainId = uint256(bytes32(res)) >> (8 * (32 - res.length));
        require(chainId == LighterConstants.LIGHTEREVM_CHAIN_ID, "LIGHTER_DEVNET_RPC_URL is not the LighterEVM devnet");
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

        // 0x0005 market info: market 0 is a perp with a positive mark price, quoteMultiplier in
        //  the documented [1, 10000] perp range and an hourly funding round timestamp.
        LighterTypes.MarketInfo memory market = _readMarketInfo(0);
        assertEq(market.marketType, 0);
        assertGt(market.markPrice, 0);
        assertGe(market.quoteMultiplier, 1);
        assertLe(market.quoteMultiplier, 10_000);
        assertGt(market.lastFundingRoundTimestamp, 0);

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
    /// @dev The formula mirrors LighterLib (devnet 1.2.0): collateral plus per-market unrealized
    ///  PnL (size * quoteMultiplier * markPrice minus the signed entry notional), pending funding
    ///  (size * quoteMultiplier * (lastFundingRatePrefixSum - fundingRatePrefixSum) / 1e6, rounded
    ///  toward negative infinity) and isolated margin added back at 1e6 — see LighterTypes for the
    ///  field scales. The in-flight term is replicated from the view data exactly as LighterLib
    ///  computes it (status read + acceptedAmount + balance baseline), so a settled-but-undelivered
    ///  transfer is compared like-for-like.
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
    ///  mark-price movement between the brackets and contribution_i = |size_i| * quoteMultiplier_i
    ///  is the per-raw-unit NAV sensitivity.
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
        // tracked markets and the in-flight record are internal accounting: read the Lighter
        ///  slot storage directly
        uint16[] memory marketIds = _readTrackedMarkets();
        (int256 inFlightAmount, uint64 lastReqId, uint64 settledAt) = _readLighterData();

        uint256 marketCount = marketIds.length;
        LighterTypes.Position[] memory positions = new LighterTypes.Position[](marketCount);
        LighterTypes.MarketInfo[] memory marketsBefore = new LighterTypes.MarketInfo[](marketCount);
        uint64[] memory markAfter = new uint64[](marketCount);

        int256 collateral = int256(_readAccountInfo(TESTER_POOL).collateralBaseAmount);
        int256 inFlight = _replicateInFlightAdjustment(inFlightAmount, lastReqId, settledAt);

        for (uint256 i; i < marketCount; ++i) {
            positions[i] = _readPosition(TESTER_POOL, marketIds[i]);
            marketsBefore[i] = _readMarketInfo(marketIds[i]);
        }

        // Issued immediately after the bracket above; the second bracket follows immediately.
        ExternalApp[] memory apps = abi.decode(
            _ethCall(
                TESTER_POOL,
                abi.encodeCall(IEApps.getAppTokenBalances, (1 << uint256(Applications.LIGHTER_PERPS)))
            ),
            (ExternalApp[])
        );

        for (uint256 i; i < marketCount; ++i) {
            markAfter[i] = _readMarketInfo(marketIds[i]).markPrice;
        }

        attempt.expectedBefore = collateral + inFlight;
        attempt.expectedAfter = collateral + inFlight;
        for (uint256 i; i < marketCount; ++i) {
            _accumulateMarket(attempt, positions[i], marketsBefore[i], markAfter[i]);
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

    /// @dev Accumulates one tracked market into an attempt: the expected valuation at both
    ///  bracket mark prices and the observed-skew fallback bound. Funding rounds are hourly, so
    ///  the prefix sum is constant across an attempt; it is read once with the first bracket and
    ///  applied to both expectations.
    function _accumulateMarket(
        NavAttempt memory attempt,
        LighterTypes.Position memory position,
        LighterTypes.MarketInfo memory marketInfo,
        uint64 markAfter
    ) internal pure {
        if (position.size == 0) return;
        attempt.nonzeroMarkets++;
        int256 quoteMultiplier = int256(uint256(marketInfo.quoteMultiplier));
        int256 entryValue = position.size > 0
            ? int256(uint256(position.entryQuote))
            : -int256(uint256(position.entryQuote));
        // Devnet 1.2.0: allocatedMargin is already Core USDC base units (1e6 per USDC).
        int256 isolated = position.marginMode == 1 ? int256(position.allocatedMargin) : int256(0);
        int256 pendingFunding = _pendingFunding(position, quoteMultiplier, marketInfo.fundingRatePrefixSum);
        attempt.expectedBefore +=
            (int256(position.size) * quoteMultiplier * int256(uint256(marketInfo.markPrice))) -
            entryValue +
            isolated +
            pendingFunding;
        attempt.expectedAfter +=
            (int256(position.size) * quoteMultiplier * int256(uint256(markAfter))) -
            entryValue +
            isolated +
            pendingFunding;

        uint256 absSize = position.size < 0 ? uint256(-int256(position.size)) : uint256(int256(position.size));
        uint256 deltaTicks = markAfter >= marketInfo.markPrice
            ? uint256(markAfter - marketInfo.markPrice)
            : uint256(marketInfo.markPrice - markAfter);
        // The pool's mark sits between the brackets up to 2 raw units of oscillation;
        // truncation toward zero adds at most 1 unit on top.
        attempt.skewBound += absSize * uint256(marketInfo.quoteMultiplier) * (deltaTicks + 2) + 1;
    }

    /// @dev Mirrors LighterLib._pendingFunding: rounds toward negative infinity like Core.
    function _pendingFunding(
        LighterTypes.Position memory position,
        int256 quoteMultiplier,
        int64 fundingRatePrefixSum
    ) internal pure returns (int256 pendingFunding) {
        int256 fundingDelta = int256(position.lastFundingRatePrefixSum) - int256(fundingRatePrefixSum);
        int256 numerator = int256(position.size) * quoteMultiplier * fundingDelta;
        pendingFunding = numerator / 1e6;
        if (numerator < 0 && numerator % 1e6 != 0) pendingFunding -= 1;
    }

    /// @dev Mirrors LighterLib._inFlightAdjustment against the view data: pending requests add the
    ///  in-flight amount back; a settled request contributes nothing once it self-resolves (full
    ///  acceptance, failure). A settled request with an outstanding leg is carried by the pool —
    ///  NAV exact by construction — and the pool's own evaluation reverts (NavLocked) until the
    ///  settle window elapses, so the attempt skips.
    function _replicateInFlightAdjustment(
        int256 amount,
        uint64 lastReqId,
        uint64 settledAt
    ) internal returns (int256 adjustment) {
        if (lastReqId == 0 || amount == 0) return 0;

        (uint8 status, bytes memory payload) = abi.decode(
            _readCore(abi.encodePacked(uint16(0x0000), lastReqId)),
            (uint8, bytes)
        );
        if (status == 0) return amount > 0 ? amount : int256(0);
        if (status == 1) {
            uint256 amount256 = uint256(amount);
            uint256 accepted = payload.length >= 32 ? abi.decode(payload, (uint64)) : 0;
            uint256 outstanding = accepted < amount256 ? amount256 - accepted : 0;
            if (outstanding == 0) return 0;
            if (settledAt != 0 && block.timestamp < settledAt + 1 hours) {
                console2.log("Skipping: settled deposit refund within the carry window");
                vm.skip(true);
            }
            return 0;
        }
        if (status == 2) return 0;
        if (settledAt != 0 && block.timestamp < settledAt + 1 hours) {
            console2.log("Skipping: settled withdrawal delivery within the carry window");
            vm.skip(true);
        }
        return 0;
    }

    /// @dev The pool's LighterData, decoded from raw storage (eth_getStorageAt). Solidity does
    ///  not split a value type across slots: slot 0 packs int128 inFlightAmount | uint64
    ///  lastReqId | uint64 settledAt, slot 1 holds the whole uint128 balanceSnapshot.
    function _readLighterData() internal returns (int256 inFlightAmount, uint64 lastReqId, uint64 settledAt) {
        bytes32 base = StorageLib.LIGHTER_DATA_SLOT;
        uint256 w0 = uint256(_storageAt(TESTER_POOL, base));
        inFlightAmount = int256(int128(uint128(w0)));
        lastReqId = uint64(w0 >> 128);
        settledAt = uint64(w0 >> 192);
    }

    /// @dev The pool's tracked-market list, decoded from raw storage: the array length sits at
    ///  slot 2 of the Lighter slot, elements pack 16 uint16 per slot from keccak256(slot 2).
    function _readTrackedMarkets() internal returns (uint16[] memory marketIds) {
        bytes32 base = StorageLib.LIGHTER_DATA_SLOT;
        uint256 count = uint256(_storageAt(TESTER_POOL, bytes32(uint256(base) + 2)));
        marketIds = new uint16[](count);
        bytes32 dataSlot = keccak256(abi.encode(bytes32(uint256(base) + 2)));
        for (uint256 i; i < count; ++i) {
            bytes32 word = _storageAt(TESTER_POOL, bytes32(uint256(dataSlot) + i / 16));
            marketIds[i] = uint16(uint256(word) >> ((i % 16) * 16));
        }
    }

    /// @dev eth_getStorageAt via the live RPC.
    function _storageAt(address account, bytes32 slot) internal returns (bytes32 value) {
        string memory params = string.concat('["', vm.toString(account), '","', vm.toString(slot), '","latest"]');
        value = abi.decode(vm.rpc("lighter", "eth_getStorageAt", params), (bytes32));
    }

    function _within(int256 a, int256 b, uint256 tolerance) internal pure returns (bool) {
        return _absDiff(a, b) <= tolerance;
    }

    function _absDiff(int256 a, int256 b) internal pure returns (uint256) {
        return a >= b ? uint256(a - b) : uint256(b - a);
    }
}
