// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity ^0.8.0;

/// @dev Typed parameters for EApps and ENavView constructors.
///  Both extensions share identical chain-specific address requirements.
struct EAppsParams {
    address grgStakingProxy;
    address univ4Posm;
}

struct Extensions {
    address eApps;
    address eOracle;
    address eUpgrade;
    address eCrosschain;
    address eNavView;
}

struct DeploymentParams {
    Extensions extensions;
    address wrappedNative;
}
