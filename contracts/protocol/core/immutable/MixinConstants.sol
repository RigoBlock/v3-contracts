// SPDX-License-Identifier: Apache 2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

import {ISmartPool} from "../../ISmartPool.sol";
import {ISmartPoolImmutable} from "../../interfaces/v4/pool/ISmartPoolImmutable.sol";

/// @notice Constants are copied in the bytecode and not assigned a storage slot, can safely be added to this contract.
/// @dev Inheriting from interface is required as we override public variables.
abstract contract MixinConstants is ISmartPool {
    /// @inheritdoc ISmartPoolImmutable
    string public constant override VERSION = "4.1.0";

    bytes32 internal constant _APPLICATIONS_SLOT = 0xdc487a67cca3fd0341a90d1b8834103014d2a61e6a212e57883f8680b8f9c831;

    bytes32 internal constant _POOL_INIT_SLOT = 0xe48b9bb119adfc3bccddcc581484cc6725fe8d292ebfcec7d67b1f93138d8bd8;

    bytes32 internal constant _POOL_VARIABLES_SLOT = 0xe3ed9e7d534645c345f2d15f0c405f8de0227b60eb37bbeb25b26db462415dec;

    bytes32 internal constant _POOL_TOKENS_SLOT = 0xf46fb7ff9ff9a406787c810524417c818e45ab2f1997f38c2555c845d23bb9f6;

    bytes32 internal constant _POOL_ACCOUNTS_SLOT = 0xfd7547127f88410746fb7969b9adb4f9e9d8d2436aa2d2277b1103542deb7b8e;

    bytes32 internal constant _TOKEN_REGISTRY_SLOT = 0x3dcde6752c7421366e48f002bbf8d6493462e0e43af349bebb99f0470a12300d;

    bytes32 internal constant _OPERATOR_BOOLEAN_SLOT =
        0xac0ed3ab25c1c02fcfdfba47b1953f88a6f24e5a50f1076d09054047884e5350;

    bytes32 internal constant _ACCEPTED_TOKENS_SLOT =
        0xa33198d1011bad6f8d9b4a537f82cf21cfac49b1430cf1a99c11aaf4d7325fc6;

    address internal constant _ZERO_ADDRESS = address(0);

    address internal constant _BASE_TOKEN_FLAG = address(1);

    uint16 internal constant _FEE_BASE = 10000;

    uint16 internal constant _MAX_SPREAD = 500; // +-5%, in basis points

    uint16 internal constant _DEFAULT_SPREAD = 10;

    uint16 internal constant _MAX_TRANSACTION_FEE = 100; // maximum 1%

    // minimum order size 1/1000th of base to avoid dust clogging things up
    uint16 internal constant _MINIMUM_ORDER_DIVISOR = 1e3;

    uint16 internal constant _SPREAD_BASE = 10000;

    uint48 internal constant _MAX_LOCKUP = 30 days;

    uint48 internal constant _MIN_LOCKUP = 1 days;
}
