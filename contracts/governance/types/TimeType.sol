// SPDX-License-Identifier: Apache-2.0-or-later
pragma solidity >=0.8.0 <0.9.0;

/// @notice Time reference type for governance voting periods.
/// @dev Declared at file level so that factories and proxies can import it without
///      depending on the governance interfaces, keeping their init code (and CREATE2
///      addresses) stable when the interfaces evolve.
enum TimeType {
    Blocknumber,
    Timestamp
}
