// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {ExtensionsMap} from "./ExtensionsMap.sol";
import {IExtensionsMapDeployer} from "../interfaces/IExtensionsMapDeployer.sol";
import {DeploymentParams, Extensions} from "../types/DeploymentParams.sol";

contract ExtensionsMapDeployer is IExtensionsMapDeployer {
    uint24 public override version;
    bytes4 private _paramsHash;

    address private transient _eApps;
    address private transient _eOracle;
    address private transient _eUpgrade;
    address private transient _wrappedNative;

    /// @inheritdoc IExtensionsMapDeployer
    function deployExtensionsMap(DeploymentParams memory params) external override returns (address) {
        _eApps = params.extensions.eApps;
        _eOracle = params.extensions.eOracle;
        _eUpgrade = params.extensions.eUpgrade;
        _wrappedNative = params.wrappedNative;

        bytes4 newParamsHash = bytes4(keccak256(abi.encode(params)));

        // increase version counter if we are passing different params from last deployed. Will redeploy in case of a rollback, which is ok.
        if (newParamsHash != _paramsHash) {
            unchecked { ++version; }
            _paramsHash = newParamsHash;
        }

        // Pre-compute the CREATE2 address
        bytes32 salt = keccak256(abi.encode(msg.sender, version));
        address map = address(
            uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(type(ExtensionsMap).creationCode)
            ))))
        );

        // Deploy only if no code exists
        if (map.code.length == 0) {
            return address(new ExtensionsMap{salt: salt}());
        } else {
            return map;
        }
    }

    /// @inheritdoc IExtensionsMapDeployer
    function parameters() external view override returns (DeploymentParams memory) {
        return DeploymentParams({
            extensions: Extensions({
                eApps: _eApps,
                eOracle: _eOracle,
                eUpgrade: _eUpgrade
            }),
            wrappedNative: _wrappedNative
        });
    }
}