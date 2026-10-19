// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

/// @notice Routes Playground's 20% cut: 75% to Tokenworks and 25% to the fixed S02 holder splitter.
/// @dev Destinations never change. Tokenworks claims its accrued ETH so its recipient cannot block deposits.
contract TokenworksSplitter is ReentrancyGuard {
    address public immutable tokenworksRecipient;
    address public immutable holderSplitter;

    uint256 public totalReceived;
    uint256 public totalHolderPaid;
    uint256 public totalTokenworksClaimed;

    error InvalidAddress();
    error Unauthorized();
    error NothingToClaim();
    error NothingToDistribute();

    event Distributed(address indexed sender, uint256 amount, uint256 holderAmount, uint256 tokenworksAmount);
    event TokenworksClaimed(address indexed recipient, uint256 amount);

    constructor(address tokenworksRecipient_, address holderSplitter_) {
        if (
            tokenworksRecipient_ == address(0) || tokenworksRecipient_ == address(this)
                || holderSplitter_ == address(this) || holderSplitter_.code.length == 0
        ) revert InvalidAddress();
        tokenworksRecipient = tokenworksRecipient_;
        holderSplitter = holderSplitter_;
    }

    receive() external payable nonReentrant {
        _distribute(msg.value);
    }

    function pendingTokenworks() public view returns (uint256) {
        return totalReceived - totalHolderPaid - totalTokenworksClaimed;
    }

    /// @notice Anyone may trigger payment, always to the configured Tokenworks recipient.
    function claimTokenworks() external nonReentrant returns (uint256) {
        return _claim(tokenworksRecipient);
    }

    /// @notice The Tokenworks recipient may direct only its own accrued share to another address.
    function claimTokenworksTo(address recipient) external nonReentrant returns (uint256) {
        if (msg.sender != tokenworksRecipient) revert Unauthorized();
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        return _claim(recipient);
    }

    /// @notice Accounts for ETH received without executing receive(), including forced transfers.
    function distributeSurplus() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance - pendingTokenworks();
        if (amount == 0) revert NothingToDistribute();
        _distribute(amount);
    }

    function _distribute(uint256 amount) private {
        if (amount == 0) return;
        totalReceived += amount;
        // Cumulative rounding gives holders exactly floor(total received / 4), even for one-wei deposits.
        uint256 holderAmount = totalReceived / 4 - totalHolderPaid;
        totalHolderPaid += holderAmount;
        emit Distributed(msg.sender, amount, holderAmount, amount - holderAmount);
        // A normal call is required: the holder splitter must account for its received ETH.
        if (holderAmount != 0) SafeTransferLib.safeTransferETH(holderSplitter, holderAmount);
    }

    function _claim(address recipient) private returns (uint256 amount) {
        amount = pendingTokenworks();
        if (amount == 0) revert NothingToClaim();
        totalTokenworksClaimed += amount;
        SafeTransferLib.safeTransferETH(recipient, amount);
        emit TokenworksClaimed(recipient, amount);
    }
}
