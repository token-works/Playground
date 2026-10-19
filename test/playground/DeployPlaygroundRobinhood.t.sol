// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPlaygroundRobinhood} from "../../script/playground/DeployPlaygroundRobinhood.s.sol";
import {PlaygroundFactory} from "../../src/playground/PlaygroundFactory.sol";
import {Playground} from "../../src/playground/Playground.sol";
import {TokenworksSplitter} from "../../src/playground/TokenworksSplitter.sol";
import {PlaygroundHolderSplitter} from "../../src/playground/PlaygroundHolderSplitter.sol";
import {PlaygroundProject} from "../../src/playground/PlaygroundProject.sol";

contract RobinhoodIntakeMock {}

contract RobinhoodDeploymentHarness is DeployPlaygroundRobinhood {
    address internal configuredOwner;
    address internal configuredIntake;

    constructor(address owner_, address intake_) {
        configuredOwner = owner_;
        configuredIntake = intake_;
    }

    function _readConfiguration() internal view override returns (address, address) {
        return (configuredOwner, configuredIntake);
    }

    function _readFactoryOwner() internal view override returns (address) {
        return configuredOwner;
    }

    function _snapshotPath() internal pure override returns (string memory) {
        return "test/fixtures/playground/s02-snapshot.json";
    }

    function parse(string memory json) external pure returns (PlaygroundHolderSplitter.Snapshot memory, bytes memory) {
        return _parseSnapshot(json);
    }
}

contract DeployPlaygroundRobinhoodTest is Test {
    RobinhoodDeploymentHarness internal script;
    address internal owner = makeAddr("owner");
    address internal intake;

    function setUp() public {
        vm.chainId(4663);
        intake = address(new RobinhoodIntakeMock());
        script = new RobinhoodDeploymentHarness(owner, intake);
    }

    function testDeploysSharedSystemAndUserCanLaunchWithoutNFT() public {
        PlaygroundFactory factory = script.run();
        assertEq(factory.owner(), owner);
        assertFalse(factory.playgroundCreationEnabled());
        assertTrue(factory.launchesEnabled());
        TokenworksSplitter router = TokenworksSplitter(payable(factory.tokenworksSplitter()));
        PlaygroundHolderSplitter splitter = PlaygroundHolderSplitter(payable(router.holderSplitter()));
        assertEq(splitter.NFT_ADDRESS().code.length, 0);
        assertEq(factory.intake(), intake);
        assertEq(router.tokenworksRecipient(), owner);
        assertEq(splitter.owner(), owner);
        assertEq(splitter.nftCounts(address(0x100)), 2);
        assertEq(splitter.nftCounts(address(0x200)), 1);
        assertEq(splitter.HOLDER_COUNT(), 2);
        assertEq(splitter.SNAPSHOT_BLOCK(), 100);
        assertEq(splitter.SNAPSHOT_SUPPLY(), 3);
        assertEq(splitter.MAX_TOKEN_ID(), 4);
        assertEq(factory.playgroundCount(), 1);
        vm.expectRevert(PlaygroundFactory.PlaygroundCreationDisabled.selector);
        factory.createPlayground();
        Playground hub = Playground(payable(factory.playgrounds(1)));
        assertTrue(factory.isPlayground(address(hub)));
        assertEq(hub.owner(), owner);
        assertEq(hub.factory(), address(factory));
        assertTrue(hub.isMember(owner));
        assertEq(hub.memberCount(), 1);
        assertEq(hub.tokenworksSplitter(), address(router));
        PlaygroundProject implementation = PlaygroundProject(payable(hub.projectImplementation()));
        assertEq(implementation.playground(), address(hub));
        assertEq(implementation.projectId(), type(uint256).max);
        assertEq(hub.projectCount(), 0);
        vm.prank(owner);
        hub.createProject();
        assertEq(hub.projectCount(), 1);
    }

    function testRejectsWrongChain() public {
        vm.chainId(1);
        vm.expectRevert("DeployPlayground: wrong chain");
        script.run();
    }

    function testRejectsZeroOwner() public {
        script = new RobinhoodDeploymentHarness(address(0), intake);
        vm.expectRevert("DeployPlayground: zero Tokenworks recipient");
        script.run();
    }

    function testRejectsMissingIntake() public {
        script = new RobinhoodDeploymentHarness(owner, address(0x123));
        vm.expectRevert("DeployPlayground: intake has no code");
        script.run();
    }

    function testRejectsCorruptedManifest() public {
        string memory json = vm.readFile("test/fixtures/playground/s02-snapshot.json");
        json = vm.replace(json, '"counts": [\n    2,', '"counts": [\n    1,');
        vm.expectRevert("DeployPlayground: holder counts do not match supply");
        script.parse(json);
    }

    function testRejectsChangedWeightsWithSameTotal() public {
        string memory json = vm.readFile("test/fixtures/playground/s02-snapshot.json");
        json = vm.replace(json, '"counts": [\n    2,\n    1', '"counts": [\n    1,\n    2');
        vm.expectRevert("DeployPlayground: corrupt allocation hash");
        script.parse(json);
    }

    function testRejectsDuplicateAddresses() public {
        string memory json = vm.readFile("test/fixtures/playground/s02-snapshot.json");
        json = vm.replace(json, "0000000000000000000000000000000000000200", "0000000000000000000000000000000000000100");
        vm.expectRevert("DeployPlayground: holders must be unique and sorted");
        script.parse(json);
    }

    function testRejectsForeignSource() public {
        string memory json = vm.readFile("test/fixtures/playground/s02-snapshot.json");
        json = vm.replace(json, '"sourceChainId": 1', '"sourceChainId": 4663');
        vm.expectRevert("DeployPlayground: snapshot is not Ethereum");
        script.parse(json);
    }
}
