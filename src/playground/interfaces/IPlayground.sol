// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared accounting and authority used by project revenue receivers.
interface IPlayground {
    function owner() external view returns (address);
    function intake() external view returns (address);
    function canSwap(address caller) external view returns (bool);
    function deposit(uint256 projectId) external payable;
}
