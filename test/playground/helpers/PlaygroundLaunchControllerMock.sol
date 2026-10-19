// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Mutable launch policy for tests that exercise an isolated Playground.
contract PlaygroundLaunchControllerMock {
    bool public launchesEnabled = true;

    function setLaunchesEnabled(bool enabled) external {
        launchesEnabled = enabled;
    }
}
