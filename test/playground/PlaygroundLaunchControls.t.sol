// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Playground} from "../../src/playground/Playground.sol";
import {PlaygroundFactory} from "../../src/playground/PlaygroundFactory.sol";
import {PlaygroundProject} from "../../src/playground/PlaygroundProject.sol";
import {PlaygroundTestIntake, PlaygroundTestToken, PlaygroundRevenueSink} from "./Playground.t.sol";
import {ProjectTestAdapter} from "./PlaygroundProject.t.sol";

contract PlaygroundLaunchControlsTest is Test {
    address internal admin = makeAddr("factory admin");
    address internal alice = makeAddr("first founder");
    address internal bob = makeAddr("second founder");
    address internal carol = makeAddr("third founder");
    PlaygroundFactory internal factory;
    Playground internal firstHub;
    Playground internal secondHub;
    PlaygroundTestIntake internal intake;
    PlaygroundTestToken internal token;
    PlaygroundRevenueSink internal sink;
    uint256 internal firstId;
    uint256 internal secondId;
    address internal firstReceiver;
    address internal secondReceiver;

    function setUp() public {
        intake = new PlaygroundTestIntake();
        token = new PlaygroundTestToken();
        sink = new PlaygroundRevenueSink();
        factory = new PlaygroundFactory(admin, address(intake), address(sink));
        vm.startPrank(alice);
        firstHub = factory.createPlayground();
        (firstId, firstReceiver) = firstHub.createProject();
        token.approve(address(firstHub), 20 ether);
        vm.stopPrank();
        vm.startPrank(bob);
        secondHub = factory.createPlayground();
        (secondId, secondReceiver) = secondHub.createProject();
        token.approve(address(secondHub), 20 ether);
        vm.stopPrank();
        token.mint(alice, 20 ether);
        token.mint(bob, 20 ether);
        vm.deal(address(this), 100 ether);
    }

    function test_existingPlaygroundsReadTheSameLiveLaunchFlag() public {
        assertEq(firstHub.factory(), address(factory));
        assertEq(secondHub.factory(), address(factory));
        assertTrue(factory.launchesEnabled());
        assertTrue(factory.playgroundCreationEnabled());
        vm.prank(admin);
        factory.setLaunchesEnabled(false);

        _assertAllLaunchPathsBlocked(firstHub, alice, firstId, firstReceiver);
        _assertAllLaunchPathsBlocked(secondHub, bob, secondId, secondReceiver);
        assertEq(factory.playgroundCount(), 2);
        assertEq(intake.nonce(), 0);

        vm.prank(admin);
        factory.setLaunchesEnabled(true);
        vm.prank(alice);
        firstHub.requestProject(firstId, bytes32("continue"), "first", address(token), 1 ether);
        vm.prank(bob);
        secondHub.requestProject(secondId, bytes32("continue"), "second", address(token), 1 ether);
        assertEq(firstHub.projectCount(), 1);
        assertEq(secondHub.projectCount(), 1);
        assertEq(intake.nonce(), 2);
        assertEq(intake.lastRequester(), secondReceiver);
    }

    function test_disablingPlaygroundCreationDoesNotDisableExistingProjectLaunches() public {
        vm.prank(admin);
        factory.setPlaygroundCreationEnabled(false);
        assertTrue(factory.launchesEnabled());
        vm.prank(carol);
        vm.expectRevert(PlaygroundFactory.PlaygroundCreationDisabled.selector);
        factory.createPlayground();

        vm.prank(alice);
        firstHub.requestProject(firstId, bytes32("continue"), "existing", address(token), 1 ether);
        vm.prank(alice);
        (uint256 newId,,) = firstHub.requestProject(bytes32("launch"), "new", address(token), 1 ether);
        vm.prank(bob);
        secondHub.createProject();
        assertEq(newId, 2);
        assertEq(firstHub.projectCount(), 2);
        assertEq(secondHub.projectCount(), 2);
        assertEq(factory.playgroundCount(), 2);
        assertEq(intake.nonce(), 2);
    }

    function test_newPlaygroundCanBeCreatedWhileItsLaunchesAreDisabled() public {
        vm.prank(admin);
        factory.setLaunchesEnabled(false);
        vm.prank(carol);
        Playground thirdHub = factory.createPlayground();
        assertEq(factory.playgroundCount(), 3);
        assertEq(thirdHub.owner(), carol);
        assertTrue(thirdHub.isMember(carol));
        assertEq(thirdHub.factory(), address(factory));
        vm.startPrank(carol);
        vm.expectRevert(Playground.LaunchesDisabled.selector);
        thirdHub.createProject();
        vm.expectRevert(Playground.LaunchesDisabled.selector);
        thirdHub.requestProject(bytes32("launch"), "new", address(token), 1 ether);
        vm.stopPrank();
        assertEq(thirdHub.projectCount(), 0);

        vm.prank(admin);
        factory.setLaunchesEnabled(true);
        vm.prank(carol);
        thirdHub.createProject();
        assertEq(thirdHub.projectCount(), 1);
    }

    function test_existingIntakePayerResumesAfterPauseWithoutRedeployment() public {
        vm.prank(alice);
        bytes32 firstRequest = firstHub.requestProject(firstId, bytes32("launch"), "first", address(token), 1 ether);
        uint64 nonceBefore = vm.getNonce(address(firstHub));
        vm.prank(admin);
        factory.setLaunchesEnabled(false);
        vm.prank(alice);
        vm.expectRevert(Playground.LaunchesDisabled.selector);
        firstHub.requestProject(firstId, bytes32("continue"), "paused", address(token), 1 ether);
        assertEq(token.balanceOf(alice), 19 ether);
        assertEq(token.balanceOf(address(intake)), 1 ether);
        assertEq(intake.nonce(), 1);

        vm.prank(admin);
        factory.setLaunchesEnabled(true);
        vm.prank(alice);
        bytes32 secondRequest =
            firstHub.requestProject(firstId, bytes32("continue"), "resumed", address(token), 1 ether);
        assertEq(intake.lastRequester(), firstReceiver);
        assertEq(firstHub.projectCount(), 1);
        assertEq(vm.getNonce(address(firstHub)), nonceBefore);
        assertEq(firstHub.requestProjectIds(address(intake), firstRequest), firstId);
        assertEq(firstHub.requestProjectIds(address(intake), secondRequest), firstId);
        assertEq(token.balanceOf(alice), 18 ether);
        assertEq(token.balanceOf(address(intake)), 2 ether);
    }

    function test_replacingIntakeCannotBypassFactoryLaunchPause() public {
        PlaygroundTestIntake replacement = new PlaygroundTestIntake();
        vm.prank(admin);
        factory.setLaunchesEnabled(false);
        vm.startPrank(alice);
        firstHub.setIntake(address(replacement));
        vm.expectRevert(Playground.LaunchesDisabled.selector);
        firstHub.requestProject(bytes32("launch"), "new", address(token), 1 ether);
        vm.expectRevert(Playground.LaunchesDisabled.selector);
        firstHub.requestProject(firstId, bytes32("continue"), "existing", address(token), 1 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 20 ether);
        assertEq(token.balanceOf(firstReceiver), 0);
        assertEq(replacement.nonce(), 0);
        vm.prank(admin);
        factory.setLaunchesEnabled(true);
        vm.prank(alice);
        firstHub.requestProject(firstId, bytes32("continue"), "resumed", address(token), 1 ether);
        assertEq(replacement.nonce(), 1);
        assertEq(replacement.lastRequester(), firstReceiver);
        assertEq(intake.nonce(), 0);
    }

    function test_unavailableOrRevertingFactoryFailsClosedWithoutBlockingRevenue() public {
        vm.etch(address(factory), "");
        vm.startPrank(alice);
        vm.expectRevert();
        firstHub.createProject();
        vm.expectRevert();
        firstHub.requestProject(firstId, bytes32("continue"), "existing", address(token), 1 ether);
        vm.stopPrank();
        firstHub.deposit{value: 10 ether}(firstId);
        firstHub.claimFor(alice);
        assertEq(alice.balance, 8 ether);

        // Runtime that unconditionally reverts simulates a failed policy read.
        vm.etch(address(factory), hex"60006000fd");
        vm.startPrank(bob);
        vm.expectRevert();
        secondHub.createProject();
        vm.expectRevert();
        secondHub.requestProject(bytes32("launch"), "new", address(token), 1 ether);
        vm.stopPrank();
        secondHub.deposit{value: 10 ether}(secondId);
        secondHub.claimFor(bob);
        assertEq(bob.balance, 8 ether);
        assertEq(firstHub.projectCount(), 1);
        assertEq(secondHub.projectCount(), 1);
        assertEq(token.balanceOf(alice), 20 ether);
        assertEq(token.balanceOf(bob), 20 ether);
        assertEq(intake.nonce(), 0);
    }

    function test_pausingBothFlagsPreservesRevenueClaimsMembershipMetadataAndSwaps() public {
        vm.startPrank(admin);
        factory.setLaunchesEnabled(false);
        factory.setPlaygroundCreationEnabled(false);
        vm.stopPrank();
        (bool sent,) = firstReceiver.call{value: 10 ether}("");
        assertTrue(sent);
        PlaygroundProject project = PlaygroundProject(payable(firstReceiver));
        project.depositETH();
        assertEq(firstHub.claimable(alice), 8 ether);
        assertEq(address(sink).balance, 2 ether);
        firstHub.claimFor(alice);
        assertEq(alice.balance, 8 ether);

        vm.startPrank(alice);
        firstHub.inviteMember(bob);
        firstHub.setMetadata("Still active", "", "", "", "", "");
        vm.stopPrank();
        vm.prank(bob);
        firstHub.acceptInvitation();
        assertTrue(firstHub.isMember(bob));
        (string memory name,,,,,) = firstHub.metadata();
        assertEq(name, "Still active");

        ProjectTestAdapter adapter = new ProjectTestAdapter();
        vm.deal(address(adapter), 2 ether);
        token.mint(firstReceiver, 1 ether);
        vm.prank(alice);
        project.configureSwap(address(token), address(adapter));
        vm.prank(bob);
        project.swapToETH(address(token), 1 ether, 2 ether, block.timestamp);
        assertEq(bob.balance, 0.01 ether);
        assertEq(firstHub.claimable(alice), 0.995 ether);
        assertEq(firstHub.claimable(bob), 0.597 ether);
        assertEq(address(sink).balance, 2.398 ether);
        firstHub.claimFor(alice);
        firstHub.claimFor(bob);
        assertEq(alice.balance, 8.995 ether);
        assertEq(bob.balance, 0.607 ether);
        assertEq(firstHub.accountedETH(), 0);
        assertEq(token.balanceOf(firstReceiver), 0);
        assertFalse(factory.launchesEnabled());
        assertFalse(factory.playgroundCreationEnabled());
    }

    function _assertAllLaunchPathsBlocked(Playground hub, address member, uint256 id, address receiver) internal {
        uint64 nonceBefore = vm.getNonce(address(hub));
        address predictedReceiver = vm.computeCreateAddress(address(hub), nonceBefore);
        uint256 balanceBefore = token.balanceOf(member);
        uint256 allowanceBefore = token.allowance(member, address(hub));
        vm.startPrank(member);
        vm.expectRevert(Playground.LaunchesDisabled.selector);
        hub.createProject();
        vm.expectRevert(Playground.LaunchesDisabled.selector);
        hub.requestProject(bytes32("launch"), "new", address(token), 1 ether);
        vm.expectRevert(Playground.LaunchesDisabled.selector);
        hub.requestProject(id, bytes32("continue"), "existing", address(token), 1 ether);
        vm.stopPrank();
        assertEq(hub.projectCount(), 1);
        assertEq(vm.getNonce(address(hub)), nonceBefore);
        assertEq(predictedReceiver.code.length, 0);
        assertEq(token.balanceOf(member), balanceBefore);
        assertEq(token.allowance(member, address(hub)), allowanceBefore);
        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.allowance(receiver, address(intake)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
    }
}
