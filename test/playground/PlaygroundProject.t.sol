// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlaygroundLaunchControllerMock} from "./helpers/PlaygroundLaunchControllerMock.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {PlaygroundHolderSplitter} from "../../src/playground/PlaygroundHolderSplitter.sol";
import {TokenworksSplitter} from "../../src/playground/TokenworksSplitter.sol";
import {Playground} from "../../src/playground/Playground.sol";
import {PlaygroundProject} from "../../src/playground/PlaygroundProject.sol";
import {IPlaygroundIntake} from "../../src/playground/interfaces/IPlaygroundIntake.sol";
import {IPlaygroundSwapAdapter} from "../../src/playground/interfaces/IPlaygroundSwapAdapter.sol";

contract ProjectTestToken is ERC20 {
    function name() public pure override returns (string memory) {
        return "Revenue";
    }

    function symbol() public pure override returns (string memory) {
        return "REV";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ProjectTestHub {
    address public owner;
    address public intake;
    uint256 public deposited;
    uint256 public lastProjectId;
    address public lastSender;
    bool public rejectDeposits;
    mapping(address => bool) public canSwap;

    error NoMembers();

    constructor(address owner_) {
        owner = owner_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function setIntake(address intake_) external {
        intake = intake_;
    }

    function setSwapCaller(address caller, bool allowed) external {
        canSwap[caller] = allowed;
    }

    function setRejectDeposits(bool reject) external {
        rejectDeposits = reject;
    }

    function deposit(uint256 id) external payable {
        if (rejectDeposits) revert NoMembers();
        deposited += msg.value;
        lastProjectId = id;
        lastSender = msg.sender;
    }
}

contract ProjectTestIntake is IPlaygroundIntake {
    bytes32 public constant REQUEST_ID = keccak256("request");
    address public payer;
    bytes32 public lastAction;
    bytes32 public bodyHash;
    address public callbackTarget;
    bytes4 public callbackSelector;
    uint256 public allowanceSeen;
    uint256 public spendReduction;

    function setSpendReduction(uint256 reduction) external {
        spendReduction = reduction;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        returns (bytes32)
    {
        payer = msg.sender;
        lastAction = action;
        bodyHash = keccak256(body);
        callbackTarget = callback.target;
        callbackSelector = callback.selector;
        allowanceSeen = ProjectTestToken(asset).allowance(msg.sender, address(this));
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), amount - spendReduction);
        return REQUEST_ID;
    }
}

contract ProjectTestAdapter is IPlaygroundSwapAdapter {
    uint256 public output = 2 ether;
    uint256 public reportedOutput = 2 ether;
    uint256 public spendReduction;
    uint256 public minimumSeen;
    uint256 public allowanceSeen;
    bool public reenter;
    bytes4 public reentryError;

    function setOutput(uint256 actual, uint256 reported) external {
        output = actual;
        reportedOutput = reported;
    }

    function setSpendReduction(uint256 reduction) external {
        spendReduction = reduction;
    }

    function setReenter(bool enabled) external {
        reenter = enabled;
    }

    function swapToETH(address asset, uint256 amountIn, uint256 minETHOut) external returns (uint256) {
        minimumSeen = minETHOut;
        allowanceSeen = ProjectTestToken(asset).allowance(msg.sender, address(this));
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), amountIn - spendReduction);
        if (reenter) {
            (bool succeeded, bytes memory data) = msg.sender.call(abi.encodeCall(PlaygroundProject.depositETH, ()));
            require(!succeeded, "reentry succeeded");
            reentryError = bytes4(data);
        }
        SafeTransferLib.safeTransferETH(msg.sender, output);
        return reportedOutput;
    }
}

