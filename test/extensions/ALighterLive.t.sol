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
/// @dev Requires LIGHTER_RPC_URL; the whole contract is skipped while it is unset.
/// @dev testLive_NavExactness compares against "latest" state and is skipped inside the
///  16-second settlement window after a Core write; see its @dev for the one-tick race and the
///  retry policy.
contract ALighterLiveTest is Test {
    /// @notice A live funded Rigoblock pool on LighterEVM devnet (chain 19529) with a Core
    ///  account and an open perp position.
    address internal constant TESTER_POOL = 0x7Bcea99B22Caa039ff282519d404dF38fbaC6CB8;

    /// @notice The post-action settlement window, mirroring LighterLib._SETTLEMENT_WINDOW.
    uint256 internal constant _SETTLEMENT_WINDOW = 16 seconds;

    function setUp() public {
        if (bytes(vm.envOr("LIGHTER_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
        }
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

    function _readAccountInfo(address account) internal returns (LighterTypes.AccountInfo memory) {
        return abi.decode(_readCore(abi.encodePacked(uint16(0x0001), account, false)), (LighterTypes.AccountInfo));
    }

    function _readPosition(address account, uint16 marketId) internal returns (LighterTypes.Position memory) {
        return
            abi.decode(_readCore(abi.encodePacked(uint16(0x0007), account, false, marketId)), (LighterTypes.Position));
    }

    function _readMarketInfo(uint16 marketId) internal returns (LighterTypes.MarketInfo memory) {
        return abi.decode(_readCore(abi.encodePacked(uint16(0x0005), marketId)), (LighterTypes.MarketInfo));
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
    ///  every read is decoded with the exact Solidity tuple type the protocol relies on.
    function testLive_ReadCoreFormats() public {
        // 0x0002 asset decimals: USDC (asset index 3) has 6 decimals.
        uint8 decimals = abi.decode(_readCore(abi.encodePacked(uint16(0x0002), uint32(3))), (uint8));
        assertEq(decimals, 6);

        // 0x0004 asset address: asset index 3 resolves to the USDC token.
        address asset = abi.decode(_readCore(abi.encodePacked(uint16(0x0004), uint32(3))), (address));
        assertEq(asset, LighterConstants.USDC);

        // 0x0005 market info: market 0 is a perp with a positive mark price.
        LighterTypes.MarketInfo memory market = _readMarketInfo(0);
        assertEq(market.marketType, 0);
        assertGt(market.markPrice, 0);

        // 0x0001 account info: the tester pool controls an existing Core account.
        LighterTypes.AccountInfo memory account = _readAccountInfo(TESTER_POOL);
        assertEq(account.evmAddress, TESTER_POOL);
        assertGe(account.collateralBaseAmount, 0);

        // 0x0009 EVM account index: nonzero and consistent with the account-info master index.
        uint48 accountIndex = abi.decode(_readCore(abi.encodePacked(uint16(0x0009), TESTER_POOL)), (uint48));
        assertGt(uint256(accountIndex), 0);
        assertEq(uint256(accountIndex), uint256(account.masterAccountIndex));

        // 0x0007 position on market 0: an open position carries a nonzero entry notional.
        LighterTypes.Position memory position = _readPosition(TESTER_POOL, 0);
        if (position.size != 0) {
            assertGt(position.entryQuote, 0);
        }

        // 0x0000 tx status: an unknown reqId reads as pending (status 0); the read never fails.
        (uint8 status, ) = abi.decode(_readCore(abi.encodePacked(uint16(0x0000), uint64(999_999_999))), (uint8, bytes));
        assertEq(status, 0);
    }

    /// @notice Independently recomputes the tester pool's Lighter NAV from live precompile reads
    ///  and asserts it equals the pool's on-chain getAppTokenBalances valuation, with zero
    ///  tolerance.
    /// @dev The formula mirrors LighterLib: collateral plus per-market PnL (mark value minus the
    ///  signed entry notional, isolated margin added back at 1e6) — see LighterTypes for the
    ///  field scales. Outside the settlement window the in-flight term is zero on both sides,
    ///  so it is omitted here.
    /// @dev One-tick race: the pool's open ETH-PERP short (size 0.008, size_decimals 4) moves
    ///  80 units of 6-decimal USDC NAV per raw mark-price tick (80 * 1e6 / 10^(4+2)), the devnet
    ///  mark price updates every block, each eth_call resolves "latest" independently (the
    ///  devnet RPC supports no pinned-block calls), and an attempt issues many eth_calls — so an
    ///  attempt can straddle a block boundary and mix two Core snapshots. Retries are the only
    ///  remedy; up to 5 attempts each re-read everything fresh and the test passes on the first
    ///  exact match. A passing attempt proves bit-exact NAV agreement between this independent
    ///  recomputation and the pool's on-chain path at a single Core snapshot — the assertion
    ///  deliberately stays a zero-tolerance equality.
    function testLive_NavExactness() public {
        int256 expected;
        int256 actual;
        for (uint256 attempt = 1; attempt <= 5; ++attempt) {
            (expected, actual) = _attemptNavComparison();
            if (actual == expected) {
                console2.log("NAV exactness confirmed on attempt", attempt);
                return;
            }
            console2.log("Attempt", attempt, "observed two mark prices (one-tick race); retrying");
            console2.logInt(expected);
            console2.logInt(actual);
        }
        assertEq(actual, expected, "On-chain NAV must equal the recomputed value on a race-free attempt");
    }

    /// @notice One attempt of testLive_NavExactness, structured to minimize the race window: all
    ///  recompute inputs (collateral, positions, mark prices) are read as late as possible and
    ///  the pool's own getAppTokenBalances read is issued immediately after, with no other RPC
    ///  in between.
    function _attemptNavComparison() internal returns (int256 expected, int256 actual) {
        LighterViewData memory viewData = abi.decode(
            _ethCall(TESTER_POOL, abi.encodeCall(IEApps.getLighterTrackedMarkets, ())),
            (LighterViewData)
        );

        if (_latestTimestamp() < uint256(viewData.lastActionTimestamp) + _SETTLEMENT_WINDOW) {
            console2.log("Skipping: pool is inside the settlement window of a recent Core write");
            vm.skip(true);
        }

        expected = int256(_readAccountInfo(TESTER_POOL).collateralBaseAmount);

        for (uint256 i; i < viewData.marketIds.length; ++i) {
            uint16 marketId = viewData.marketIds[i];
            LighterTypes.Position memory position = _readPosition(TESTER_POOL, marketId);
            if (position.size == 0) continue;

            LighterTypes.MarketInfo memory market = _readMarketInfo(marketId);
            int256 entryValue = position.size > 0
                ? int256(uint256(position.entryQuote))
                : -int256(uint256(position.entryQuote));
            uint8 scale = viewData.sizeDecimals[i] + viewData.priceDecimals[i];
            int256 value = ((int256(position.size) * int256(uint256(market.markPrice)) * 1e6) / int256(10 ** scale)) -
                entryValue;
            if (position.marginMode == 1) {
                // allocatedMargin is 12-decimal USDC (see LighterTypes.Position).
                value += int256(position.allocatedMargin) / 1e6;
            }
            expected += value;
        }

        // Issued immediately after the reads above so all calls observe the same Core snapshot.
        ExternalApp[] memory apps = abi.decode(
            _ethCall(
                TESTER_POOL,
                abi.encodeCall(IEApps.getAppTokenBalances, (1 << uint256(Applications.LIGHTER_PERPS)))
            ),
            (ExternalApp[])
        );

        bool found;
        for (uint256 i; i < apps.length; ++i) {
            if (apps[i].appType == uint256(Applications.LIGHTER_PERPS)) {
                found = true;
                assertEq(apps[i].balances.length, 1, "Lighter app should report one balance");
                assertEq(apps[i].balances[0].token, LighterConstants.USDC);
                actual = apps[i].balances[0].amount;
            }
        }
        assertTrue(found, "Lighter application should be returned");
    }
}
