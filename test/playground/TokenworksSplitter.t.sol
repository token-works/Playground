// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {TokenworksSplitter} from "../../src/playground/TokenworksSplitter.sol";
import {PlaygroundHolderSplitter} from "../../src/playground/PlaygroundHolderSplitter.sol";

contract TokenworksRecordingRecipient {
    uint256 public received;
    bool public rejecting;
    TokenworksSplitter public target;
    bool public allReentriesBlocked;

    function configure(bool rejecting_, TokenworksSplitter target_) external {
        rejecting = rejecting_;
        target = target_;
    }

    function redirect(TokenworksSplitter router, address recipient) external {
        router.claimTokenworksTo(recipient);
    }

    receive() external payable {
        require(!rejecting, "rejecting recipient");
        received += msg.value;
        if (address(target) != address(0)) {
            bool claimBlocked = _blocked(abi.encodeCall(target.claimTokenworks, ()));
            bool redirectBlocked = _blocked(abi.encodeCall(target.claimTokenworksTo, (address(0x1234))));
            bool surplusBlocked = _blocked(abi.encodeCall(target.distributeSurplus, ()));
            bool depositBlocked = _blocked("");
            allReentriesBlocked = claimBlocked && redirectBlocked && surplusBlocked && depositBlocked;
        }
    }

    function _blocked(bytes memory data) private returns (bool) {
        (bool success, bytes memory result) = address(target).call(data);
        return !success && result.length == 4 && bytes4(result) == ReentrancyGuard.Reentrancy.selector;
    }
}

contract TokenworksForceETH {
    constructor(address recipient) payable {
        selfdestruct(payable(recipient));
    }
}

