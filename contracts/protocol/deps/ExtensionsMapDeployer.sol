// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity 0.8.28;

import {ExtensionsMap} from "./ExtensionsMap.sol";
import {IExtensionsMapDeployer} from "../interfaces/IExtensionsMapDeployer.sol";
import {DeploymentParams, Extensions} from "../types/DeploymentParams.sol";

contract ExtensionsMapDeployer is IExtensionsMapDeployer {
    address private transient _eApps;
    address private transient _eNavView;
    address private transient _eOracle;
    address private transient _eUpgrade;
    address private transient _eAcrossHandler;
    address private transient _wrappedNative;

    /// @inheritdoc IExtensionsMapDeployer
    mapping(address deployer => mapping(bytes32 salt => address mapAddress)) public deployedMaps;

    /// @inheritdoc IExtensionsMapDeployer
    function deployExtensionsMap(DeploymentParams memory params, bytes32 salt) external override returns (address) {
        _eApps = params.extensions.eApps;
        _eNavView = params.extensions.eNavView;
        _eOracle = params.extensions.eOracle;
        _eUpgrade = params.extensions.eUpgrade;
        _eAcrossHandler = params.extensions.eAcrossHandler;
        _wrappedNative = params.wrappedNative;

        // Pre-compute the CREATE2 address
        salt = keccak256(abi.encode(msg.sender, salt));
        address map = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(type(ExtensionsMap).creationCode))
                    )
                )
            )
        );

        // Deploy only if no code exists
        if (map.code.length == 0) {
            address newMap = address(new ExtensionsMap{salt: salt}());
            assert(newMap == map);
            deployedMaps[msg.sender][salt] = map;
        }

        return map;
    }

    /// @inheritdoc IExtensionsMapDeployer
    function parameters() external view override returns (DeploymentParams memory) {
        return
            DeploymentParams({
                extensions: Extensions({
                    eApps: _eApps, 
                    eNavView: _eNavView,
                    eOracle: _eOracle, 
                    eUpgrade: _eUpgrade,
                    eAcrossHandler: _eAcrossHandler
                }),
                wrappedNative: _wrappedNative
            });
    }
}
