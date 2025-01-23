// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

struct AppTokenBalance {
    address token;
    int256 amount;
}

struct ExternalApp {
    AppTokenBalance[] balances;
    uint256 appType;    // stored as a uint256 to facilityte supporting new apps
}