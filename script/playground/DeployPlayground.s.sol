// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployPlaygroundSystem} from "./DeployPlaygroundSystem.s.sol";
import {PlaygroundFactory} from "../../src/playground/PlaygroundFactory.sol";

/// @notice Deploys shared splitters, a factory and one Playground, then disables further Playground creation on chain 1.
contract DeployPlayground is DeployPlaygroundSystem {
    function run() external returns (PlaygroundFactory) {
        return _deploy(1);
    }
}
