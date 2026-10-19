// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice An owner-selected adapter with its own fixed swap route.
interface IPlaygroundSwapAdapter {
    /// @dev Pull exactly amountIn from msg.sender and send native ETH back to msg.sender.
    /// The receiver independently checks input spent and actual ETH received.
    /// minETHOut is before the receiver deducts its caller reward.
    function swapToETH(address asset, uint256 amountIn, uint256 minETHOut) external returns (uint256 amountOut);
}