contract ProjectTestRewardCaller {
    PlaygroundProject public immutable project;
    ProjectTestHub public immutable hub;
    bool public rejectETH;
    bytes4 public reentryError;
    uint256 public depositedAtPayment;

    constructor(PlaygroundProject project_, ProjectTestHub hub_) {
        project = project_;
        hub = hub_;
    }

    function setRejectETH(bool reject) external {
        rejectETH = reject;
    }

    function execute(address asset, uint256 amount, uint256 minimum) external {
        project.swapToETH(asset, amount, minimum, block.timestamp);
    }

    receive() external payable {
        require(!rejectETH, "reject reward");
        depositedAtPayment = hub.deposited();
        (bool succeeded, bytes memory data) = address(project).call(abi.encodeCall(PlaygroundProject.depositETH, ()));
        require(!succeeded, "reentry succeeded");
        reentryError = bytes4(data);
    }
}

contract PlaygroundProjectTest is Test {
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    ProjectTestHub internal hub;
    PlaygroundLaunchControllerMock internal launchController;
    PlaygroundProject internal implementation;
    PlaygroundProject internal project;
    ProjectTestToken internal token;
    ProjectTestIntake internal intake;
    ProjectTestAdapter internal adapter;
    uint256 internal constant PROJECT_ID = 42;
    address internal constant S02_COLLECTION = 0xb33d806a94B6770C9d309E0842a75f8E6edCd5A6;

    function setUp() public {
        launchController = new PlaygroundLaunchControllerMock();
        hub = new ProjectTestHub(owner);
        implementation = new PlaygroundProject(address(hub));
        project = _newClone(PROJECT_ID);
        token = new ProjectTestToken();
        intake = new ProjectTestIntake();
        adapter = new ProjectTestAdapter();
        hub.setIntake(address(intake));
        hub.setSwapCaller(address(this), true);
        vm.deal(address(adapter), 100 ether);
        token.mint(address(project), 10 ether);
        vm.prank(owner);
        project.configureSwap(address(token), address(adapter));
    }

    function testConstructorRejectsZeroHub() public {
        vm.expectRevert(PlaygroundProject.InvalidAddress.selector);
        new PlaygroundProject(address(0));
    }

    function testImplementationIsPermanentlyInitializedAndCloneHasOwnId() public {
        assertEq(implementation.playground(), address(hub));
        assertEq(implementation.projectId(), type(uint256).max);
        assertEq(project.playground(), address(hub));
        assertEq(project.projectId(), PROJECT_ID);
        assertEq(address(project).code.length, 44);
        assertLt(address(project).code.length, address(implementation).code.length);
        vm.prank(address(hub));
        vm.expectRevert(PlaygroundProject.AlreadyInitialized.selector);
        implementation.initialize(PROJECT_ID);
    }

    function testOnlyBoundHubMayInitializeFreshClone() public {
        PlaygroundProject fresh = PlaygroundProject(payable(LibClone.clone(address(implementation))));
        assertEq(fresh.projectId(), 0);
        vm.prank(stranger);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        fresh.initialize(99);
        vm.prank(owner);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        fresh.initialize(99);
        assertEq(fresh.projectId(), 0);
        vm.prank(address(hub));
        fresh.initialize(99);
        assertEq(fresh.projectId(), 99);
        assertEq(fresh.playground(), address(hub));
    }

    function testInitializerRejectsZeroAndCannotRunTwice() public {
        PlaygroundProject fresh = PlaygroundProject(payable(LibClone.clone(address(implementation))));
        vm.startPrank(address(hub));
        vm.expectRevert(PlaygroundProject.InvalidProjectId.selector);
        fresh.initialize(0);
        assertEq(fresh.projectId(), 0);
        fresh.initialize(99);
        vm.expectRevert(PlaygroundProject.AlreadyInitialized.selector);
        fresh.initialize(100);
        vm.expectRevert(PlaygroundProject.AlreadyInitialized.selector);
        project.initialize(100);
        vm.stopPrank();
        assertEq(fresh.projectId(), 99);
        assertEq(project.projectId(), PROJECT_ID);
    }

    function testClonesHaveIndependentRoutesTokensETHAndProjectAttribution() public {
        PlaygroundProject second = _newClone(PROJECT_ID + 1);
        ProjectTestAdapter secondAdapter = new ProjectTestAdapter();
        assertEq(keccak256(address(second).code), keccak256(address(project).code));
        assertEq(second.swapAdapters(address(token)), address(0));
        assertEq(implementation.swapAdapters(address(token)), address(0));
        vm.prank(owner);
        second.configureSwap(address(token), address(secondAdapter));
        assertEq(project.swapAdapters(address(token)), address(adapter));
        assertEq(second.swapAdapters(address(token)), address(secondAdapter));
        vm.prank(owner);
        project.clearSwap(address(token));
        assertEq(second.swapAdapters(address(token)), address(secondAdapter));

        token.mint(address(second), 3 ether);
        vm.deal(address(project), 1 ether);
        vm.deal(address(second), 2 ether);
        second.depositETH();
        assertEq(hub.lastProjectId(), PROJECT_ID + 1);
        assertEq(hub.lastSender(), address(second));
        assertEq(hub.deposited(), 2 ether);
        assertEq(address(second).balance, 0);
        assertEq(address(project).balance, 1 ether);
        assertEq(token.balanceOf(address(project)), 10 ether);
        assertEq(token.balanceOf(address(second)), 3 ether);
        assertEq(token.balanceOf(address(implementation)), 0);
        assertEq(address(implementation).balance, 0);
    }

    function testClonesUseSameCurrentHubAuthority() public {
        PlaygroundProject second = _newClone(PROJECT_ID + 1);
        hub.setOwner(stranger);
        vm.startPrank(owner);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        project.configureSwap(address(token), address(adapter));
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        second.configureSwap(address(token), address(adapter));
        vm.stopPrank();
        vm.startPrank(stranger);
        project.configureSwap(address(token), address(adapter));
        second.configureSwap(address(token), address(adapter));
        vm.stopPrank();

        token.mint(address(second), 3 ether);
        hub.setSwapCaller(address(this), false);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        project.swapToETH(address(token), 1 ether, 1 ether, block.timestamp);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        second.swapToETH(address(token), 1 ether, 1 ether, block.timestamp);
        hub.setSwapCaller(stranger, true);
        vm.startPrank(stranger);
        project.swapToETH(address(token), 1 ether, 1 ether, block.timestamp);
        second.swapToETH(address(token), 1 ether, 1 ether, block.timestamp);
        vm.stopPrank();
        assertEq(hub.deposited(), 3.98 ether);
        assertEq(stranger.balance, 0.02 ether);
        assertEq(token.balanceOf(address(project)), 9 ether);
        assertEq(token.balanceOf(address(second)), 2 ether);
    }

    function testReceivesETHWithoutCallingHubThenAnyoneCanDeposit() public {
        vm.deal(stranger, 3 ether);
        hub.setRejectDeposits(true);
        vm.prank(stranger);
        (bool success,) = address(project).call{value: 3 ether}("");
        assertTrue(success);
        assertEq(hub.deposited(), 0);
        assertEq(address(project).balance, 3 ether);

        hub.setRejectDeposits(false);
        vm.prank(stranger);
        assertEq(project.depositETH(), 3 ether);
        assertEq(hub.deposited(), 3 ether);
        assertEq(hub.lastSender(), address(project));
        assertEq(hub.lastProjectId(), PROJECT_ID);
        assertEq(address(project).balance, 0);
        assertEq(stranger.balance, 0); // Forwarding held ETH has no caller reward.
    }

    function testDepositRetainsETHIfHubRejects() public {
        vm.deal(address(project), 3 ether);
        hub.setRejectDeposits(true);
        vm.expectRevert(ProjectTestHub.NoMembers.selector);
        project.depositETH();
        assertEq(address(project).balance, 3 ether);
        assertEq(hub.deposited(), 0);
    }

    function testDepositRejectsEmptyBalance() public {
        vm.expectRevert(PlaygroundProject.InvalidAmount.selector);
        project.depositETH();
    }

    function testRequestPreservesRevenueAndUsesExactApprovalAndStablePayer() public {
        token.mint(address(project), 0.5 ether);
        vm.deal(address(project), 3 ether);
        bytes32 action = bytes32("oracle.request@oracle-1");
        bytes memory body = bytes('{"v":1}');
        vm.prank(address(hub));
        bytes32 id = project.request(address(intake), action, body, address(token), 0.5 ether);
        assertEq(id, intake.REQUEST_ID());
        assertEq(intake.payer(), address(project));
        assertEq(intake.lastAction(), action);
        assertEq(intake.bodyHash(), keccak256(body));
        assertEq(intake.callbackTarget(), address(0));
        assertEq(intake.callbackSelector(), bytes4(0));
        assertEq(intake.allowanceSeen(), 0.5 ether);
        assertEq(token.allowance(address(project), address(intake)), 0);
        assertEq(token.balanceOf(address(project)), 10 ether);
        assertEq(address(project).balance, 3 ether);
    }

    function testOnlyHubCanRequest() public {
        vm.prank(owner);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        project.request(address(intake), bytes32("launch"), "{}", address(token), 1 ether);
    }

    function testRequestUsesHubSuppliedIntakeSnapshot() public {
        ProjectTestIntake secondIntake = new ProjectTestIntake();
        hub.setIntake(address(secondIntake));
        vm.prank(address(hub));
        project.request(address(intake), bytes32("launch"), "{}", address(token), 1 ether);
        assertEq(intake.payer(), address(project));
        assertEq(secondIntake.payer(), address(0));
        assertEq(token.allowance(address(project), address(intake)), 0);
    }

    function testRequestRejectsPartialSpendAtomically() public {
        intake.setSpendReduction(1);
        vm.prank(address(hub));
        vm.expectRevert(PlaygroundProject.UnexpectedTokenSpent.selector);
        project.request(address(intake), bytes32("launch"), "{}", address(token), 1 ether);
        assertEq(token.balanceOf(address(project)), 10 ether);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.allowance(address(project), address(intake)), 0);
    }

    function testRequestRejectsInvalidAddresses() public {
        vm.startPrank(address(hub));
        vm.expectRevert(PlaygroundProject.InvalidAddress.selector);
        project.request(stranger, bytes32("launch"), "{}", address(token), 1 ether);
        vm.expectRevert(PlaygroundProject.InvalidAddress.selector);
        project.request(address(intake), bytes32("launch"), "{}", stranger, 1 ether);
        vm.stopPrank();
    }

    function testRequestRejectsZeroOrUnavailablePayment() public {
        vm.startPrank(address(hub));
        vm.expectRevert(PlaygroundProject.InvalidAmount.selector);
        project.request(address(intake), bytes32("launch"), "{}", address(token), 0);
        vm.expectRevert(PlaygroundProject.InvalidAmount.selector);
        project.request(address(intake), bytes32("launch"), "{}", address(token), 11 ether);
        vm.stopPrank();
    }

    function testOnlyCurrentHubOwnerCanConfigureOrClearSwap() public {
        vm.prank(stranger);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        project.configureSwap(address(token), address(adapter));
        vm.prank(stranger);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        project.clearSwap(address(token));

        hub.setOwner(stranger);
        vm.prank(owner);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        project.clearSwap(address(token));
        vm.startPrank(stranger);
        project.configureSwap(address(token), address(adapter));
        assertEq(project.swapAdapters(address(token)), address(adapter));
        project.clearSwap(address(token));
        vm.stopPrank();
        assertEq(project.swapAdapters(address(token)), address(0));
    }

    function testConfigurationRequiresContracts() public {
        vm.startPrank(owner);
        vm.expectRevert(PlaygroundProject.InvalidAddress.selector);
        project.configureSwap(stranger, address(adapter));
        vm.expectRevert(PlaygroundProject.InvalidAddress.selector);
        project.configureSwap(address(token), stranger);
        vm.stopPrank();
    }

    function testAuthorizedCallerSwapsAndOnlyNewETHIsRewarded() public {
        vm.deal(address(project), 3 ether);
        hub.setSwapCaller(stranger, true);
        vm.prank(stranger);
        uint256 output = project.swapToETH(address(token), 10 ether, 1 ether, block.timestamp);
        assertEq(output, 2 ether);
        assertEq(stranger.balance, 0.01 ether);
        assertEq(adapter.minimumSeen(), 1 ether);
        assertEq(adapter.allowanceSeen(), 10 ether);
        assertEq(token.allowance(address(project), address(adapter)), 0);
        assertEq(token.balanceOf(address(project)), 0);
        assertEq(token.balanceOf(address(adapter)), 10 ether);
        assertEq(hub.deposited(), 4.99 ether);
        assertEq(hub.lastProjectId(), PROJECT_ID);
        assertEq(address(project).balance, 0);
    }

    function testCallerSuppliesGrossOutputMinimum() public {
        project.swapToETH(address(token), 10 ether, 1.5 ether, block.timestamp);
        assertEq(adapter.minimumSeen(), 1.5 ether);
    }

    function testRewardRoundsDownToZeroForSmallOutput() public {
        adapter.setOutput(1, 1);
        project.swapToETH(address(token), 1, 1, block.timestamp);
        assertEq(adapter.minimumSeen(), 1);
        assertEq(hub.deposited(), 1);
    }

    function testSwapMeasuresETHAndIgnoresAdapterReturnValue() public {
        adapter.setOutput(2 ether, 0);
        assertEq(project.swapToETH(address(token), 10 ether, 1 ether, block.timestamp), 2 ether);
        assertEq(hub.deposited(), 1.99 ether);
    }

    function testOldETHCannotSatisfySwapMinimumEvenIfAdapterLies() public {
        vm.deal(address(project), 3 ether);
        adapter.setOutput(0, 100 ether);
        vm.expectRevert(PlaygroundProject.InsufficientETHReceived.selector);
        project.swapToETH(address(token), 10 ether, 1 ether, block.timestamp);
        assertEq(token.balanceOf(address(project)), 10 ether);
        assertEq(address(project).balance, 3 ether);
        assertEq(hub.deposited(), 0);
        assertEq(token.allowance(address(project), address(adapter)), 0);
    }

    function testSwapRejectsOutputBelowCallerMinimumWithoutPayingReward() public {
        hub.setSwapCaller(stranger, true);
        vm.prank(stranger);
        vm.expectRevert(PlaygroundProject.InsufficientETHReceived.selector);
        project.swapToETH(address(token), 10 ether, 3 ether, block.timestamp);
        assertEq(token.balanceOf(address(project)), 10 ether);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 100 ether);
        assertEq(stranger.balance, 0);
        assertEq(hub.deposited(), 0);
    }

    function testSwapRejectsPartialInputSpend() public {
        adapter.setSpendReduction(1);
        vm.expectRevert(PlaygroundProject.UnexpectedTokenSpent.selector);
        project.swapToETH(address(token), 10 ether, 1 ether, block.timestamp);
        assertEq(token.balanceOf(address(project)), 10 ether);
        assertEq(token.allowance(address(project), address(adapter)), 0);
        assertEq(hub.deposited(), 0);
    }

    function testSwapRollsBackWhenHubCannotAcceptRevenue() public {
        vm.deal(address(project), 3 ether);
        hub.setSwapCaller(stranger, true);
        hub.setRejectDeposits(true);
        vm.prank(stranger);
        vm.expectRevert(ProjectTestHub.NoMembers.selector);
        project.swapToETH(address(token), 10 ether, 1 ether, block.timestamp);
        assertEq(token.balanceOf(address(project)), 10 ether);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(address(project).balance, 3 ether);
        assertEq(address(adapter).balance, 100 ether);
        assertEq(token.allowance(address(project), address(adapter)), 0);
        assertEq(stranger.balance, 0);
        assertEq(hub.deposited(), 0);
    }

    function testAdapterCannotReenterDeposit() public {
        vm.deal(address(project), 3 ether);
        adapter.setReenter(true);
        project.swapToETH(address(token), 10 ether, 1 ether, block.timestamp);
        assertEq(adapter.reentryError(), ReentrancyGuard.Reentrancy.selector);
        assertEq(hub.deposited(), 4.99 ether);
    }

    function testSwapRejectsExpiredDeadline() public {
        vm.warp(100);
        vm.expectRevert(PlaygroundProject.DeadlineExpired.selector);
        project.swapToETH(address(token), 10 ether, 1 ether, 99);
    }

    function testSwapRejectsZeroOrUnavailableInput() public {
        vm.expectRevert(PlaygroundProject.InvalidAmount.selector);
        project.swapToETH(address(token), 0, 1 ether, block.timestamp);
        vm.expectRevert(PlaygroundProject.InvalidAmount.selector);
        project.swapToETH(address(token), 11 ether, 1 ether, block.timestamp);
    }

    function testClearedSwapCannotExecute() public {
        vm.prank(owner);
        project.clearSwap(address(token));
        vm.expectRevert(PlaygroundProject.SwapNotConfigured.selector);
        project.swapToETH(address(token), 10 ether, 1 ether, block.timestamp);
    }

    function testStrangersAndOwnerHaveNoImplicitSwapPermission() public {
        vm.prank(stranger);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        project.swapToETH(address(token), 10 ether, 1 ether, block.timestamp);
        vm.prank(owner);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        project.swapToETH(address(token), 10 ether, 1 ether, block.timestamp);
        assertEq(token.balanceOf(address(project)), 10 ether);
        assertEq(hub.deposited(), 0);
    }

    function testRevokingCallerImmediatelyStopsSwaps() public {
        hub.setSwapCaller(address(this), false);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        project.swapToETH(address(token), 10 ether, 1 ether, block.timestamp);
    }

    function testSwapRequiresNonzeroMinimum() public {
        vm.expectRevert(PlaygroundProject.InvalidMinimum.selector);
        project.swapToETH(address(token), 10 ether, 0, block.timestamp);
        assertEq(token.balanceOf(address(project)), 10 ether);
        assertEq(token.allowance(address(project), address(adapter)), 0);
    }

    function testOneETHGrossPaysPointZeroZeroFiveETHAndMeetsGrossMinimum() public {
        adapter.setOutput(1 ether, 50 ether);
        hub.setSwapCaller(stranger, true);
        vm.expectEmit(true, true, true, true, address(project));
        emit PlaygroundProject.Swapped(address(token), address(adapter), stranger, 10 ether, 1 ether, 0.005 ether);
        vm.prank(stranger);
        assertEq(project.swapToETH(address(token), 10 ether, 1 ether, block.timestamp), 1 ether);
        assertEq(stranger.balance, 0.005 ether);
        assertEq(hub.deposited(), 0.995 ether);
        assertEq(project.CALLER_REWARD_BPS(), 50);
        assertEq(project.BPS(), 10_000);
    }

    function testRewardRoundsDownAtWeiBoundary() public {
        hub.setSwapCaller(stranger, true);
        uint256[3] memory outputs = [uint256(199), 200, 399];
        for (uint256 i; i < outputs.length; ++i) {
            adapter.setOutput(outputs[i], 0);
            vm.prank(stranger);
            project.swapToETH(address(token), 1, 1, block.timestamp);
        }
        assertEq(stranger.balance, 2);
        assertEq(hub.deposited(), 796);
        assertEq(address(project).balance, 0);
    }

    function testRewardCannotReenterAndIsPaidAfterDeposit() public {
        ProjectTestRewardCaller caller = new ProjectTestRewardCaller(project, hub);
        hub.setSwapCaller(address(caller), true);
        caller.execute(address(token), 10 ether, 1 ether);
        assertEq(caller.reentryError(), ReentrancyGuard.Reentrancy.selector);
        assertEq(caller.depositedAtPayment(), 1.99 ether);
        assertEq(address(caller).balance, 0.01 ether);
        assertEq(hub.deposited(), 1.99 ether);
        assertEq(address(project).balance, 0);
    }

    function testRejectingCallerStillReceivesReward() public {
        ProjectTestRewardCaller caller = new ProjectTestRewardCaller(project, hub);
        hub.setSwapCaller(address(caller), true);
        caller.setRejectETH(true);
        caller.execute(address(token), 10 ether, 1 ether);
        assertEq(address(caller).balance, 0.01 ether);
        assertEq(hub.deposited(), 1.99 ether);
        assertEq(address(project).balance, 0);
    }

    function testRealHubOtherMembersCanSwapAndRemovalRequiresExplicitAuthorization() public {
        TokenworksSplitter router = _installSnapshotRouter();
        Playground realHub = new Playground(owner, address(intake), address(router), address(launchController));
        address swappingMember = makeAddr("swapping member");
        vm.startPrank(owner);
        realHub.inviteMember(stranger);
        realHub.inviteMember(swappingMember);
        vm.stopPrank();
        vm.prank(stranger);
        realHub.acceptInvitation();
        vm.prank(swappingMember);
        realHub.acceptInvitation();
        vm.prank(stranger);
        (, address receiver) = realHub.createProject();
        PlaygroundProject realProject = PlaygroundProject(payable(receiver));
        token.mint(receiver, 10 ether);
        vm.prank(owner);
        realProject.configureSwap(address(token), address(adapter));

        vm.prank(swappingMember);
        realProject.swapToETH(address(token), 1 ether, 1 ether, block.timestamp);
        assertEq(swappingMember.balance, 0.01 ether);

        vm.prank(owner);
        realHub.removeMember(swappingMember);
        vm.prank(swappingMember);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        realProject.swapToETH(address(token), 1 ether, 1 ether, block.timestamp);

        vm.prank(owner);
        realHub.setSwapCaller(swappingMember, true);
        vm.prank(swappingMember);
        realProject.swapToETH(address(token), 1 ether, 1 ether, block.timestamp);
        assertEq(swappingMember.balance, 0.02 ether);

        vm.prank(owner);
        realHub.setSwapCaller(swappingMember, false);
        vm.prank(swappingMember);
        vm.expectRevert(PlaygroundProject.Unauthorized.selector);
        realProject.swapToETH(address(token), 1 ether, 1 ether, block.timestamp);
        assertEq(token.balanceOf(receiver), 8 ether);
        assertEq(realHub.totalDeposited(), 3.98 ether);
        assertEq(realHub.totalTokenworksPaid(), 0.796 ether);
        assertEq(router.holderSplitter().balance, 0.199 ether);
        assertEq(router.pendingTokenworks(), 0.597 ether);
        assertEq(realHub.accountedETH(), 3.184 ether);
    }

    function testFuzzCallerRewardIsOnlyHalfPercentOfNewETH(uint96 gross, uint96 existingETH) public {
        gross = uint96(bound(gross, 1, 100 ether));
        existingETH = uint96(bound(existingETH, 0, 100 ether));
        uint256 expectedReward = uint256(gross) * 50 / 10_000;
        vm.deal(address(project), existingETH);
        adapter.setOutput(gross, 0);
        hub.setSwapCaller(stranger, true);
        vm.prank(stranger);
        project.swapToETH(address(token), 10 ether, gross, block.timestamp);
        assertEq(adapter.minimumSeen(), gross);
        assertEq(hub.deposited(), uint256(existingETH) + gross - expectedReward);
        assertEq(stranger.balance, expectedReward);
        assertEq(address(project).balance, 0);
        assertEq(token.allowance(address(project), address(adapter)), 0);
    }

    function testRealPlaygroundRequestThenSwapAndClaimAllRevenue() public {
        TokenworksSplitter router = _installSnapshotRouter();
        Playground realHub = new Playground(owner, address(intake), address(router), address(launchController));
        address secondMember = makeAddr("second member");
        vm.startPrank(owner);
        realHub.inviteMember(stranger);
        realHub.inviteMember(secondMember);
        vm.stopPrank();
        vm.prank(stranger);
        realHub.acceptInvitation();
        vm.prank(secondMember);
        realHub.acceptInvitation();

        vm.prank(stranger);
        (uint256 id, address receiver) = realHub.createProject();
        PlaygroundProject realProject = PlaygroundProject(payable(receiver));
        assertEq(realProject.playground(), address(realHub));
        assertEq(realProject.projectId(), id);
        token.mint(receiver, 10 ether);
        vm.deal(receiver, 6 ether);

        // Creator supplies a separate request fee even though the receiver already has revenue.
        token.mint(stranger, 0.5 ether);
        vm.startPrank(stranger);
        token.approve(address(realHub), 0.5 ether);
        bytes32 requestId =
            realHub.requestProject(id, bytes32("oracle.request@oracle-1"), bytes('{"v":1}'), address(token), 0.5 ether);
        vm.stopPrank();
        assertEq(realHub.requestProjectIds(address(intake), requestId), id);
        assertEq(intake.payer(), receiver);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(token.balanceOf(address(intake)), 0.5 ether);
        assertEq(token.balanceOf(receiver), 10 ether);
        assertEq(token.balanceOf(address(realHub)), 0);
        assertEq(token.allowance(receiver, address(intake)), 0);
        assertEq(receiver.balance, 6 ether);
        assertEq(realHub.totalDeposited(), 0);

        address keeper = makeAddr("authorized keeper");
        vm.startPrank(owner);
        realHub.setSwapCaller(keeper, true);
        realProject.configureSwap(address(token), address(adapter));
        vm.stopPrank();
        vm.prank(keeper);
        assertEq(realProject.swapToETH(address(token), 10 ether, 2 ether, block.timestamp), 2 ether);
        assertEq(keeper.balance, 0.01 ether);
        assertEq(receiver.balance, 0);
        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.allowance(receiver, address(adapter)), 0);
        assertEq(realHub.totalDeposited(), 7.99 ether);
        assertEq(realHub.accountedETH(), 6.392 ether);
        assertEq(realHub.totalTokenworksPaid(), 1.598 ether);
        assertEq(router.holderSplitter().balance, 0.3995 ether);
        assertEq(router.pendingTokenworks(), 1.1985 ether);
        assertEq(PlaygroundHolderSplitter(payable(router.holderSplitter())).totalReceived(), 0.3995 ether);
        assertEq(realHub.claimable(stranger), 3.995 ether); // Creator receives no share of its own member pool.
        assertEq(realHub.claimable(secondMember), 1.1985 ether);
        assertEq(realHub.claimable(owner), 1.1985 ether);

        realHub.claimFor(stranger);
        realHub.claimFor(secondMember);
        realHub.claimFor(owner);
        assertEq(stranger.balance, 3.995 ether);
        assertEq(secondMember.balance, 1.1985 ether);
        assertEq(owner.balance, 1.1985 ether);
        assertEq(realHub.totalClaimed(), 6.392 ether);
        assertEq(realHub.accountedETH(), 0);
        assertEq(address(realHub).balance, 0);
        assertEq(realHub.totalClaimed() + realHub.totalTokenworksPaid(), realHub.totalDeposited());
    }

    function _installSnapshotRouter() private returns (TokenworksSplitter router) {
        PlaygroundHolderSplitter.Snapshot memory snapshot =
            PlaygroundHolderSplitter.Snapshot(100, bytes32(uint256(123)), 1, 1);
        PlaygroundHolderSplitter holders =
            new PlaygroundHolderSplitter(owner, snapshot, abi.encodePacked(stranger, uint32(1)));
        router = new TokenworksSplitter(owner, address(holders));
    }

    function _newClone(uint256 id) private returns (PlaygroundProject clone) {
        clone = PlaygroundProject(payable(LibClone.clone(address(implementation))));
        vm.prank(address(hub));
        clone.initialize(id);
    }
}
