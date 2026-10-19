// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "solady/src/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

/// @notice Splits ETH among a fixed snapshot of Ethereum S02 holders on either supported chain.
/// @dev The deployer supplies the snapshot; there is no cross-chain ownership oracle.
///      Weights cannot change. After 365 days the owner may close claims and sweep all ETH.
contract PlaygroundHolderSplitter is Ownable, ReentrancyGuard {
    struct Snapshot {
        uint256 blockNumber;
        bytes32 blockHash;
        uint256 supply;
        uint256 maxTokenId;
    }

    uint256 public constant SOURCE_CHAIN_ID = 1;
    address public constant NFT_ADDRESS = 0xb33d806a94B6770C9d309E0842a75f8E6edCd5A6;
    uint256 public constant SWEEP_DELAY = 365 days;
    uint256 public immutable SNAPSHOT_BLOCK;
    bytes32 public immutable SNAPSHOT_BLOCK_HASH;
    uint256 public immutable SNAPSHOT_SUPPLY;
    uint256 public immutable MAX_TOKEN_ID;
    uint256 public immutable HOLDER_COUNT;
    bytes32 public immutable ALLOCATION_HASH;
    uint256 public immutable SWEEP_AVAILABLE_AT;

    mapping(address holder => uint256 count) public nftCounts;
    mapping(address holder => uint256 amount) public claimed;
    uint256 public totalReceived;
    uint256 public totalClaimed;
    bool public claimsClosed;

    error InvalidAddress();
    error InvalidSnapshot();
    error InvalidAllocations();
    error NothingToClaim();
    error ClaimsClosed();
    error SweepNotAvailable();

    event SnapshotLoaded(uint256 indexed sourceBlock, bytes32 blockHash, bytes32 allocationHash, uint256 holders);
    event ETHReceived(address indexed sender, uint256 amount);
    event Claimed(address indexed holder, address indexed recipient, uint256 amount);
    event Swept(address indexed owner, uint256 amount, bool firstSweep);

    /// @param allocations Sorted records of address (20 bytes) followed by NFT count (4 bytes, big endian).
    /// Packing keeps constructor calldata small enough for deployment with many holders.
    constructor(address owner_, Snapshot memory snapshot, bytes memory allocations) {
        if (owner_ == address(0) || owner_ == address(this)) revert InvalidAddress();
        if (
            snapshot.blockNumber == 0 || snapshot.blockHash == bytes32(0) || snapshot.supply == 0
                || snapshot.maxTokenId < snapshot.supply
        ) revert InvalidSnapshot();
        if (allocations.length == 0 || allocations.length % 24 != 0) revert InvalidAllocations();
        uint256 total;
        address previous;
        for (uint256 offset; offset < allocations.length; offset += 24) {
            address holder;
            uint256 count;
            assembly ("memory-safe") {
                let record := mload(add(add(allocations, 32), offset))
                holder := shr(96, record)
                count := and(shr(64, record), 0xffffffff)
            }
            // Strict ordering also rejects zero addresses and duplicate allocations.
            if (holder <= previous || holder == address(this) || count == 0) revert InvalidAllocations();
            nftCounts[holder] = count;
            total += count;
            previous = holder;
        }
        if (total != snapshot.supply) revert InvalidAllocations();
        _initializeOwner(owner_);
        SNAPSHOT_BLOCK = snapshot.blockNumber;
        SNAPSHOT_BLOCK_HASH = snapshot.blockHash;
        SNAPSHOT_SUPPLY = total;
        MAX_TOKEN_ID = snapshot.maxTokenId;
        HOLDER_COUNT = allocations.length / 24;
        ALLOCATION_HASH = keccak256(allocations);
        SWEEP_AVAILABLE_AT = block.timestamp + SWEEP_DELAY;
        emit SnapshotLoaded(snapshot.blockNumber, snapshot.blockHash, ALLOCATION_HASH, HOLDER_COUNT);
    }

    receive() external payable {
        if (!claimsClosed) {
            totalReceived += msg.value;
            emit ETHReceived(msg.sender, msg.value);
        }
    }

    function pending(address holder) public view returns (uint256) {
        if (claimsClosed) return 0;
        return FixedPointMathLib.fullMulDiv(totalReceived, nftCounts[holder], SNAPSHOT_SUPPLY) - claimed[holder];
    }

    function claim() external nonReentrant returns (uint256) {
        return _claim(msg.sender, msg.sender);
    }

    function claimTo(address recipient) external nonReentrant returns (uint256) {
        return _claim(msg.sender, recipient);
    }

    /// @notice Anyone can trigger a claim, always paying the recorded holder.
    function claimFor(address holder) external nonReentrant returns (uint256) {
        return _claim(holder, holder);
    }

    function _claim(address holder, address recipient) private returns (uint256 amount) {
        if (claimsClosed) revert ClaimsClosed();
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        amount = pending(holder);
        if (amount == 0) revert NothingToClaim();
        claimed[holder] += amount;
        totalClaimed += amount;
        SafeTransferLib.forceSafeTransferETH(recipient, amount);
        emit Claimed(holder, recipient, amount);
    }

    /// @notice The first nonempty sweep closes claims; later receipts remain sweepable.
    function sweep() external onlyOwner nonReentrant returns (uint256 amount) {
        if (block.timestamp < SWEEP_AVAILABLE_AT) revert SweepNotAvailable();
        amount = address(this).balance;
        if (amount == 0) revert NothingToClaim();
        bool firstSweep = !claimsClosed;
        claimsClosed = true;
        address recipient = owner();
        SafeTransferLib.forceSafeTransferAllETH(recipient);
        emit Swept(recipient, amount, firstSweep);
    }
}
