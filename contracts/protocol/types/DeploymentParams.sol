// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

struct Extensions {
    address eApps;
    address eOracle;
    address eUpgrade;
    address eAcrossHandler;
}

struct DeploymentParams {
    Extensions extensions;
    address wrappedNative;
}
