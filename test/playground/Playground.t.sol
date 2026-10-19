// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlaygroundLaunchControllerMock} from "./helpers/PlaygroundLaunchControllerMock.sol";
import {Playground} from "../../src/playground/Playground.sol";
import {PlaygroundProject} from "../../src/playground/PlaygroundProject.sol";
import {IPlaygroundIntake} from "../../src/playground/interfaces/IPlaygroundIntake.sol";

contract PlaygroundTestToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public chargeFee;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function setChargeFee(bool enabled) external {
        chargeFee = enabled;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += chargeFee && amount != 0 ? amount - 1 : amount;
    }
}

contract PlaygroundTestIntake is IPlaygroundIntake {
    address public lastRequester;
    address public lastAsset;
    uint256 public lastAmount;
    bytes32 public lastAction;
    bytes public lastBody;
    address public lastCallbackTarget;
    bytes4 public lastCallbackSelector;
    uint256 public nonce;
    bytes32 public forcedRequestId;
    bool public returnZero;
    bool public shouldRevert;
    bool public overrideSpend;
    uint256 public spendAmount;
    uint256 public lastApprovedAllowance;

    function configure(bytes32 requestId_, bool returnZero_, bool shouldRevert_) external {
        forcedRequestId = requestId_;
        returnZero = returnZero_;
        shouldRevert = shouldRevert_;
    }

    function setSpendAmount(uint256 amount) external {
        overrideSpend = true;
        spendAmount = amount;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        returns (bytes32 requestId)
    {
        require(!shouldRevert, "INTAKE_REVERT");
        lastRequester = msg.sender;
        lastAsset = asset;
        lastAmount = amount;
        lastAction = action;
        lastBody = body;
        lastCallbackTarget = callback.target;
        lastCallbackSelector = callback.selector;
        lastApprovedAllowance = PlaygroundTestToken(asset).allowance(msg.sender, address(this));
        uint256 amountToSpend = overrideSpend ? spendAmount : amount;
        if (amountToSpend != 0) PlaygroundTestToken(asset).transferFrom(msg.sender, address(this), amountToSpend);
        ++nonce;
        if (returnZero) return bytes32(0);
        if (forcedRequestId != bytes32(0)) return forcedRequestId;
        return bytes32(nonce);
    }
}

contract PlaygroundRevenueSink {
    receive() external payable {}
}

contract PlaygroundRejectingRecipient {
    receive() external payable {
        revert("NO_ETH");
    }
}

contract PlaygroundReentrantRecipient {
    Playground public immutable playground;
    bool public attemptedReentry;
    bool public reentrySucceeded;

    constructor(Playground playground_) {
        playground = playground_;
    }

    receive() external payable {
        attemptedReentry = true;
        (reentrySucceeded,) = address(playground).call(abi.encodeCall(Playground.claim, ()));
    }
}

contract PlaygroundTest is Test {
    event SwapCallerSet(address indexed caller, bool allowed);
    event MemberInvited(address indexed member);
    event MemberInvitationRevoked(address indexed member);
    event MemberAdded(address indexed member, uint256 memberCount);
    event ProjectCreated(uint256 indexed projectId, address indexed creator, address indexed receiver);
    event ProjectRequestSubmitted(
        uint256 indexed projectId,
        address indexed requestIntake,
        bytes32 indexed requestId,
        bytes32 action,
        address paymentAsset,
        uint256 amount
    );

    Playground internal playground;
    PlaygroundLaunchControllerMock internal launchController;
    PlaygroundRevenueSink internal tokenworksSplitter;
    PlaygroundTestIntake internal intake;
    PlaygroundTestToken internal token;
    address internal ownerWallet = makeAddr("playground owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal outsider = makeAddr("outsider");
    uint256 internal projectId;
    address internal receiver;

    function setUp() public {
        launchController = new PlaygroundLaunchControllerMock();
        intake = new PlaygroundTestIntake();
        token = new PlaygroundTestToken();
        tokenworksSplitter = new PlaygroundRevenueSink();
        playground =
            new Playground(ownerWallet, address(intake), address(tokenworksSplitter), address(launchController));
        _addMember(alice);
        vm.prank(alice);
        (projectId, receiver) = playground.createProject();
        vm.deal(address(this), 1_000_000 ether);
    }

    function test_constructorRequiresValidOwnerAndIntake() public {
        vm.expectRevert(Playground.InvalidAddress.selector);
        new Playground(address(0), address(intake), address(tokenworksSplitter), address(launchController));
        vm.expectRevert(Playground.InvalidIntake.selector);
        new Playground(ownerWallet, outsider, address(tokenworksSplitter), address(launchController));
        vm.expectRevert(Playground.InvalidIntake.selector);
        new Playground(ownerWallet, address(0), address(tokenworksSplitter), address(launchController));
        Playground fresh =
            new Playground(ownerWallet, address(intake), address(tokenworksSplitter), address(launchController));
        assertEq(fresh.owner(), ownerWallet);
        assertEq(fresh.memberCount(), 1);
        assertTrue(fresh.isMember(ownerWallet));
        assertEq(fresh.tokenworksSplitter(), address(tokenworksSplitter));
        assertEq(fresh.factory(), address(launchController));
        vm.expectRevert(Playground.InvalidAddress.selector);
        new Playground(ownerWallet, address(intake), address(0), address(launchController));
        vm.expectRevert(Playground.InvalidAddress.selector);
        new Playground(ownerWallet, address(intake), outsider, address(launchController));
        vm.expectRevert(Playground.InvalidAddress.selector);
        new Playground(ownerWallet, address(intake), address(tokenworksSplitter), address(0));
        vm.expectRevert(Playground.InvalidAddress.selector);
        new Playground(ownerWallet, address(intake), address(tokenworksSplitter), outsider);
        vm.prank(ownerWallet);
        fresh.createProject();
        assertEq(fresh.projectCount(), 1);
    }

    function test_onlyOwnerManagesMembershipAndIntake() public {
        vm.startPrank(outsider);
        vm.expectRevert();
        playground.inviteMember(bob);
        vm.expectRevert();
        playground.removeMember(alice);
        vm.expectRevert();
        playground.setIntake(address(intake));
        vm.stopPrank();

        vm.startPrank(ownerWallet);
        vm.expectRevert(Playground.AlreadyMember.selector);
        playground.inviteMember(alice);
        vm.expectRevert(Playground.UnknownMember.selector);
        playground.removeMember(bob);
        vm.expectRevert(Playground.InvalidAddress.selector);
        playground.inviteMember(address(0));
        vm.expectRevert(Playground.InvalidAddress.selector);
        playground.inviteMember(address(playground));
        vm.expectRevert(Playground.InvalidIntake.selector);
        playground.setIntake(outsider);
        playground.inviteMember(bob);
        assertEq(playground.memberCount(), 2);
        assertTrue(playground.isInvited(bob));
        assertFalse(playground.isMember(bob));
        playground.removeMember(alice);
        assertEq(playground.memberCount(), 1);
        assertFalse(playground.isMember(alice));
        vm.stopPrank();
        vm.prank(bob);
        playground.acceptInvitation();
        assertEq(playground.memberCount(), 2);
        assertTrue(playground.isMember(bob));
    }

    function test_onlyOwnerCanInviteAndRevokeWhileOnlyInviteeCanAccept() public {
        vm.prank(outsider);
        vm.expectRevert();
        playground.inviteMember(bob);
        vm.prank(alice);
        vm.expectRevert();
        playground.inviteMember(bob);
        vm.prank(ownerWallet);
        vm.expectEmit(true, false, false, true, address(playground));
        emit MemberInvited(bob);
        playground.inviteMember(bob);

        vm.prank(outsider);
        vm.expectRevert();
        playground.revokeInvitation(bob);
        vm.prank(alice);
        vm.expectRevert();
        playground.revokeInvitation(bob);
        vm.prank(ownerWallet);
        vm.expectRevert(Playground.NotInvited.selector);
        playground.acceptInvitation();
        vm.prank(outsider);
        vm.expectRevert(Playground.NotInvited.selector);
        playground.acceptInvitation();
        assertTrue(playground.isInvited(bob));
        assertEq(playground.memberCount(), 2);

        vm.prank(bob);
        vm.expectEmit(true, false, false, true, address(playground));
        emit MemberAdded(bob, 3);
        playground.acceptInvitation();
        assertTrue(playground.isMember(bob));
        assertFalse(playground.isInvited(bob));
        assertEq(playground.memberCount(), 3);
        vm.prank(bob);
        vm.expectRevert(Playground.NotInvited.selector);
        playground.acceptInvitation();
        assertEq(playground.memberCount(), 3);
    }

    function test_pendingInvitationGrantsNoMembershipIncomeOrProjectPrivileges() public {
        vm.prank(ownerWallet);
        playground.inviteMember(bob);
        playground.deposit{value: 10 ether}(projectId);
        assertFalse(playground.isMember(bob));
        assertFalse(playground.canSwap(bob));
        assertEq(playground.memberCount(), 2);
        assertEq(playground.claimable(bob), 0);
        assertEq(playground.claimable(ownerWallet), 3 ether);
        vm.startPrank(bob);
        vm.expectRevert(Playground.NotMember.selector);
        playground.createProject();
        vm.expectRevert(Playground.NotMember.selector);
        playground.requestProject(bytes32(0), "", address(token), 1);
        vm.expectRevert(Playground.NothingToClaim.selector);
        playground.claim();
        playground.acceptInvitation();
        vm.stopPrank();

        assertEq(playground.claimable(bob), 0);
        assertTrue(playground.canSwap(bob));
        playground.deposit{value: 10 ether}(projectId);
        assertEq(playground.claimable(bob), 1.5 ether);
        assertEq(playground.claimable(ownerWallet), 4.5 ether);
        assertEq(playground.claimable(alice), 10 ether);
        vm.prank(bob);
        (uint256 bobProject,) = playground.createProject();
        assertEq(bobProject, projectId + 1);
    }

    function test_duplicateInvitationsAreRejectedAndRevocationAllowsReinviting() public {
        vm.startPrank(ownerWallet);
        playground.inviteMember(bob);
        vm.expectRevert(Playground.AlreadyInvited.selector);
        playground.inviteMember(bob);
        vm.expectRevert(Playground.AlreadyMember.selector);
        playground.inviteMember(alice);
        vm.expectEmit(true, false, false, true, address(playground));
        emit MemberInvitationRevoked(bob);
        playground.revokeInvitation(bob);
        assertFalse(playground.isInvited(bob));
        assertEq(playground.memberCount(), 2);
        vm.expectRevert(Playground.NotInvited.selector);
        playground.revokeInvitation(bob);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(Playground.NotInvited.selector);
        playground.acceptInvitation();
        _addMember(bob);
        assertTrue(playground.isMember(bob));
        assertFalse(playground.isInvited(bob));
        vm.prank(ownerWallet);
        vm.expectRevert(Playground.AlreadyMember.selector);
        playground.inviteMember(bob);
    }

    function test_removalRequiresAnotherInvitationBeforeRejoining() public {
        _addMember(bob);
        _removeMember(bob);
        assertFalse(playground.isInvited(bob));
        vm.prank(bob);
        vm.expectRevert(Playground.NotInvited.selector);
        playground.acceptInvitation();
        _addMember(bob);
        assertTrue(playground.isMember(bob));
        assertFalse(playground.isInvited(bob));
        assertEq(playground.memberCount(), 3);
    }

    function test_reinvitationPreservesEarnedCreditAndFractionsButSkipsPendingIncome() public {
        _addMember(bob);
        playground.deposit{value: 12}(projectId);
        _removeMember(bob);
        assertEq(playground.claimable(bob), 1);
        vm.prank(ownerWallet);
        playground.inviteMember(bob);
        playground.deposit{value: 4}(projectId);
        assertEq(playground.claimable(bob), 1);
        vm.prank(bob);
        assertEq(playground.claim(), 1);
        assertTrue(playground.isInvited(bob));
        vm.prank(bob);
        playground.acceptInvitation();
        assertEq(playground.claimable(bob), 0);
        playground.deposit{value: 4}(projectId);
        assertEq(playground.claimable(bob), 1);
        assertEq(playground.claimable(alice), 13);
        assertEq(playground.claimable(ownerWallet), 3);
        playground.claimFor(bob);
        assertEq(bob.balance, 2);
    }

    function test_pendingInvitationsSurviveOwnershipTransfersAndNewOwnerCanRevoke() public {
        vm.startPrank(ownerWallet);
        playground.inviteMember(bob);
        playground.transferOwnership(carol);
        vm.expectRevert();
        playground.revokeInvitation(bob);
        vm.stopPrank();
        assertTrue(playground.isInvited(bob));
        vm.startPrank(carol);
        playground.revokeInvitation(bob);
        playground.inviteMember(bob);
        playground.transferOwnership(outsider);
        vm.stopPrank();
        assertTrue(playground.isInvited(bob));
        vm.prank(bob);
        playground.acceptInvitation();
        assertTrue(playground.isMember(bob));
        assertFalse(playground.isInvited(bob));
        assertEq(playground.owner(), outsider);
        assertTrue(playground.isMember(ownerWallet));
        assertFalse(playground.isMember(carol));
        assertFalse(playground.isMember(outsider));
    }

    function test_revokingInvitationDoesNotRevokeExplicitSwapPermission() public {
        vm.startPrank(ownerWallet);
        playground.setSwapCaller(bob, true);
        playground.inviteMember(bob);
        playground.revokeInvitation(bob);
        vm.stopPrank();
        assertTrue(playground.canSwap(bob));
        assertTrue(playground.swapCallers(bob));
        assertFalse(playground.isMember(bob));
        assertFalse(playground.isInvited(bob));
        playground.deposit{value: 10 ether}(projectId);
        assertEq(playground.claimable(bob), 0);
        assertEq(playground.memberCount(), 2);
        vm.prank(bob);
        vm.expectRevert(Playground.NotMember.selector);
        playground.createProject();
    }

    function test_onlyOwnerCanConfigureSwapCallersAndAddressesMustBeValid() public {
        vm.prank(outsider);
        vm.expectRevert();
        playground.setSwapCaller(bob, true);
        vm.prank(alice);
        vm.expectRevert();
        playground.setSwapCaller(bob, true);

        vm.startPrank(ownerWallet);
        vm.expectRevert(Playground.InvalidAddress.selector);
        playground.setSwapCaller(address(0), true);
        vm.expectRevert(Playground.InvalidAddress.selector);
        playground.setSwapCaller(address(playground), true);
        vm.expectRevert(Playground.InvalidAddress.selector);
        playground.setSwapCaller(address(0), false);
        vm.expectRevert(Playground.InvalidAddress.selector);
        playground.setSwapCaller(address(playground), false);
        vm.stopPrank();
    }

    function test_ownerCanAllowAndRevokeNonmemberSwapCaller() public {
        assertFalse(playground.canSwap(bob));
        assertFalse(playground.swapCallers(bob));
        vm.startPrank(ownerWallet);
        vm.expectEmit(true, false, false, true, address(playground));
        emit SwapCallerSet(bob, true);
        playground.setSwapCaller(bob, true);
        assertTrue(playground.swapCallers(bob));
        assertTrue(playground.canSwap(bob));
        assertFalse(playground.isMember(bob));
        assertEq(playground.memberCount(), 2);
        vm.expectEmit(true, false, false, true, address(playground));
        emit SwapCallerSet(bob, false);
        playground.setSwapCaller(bob, false);
        vm.stopPrank();
        assertFalse(playground.swapCallers(bob));
        assertFalse(playground.canSwap(bob));
    }

    function test_memberSwapPermissionTracksRemovalAndRejoiningImmediately() public {
        assertTrue(playground.canSwap(alice));
        assertFalse(playground.swapCallers(alice));
        _removeMember(alice);
        assertFalse(playground.canSwap(alice));
        _addMember(alice);
        assertTrue(playground.canSwap(alice));
        assertFalse(playground.swapCallers(alice));

        // Removing an explicit permission cannot remove current membership's permission.
        vm.prank(ownerWallet);
        playground.setSwapCaller(alice, false);
        assertTrue(playground.canSwap(alice));
        _removeMember(alice);
        assertFalse(playground.canSwap(alice));
    }

    function test_explicitSwapPermissionSurvivesMembershipRemovalUntilRevoked() public {
        vm.prank(ownerWallet);
        playground.setSwapCaller(alice, true);
        _removeMember(alice);
        assertFalse(playground.isMember(alice));
        assertTrue(playground.swapCallers(alice));
        assertTrue(playground.canSwap(alice));
        vm.prank(ownerWallet);
        playground.setSwapCaller(alice, false);
        assertFalse(playground.canSwap(alice));
        _addMember(alice);
        assertTrue(playground.canSwap(alice));
        assertFalse(playground.swapCallers(alice));
    }

    function test_swapCallerPermissionDoesNotGrantMembershipRevenueOrProjectPrivileges() public {
        vm.prank(ownerWallet);
        playground.setSwapCaller(bob, true);
        assertEq(playground.memberCount(), 2);
        assertFalse(playground.isMember(bob));

        playground.deposit{value: 8 ether}(projectId);
        assertEq(playground.claimable(alice), 4 ether);
        assertEq(playground.claimable(ownerWallet), 2.4 ether);
        assertEq(playground.claimable(bob), 0);
        vm.startPrank(bob);
        vm.expectRevert(Playground.NotMember.selector);
        playground.createProject();
        vm.expectRevert(Playground.NotMember.selector);
        playground.requestProject(bytes32(0), "", address(token), 1);
        vm.expectRevert(Playground.NotProjectCreator.selector);
        playground.requestProject(projectId, bytes32(0), "", address(token), 1);
        vm.expectRevert(Playground.NothingToClaim.selector);
        playground.claim();
        vm.expectRevert();
        playground.inviteMember(bob);
        vm.stopPrank();
    }

    function test_ownershipChangesPreserveExplicitSwapCallersWithoutGrantingPermission() public {
        assertTrue(playground.canSwap(ownerWallet));
        vm.startPrank(ownerWallet);
        playground.setSwapCaller(outsider, true);
        playground.transferOwnership(bob);
        vm.stopPrank();

        assertTrue(playground.canSwap(ownerWallet));
        assertFalse(playground.canSwap(bob));
        assertTrue(playground.swapCallers(outsider));
        assertTrue(playground.canSwap(outsider));
        assertTrue(playground.canSwap(alice));
        vm.prank(ownerWallet);
        vm.expectRevert();
        playground.setSwapCaller(outsider, false);
        vm.prank(bob);
        playground.setSwapCaller(outsider, false);
        assertFalse(playground.canSwap(outsider));
    }

    function test_nonmemberOwnerCanExplicitlyAuthorizeItselfWithoutExtraRewards() public {
        _removeMember(ownerWallet);
        _addMember(carol);
        assertFalse(playground.canSwap(ownerWallet));
        assertFalse(playground.isMember(ownerWallet));
        vm.prank(ownerWallet);
        playground.setSwapCaller(ownerWallet, true);
        assertTrue(playground.canSwap(ownerWallet));
        assertTrue(playground.swapCallers(ownerWallet));
        assertFalse(playground.isMember(ownerWallet));
        assertEq(playground.memberCount(), 2);
        playground.deposit{value: 8 ether}(projectId);
        assertEq(playground.claimable(ownerWallet), 0);
        assertEq(playground.claimable(alice), 4 ether);

        vm.prank(ownerWallet);
        playground.transferOwnership(bob);
        assertTrue(playground.canSwap(ownerWallet));
        assertFalse(playground.canSwap(bob));
    }

    function test_membersCreateDistinctInitializedMinimalProxyReceivers() public {
        vm.prank(outsider);
        vm.expectRevert(Playground.NotMember.selector);
        playground.createProject();
        _addMember(bob);
        vm.prank(bob);
        (uint256 anotherId, address anotherReceiver) = playground.createProject();
        assertEq(anotherId, projectId + 1);
        assertEq(playground.projectCount(), 2);
        (address creator, address storedReceiver) = playground.projects(projectId);
        assertEq(creator, alice);
        assertEq(storedReceiver, receiver);
        (creator, storedReceiver) = playground.projects(anotherId);
        assertEq(creator, bob);
        assertEq(storedReceiver, anotherReceiver);
        assertTrue(receiver != anotherReceiver);
        assertEq(receiver.codehash, anotherReceiver.codehash);
        assertGt(receiver.code.length, 0);
        assertLt(receiver.code.length, 128);
        address implementation = playground.projectImplementation();
        assertGt(implementation.code.length, receiver.code.length);
        assertEq(PlaygroundProject(payable(implementation)).projectId(), type(uint256).max);
        assertEq(PlaygroundProject(payable(receiver)).playground(), address(playground));
        assertEq(PlaygroundProject(payable(receiver)).projectId(), projectId);
        assertEq(PlaygroundProject(payable(anotherReceiver)).playground(), address(playground));
        assertEq(PlaygroundProject(payable(anotherReceiver)).projectId(), anotherId);
        assertEq(intake.nonce(), 0);
    }

    function test_depositsSplitAcrossCreatorOtherMembersAndFixedSplitter() public {
        _addMember(bob);
        playground.deposit{value: 8 ether}(projectId);
        assertEq(playground.claimable(alice), 4 ether);
        assertEq(playground.claimable(bob), 1.2 ether);
        assertEq(playground.claimable(ownerWallet), 1.2 ether);
        assertEq(playground.totalDeposited(), 8 ether);
        assertEq(playground.accountedETH(), 6.4 ether);
        assertEq(playground.totalTokenworksPaid(), 1.6 ether);
        assertEq(address(tokenworksSplitter).balance, 1.6 ether);
        assertEq(alice.balance, 0);
        assertEq(bob.balance, 0);
        playground.deposit{value: 12 ether}(projectId);
        assertEq(playground.totalTokenworksPaid(), 4 ether);
        assertEq(address(tokenworksSplitter).balance, 4 ether);
        assertEq(playground.accountedETH(), 16 ether);
    }

    function test_eachCreatorIsExcludedOnlyFromTheirOwnProjects() public {
        _addMember(bob);
        vm.prank(bob);
        (uint256 bobProject,) = playground.createProject();
        playground.deposit{value: 20 ether}(projectId);
        playground.deposit{value: 20 ether}(bobProject);
        assertEq(playground.claimable(alice), 13 ether);
        assertEq(playground.claimable(bob), 13 ether);
        assertEq(playground.claimable(ownerWallet), 6 ether);
        assertEq(address(tokenworksSplitter).balance, 8 ether);
    }

    function test_creatorExclusionPreservesFractionalEarningsFromOtherProjects() public {
        _addMember(bob);
        vm.prank(bob);
        (uint256 bobProject,) = playground.createProject();
        playground.deposit{value: 4}(projectId);
        playground.deposit{value: 4}(bobProject);
        playground.deposit{value: 4}(projectId);
        playground.deposit{value: 4}(bobProject);
        assertEq(playground.claimable(alice), 7);
        assertEq(playground.claimable(bob), 7);
        assertEq(playground.claimable(ownerWallet), 2);
        playground.claimFor(alice);
        playground.claimFor(bob);
        playground.claimFor(ownerWallet);
        assertEq(playground.accountedETH(), 0);
        assertEq(address(playground).balance, 0);
    }

    function test_roundingResidueGoesToCreator() public {
        _addMember(bob);
        playground.deposit{value: 7}(projectId);
        assertEq(playground.claimable(alice), 4);
        assertEq(playground.claimable(ownerWallet), 1);
        assertEq(playground.claimable(bob), 1);
        playground.deposit{value: 1}(projectId);
        assertEq(playground.claimable(alice), 5);
        assertEq(playground.totalDeposited(), 8);
        assertEq(address(tokenworksSplitter).balance, 1);
    }

    function test_newMembersCannotClaimPastIncome() public {
        playground.deposit{value: 8 ether}(projectId);
        _addMember(bob);
        assertEq(playground.claimable(bob), 0);
        playground.deposit{value: 8 ether}(projectId);
        assertEq(playground.claimable(alice), 8 ether);
        assertEq(playground.claimable(bob), 1.2 ether);
        assertEq(playground.claimable(ownerWallet), 3.6 ether);
    }

    function test_fractionalMemberCreditSurvivesClaimRemovalAndRejoining() public {
        _addMember(bob);
        playground.deposit{value: 12}(projectId);
        vm.prank(bob);
        assertEq(playground.claim(), 1);
        _removeMember(bob);
        playground.deposit{value: 4}(projectId);
        assertEq(playground.claimable(bob), 0);
        _addMember(bob);
        playground.deposit{value: 4}(projectId);
        assertEq(playground.claimable(bob), 1);
        assertEq(playground.claimable(alice), 13);
        assertEq(playground.claimable(ownerWallet), 3);
        playground.claimFor(bob);
        assertEq(bob.balance, 2);
    }

    function test_removedCreatorsKeepCreatorRevenueAndPreviouslyEarnedMemberCredit() public {
        _addMember(bob);
        vm.prank(bob);
        (uint256 bobProject,) = playground.createProject();
        playground.deposit{value: 8 ether}(bobProject);
        _removeMember(alice);
        playground.deposit{value: 8 ether}(projectId);
        assertEq(playground.claimable(alice), 5.2 ether);
        assertEq(playground.claimable(bob), 5.2 ether);
        assertEq(playground.claimable(ownerWallet), 2.4 ether);
        playground.claimFor(alice);
        assertEq(alice.balance, 5.2 ether);
    }

    function test_ownerChangesDoNotRedirectRevenueOrChangeMembership() public {
        playground.deposit{value: 8 ether}(projectId);
        vm.prank(ownerWallet);
        playground.transferOwnership(carol);
        playground.deposit{value: 8 ether}(projectId);
        assertEq(playground.claimable(ownerWallet), 4.8 ether);
        assertEq(playground.claimable(carol), 0);
        assertTrue(playground.isMember(ownerWallet));
        assertFalse(playground.isMember(carol));
        playground.claimFor(ownerWallet);
        assertEq(ownerWallet.balance, 4.8 ether);
        assertEq(playground.owner(), carol);
    }

    function test_creatorOwnerDoesNotReceiveItsOwnMemberShare() public {
        vm.prank(ownerWallet);
        playground.transferOwnership(alice);
        playground.deposit{value: 8 ether}(projectId);
        assertEq(playground.claimable(alice), 4 ether);
        vm.prank(alice);
        assertEq(playground.claim(), 4 ether);
        assertEq(address(playground).balance, 2.4 ether);
        assertEq(playground.accountedETH(), 2.4 ether);
        assertEq(playground.totalClaimed(), 4 ether);
    }

    function test_depositsRequireKnownProjectAndRevenue() public {
        vm.expectRevert(Playground.UnknownProject.selector);
        playground.deposit{value: 1}(projectId + 1);
        vm.expectRevert(Playground.NoRevenue.selector);
        playground.deposit(projectId);
    }

    function test_creatorReceivesUnallocatedMemberShareWhenNoOtherMembersExist() public {
        _removeMember(ownerWallet);
        playground.deposit{value: 10 ether}(projectId);
        assertEq(playground.claimable(alice), 8 ether);
        assertEq(playground.accETHPerMember(), 0);
        _removeMember(alice);
        playground.deposit{value: 10 ether}(projectId);
        assertEq(playground.claimable(alice), 16 ether);
        assertEq(playground.totalTokenworksPaid(), 4 ether);
        _addMember(bob);
        playground.deposit{value: 10 ether}(projectId);
        assertEq(playground.claimable(alice), 21 ether);
        assertEq(playground.claimable(bob), 3 ether);
    }

    function test_claimForCannotRedirectBeneficiaryCredit() public {
        playground.deposit{value: 8 ether}(projectId);
        vm.prank(outsider);
        assertEq(playground.claimFor(alice), 4 ether);
        assertEq(alice.balance, 4 ether);
        assertEq(outsider.balance, 0);
        assertEq(playground.claimable(alice), 0);
        assertEq(playground.accountedETH(), 2.4 ether);
        vm.prank(outsider);
        vm.expectRevert(Playground.NothingToClaim.selector);
        playground.claimTo(outsider);
    }

    function test_beneficiaryCanChooseRecipientButNotZeroOrHub() public {
        playground.deposit{value: 8 ether}(projectId);
        vm.startPrank(alice);
        vm.expectRevert(Playground.InvalidAddress.selector);
        playground.claimTo(address(0));
        vm.expectRevert(Playground.InvalidAddress.selector);
        playground.claimTo(address(playground));
        assertEq(playground.claimTo(bob), 4 ether);
        vm.stopPrank();
        assertEq(bob.balance, 4 ether);
        assertEq(alice.balance, 0);
    }

    function test_failedClaimRetainsCreditAndCanUseDifferentRecipient() public {
        PlaygroundRejectingRecipient rejecting = new PlaygroundRejectingRecipient();
        _addMember(address(rejecting));
        playground.deposit{value: 8 ether}(projectId);
        vm.expectRevert();
        playground.claimFor(address(rejecting));
        assertEq(playground.claimable(address(rejecting)), 1.2 ether);
        assertEq(playground.totalClaimed(), 0);
        assertEq(playground.accountedETH(), 6.4 ether);
        vm.prank(address(rejecting));
        playground.claimTo(bob);
        assertEq(bob.balance, 1.2 ether);
    }

    function test_claimReentrancyCannotWithdrawTwice() public {
        PlaygroundReentrantRecipient attacking = new PlaygroundReentrantRecipient(playground);
        _addMember(address(attacking));
        playground.deposit{value: 8 ether}(projectId);
        playground.claimFor(address(attacking));
        assertTrue(attacking.attemptedReentry());
        assertFalse(attacking.reentrySucceeded());
        assertEq(address(attacking).balance, 1.2 ether);
        assertEq(playground.totalClaimed(), 1.2 ether);
        assertEq(playground.claimable(address(attacking)), 0);
    }

    function test_plainETHRequiresProjectAttribution() public {
        vm.expectRevert(Playground.ProjectRequired.selector);
        payable(address(playground)).transfer(1);
    }

    function test_payableOwnershipHandoverKeepsValueUnaccountedUntilAllocated() public {
        playground.deposit{value: 8 ether}(projectId);
        vm.deal(ownerWallet, 1 ether);
        vm.deal(bob, 1 ether);
        vm.startPrank(bob);
        playground.requestOwnershipHandover{value: 0.5 ether}();
        playground.cancelOwnershipHandover{value: 0.5 ether}();
        playground.requestOwnershipHandover();
        vm.stopPrank();
        vm.prank(ownerWallet);
        playground.completeOwnershipHandover{value: 1 ether}(bob);
        assertEq(playground.owner(), bob);
        assertEq(address(playground).balance, 8.4 ether);
        assertEq(playground.totalDeposited(), 8 ether);
        assertEq(playground.accountedETH(), 6.4 ether);
        assertEq(playground.claimable(ownerWallet), 2.4 ether);
        assertEq(playground.claimable(bob), 0);
        assertEq(playground.claimable(alice), 4 ether);

        vm.prank(bob);
        playground.allocateSurplus(projectId);
        assertEq(playground.totalDeposited(), 10 ether);
        assertEq(playground.accountedETH(), 8 ether);
        assertEq(playground.claimable(ownerWallet), 3 ether);
        assertEq(playground.claimable(bob), 0);
        assertEq(playground.claimable(alice), 5 ether);
        playground.claimFor(ownerWallet);
        assertEq(ownerWallet.balance, 3 ether);
    }

    function test_payableOwnershipTransferTreatsAttachedETHAsSurplus() public {
        playground.deposit{value: 8 ether}(projectId);
        vm.deal(ownerWallet, 4 ether);
        vm.prank(ownerWallet);
        playground.transferOwnership{value: 4 ether}(bob);
        assertEq(playground.owner(), bob);
        assertEq(playground.totalDeposited(), 8 ether);
        assertEq(playground.accountedETH(), 6.4 ether);
        assertEq(address(playground).balance, 10.4 ether);
        vm.prank(bob);
        playground.allocateSurplus(projectId);
        assertEq(playground.claimable(ownerWallet), 3.6 ether);
        assertEq(playground.claimable(bob), 0);
        assertEq(playground.claimable(alice), 6 ether);
        assertEq(playground.totalDeposited(), 12 ether);
        assertEq(playground.accountedETH(), 9.6 ether);
    }

    function test_renouncingOwnershipPreservesDepositsAndClaims() public {
        playground.deposit{value: 8 ether}(projectId);
        vm.deal(ownerWallet, 1 ether);
        vm.prank(ownerWallet);
        playground.renounceOwnership{value: 1 ether}();
        assertEq(playground.owner(), address(0));
        playground.deposit{value: 4 ether}(projectId);
        assertEq(playground.totalDeposited(), 12 ether);
        assertEq(playground.accountedETH(), 9.6 ether);
        assertEq(playground.claimable(address(0)), 0);
        assertEq(playground.claimable(ownerWallet), 3.6 ether);
        assertEq(playground.claimable(alice), 6 ether);
        playground.claimFor(ownerWallet);
        playground.claimFor(alice);
        assertEq(ownerWallet.balance, 3.6 ether);
        assertEq(alice.balance, 6 ether);
        assertEq(playground.accountedETH(), 0);
        assertEq(playground.totalClaimed(), 9.6 ether);
        assertEq(address(playground).balance, 1 ether);
    }

    function test_selfOwnershipDoesNotBlockDepositsOrPriorClaims() public {
        playground.deposit{value: 8 ether}(projectId);
        vm.prank(ownerWallet);
        playground.transferOwnership(address(playground));
        assertEq(playground.owner(), address(playground));
        playground.deposit{value: 4 ether}(projectId);
        assertEq(playground.totalDeposited(), 12 ether);
        assertEq(playground.accountedETH(), 9.6 ether);
        assertEq(playground.claimable(address(playground)), 0);
        playground.claimFor(ownerWallet);
        playground.claimFor(alice);
        assertEq(ownerWallet.balance, 3.6 ether);
        assertEq(alice.balance, 6 ether);
        assertEq(playground.accountedETH(), 0);
        assertEq(playground.totalClaimed(), 9.6 ether);
        assertEq(address(playground).balance, 0);
    }

    function test_surplusAllocationCannotSpendExistingClaimLiabilities() public {
        playground.deposit{value: 8 ether}(projectId);
        vm.deal(address(playground), address(playground).balance + 4 ether);
        assertEq(playground.accountedETH(), 6.4 ether);
        vm.prank(outsider);
        vm.expectRevert();
        playground.allocateSurplus(projectId);
        vm.prank(ownerWallet);
        playground.allocateSurplus(projectId);
        assertEq(playground.totalDeposited(), 12 ether);
        assertEq(playground.accountedETH(), 9.6 ether);
        assertEq(playground.claimable(alice), 6 ether);
        assertEq(playground.claimable(ownerWallet), 3.6 ether);
        assertEq(playground.totalTokenworksPaid(), 2.4 ether);
        assertEq(address(tokenworksSplitter).balance, 2.4 ether);
        vm.prank(ownerWallet);
        vm.expectRevert(Playground.NoRevenue.selector);
        playground.allocateSurplus(projectId);
        playground.claimFor(alice);
        playground.claimFor(ownerWallet);
        assertEq(address(playground).balance, 0);
        assertEq(playground.accountedETH(), 0);
    }

    function test_fractionalMemberReservesAreNotSurplus() public {
        _addMember(bob);
        _addMember(carol);
        playground.deposit{value: 4}(projectId);
        playground.claimFor(alice);
        assertEq(address(playground).balance, 1);
        assertEq(playground.accountedETH(), 1);
        vm.prank(ownerWallet);
        vm.expectRevert(Playground.NoRevenue.selector);
        playground.allocateSurplus(projectId);
    }

    function test_ownerCanSetAllMetadataAndClearIt() public {
        vm.prank(ownerWallet);
        playground.setMetadata(
            "Playground", "A shared studio", "ipfs://image", "ipfs://banner", "https://site.test", "@studio"
        );
        (
            string memory name,
            string memory description,
            string memory image,
            string memory banner,
            string memory website,
            string memory twitter
        ) = playground.metadata();
        assertEq(name, "Playground");
        assertEq(description, "A shared studio");
        assertEq(image, "ipfs://image");
        assertEq(banner, "ipfs://banner");
        assertEq(website, "https://site.test");
        assertEq(twitter, "@studio");
        vm.prank(ownerWallet);
        playground.setMetadata("", "", "", "", "", "");
        (name, description, image, banner, website, twitter) = playground.metadata();
        assertEq(name, "");
        assertEq(description, "");
        assertEq(image, "");
        assertEq(banner, "");
        assertEq(website, "");
        assertEq(twitter, "");
    }

    function test_metadataPermissionsFollowStandardOwnership() public {
        vm.prank(alice);
        vm.expectRevert();
        playground.setMetadata("No", "", "", "", "", "");
        vm.prank(ownerWallet);
        playground.transferOwnership(bob);
        vm.prank(ownerWallet);
        vm.expectRevert();
        playground.setMetadata("No", "", "", "", "", "");
        vm.prank(bob);
        playground.setMetadata("New owner", "", "", "", "", "");
        (string memory name,,,,,) = playground.metadata();
        assertEq(name, "New owner");
        assertEq(playground.tokenworksSplitter(), address(tokenworksSplitter));
        assertEq(playground.memberCount(), 2);
    }

    function test_oneShotRequestCreatesClonePayerWithNoCallbackAndExactTemporaryAllowance() public {
        bytes memory body = abi.encode("project manifest", uint256(42));
        bytes32 action = keccak256("deploy-project");
        address predictedReceiver = vm.computeCreateAddress(address(playground), vm.getNonce(address(playground)));
        token.mint(alice, 20 ether);
        vm.startPrank(alice);
        token.approve(address(playground), 20 ether);
        vm.expectEmit(true, true, true, true, address(playground));
        emit ProjectCreated(projectId + 1, alice, predictedReceiver);
        vm.expectEmit(true, true, true, true, address(playground));
        emit ProjectRequestSubmitted(
            projectId + 1, address(intake), bytes32(uint256(1)), action, address(token), 7 ether
        );
        (uint256 newProjectId, address newReceiver, bytes32 requestId) =
            playground.requestProject(action, body, address(token), 7 ether);
        vm.stopPrank();
        assertEq(newProjectId, projectId + 1);
        assertEq(playground.projectCount(), 2);
        (address creator, address storedReceiver) = playground.projects(newProjectId);
        assertEq(creator, alice);
        assertEq(storedReceiver, newReceiver);
        assertEq(newReceiver, predictedReceiver);
        assertEq(PlaygroundProject(payable(newReceiver)).playground(), address(playground));
        assertEq(PlaygroundProject(payable(newReceiver)).projectId(), newProjectId);
        assertEq(newReceiver.codehash, receiver.codehash);
        assertEq(intake.lastRequester(), newReceiver);
        assertEq(intake.lastAction(), action);
        assertEq(intake.lastBody(), body);
        assertEq(intake.lastAsset(), address(token));
        assertEq(intake.lastAmount(), 7 ether);
        assertEq(intake.lastApprovedAllowance(), 7 ether);
        assertEq(intake.lastCallbackTarget(), address(0));
        assertEq(intake.lastCallbackSelector(), bytes4(0));
        assertEq(token.balanceOf(alice), 13 ether);
        assertEq(token.balanceOf(address(intake)), 7 ether);
        assertEq(token.balanceOf(newReceiver), 0);
        assertEq(token.balanceOf(address(playground)), 0);
        assertEq(token.allowance(newReceiver, address(intake)), 0);
        assertEq(playground.requestProjectIds(address(intake), requestId), newProjectId);
    }

    function test_existingProjectRequestsPreserveReceiverRevenueAndReuseItsPayer() public {
        token.mint(alice, 10 ether);
        token.mint(receiver, 10 ether);
        uint64 priorNonce = vm.getNonce(address(playground));
        vm.startPrank(alice);
        token.approve(address(playground), 10 ether);
        bytes32 firstId = playground.requestProject(projectId, bytes32(0), "first", address(token), 7 ether);
        bytes32 secondId = playground.requestProject(projectId, bytes32(0), "second", address(token), 1 ether);
        vm.stopPrank();
        assertEq(playground.projectCount(), 1);
        assertEq(vm.getNonce(address(playground)), priorNonce);
        assertEq(intake.lastRequester(), receiver);
        assertEq(token.balanceOf(receiver), 10 ether);
        assertEq(token.balanceOf(alice), 2 ether);
        assertEq(token.balanceOf(address(intake)), 8 ether);
        assertEq(token.allowance(receiver, address(intake)), 0);
        assertEq(playground.requestProjectIds(address(intake), firstId), projectId);
        assertEq(playground.requestProjectIds(address(intake), secondId), projectId);

        PlaygroundTestIntake replacement = new PlaygroundTestIntake();
        vm.prank(ownerWallet);
        playground.setIntake(address(replacement));
        vm.prank(alice);
        bytes32 replacementId = playground.requestProject(projectId, bytes32(0), "third", address(token), 1 ether);
        assertEq(replacementId, firstId);
        assertEq(replacement.lastRequester(), receiver);
        assertEq(playground.requestProjectIds(address(replacement), replacementId), projectId);
        assertEq(token.balanceOf(receiver), 10 ether);
        assertEq(token.allowance(receiver, address(replacement)), 0);
        assertEq(playground.projectCount(), 1);
    }

    function test_existingProjectRequestsRequireActiveOriginalCreator() public {
        _addMember(bob);
        vm.prank(bob);
        vm.expectRevert(Playground.NotProjectCreator.selector);
        playground.requestProject(projectId, bytes32(0), "", address(token), 1);
        _removeMember(alice);
        vm.prank(alice);
        vm.expectRevert(Playground.NotMember.selector);
        playground.requestProject(projectId, bytes32(0), "", address(token), 1);
        vm.prank(bob);
        vm.expectRevert(Playground.UnknownProject.selector);
        playground.requestProject(projectId + 1, bytes32(0), "", address(token), 1);
    }

    function test_oneShotRequestRollsBackCloneWhenIntakeDoesNotConsumeExactPayment() public {
        token.mint(alice, 10 ether);
        intake.setSpendAmount(0.5 ether);
        uint64 priorNonce = vm.getNonce(address(playground));
        address predictedReceiver = vm.computeCreateAddress(address(playground), priorNonce);
        vm.startPrank(alice);
        token.approve(address(playground), 10 ether);
        vm.expectRevert(PlaygroundProject.UnexpectedTokenSpent.selector);
        playground.requestProject(bytes32(0), "", address(token), 1 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.balanceOf(predictedReceiver), 0);
        assertEq(token.allowance(alice, address(playground)), 10 ether);
        assertEq(token.allowance(predictedReceiver, address(intake)), 0);
        assertEq(playground.projectCount(), 1);
        assertEq(vm.getNonce(address(playground)), priorNonce);
        assertEq(predictedReceiver.code.length, 0);
        (address creator, address storedReceiver) = playground.projects(2);
        assertEq(creator, address(0));
        assertEq(storedReceiver, address(0));
    }

    function test_onlyActiveMembersCanRequestNewProjects() public {
        vm.prank(outsider);
        vm.expectRevert(Playground.NotMember.selector);
        playground.requestProject(bytes32(0), "", address(token), 1);
        _removeMember(ownerWallet);
        vm.prank(ownerWallet);
        vm.expectRevert(Playground.NotMember.selector);
        playground.requestProject(bytes32(0), "", address(token), 1);
        _removeMember(alice);
        vm.prank(alice);
        vm.expectRevert(Playground.NotMember.selector);
        playground.requestProject(bytes32(0), "", address(token), 1);
        assertEq(playground.projectCount(), 1);
        _addMember(alice);
        token.mint(alice, 1);
        vm.startPrank(alice);
        token.approve(address(playground), 1);
        (uint256 newProjectId,,) = playground.requestProject(bytes32(0), "", address(token), 1);
        vm.stopPrank();
        assertEq(newProjectId, 2);
    }

    function test_intakeReplacementPreservesProjectsAndNamespacesRequestIds() public {
        bytes32 sharedId = bytes32(uint256(77));
        intake.configure(sharedId, false, false);
        token.mint(alice, 2);
        vm.prank(alice);
        token.approve(address(playground), 2);
        vm.prank(alice);
        (uint256 firstId, address firstReceiver,) = playground.requestProject(bytes32(0), "first", address(token), 1);
        PlaygroundTestIntake replacement = new PlaygroundTestIntake();
        replacement.configure(sharedId, false, false);
        vm.prank(ownerWallet);
        playground.setIntake(address(replacement));
        vm.prank(alice);
        (uint256 secondId, address secondReceiver,) = playground.requestProject(bytes32(0), "second", address(token), 1);
        assertEq(firstId, projectId + 1);
        assertEq(secondId, firstId + 1);
        assertEq(playground.requestProjectIds(address(intake), sharedId), firstId);
        assertEq(playground.requestProjectIds(address(replacement), sharedId), secondId);
        assertEq(intake.lastRequester(), firstReceiver);
        assertEq(replacement.lastRequester(), secondReceiver);
        (address creator, address storedReceiver) = playground.projects(projectId);
        assertEq(creator, alice);
        assertEq(storedReceiver, receiver);
        (creator, storedReceiver) = playground.projects(firstId);
        assertEq(creator, alice);
        assertEq(storedReceiver, firstReceiver);
        (creator, storedReceiver) = playground.projects(secondId);
        assertEq(creator, alice);
        assertEq(storedReceiver, secondReceiver);
    }

    function test_requestRequiresTokenContractAndNonzeroPayment() public {
        uint64 priorNonce = vm.getNonce(address(playground));
        address predictedReceiver = vm.computeCreateAddress(address(playground), priorNonce);
        vm.startPrank(alice);
        vm.expectRevert(Playground.InvalidAddress.selector);
        playground.requestProject(bytes32(0), "", outsider, 1);
        vm.expectRevert(Playground.InvalidAddress.selector);
        playground.requestProject(bytes32(0), "", address(0), 1);
        vm.expectRevert(Playground.IncorrectPayment.selector);
        playground.requestProject(bytes32(0), "", address(token), 0);
        vm.stopPrank();
        assertEq(playground.projectCount(), 1);
        assertEq(vm.getNonce(address(playground)), priorNonce);
        assertEq(predictedReceiver.code.length, 0);
    }

    function test_duplicateRequestRollsBackProjectAndPayment() public {
        intake.configure(bytes32(uint256(99)), false, false);
        token.mint(alice, 10 ether);
        vm.startPrank(alice);
        token.approve(address(playground), 10 ether);
        (uint256 firstId, address firstReceiver,) = playground.requestProject(bytes32(0), "", address(token), 1 ether);
        uint64 priorNonce = vm.getNonce(address(playground));
        address predictedReceiver = vm.computeCreateAddress(address(playground), priorNonce);
        vm.expectRevert(Playground.DuplicateRequest.selector);
        playground.requestProject(bytes32(0), "", address(token), 1 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 9 ether);
        assertEq(token.balanceOf(address(intake)), 1 ether);
        assertEq(token.allowance(firstReceiver, address(intake)), 0);
        assertEq(token.allowance(alice, address(playground)), 9 ether);
        assertEq(playground.projectCount(), firstId);
        (address creator, address storedReceiver) = playground.projects(firstId + 1);
        assertEq(creator, address(0));
        assertEq(storedReceiver, address(0));
        assertEq(vm.getNonce(address(playground)), priorNonce);
        assertEq(predictedReceiver.code.length, 0);
        assertEq(playground.requestProjectIds(address(intake), bytes32(uint256(99))), firstId);
    }

    function test_zeroRequestIdAndIntakeFailureRollBackProjectAndPayment() public {
        uint64 priorNonce = vm.getNonce(address(playground));
        address predictedReceiver = vm.computeCreateAddress(address(playground), priorNonce);
        token.mint(alice, 10 ether);
        vm.prank(alice);
        token.approve(address(playground), 10 ether);
        intake.configure(bytes32(0), true, false);
        vm.prank(alice);
        vm.expectRevert(Playground.InvalidRequest.selector);
        playground.requestProject(bytes32(0), "", address(token), 1 ether);
        intake.configure(bytes32(0), false, true);
        vm.prank(alice);
        vm.expectRevert("INTAKE_REVERT");
        playground.requestProject(bytes32(0), "", address(token), 1 ether);
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(address(playground)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.allowance(predictedReceiver, address(intake)), 0);
        assertEq(playground.projectCount(), 1);
        (address creator, address storedReceiver) = playground.projects(2);
        assertEq(creator, address(0));
        assertEq(storedReceiver, address(0));
        assertEq(intake.nonce(), 0);
        assertEq(vm.getNonce(address(playground)), priorNonce);
        assertEq(predictedReceiver.code.length, 0);
        intake.configure(bytes32(0), false, false);
        vm.prank(alice);
        (uint256 retriedId, address retriedReceiver,) =
            playground.requestProject(bytes32(0), "", address(token), 1 ether);
        assertEq(retriedId, 2);
        assertEq(retriedReceiver, predictedReceiver);
        assertGt(retriedReceiver.code.length, 0);
    }

    function test_requestRejectsTransferTaxEvenWhenReceiverHasExistingTokens() public {
        token.mint(alice, 10 ether);
        token.mint(receiver, 10 ether);
        token.setChargeFee(true);
        vm.startPrank(alice);
        token.approve(address(playground), 10 ether);
        vm.expectRevert(Playground.IncorrectPayment.selector);
        playground.requestProject(projectId, bytes32(0), "", address(token), 1 ether);
        vm.expectRevert(Playground.IncorrectPayment.selector);
        playground.requestProject(bytes32(0), "", address(token), 1 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 10 ether);
        assertEq(token.balanceOf(receiver), 10 ether);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(playground.projectCount(), 1);
        (address creator, address storedReceiver) = playground.projects(2);
        assertEq(creator, address(0));
        assertEq(storedReceiver, address(0));
    }

    function test_onlyOwnerCanForwardHubTokensToKnownProject() public {
        token.mint(address(playground), 10 ether);
        vm.prank(outsider);
        vm.expectRevert();
        playground.forwardTokenToProject(projectId, address(token), 4 ether);
        vm.prank(ownerWallet);
        vm.expectRevert(Playground.UnknownProject.selector);
        playground.forwardTokenToProject(projectId + 1, address(token), 4 ether);
        vm.prank(ownerWallet);
        playground.forwardTokenToProject(projectId, address(token), 4 ether);
        assertEq(token.balanceOf(receiver), 4 ether);
        assertEq(token.balanceOf(address(playground)), 6 ether);
        assertEq(playground.totalDeposited(), 0);
    }

    function testFuzz_distributionConservesValue(uint96 depositAmount) public {
        uint256 amount = bound(uint256(depositAmount), 1, 1_000 ether);
        _addMember(bob);
        playground.deposit{value: amount}(projectId);
        uint256 memberAmount = amount * 3 / 10;
        uint256 tokenworksAmount = amount / 5;
        uint256 creatorAmount = amount - memberAmount - tokenworksAmount;
        assertEq(playground.claimable(alice), creatorAmount);
        assertEq(playground.claimable(bob), memberAmount / 2);
        assertEq(playground.claimable(ownerWallet), memberAmount / 2);
        uint256 aggregate = playground.claimable(alice) + playground.claimable(bob) + playground.claimable(ownerWallet);
        assertLe(aggregate + tokenworksAmount, amount);
        assertLe(amount - aggregate - tokenworksAmount, 1);
        assertEq(playground.accountedETH(), amount - tokenworksAmount);
        assertEq(playground.totalTokenworksPaid(), tokenworksAmount);
        assertEq(address(tokenworksSplitter).balance, tokenworksAmount);
    }

    // Multiples of 120 wei make creator, Tokenworks, and 1-3 eligible-member shares exact.
    // Exercise changing creators and membership with an independent ledger, including empty groups.
    function testFuzz_memberChangesAndClaimsMatchIndependentLedger(uint256 seed) public {
        address[4] memory actors = [alice, bob, carol, ownerWallet];
        bool[4] memory active = [true, false, false, true];
        uint256[4] memory projectIds;
        projectIds[0] = projectId;
        for (uint256 i = 1; i < 4; ++i) {
            if (!active[i]) _addMember(actors[i]);
            vm.prank(actors[i]);
            (projectIds[i],) = playground.createProject();
            if (!active[i]) _removeMember(actors[i]);
        }
        uint256[4] memory expected;
        uint256 count = 2;
        uint256 deposited;
        uint256 claimed;
        uint256 tokenworksPaid;

        for (uint256 i; i < 36; ++i) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = entropy % 3;
            if (action == 0) {
                uint256 memberIndex = (entropy >> 8) % 4;
                if (active[memberIndex]) {
                    _removeMember(actors[memberIndex]);
                    --count;
                } else {
                    _addMember(actors[memberIndex]);
                    ++count;
                }
                active[memberIndex] = !active[memberIndex];
            } else if (action == 1) {
                uint256 amount = (((entropy >> 16) % 1_000_000) + 1) * 120;
                uint256 creatorIndex = (entropy >> 40) % 4;
                uint256 recipients = count - (active[creatorIndex] ? 1 : 0);
                playground.deposit{value: amount}(projectIds[creatorIndex]);
                deposited += amount;
                tokenworksPaid += amount / 5;
                if (recipients == 0) {
                    expected[creatorIndex] += amount * 4 / 5;
                } else {
                    expected[creatorIndex] += amount / 2;
                    for (uint256 j; j < 4; ++j) {
                        if (active[j] && j != creatorIndex) expected[j] += amount * 3 / 10 / recipients;
                    }
                }
            } else {
                uint256 claimant = (entropy >> 8) % 4;
                if (expected[claimant] == 0) {
                    vm.expectRevert(Playground.NothingToClaim.selector);
                    playground.claimFor(actors[claimant]);
                } else {
                    uint256 priorBalance = actors[claimant].balance;
                    assertEq(playground.claimFor(actors[claimant]), expected[claimant]);
                    assertEq(actors[claimant].balance - priorBalance, expected[claimant]);
                    claimed += expected[claimant];
                    expected[claimant] = 0;
                }
            }

            uint256 pending;
            for (uint256 j; j < 4; ++j) {
                assertEq(playground.claimable(actors[j]), expected[j]);
                pending += expected[j];
            }
            assertEq(playground.memberCount(), count);
            assertEq(playground.totalDeposited(), deposited);
            assertEq(playground.totalClaimed(), claimed);
            assertEq(playground.totalTokenworksPaid(), tokenworksPaid);
            assertEq(address(tokenworksSplitter).balance, tokenworksPaid);
            assertEq(playground.accountedETH(), deposited - claimed - tokenworksPaid);
            assertEq(address(playground).balance, pending);
            assertEq(pending + claimed + tokenworksPaid, deposited);
        }
    }

    function _addMember(address member) internal {
        vm.prank(ownerWallet);
        playground.inviteMember(member);
        vm.prank(member);
        playground.acceptInvitation();
    }

    function _removeMember(address member) internal {
        vm.prank(ownerWallet);
        playground.removeMember(member);
    }
}
