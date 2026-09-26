// SPDX-License-Identifier: Apache-2.0-or-later
// solhint-disable-next-line
pragma solidity 0.8.37;

import {IAGovernance} from "./interfaces/IAGovernance.sol";
import {IMinimumVersion} from "./interfaces/IMinimumVersion.sol";
import {IRigoblockGovernance} from "../../../governance/IRigoblockGovernance.sol";

/// @title Governance adapter - Allows a pool to interact with Rigoblock governance.
/// @author Gabriele Rigo - <gab@rigoblock.com>
contract AGovernance is IAGovernance, IMinimumVersion {
    /// @notice Thrown when the adapter is called directly instead of via a pool's fallback.
    error DirectCallNotAllowed();

    string private constant _REQUIRED_VERSION = "4.0.0";

    /// @notice Address of this adapter, used to prevent direct calls.
    address private immutable _IMPLEMENTATION;

    /// @notice Address of the Rigoblock governance contract.
    address private immutable _governance;

    /// @param governance Address of the Rigoblock governance contract (chain-specific, immutable).
    constructor(address governance) {
        _IMPLEMENTATION = address(this);
        _governance = governance;
    }

    modifier onlyDelegateCall() {
        require(address(this) != _IMPLEMENTATION, DirectCallNotAllowed());
        _;
    }

    /// @inheritdoc IAGovernance
    function propose(
        IRigoblockGovernance.ProposedAction[] calldata actions,
        string calldata description
    ) external override onlyDelegateCall returns (uint256 proposalId) {
        return IRigoblockGovernance(_getGovernance()).propose(actions, description);
    }

    /// @inheritdoc IAGovernance
    function castVote(uint256 proposalId, IRigoblockGovernance.VoteType voteType) external override onlyDelegateCall {
        IRigoblockGovernance(_getGovernance()).castVote(proposalId, voteType);
    }

    /// @inheritdoc IAGovernance
    function execute(uint256 proposalId) external payable override onlyDelegateCall {
        IRigoblockGovernance(_getGovernance()).execute{value: msg.value}(proposalId);
    }

    /// @inheritdoc IMinimumVersion
    function requiredVersion() external pure override returns (string memory) {
        return _REQUIRED_VERSION;
    }

    function _getGovernance() private view returns (address) {
        return _governance;
    }
}
