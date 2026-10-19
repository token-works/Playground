// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlaygroundLaunchControllerMock} from "./helpers/PlaygroundLaunchControllerMock.sol";
import {PlaygroundHolderSplitter as Splitter} from "../../src/playground/PlaygroundHolderSplitter.sol";
import {TokenworksSplitter} from "../../src/playground/TokenworksSplitter.sol";
import {Playground} from "../../src/playground/Playground.sol";

contract HolderIntakeMock {}

contract PlaygroundHolderSplitterTest is Test {
    address internal constant ALICE = address(0x100);
    address internal constant BOB = address(0x200);
    address internal owner = makeAddr("owner");
    Splitter internal splitter;
    PlaygroundLaunchControllerMock internal launchController;

    function config() internal pure returns (Splitter.Snapshot memory) {
        return Splitter.Snapshot(100, bytes32(uint256(123)), 3, 4);
    }

    function weights() internal pure returns (bytes memory) {
        return abi.encodePacked(ALICE, uint32(2), BOB, uint32(1));
    }

    function setUp() public {
        launchController = new PlaygroundLaunchControllerMock();
        vm.warp(1_800_000_000);
        vm.deal(address(this), 100 ether);
        splitter = new Splitter(owner, config(), weights());
    }

    function sendETH(uint256 amount) internal {
        (bool ok,) = address(splitter).call{value: amount}("");
        assertTrue(ok);
    }

    function testWeightedClaimsAcrossDepositsAndRedirect() public {
        sendETH(3 ether);
        assertEq(splitter.pending(ALICE), 2 ether);
        vm.prank(ALICE);
        splitter.claimTo(BOB);
        assertEq(BOB.balance, 2 ether);
        sendETH(6 ether);
        splitter.claimFor(ALICE);
        splitter.claimFor(BOB);
        assertEq(ALICE.balance, 4 ether);
        assertEq(BOB.balance, 5 ether);
        assertEq(splitter.totalClaimed(), 9 ether);
        assertEq(address(splitter).balance, 0);
        vm.prank(ALICE);
        vm.expectRevert(Splitter.NothingToClaim.selector);
        splitter.claim();
    }

    function testNonHolderCannotRedirectOthersClaims() public {
        sendETH(3 ether);
        vm.expectRevert(Splitter.NothingToClaim.selector);
        splitter.claimTo(address(this));
        splitter.claimFor(ALICE);
        assertEq(ALICE.balance, 2 ether);
    }

    function testRejectsInvalidClaimRecipient() public {
        sendETH(3 ether);
        vm.prank(ALICE);
        vm.expectRevert(Splitter.InvalidAddress.selector);
        splitter.claimTo(address(0));
        vm.prank(ALICE);
        vm.expectRevert(Splitter.InvalidAddress.selector);
        splitter.claimTo(address(splitter));
    }

    function testFuzzRoundingAndCumulativeClaims(uint96 first, uint96 second) public {
        first = uint96(bound(first, 3, 30 ether));
        second = uint96(bound(second, 3, 30 ether));
        sendETH(first);
        splitter.claimFor(ALICE);
        splitter.claimFor(BOB);
        sendETH(second);
        splitter.claimFor(ALICE);
        splitter.claimFor(BOB);
        uint256 total = uint256(first) + second;
        assertEq(ALICE.balance, total * 2 / 3);
        assertEq(BOB.balance, total / 3);
        assertEq(address(splitter).balance + splitter.totalClaimed(), total);
        assertLe(address(splitter).balance, 1);
    }

    function testSweepDeadlineAndPermanentClosure() public {
        sendETH(3 ether);
        vm.prank(owner);
        vm.expectRevert(Splitter.SweepNotAvailable.selector);
        splitter.sweep();
        vm.warp(splitter.SWEEP_AVAILABLE_AT());
        // Expiry alone does not close claims.
        splitter.claimFor(BOB);
        vm.expectRevert();
        splitter.sweep();
        vm.prank(owner);
        splitter.sweep();
        assertEq(owner.balance, 2 ether);
        assertTrue(splitter.claimsClosed());
        assertEq(splitter.pending(ALICE), 0);
        vm.expectRevert(Splitter.ClaimsClosed.selector);
        splitter.claimFor(ALICE);
        sendETH(6 ether);
        assertEq(splitter.totalReceived(), 3 ether);
        vm.prank(owner);
        splitter.sweep();
        assertEq(owner.balance, 8 ether);
    }

    function testEmptySweepDoesNotCloseAndNewOwnerCanSweep() public {
        vm.warp(splitter.SWEEP_AVAILABLE_AT());
        vm.prank(owner);
        vm.expectRevert(Splitter.NothingToClaim.selector);
        splitter.sweep();
        assertFalse(splitter.claimsClosed());
        sendETH(3 ether);
        vm.prank(owner);
        splitter.transferOwnership(BOB);
        assertEq(splitter.pending(ALICE), 2 ether);
        vm.prank(BOB);
        splitter.sweep();
        assertEq(BOB.balance, 3 ether);
    }

    function testForcedETHIsSweepableResidue() public {
        vm.deal(address(splitter), 1 ether);
        assertEq(splitter.pending(ALICE), 0);
        vm.warp(splitter.SWEEP_AVAILABLE_AT());
        vm.prank(owner);
        splitter.sweep();
        assertEq(owner.balance, 1 ether);
    }

    function testRejectsMalformedAllocations() public {
        vm.expectRevert(Splitter.InvalidAllocations.selector);
        new Splitter(owner, config(), hex"");
        vm.expectRevert(Splitter.InvalidAllocations.selector);
        new Splitter(owner, config(), hex"01");
        vm.expectRevert(Splitter.InvalidAllocations.selector);
        new Splitter(owner, config(), abi.encodePacked(ALICE, uint32(1), ALICE, uint32(2)));
        vm.expectRevert(Splitter.InvalidAllocations.selector);
        new Splitter(owner, config(), abi.encodePacked(BOB, uint32(1), ALICE, uint32(2)));
        vm.expectRevert(Splitter.InvalidAllocations.selector);
        new Splitter(owner, config(), abi.encodePacked(address(0), uint32(3)));
        vm.expectRevert(Splitter.InvalidAllocations.selector);
        new Splitter(owner, config(), abi.encodePacked(ALICE, uint32(0), BOB, uint32(3)));
        vm.expectRevert(Splitter.InvalidAllocations.selector);
        new Splitter(owner, config(), abi.encodePacked(ALICE, uint32(2)));
    }

    function testRejectsInvalidSnapshotAndOwner() public {
        vm.expectRevert(Splitter.InvalidAddress.selector);
        new Splitter(address(0), config(), weights());
        Splitter.Snapshot memory snap = config();
        snap.blockHash = 0;
        vm.expectRevert(Splitter.InvalidSnapshot.selector);
        new Splitter(owner, snap, weights());
        snap = config();
        snap.maxTokenId = 2;
        vm.expectRevert(Splitter.InvalidSnapshot.selector);
        new Splitter(owner, snap, weights());
    }

    function testRobinhoodHubRoutesFivePercentWithoutNFTContract() public {
        vm.chainId(4663);
        assertEq(splitter.NFT_ADDRESS().code.length, 0);
        TokenworksSplitter router = new TokenworksSplitter(owner, address(splitter));
        Playground hub =
            new Playground(owner, address(new HolderIntakeMock()), address(router), address(launchController));
        Splitter destination = splitter;
        vm.prank(owner);
        hub.inviteMember(ALICE);
        vm.prank(ALICE);
        hub.acceptInvitation();
        vm.prank(ALICE);
        (uint256 id,) = hub.createProject();
        hub.deposit{value: 60 ether}(id);
        assertEq(destination.totalReceived(), 3 ether);
        assertEq(destination.pending(ALICE), 2 ether);
        assertEq(destination.pending(BOB), 1 ether);
        assertEq(hub.claimable(ALICE), 30 ether);
        assertEq(hub.claimable(owner), 18 ether);
        assertEq(router.pendingTokenworks(), 9 ether);
        assertEq(destination.owner(), owner);
        assertEq(destination.ALLOCATION_HASH(), keccak256(weights()));
    }

    function testHubRejectsMissingSplitterButAllowsIndependentOwner() public {
        address intake = address(new HolderIntakeMock());
        vm.expectRevert(Playground.InvalidAddress.selector);
        new Playground(owner, intake, ALICE, address(launchController));
        Playground hub = new Playground(BOB, intake, address(splitter), address(launchController));
        assertEq(hub.owner(), BOB);
        assertEq(splitter.owner(), owner);
    }
}
