// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {IPlayground} from "./interfaces/IPlayground.sol";
import {IPlaygroundIntake} from "./interfaces/IPlaygroundIntake.sol";
import {IPlaygroundSwapAdapter} from "./interfaces/IPlaygroundSwapAdapter.sol";

/// @notice Stable Intake payer and permissionless revenue receiver for one Playground project.
/// @dev Each hub deploys one implementation and creates non-upgradeable clones initialized with
/// their own project ID. ERC20 revenue stays in each clone until converted to attributed ETH.
contract PlaygroundProject is ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 public constant CALLER_REWARD_BPS = 50;
    uint256 public constant BPS = 10_000;

    error Unauthorized();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidProjectId();
    error AlreadyInitialized();
    error InvalidMinimum();
    error SwapNotConfigured();
    error DeadlineExpired();
    error UnexpectedTokenSpent();
    error InsufficientETHReceived();

    event SwapConfigured(address indexed asset, address indexed adapter);
    event SwapCleared(address indexed asset);
    event Swapped(
        address indexed asset,
        address indexed adapter,
        address indexed caller,
        uint256 amountIn,
        uint256 ethReceived,
        uint256 callerReward
    );
    event ETHDeposited(uint256 amount);

    address public immutable playground;
    uint256 public projectId;
    mapping(address asset => address adapter) public swapAdapters;

    /// @notice Deploy a receiver implementation permanently bound to one hub.
    constructor(address playground_) {
        if (playground_ == address(0)) revert InvalidAddress();
        playground = playground_;
        // Lock the implementation. Each clone has independent, initially zero storage.
        projectId = type(uint256).max;
    }

    /// @notice The hub initializes a fresh clone in the same transaction that creates it.
    function initialize(uint256 projectId_) external {
        if (msg.sender != playground) revert Unauthorized();
        if (projectId != 0) revert AlreadyInitialized();
        if (projectId_ == 0) revert InvalidProjectId();
        projectId = projectId_;
    }

    modifier onlyPlaygroundOwner() {
        if (msg.sender != IPlayground(playground).owner()) revert Unauthorized();
        _;
    }

    /// @dev Receipt does no external calls; anyone may subsequently forward the balance.
    receive() external payable {}

    /// @notice Anyone may forward every held wei to this project's accounting, without a reward.
    function depositETH() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert InvalidAmount();
        _depositETH(amount);
    }

    /// @notice Submit a request as this project's stable payer, using freshly funded tokens.
    /// @dev Only the hub may call this after transferring exactly amount of paymentAsset here.
    /// The hub snapshots intake_ before the transfer and records it with the returned request ID.
    function request(address intake_, bytes32 action, bytes calldata body, address paymentAsset, uint256 amount)
        external
        nonReentrant
        returns (bytes32 requestId)
    {
        if (msg.sender != playground) revert Unauthorized();
        if (intake_.code.length == 0 || paymentAsset.code.length == 0) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        uint256 balanceBefore = paymentAsset.balanceOf(address(this));
        if (balanceBefore < amount) revert InvalidAmount();
        paymentAsset.safeApproveWithRetry(intake_, amount);
        requestId = IPlaygroundIntake(intake_).request(
            action, body, IPlaygroundIntake.Callback(address(0), bytes4(0)), paymentAsset, amount
        );
        paymentAsset.safeApprove(intake_, 0);
        if (paymentAsset.balanceOf(address(this)) != balanceBefore - amount) revert UnexpectedTokenSpent();
    }

    /// @notice Set the trusted route used by members and explicitly authorized swap callers.
    function configureSwap(address asset, address adapter) external onlyPlaygroundOwner nonReentrant {
        if (asset.code.length == 0 || adapter.code.length == 0) revert InvalidAddress();
        swapAdapters[asset] = adapter;
        emit SwapConfigured(asset, adapter);
    }

    function clearSwap(address asset) external onlyPlaygroundOwner nonReentrant {
        delete swapAdapters[asset];
        emit SwapCleared(asset);
    }

    /// @notice Authorized callers convert revenue and earn 0.5% of newly received native ETH.
    /// @dev minETHOut is gross output after DEX fees, before the caller reward, and must be nonzero.
    /// Previously held ETH earns no reward. All remaining ETH goes to this project's accounting.
    /// Insufficient output or a failed deposit reverts the entire swap, including the reward.
    function swapToETH(address asset, uint256 amountIn, uint256 minETHOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 ethReceived)
    {
        if (!IPlayground(playground).canSwap(msg.sender)) revert Unauthorized();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert InvalidAmount();
        if (minETHOut == 0) revert InvalidMinimum();
        address adapter = swapAdapters[asset];
        if (adapter == address(0)) revert SwapNotConfigured();

        uint256 tokenBalanceBefore = asset.balanceOf(address(this));
        if (tokenBalanceBefore < amountIn) revert InvalidAmount();
        uint256 ethBalanceBefore = address(this).balance;

        asset.safeApproveWithRetry(adapter, amountIn);
        IPlaygroundSwapAdapter(adapter).swapToETH(asset, amountIn, minETHOut);
        asset.safeApprove(adapter, 0);

        if (asset.balanceOf(address(this)) != tokenBalanceBefore - amountIn) revert UnexpectedTokenSpent();
        uint256 ethBalanceAfter = address(this).balance;
        if (ethBalanceAfter < ethBalanceBefore) revert InsufficientETHReceived();
        ethReceived = ethBalanceAfter - ethBalanceBefore;
        if (ethReceived < minETHOut) revert InsufficientETHReceived();

        uint256 callerReward = FixedPointMathLib.fullMulDiv(ethReceived, CALLER_REWARD_BPS, BPS);
        emit Swapped(asset, adapter, msg.sender, amountIn, ethReceived, callerReward);
        _depositETH(ethBalanceAfter - callerReward);
        if (callerReward != 0) SafeTransferLib.forceSafeTransferETH(msg.sender, callerReward);
    }

    function _depositETH(uint256 amount) private {
        IPlayground(playground).deposit{value: amount}(projectId);
        emit ETHDeposited(amount);
    }
}
