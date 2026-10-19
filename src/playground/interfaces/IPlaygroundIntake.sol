// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Stable IMD Intake request ABI: https://imd.fun/docs/#intake.
interface IPlaygroundIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        returns (bytes32 requestId);
}
