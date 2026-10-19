// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PlaygroundFactory} from "../../src/playground/PlaygroundFactory.sol";
import {Playground} from "../../src/playground/Playground.sol";
import {PlaygroundHolderSplitter} from "../../src/playground/PlaygroundHolderSplitter.sol";
import {TokenworksSplitter} from "../../src/playground/TokenworksSplitter.sol";

/// @notice Shared snapshot-based system deployment for Ethereum and Robinhood.
abstract contract DeployPlaygroundSystem is Script {
    address public constant DEFAULT_OWNER = 0x019817aD02a31B990433542097bE29D97613E8Cb;
    address public constant DEFAULT_INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant S02_COLLECTION = 0xb33d806a94B6770C9d309E0842a75f8E6edCd5A6;

    function _deploy(uint256 chainId) internal returns (PlaygroundFactory factory) {
        require(block.chainid == chainId, "DeployPlayground: wrong chain");
        (address tokenworks, address intake) = _readConfiguration();
        address factoryOwner = _readFactoryOwner();
        require(tokenworks != address(0), "DeployPlayground: zero Tokenworks recipient");
        require(factoryOwner != address(0), "DeployPlayground: zero factory owner");
        require(intake.code.length != 0, "DeployPlayground: intake has no code");
        (PlaygroundHolderSplitter.Snapshot memory snapshot, bytes memory allocations) = _readSnapshot();
        require(
            type(PlaygroundHolderSplitter).creationCode.length + abi.encode(tokenworks, snapshot, allocations).length
                <= 49_152,
            "DeployPlayground: snapshot exceeds initcode limit"
        );

        // One signer owns the factory, creates the initial community, and closes further creation.
        vm.startBroadcast(factoryOwner);
        PlaygroundHolderSplitter holderSplitter = new PlaygroundHolderSplitter(tokenworks, snapshot, allocations);
        TokenworksSplitter tokenworksSplitter = new TokenworksSplitter(tokenworks, address(holderSplitter));
        factory = new PlaygroundFactory(factoryOwner, intake, address(tokenworksSplitter));
        Playground initialPlayground = factory.createPlayground();
        factory.setPlaygroundCreationEnabled(false);
        vm.stopBroadcast();

        require(factory.intake() == intake, "DeployPlayground: intake mismatch");
        require(factory.owner() == factoryOwner, "DeployPlayground: factory owner mismatch");
        require(!factory.playgroundCreationEnabled(), "DeployPlayground: creation still enabled");
        require(factory.launchesEnabled(), "DeployPlayground: project launches disabled");
        require(factory.tokenworksSplitter() == address(tokenworksSplitter), "DeployPlayground: router mismatch");
        require(factory.playgroundCount() == 1, "DeployPlayground: expected one Playground");
        require(factory.playgrounds(1) == address(initialPlayground), "DeployPlayground: initial Playground mismatch");
        require(factory.isPlayground(address(initialPlayground)), "DeployPlayground: initial Playground not registered");
        require(initialPlayground.factory() == address(factory), "DeployPlayground: factory binding mismatch");
        require(initialPlayground.owner() == factoryOwner, "DeployPlayground: initial owner mismatch");
        require(
            initialPlayground.isMember(factoryOwner) && initialPlayground.memberCount() == 1,
            "DeployPlayground: initial membership mismatch"
        );
        require(initialPlayground.projectCount() == 0, "DeployPlayground: initial projects not empty");
        require(initialPlayground.intake() == intake, "DeployPlayground: initial Intake mismatch");
        require(
            initialPlayground.tokenworksSplitter() == address(tokenworksSplitter),
            "DeployPlayground: initial router mismatch"
        );
        require(tokenworksSplitter.tokenworksRecipient() == tokenworks, "DeployPlayground: recipient mismatch");
        require(
            tokenworksSplitter.holderSplitter() == address(holderSplitter), "DeployPlayground: holder splitter mismatch"
        );
        require(holderSplitter.owner() == tokenworks, "DeployPlayground: sweep owner mismatch");
        require(holderSplitter.SNAPSHOT_SUPPLY() == snapshot.supply, "DeployPlayground: supply mismatch");
        require(holderSplitter.MAX_TOKEN_ID() == snapshot.maxTokenId, "DeployPlayground: cap mismatch");
        require(holderSplitter.SNAPSHOT_BLOCK() == snapshot.blockNumber, "DeployPlayground: block mismatch");
        require(holderSplitter.SNAPSHOT_BLOCK_HASH() == snapshot.blockHash, "DeployPlayground: block hash mismatch");
        require(holderSplitter.ALLOCATION_HASH() == keccak256(allocations), "DeployPlayground: allocation mismatch");
        require(holderSplitter.HOLDER_COUNT() == allocations.length / 24, "DeployPlayground: holder count mismatch");
        require(
            holderSplitter.SWEEP_AVAILABLE_AT() == block.timestamp + 365 days, "DeployPlayground: deadline mismatch"
        );
        require(!holderSplitter.claimsClosed(), "DeployPlayground: claims closed");

        console.log("Playground factory:", address(factory));
        console.log("Factory owner (global creation and launch controls):", factoryOwner);
        console.log("Initial Playground:", address(initialPlayground));
        console.log("Project receiver implementation:", initialPlayground.projectImplementation());
        console.log("New Playground creation enabled:", false);
        console.log("Project launches enabled:", true);
        console.log("Tokenworks splitter (20% of project revenue):", address(tokenworksSplitter));
        console.log("Tokenworks recipient (15% of project revenue):", tokenworks);
        console.log("Holder snapshot splitter (5% of project revenue):", address(holderSplitter));
        console.log("Default Intake:", intake);
        console.log("Ethereum snapshot block:", snapshot.blockNumber);
        console.log("Snapshot allocation hash:");
        console.logBytes32(holderSplitter.ALLOCATION_HASH());
        console.log("S02 snapshot supply:", snapshot.supply);
        console.log("S02 holder count:", holderSplitter.HOLDER_COUNT());
        console.log("Sweep available at (Unix seconds):", holderSplitter.SWEEP_AVAILABLE_AT());
    }

    function _readConfiguration() internal view virtual returns (address owner, address intake) {
        owner = vm.envOr("PLAYGROUND_TOKENWORKS", DEFAULT_OWNER);
        intake = vm.envOr("PLAYGROUND_INTAKE", DEFAULT_INTAKE);
    }

    function _readFactoryOwner() internal view virtual returns (address) {
        return vm.envOr("PLAYGROUND_FACTORY_OWNER", DEFAULT_OWNER);
    }

    function _snapshotPath() internal view virtual returns (string memory) {
        return vm.envOr("PLAYGROUND_S02_SNAPSHOT", string("output/playground/s02-snapshot.json"));
    }

    function _readSnapshot()
        internal
        view
        returns (PlaygroundHolderSplitter.Snapshot memory snapshot, bytes memory allocations)
    {
        return _parseSnapshot(vm.readFile(_snapshotPath()));
    }

    function _parseSnapshot(string memory json)
        internal
        pure
        returns (PlaygroundHolderSplitter.Snapshot memory snapshot, bytes memory allocations)
    {
        require(vm.parseJsonUint(json, ".schemaVersion") == 1, "DeployPlayground: unknown snapshot format");
        require(vm.parseJsonUint(json, ".sourceChainId") == 1, "DeployPlayground: snapshot is not Ethereum");
        require(vm.parseJsonAddress(json, ".collection") == S02_COLLECTION, "DeployPlayground: wrong collection");
        snapshot = PlaygroundHolderSplitter.Snapshot({
            blockNumber: vm.parseJsonUint(json, ".blockNumber"),
            blockHash: vm.parseJsonBytes32(json, ".blockHash"),
            supply: vm.parseJsonUint(json, ".supply"),
            maxTokenId: vm.parseJsonUint(json, ".maxTokenId")
        });
        address[] memory holders = vm.parseJsonAddressArray(json, ".holders");
        uint256[] memory counts = vm.parseJsonUintArray(json, ".counts");
        require(holders.length != 0 && holders.length == counts.length, "DeployPlayground: invalid holder arrays");
        // Eight extra bytes keep the final 32-byte write within allocated memory.
        allocations = new bytes(holders.length * 24 + 8);
        assembly ("memory-safe") {
            mstore(allocations, mul(mload(holders), 24))
        }
        uint256 total;
        address previous;
        for (uint256 i; i < holders.length; ++i) {
            require(holders[i] > previous, "DeployPlayground: holders must be unique and sorted");
            require(counts[i] != 0 && counts[i] <= type(uint32).max, "DeployPlayground: invalid NFT count");
            uint256 record = (uint256(uint160(holders[i])) << 96) | (counts[i] << 64);
            assembly ("memory-safe") {
                mstore(add(add(allocations, 32), mul(i, 24)), record)
            }
            previous = holders[i];
            total += counts[i];
        }
        require(total == snapshot.supply, "DeployPlayground: holder counts do not match supply");
        require(
            keccak256(allocations) == vm.parseJsonBytes32(json, ".allocationHash"),
            "DeployPlayground: corrupt allocation hash"
        );
    }
}
