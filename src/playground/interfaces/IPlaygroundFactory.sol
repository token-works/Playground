// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared launch policy read by every Playground created by a factory.
interface IPlaygroundFactory {
    function launchesEnabled() external view returns (bool);
}
