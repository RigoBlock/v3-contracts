// SPDX-License-Identifier: Apache 2.0

pragma solidity >=0.8.0 <0.9.0;

// TODO: add natspec docs
interface IEUpgrade {
    event Upgraded(address indexed implementation);

    function upgradeImplementation() external;
}