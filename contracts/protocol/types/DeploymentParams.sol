// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

/// @dev Typed parameters for the EApps extensions family constructors.
struct EAppsParams {
    address grgStakingProxy;
    address univ4Posm;
}

struct Extensions {
    address eApps;
    address eOracle;
    address eUpgrade;
    address eCrosschain;
    address eGmxCallback;
    address eErc20;
}

struct DeploymentParams {
    Extensions extensions;
    address wrappedNative;
}
