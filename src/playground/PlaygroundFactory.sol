// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Playground} from "./Playground.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";

/// @notice Public creation of independently owned Playgrounds, with factory-wide availability controls.
/// @dev The initial Intake and Tokenworks splitter are fixed for this factory. Each Playground's
/// owner may subsequently change its own Intake; the shared splitter cannot be overridden.
contract PlaygroundFactory is Ownable {
    error InvalidOwner();
    error InvalidIntake();
    error InvalidTokenworksSplitter();
    error PlaygroundCreationDisabled();

    event PlaygroundCreated(uint256 indexed index, address indexed playground, address indexed creator);
    event PlaygroundCreationEnabledSet(bool enabled);
    event LaunchesEnabledSet(bool enabled);

    address public immutable intake;
    address public immutable tokenworksSplitter;

    bool public playgroundCreationEnabled = true;
    bool public launchesEnabled = true;

    uint256 public playgroundCount;
    mapping(uint256 index => address playground) public playgrounds;
    mapping(address playground => bool registered) public isPlayground;

    constructor(address initialOwner, address intake_, address tokenworksSplitter_) {
        if (initialOwner == address(0) || initialOwner == address(this)) revert InvalidOwner();
        if (intake_.code.length == 0) revert InvalidIntake();
        if (tokenworksSplitter_.code.length == 0) revert InvalidTokenworksSplitter();
        _initializeOwner(initialOwner);
        intake = intake_;
        tokenworksSplitter = tokenworksSplitter_;
    }

    /// @notice Control new Playground creation without changing existing Playgrounds.
    function setPlaygroundCreationEnabled(bool enabled) external onlyOwner {
        playgroundCreationEnabled = enabled;
        emit PlaygroundCreationEnabledSet(enabled);
    }

    /// @notice Control project creation and Intake submissions across this factory's Playgrounds.
    function setLaunchesEnabled(bool enabled) external onlyOwner {
        launchesEnabled = enabled;
        emit LaunchesEnabledSet(enabled);
    }

    /// @notice Create a Playground owned by the caller, who also becomes its first member.
    /// @dev Registry indices start at one. Metadata and additional members are configured afterward.
    function createPlayground() external returns (Playground playground) {
        if (!playgroundCreationEnabled) revert PlaygroundCreationDisabled();
        playground = new Playground(msg.sender, intake, tokenworksSplitter, address(this));
        uint256 index = ++playgroundCount;
        playgrounds[index] = address(playground);
        isPlayground[address(playground)] = true;
        emit PlaygroundCreated(index, address(playground), msg.sender);
    }
}
