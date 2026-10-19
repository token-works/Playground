// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPlayground} from "../../script/playground/DeployPlayground.s.sol";
import {PlaygroundFactory} from "../../src/playground/PlaygroundFactory.sol";
import {Playground} from "../../src/playground/Playground.sol";
import {PlaygroundHolderSplitter} from "../../src/playground/PlaygroundHolderSplitter.sol";
import {TokenworksSplitter} from "../../src/playground/TokenworksSplitter.sol";

contract DeploymentIntakeMock {}

contract DeployPlaygroundHarness is DeployPlayground {
    address internal configuredOwner;
    address internal configuredIntake;
    address internal configuredFactoryOwner;

    constructor(address owner_, address intake_) {
        configuredOwner = owner_;
        configuredFactoryOwner = owner_;
        configuredIntake = intake_;
    }

    function _readConfiguration() internal view override returns (address, address) {
        return (configuredOwner, configuredIntake);
    }

    function setFactoryOwner(address newOwner) external {
        configuredFactoryOwner = newOwner;
    }

    function _readFactoryOwner() internal view override returns (address) {
        return configuredFactoryOwner;
    }

    function _snapshotPath() internal pure override returns (string memory) {
        return "test/fixtures/playground/s02-snapshot.json";
    }
}

contract DeployPlaygroundTest is Test {
    address internal tokenworks = makeAddr("Tokenworks");
    DeployPlaygroundHarness internal deployment;

    function setUp() public {
        vm.chainId(1);
        deployment = new DeployPlaygroundHarness(tokenworks, address(new DeploymentIntakeMock()));
    }

    function testEthereumUsesSameFrozenSnapshotAndFactoryRouting() public {
        address factoryAdmin = makeAddr("factory admin");
        deployment.setFactoryOwner(factoryAdmin);
        PlaygroundFactory factory = deployment.run();
        assertEq(factory.owner(), factoryAdmin);
        assertFalse(factory.playgroundCreationEnabled());
        assertTrue(factory.launchesEnabled());
        TokenworksSplitter router = TokenworksSplitter(payable(factory.tokenworksSplitter()));
        PlaygroundHolderSplitter splitter = PlaygroundHolderSplitter(payable(router.holderSplitter()));
        assertEq(splitter.SNAPSHOT_SUPPLY(), 3);
        assertEq(splitter.MAX_TOKEN_ID(), 4);
        assertEq(splitter.nftCounts(address(0x100)), 2);
        assertEq(splitter.SWEEP_AVAILABLE_AT(), block.timestamp + 365 days);
        assertEq(splitter.owner(), tokenworks);
        assertEq(factory.playgroundCount(), 1);
        Playground hub = Playground(payable(factory.playgrounds(1)));
        assertTrue(factory.isPlayground(address(hub)));
        assertEq(hub.owner(), factoryAdmin);
        assertTrue(hub.isMember(factoryAdmin));
        assertEq(hub.memberCount(), 1);
        assertEq(hub.projectCount(), 0);
        vm.expectRevert(PlaygroundFactory.PlaygroundCreationDisabled.selector);
        factory.createPlayground();
        address creator = factoryAdmin;
        address member = makeAddr("member");
        vm.startPrank(creator);
        assertEq(hub.factory(), address(factory));
        hub.inviteMember(member);
        (uint256 id,) = hub.createProject();
        vm.stopPrank();
        vm.prank(member);
        hub.acceptInvitation();
        vm.deal(address(this), 100 ether);
        hub.deposit{value: 100 ether}(id);
        assertEq(hub.claimable(creator), 50 ether);
        assertEq(hub.claimable(member), 30 ether);
        assertEq(hub.claimable(tokenworks), 0);
        assertEq(router.pendingTokenworks(), 15 ether);
        assertEq(splitter.totalReceived(), 5 ether);
        router.claimTokenworks();
        assertEq(tokenworks.balance, 15 ether);
        vm.prank(factoryAdmin);
        factory.setPlaygroundCreationEnabled(true);
        vm.prank(member);
        Playground next = factory.createPlayground();
        assertEq(factory.playgroundCount(), 2);
        assertEq(next.owner(), member);
    }

    function testRejectsOtherChain() public {
        vm.chainId(4663);
        vm.expectRevert("DeployPlayground: wrong chain");
        deployment.run();
    }

    function testRejectsZeroTokenworks() public {
        deployment = new DeployPlaygroundHarness(address(0), address(new DeploymentIntakeMock()));
        vm.expectRevert("DeployPlayground: zero Tokenworks recipient");
        deployment.run();
    }

    function testRejectsZeroFactoryOwner() public {
        deployment.setFactoryOwner(address(0));
        vm.expectRevert("DeployPlayground: zero factory owner");
        deployment.run();
    }

    function testRejectsIntakeWithoutCode() public {
        deployment = new DeployPlaygroundHarness(tokenworks, address(0x123));
        vm.expectRevert("DeployPlayground: intake has no code");
        deployment.run();
    }
}