contract TokenworksSplitterTest is Test {
    address internal tokenworks = makeAddr("tokenworks");
    address internal recipient = makeAddr("recipient");
    TokenworksRecordingRecipient internal holder;
    TokenworksSplitter internal splitter;

    function setUp() public {
        vm.deal(address(this), 100 ether);
        holder = new TokenworksRecordingRecipient();
        splitter = new TokenworksSplitter(tokenworks, address(holder));
    }

    function _send(TokenworksSplitter destination, uint256 amount) internal {
        (bool success,) = address(destination).call{value: amount}("");
        assertTrue(success);
    }

    function testAnyoneCanDepositAndClaimToFixedDestinations() public {
        _send(splitter, 20 ether);
        assertEq(splitter.tokenworksRecipient(), tokenworks);
        assertEq(splitter.holderSplitter(), address(holder));
        assertEq(holder.received(), 5 ether);
        assertEq(splitter.totalReceived(), 20 ether);
        assertEq(splitter.totalHolderPaid(), 5 ether);
        assertEq(splitter.pendingTokenworks(), 15 ether);
        assertEq(tokenworks.balance, 0);
        vm.prank(recipient);
        assertEq(splitter.claimTokenworks(), 15 ether);
        assertEq(tokenworks.balance, 15 ether);
        assertEq(recipient.balance, 0);
        assertEq(splitter.totalTokenworksClaimed(), 15 ether);
        assertEq(splitter.pendingTokenworks(), 0);
        assertEq(address(splitter).balance, 0);
        vm.expectRevert(TokenworksSplitter.NothingToClaim.selector);
        splitter.claimTokenworks();
    }

    function testRepeatedOneWeiDepositsAndClaimsPreserveHolderShare() public {
        for (uint256 i = 1; i <= 100; ++i) {
            _send(splitter, 1);
            if (splitter.pendingTokenworks() != 0) splitter.claimTokenworks();
            assertEq(holder.received(), i / 4);
            assertEq(tokenworks.balance, i - i / 4);
            assertEq(address(splitter).balance, 0);
        }
    }

    function testOnlyTokenworksCanRedirectItsClaimAndDestinationStaysFixed() public {
        _send(splitter, 4 ether);
        vm.prank(recipient);
        vm.expectRevert(TokenworksSplitter.Unauthorized.selector);
        splitter.claimTokenworksTo(recipient);
        vm.prank(tokenworks);
        splitter.claimTokenworksTo(recipient);
        assertEq(recipient.balance, 3 ether);
        assertEq(splitter.tokenworksRecipient(), tokenworks);
        _send(splitter, 4 ether);
        splitter.claimTokenworks();
        assertEq(tokenworks.balance, 3 ether);
        assertEq(holder.received(), 2 ether);
    }

    function testRejectingTokenworksCannotBlockDepositsAndCanRecoverOwnShare() public {
        TokenworksRecordingRecipient rejecting = new TokenworksRecordingRecipient();
        rejecting.configure(true, TokenworksSplitter(payable(address(0))));
        TokenworksSplitter router = new TokenworksSplitter(address(rejecting), address(holder));
        _send(router, 4 ether);
        assertEq(holder.received(), 1 ether);
        assertEq(router.pendingTokenworks(), 3 ether);
        vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
        router.claimTokenworks();
        assertEq(router.totalTokenworksClaimed(), 0);
        assertEq(router.pendingTokenworks(), 3 ether);
        rejecting.redirect(router, recipient);
        assertEq(recipient.balance, 3 ether);
        assertEq(router.totalTokenworksClaimed(), 3 ether);
    }

    function testInvalidClaimDestinationsPreserveCredits() public {
        _send(splitter, 4 ether);
        vm.startPrank(tokenworks);
        vm.expectRevert(TokenworksSplitter.InvalidAddress.selector);
        splitter.claimTokenworksTo(address(0));
        vm.expectRevert(TokenworksSplitter.InvalidAddress.selector);
        splitter.claimTokenworksTo(address(splitter));
        vm.stopPrank();
        assertEq(splitter.pendingTokenworks(), 3 ether);
    }

    function testRejectingHolderRevertsReceiptInsteadOfLosingHolderAccounting() public {
        holder.configure(true, TokenworksSplitter(payable(address(0))));
        (bool success, bytes memory reason) = address(splitter).call{value: 4 ether}("");
        assertFalse(success);
        assertEq(bytes4(reason), SafeTransferLib.ETHTransferFailed.selector);
        assertEq(splitter.totalReceived(), 0);
        assertEq(splitter.totalHolderPaid(), 0);
        assertEq(splitter.pendingTokenworks(), 0);
        assertEq(address(splitter).balance, 0);
    }

    function testHolderReceiveCannotReenterAccountingOrClaims() public {
        holder.configure(false, splitter);
        _send(splitter, 4 ether);
        assertTrue(holder.allReentriesBlocked());
        assertEq(holder.received(), 1 ether);
        assertEq(splitter.totalReceived(), 4 ether);
        assertEq(splitter.pendingTokenworks(), 3 ether);
        splitter.claimTokenworks();
        assertEq(tokenworks.balance, 3 ether);
    }

    function testTokenworksReceiveCannotReenterAccountingOrClaims() public {
        TokenworksRecordingRecipient tokenworksContract = new TokenworksRecordingRecipient();
        TokenworksSplitter router = new TokenworksSplitter(address(tokenworksContract), address(holder));
        tokenworksContract.configure(false, router);
        _send(router, 4 ether);
        router.claimTokenworks();
        assertTrue(tokenworksContract.allReentriesBlocked());
        assertEq(tokenworksContract.received(), 3 ether);
        assertEq(holder.received(), 1 ether);
        assertEq(router.pendingTokenworks(), 0);
        assertEq(router.totalTokenworksClaimed(), 3 ether);
    }

    function testForcedETHOnlyDistributesSurplusAndNeverReallocatesTokenworksCredits() public {
        _send(splitter, 8 ether);
        new TokenworksForceETH{value: 4 ether}(address(splitter));
        assertEq(splitter.totalReceived(), 8 ether);
        assertEq(splitter.pendingTokenworks(), 6 ether);
        assertEq(holder.received(), 2 ether);
        vm.prank(recipient);
        assertEq(splitter.distributeSurplus(), 4 ether);
        assertEq(splitter.totalReceived(), 12 ether);
        assertEq(holder.received(), 3 ether);
        assertEq(splitter.pendingTokenworks(), 9 ether);
        vm.expectRevert(TokenworksSplitter.NothingToDistribute.selector);
        splitter.distributeSurplus();
        splitter.claimTokenworks();
        new TokenworksForceETH{value: 4 ether}(address(splitter));
        splitter.distributeSurplus();
        splitter.claimTokenworks();
        assertEq(holder.received(), 4 ether);
        assertEq(tokenworks.balance, 12 ether);
        assertEq(address(splitter).balance, 0);
    }

    function testRegularDepositDoesNotConsumeForcedETHUntilDistribution() public {
        new TokenworksForceETH{value: 4 ether}(address(splitter));
        _send(splitter, 4 ether);
        assertEq(splitter.totalReceived(), 4 ether);
        splitter.claimTokenworks();
        assertEq(tokenworks.balance, 3 ether);
        assertEq(address(splitter).balance, 4 ether);
        splitter.distributeSurplus();
        assertEq(holder.received(), 2 ether);
        assertEq(splitter.pendingTokenworks(), 3 ether);
    }

    function testZeroReceiptLeavesCreditsUnchanged() public {
        _send(splitter, 4 ether);
        _send(splitter, 0);
        assertEq(splitter.totalReceived(), 4 ether);
        assertEq(splitter.pendingTokenworks(), 3 ether);
        vm.expectRevert(TokenworksSplitter.NothingToDistribute.selector);
        splitter.distributeSurplus();
    }

    function testRealHolderSplitterAccountsForForwardingAndCanClaim() public {
        address alice = address(0x100);
        address bob = address(0x200);
        PlaygroundHolderSplitter holders = new PlaygroundHolderSplitter(
            tokenworks,
            PlaygroundHolderSplitter.Snapshot(100, bytes32(uint256(123)), 3, 4),
            abi.encodePacked(alice, uint32(2), bob, uint32(1))
        );
        TokenworksSplitter router = new TokenworksSplitter(tokenworks, address(holders));
        _send(router, 12 ether);
        assertEq(holders.totalReceived(), 3 ether);
        assertEq(holders.pending(alice), 2 ether);
        assertEq(holders.pending(bob), 1 ether);
        holders.claimFor(alice);
        holders.claimFor(bob);
        assertEq(alice.balance, 2 ether);
        assertEq(bob.balance, 1 ether);
        router.claimTokenworks();
        assertEq(tokenworks.balance, 9 ether);
    }

    function testHolderSweepClosureStillAllowsNewReceiptsToRemainSweepable() public {
        PlaygroundHolderSplitter holders = new PlaygroundHolderSplitter(
            tokenworks,
            PlaygroundHolderSplitter.Snapshot(100, bytes32(uint256(123)), 1, 1),
            abi.encodePacked(recipient, uint32(1))
        );
        TokenworksSplitter router = new TokenworksSplitter(tokenworks, address(holders));
        _send(router, 4 ether);
        vm.warp(holders.SWEEP_AVAILABLE_AT());
        vm.prank(tokenworks);
        holders.sweep();
        _send(router, 4 ether);
        assertEq(holders.totalReceived(), 1 ether);
        assertEq(address(holders).balance, 1 ether);
        assertEq(router.totalHolderPaid(), 2 ether);
        vm.prank(tokenworks);
        holders.sweep();
        router.claimTokenworks();
        assertEq(tokenworks.balance, 8 ether);
    }

    function testFuzzDepositsClaimsAndForcedETHConserveEveryWei(uint96 first, uint96 second, uint96 forced) public {
        first = uint96(bound(first, 0, 40 ether));
        second = uint96(bound(second, 0, 40 ether));
        forced = uint96(bound(forced, 0, 20 ether));
        _send(splitter, first);
        if (splitter.pendingTokenworks() != 0) splitter.claimTokenworks();
        new TokenworksForceETH{value: forced}(address(splitter));
        _send(splitter, second);
        if (splitter.pendingTokenworks() != 0) splitter.claimTokenworks();
        if (forced != 0) splitter.distributeSurplus();
        if (splitter.pendingTokenworks() != 0) splitter.claimTokenworks();
        uint256 total = uint256(first) + second + forced;
        assertEq(splitter.totalReceived(), total);
        assertEq(holder.received(), total / 4);
        assertEq(tokenworks.balance, total - total / 4);
        assertEq(splitter.totalHolderPaid(), holder.received());
        assertEq(splitter.totalTokenworksClaimed(), tokenworks.balance);
        assertEq(address(splitter).balance, 0);
        vm.expectRevert(TokenworksSplitter.NothingToDistribute.selector);
        splitter.distributeSurplus();
    }

    function testRejectsInvalidDestinations() public {
        vm.expectRevert(TokenworksSplitter.InvalidAddress.selector);
        new TokenworksSplitter(address(0), address(holder));
        vm.expectRevert(TokenworksSplitter.InvalidAddress.selector);
        new TokenworksSplitter(tokenworks, address(0));
        vm.expectRevert(TokenworksSplitter.InvalidAddress.selector);
        new TokenworksSplitter(tokenworks, recipient);
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(TokenworksSplitter.InvalidAddress.selector);
        new TokenworksSplitter(next, address(holder));
        next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(TokenworksSplitter.InvalidAddress.selector);
        new TokenworksSplitter(tokenworks, next);
    }
}
