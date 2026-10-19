// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {Playground} from "../../src/playground/Playground.sol";
import {PlaygroundProject} from "../../src/playground/PlaygroundProject.sol";
import {PlaygroundFactory} from "../../src/playground/PlaygroundFactory.sol";

contract FactoryIntakeMock {
    function marker() external pure returns (bytes32) {
        return keccak256("factory intake mock");
    }
}

contract FactoryTokenworksSplitterMock {
    receive() external payable {}
}

contract FactoryContractCreator {
    function create(PlaygroundFactory factory) external returns (Playground) {
        return factory.createPlayground();
    }
}

contract PlaygroundFactoryTest is Test {
    address internal factoryOwner = makeAddr("factory owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal outsider = makeAddr("outsider");
    FactoryIntakeMock internal intake;
    FactoryTokenworksSplitterMock internal splitter;
    PlaygroundFactory internal factory;

    function setUp() public {
        intake = new FactoryIntakeMock();
        splitter = new FactoryTokenworksSplitterMock();
        factory = new PlaygroundFactory(factoryOwner, address(intake), address(splitter));
    }

    function testFactoryStoresFixedConfigurationAndStartsEmpty() public view {
        assertEq(factory.intake(), address(intake));
        assertEq(factory.tokenworksSplitter(), address(splitter));
        assertEq(factory.owner(), factoryOwner);
        assertTrue(factory.playgroundCreationEnabled());
        assertTrue(factory.launchesEnabled());
        assertEq(factory.playgroundCount(), 0);
        assertEq(factory.playgrounds(0), address(0));
        assertEq(factory.playgrounds(1), address(0));
        assertFalse(factory.isPlayground(address(factory)));
        assertFalse(factory.isPlayground(address(intake)));
    }

    function testCreationIsPermissionlessAndCreatesIndependentOwnersAndMembers() public {
        vm.prank(alice);
        Playground first = factory.createPlayground();
        vm.prank(bob);
        Playground second = factory.createPlayground();

        assertNotEq(address(first), address(second));
        assertEq(first.owner(), alice);
        assertEq(second.owner(), bob);
        assertEq(first.memberCount(), 1);
        assertEq(second.memberCount(), 1);
        assertTrue(first.isMember(alice));
        assertTrue(second.isMember(bob));
        assertFalse(first.isMember(bob));
        assertFalse(second.isMember(alice));
        assertFalse(first.isMember(address(factory)));
        assertFalse(second.isMember(address(factory)));
        assertFalse(first.isMember(factoryOwner));
        assertFalse(second.isMember(factoryOwner));
        assertTrue(first.canSwap(alice));
        assertTrue(second.canSwap(bob));
        assertEq(first.projectCount(), 0);
        assertEq(second.projectCount(), 0);

        vm.prank(alice);
        first.inviteMember(outsider);
        assertFalse(first.isMember(outsider));
        assertFalse(first.canSwap(outsider));
        assertEq(first.memberCount(), 1);
        vm.prank(outsider);
        first.acceptInvitation();
        assertTrue(first.isMember(outsider));
        assertEq(first.memberCount(), 2);
        assertFalse(second.isMember(outsider));
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        second.inviteMember(outsider);
    }

    function testRegistryAndCreationEventIdentifyEveryInstance() public {
        vm.recordLogs();
        vm.prank(alice);
        Playground first = factory.createPlayground();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory creation = logs[logs.length - 1];
        assertEq(creation.emitter, address(factory));
        assertEq(creation.topics.length, 4);
        assertEq(creation.topics[0], keccak256("PlaygroundCreated(uint256,address,address)"));
        assertEq(creation.topics[1], bytes32(uint256(1)));
        assertEq(creation.topics[2], bytes32(uint256(uint160(address(first)))));
        assertEq(creation.topics[3], bytes32(uint256(uint160(alice))));

        vm.prank(bob);
        Playground second = factory.createPlayground();
        assertEq(factory.playgroundCount(), 2);
        assertEq(factory.playgrounds(1), address(first));
        assertEq(factory.playgrounds(2), address(second));
        assertEq(factory.playgrounds(3), address(0));
        assertTrue(factory.isPlayground(address(first)));
        assertTrue(factory.isPlayground(address(second)));
        assertFalse(factory.isPlayground(outsider));
    }

    function testEveryInstanceUsesSharedSplitterAndItsOwnReceiverImplementation() public {
        vm.prank(alice);
        Playground first = factory.createPlayground();
        vm.prank(bob);
        Playground second = factory.createPlayground();
        assertEq(first.tokenworksSplitter(), address(splitter));
        assertEq(second.tokenworksSplitter(), address(splitter));
        assertEq(first.intake(), address(intake));
        assertEq(second.intake(), address(intake));
        assertEq(first.factory(), address(factory));
        assertEq(second.factory(), address(factory));
        assertNotEq(first.projectImplementation(), second.projectImplementation());
        PlaygroundProject firstImplementation = PlaygroundProject(payable(first.projectImplementation()));
        PlaygroundProject secondImplementation = PlaygroundProject(payable(second.projectImplementation()));
        assertEq(firstImplementation.playground(), address(first));
        assertEq(secondImplementation.playground(), address(second));
        assertEq(firstImplementation.projectId(), type(uint256).max);
        assertEq(secondImplementation.projectId(), type(uint256).max);
    }

    function testOwnerIntakeUpdateAffectsOnlyItsInstanceAndNotFutureDeployments() public {
        vm.prank(alice);
        Playground first = factory.createPlayground();
        FactoryIntakeMock replacement = new FactoryIntakeMock();
        vm.prank(outsider);
        vm.expectRevert(Ownable.Unauthorized.selector);
        first.setIntake(address(replacement));
        vm.prank(alice);
        first.setIntake(address(replacement));
        vm.prank(alice);
        Playground second = factory.createPlayground();
        assertEq(first.intake(), address(replacement));
        assertEq(second.intake(), address(intake));
        assertEq(factory.intake(), address(intake));
        assertEq(first.tokenworksSplitter(), address(splitter));
        assertEq(second.tokenworksSplitter(), address(splitter));
        assertEq(factory.playgroundCount(), 2);
    }

    function testContractCallerBecomesOwnerAndFirstMember() public {
        FactoryContractCreator creator = new FactoryContractCreator();
        Playground created = creator.create(factory);
        assertEq(created.owner(), address(creator));
        assertTrue(created.isMember(address(creator)));
        assertEq(created.memberCount(), 1);
        assertFalse(created.isMember(address(this)));
        assertTrue(factory.isPlayground(address(created)));
    }

    function testConstructorRejectsInvalidIntake() public {
        vm.expectRevert(PlaygroundFactory.InvalidIntake.selector);
        new PlaygroundFactory(factoryOwner, address(0), address(splitter));
        vm.expectRevert(PlaygroundFactory.InvalidIntake.selector);
        new PlaygroundFactory(factoryOwner, outsider, address(splitter));
    }

    function testConstructorRejectsInvalidSplitter() public {
        vm.expectRevert(PlaygroundFactory.InvalidTokenworksSplitter.selector);
        new PlaygroundFactory(factoryOwner, address(intake), address(0));
        vm.expectRevert(PlaygroundFactory.InvalidTokenworksSplitter.selector);
        new PlaygroundFactory(factoryOwner, address(intake), outsider);
    }

    function testConstructorRejectsZeroAndSelfOwner() public {
        vm.expectRevert(PlaygroundFactory.InvalidOwner.selector);
        new PlaygroundFactory(address(0), address(intake), address(splitter));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(PlaygroundFactory.InvalidOwner.selector);
        new PlaygroundFactory(predicted, address(intake), address(splitter));
    }

    function testOnlyFactoryOwnerCanChangeAvailability() public {
        vm.startPrank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setPlaygroundCreationEnabled(false);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setLaunchesEnabled(false);
        vm.stopPrank();
        assertTrue(factory.playgroundCreationEnabled());
        assertTrue(factory.launchesEnabled());

        vm.expectEmit(false, false, false, true, address(factory));
        emit PlaygroundFactory.PlaygroundCreationEnabledSet(false);
        vm.prank(factoryOwner);
        factory.setPlaygroundCreationEnabled(false);
        vm.expectEmit(false, false, false, true, address(factory));
        emit PlaygroundFactory.LaunchesEnabledSet(false);
        vm.prank(factoryOwner);
        factory.setLaunchesEnabled(false);
        assertFalse(factory.playgroundCreationEnabled());
        assertFalse(factory.launchesEnabled());
    }

    function testCreationPausePreservesRegistryAndCanBeReenabled() public {
        vm.prank(alice);
        Playground first = factory.createPlayground();
        vm.prank(factoryOwner);
        factory.setPlaygroundCreationEnabled(false);
        vm.prank(bob);
        vm.expectRevert(PlaygroundFactory.PlaygroundCreationDisabled.selector);
        factory.createPlayground();
        assertEq(factory.playgroundCount(), 1);
        assertEq(factory.playgrounds(1), address(first));
        assertEq(factory.playgrounds(2), address(0));
        assertTrue(factory.isPlayground(address(first)));
        assertTrue(factory.launchesEnabled());
        assertEq(first.owner(), alice);

        vm.prank(factoryOwner);
        factory.setPlaygroundCreationEnabled(true);
        vm.prank(bob);
        Playground second = factory.createPlayground();
        assertEq(factory.playgroundCount(), 2);
        assertEq(factory.playgrounds(2), address(second));
        assertEq(second.owner(), bob);
    }

    function testLaunchAvailabilityIsIndependentOfPlaygroundCreation() public {
        vm.prank(factoryOwner);
        factory.setLaunchesEnabled(false);
        assertTrue(factory.playgroundCreationEnabled());
        vm.prank(alice);
        Playground created = factory.createPlayground();
        assertTrue(factory.isPlayground(address(created)));
        assertEq(created.factory(), address(factory));
        assertFalse(factory.launchesEnabled());

        vm.startPrank(factoryOwner);
        factory.setPlaygroundCreationEnabled(false);
        factory.setLaunchesEnabled(true);
        vm.stopPrank();
        assertTrue(factory.launchesEnabled());
        assertFalse(factory.playgroundCreationEnabled());
        vm.expectRevert(PlaygroundFactory.PlaygroundCreationDisabled.selector);
        factory.createPlayground();
    }

    function testFactoryOwnershipHandoverTransfersOnlyAvailabilityAuthority() public {
        vm.prank(alice);
        Playground created = factory.createPlayground();
        vm.prank(bob);
        factory.requestOwnershipHandover();
        vm.prank(factoryOwner);
        factory.completeOwnershipHandover(bob);
        assertEq(factory.owner(), bob);
        assertEq(created.owner(), alice);
        assertEq(factory.intake(), address(intake));
        assertEq(factory.tokenworksSplitter(), address(splitter));

        vm.startPrank(factoryOwner);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setPlaygroundCreationEnabled(false);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setLaunchesEnabled(false);
        vm.stopPrank();
        vm.startPrank(bob);
        factory.setPlaygroundCreationEnabled(false);
        factory.setLaunchesEnabled(false);
        vm.stopPrank();
        assertFalse(factory.playgroundCreationEnabled());
        assertFalse(factory.launchesEnabled());
        assertEq(created.owner(), alice);
    }

    function testRevertingInstanceCreationDoesNotRegisterOrIncreaseCount() public {
        vm.etch(address(intake), "");
        vm.prank(alice);
        vm.expectRevert();
        factory.createPlayground();
        assertEq(factory.playgroundCount(), 0);
        assertEq(factory.playgrounds(1), address(0));
    }
}
