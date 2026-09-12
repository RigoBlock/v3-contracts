// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UnitTestFixture} from "../fixtures/UnitTestFixture.sol";
import {IRigoblockPoolProxyFactory} from "../../contracts/protocol/interfaces/IRigoblockPoolProxyFactory.sol";
import {ISmartPoolState} from "../../contracts/protocol/interfaces/v4/pool/ISmartPoolState.sol";
import {IEERC20} from "../../contracts/protocol/extensions/adapters/interfaces/IEERC20.sol";
import {EERC20} from "../../contracts/protocol/extensions/EERC20.sol";

/// @title EERC20Unit - Unit tests for the disabled ERC20 extension
/// @notice The pool serves transfer/transferFrom/approve/allowance via the EERC20 extension
/// @notice through the fallback → ExtensionsMap routing; shares are non-transferable.
contract EERC20UnitTest is Test, UnitTestFixture {
    address internal poolProxy;
    address internal holder;
    address internal spender;
    address internal recipient;

    function setUp() public {
        deployFixture();
        (poolProxy, ) = IRigoblockPoolProxyFactory(deployment.factory).createPool("erc20 pool", "E20", address(0));
        holder = makeAddr("holder");
        spender = makeAddr("spender");
        recipient = makeAddr("recipient");
        console2.log("Pool proxy created:", poolProxy);
    }

    function test_Transfer_Reverts() public {
        vm.expectRevert(EERC20.PoolTokenOperationNotAllowed.selector);
        IEERC20(poolProxy).transfer(recipient, 1 ether);
    }

    function test_TransferFrom_Reverts() public {
        vm.expectRevert(EERC20.PoolTokenOperationNotAllowed.selector);
        IEERC20(poolProxy).transferFrom(holder, recipient, 1 ether);
    }

    function test_Approve_Reverts() public {
        vm.expectRevert(EERC20.PoolTokenOperationNotAllowed.selector);
        IEERC20(poolProxy).approve(spender, 1 ether);
    }

    function test_Allowance_ReturnsZero() public view {
        assertEq(IEERC20(poolProxy).allowance(holder, spender), 0);
    }

    /// @dev balanceOf and decimals remain implemented by the pool itself.
    function test_BalanceOfAndDecimals_StillOnImplementation() public view {
        assertEq(ISmartPoolState(poolProxy).balanceOf(holder), 0);
        assertEq(ISmartPoolState(poolProxy).decimals(), 18);
    }
}
