// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "solady/src/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {PlaygroundProject} from "./PlaygroundProject.sol";
import {IPlaygroundFactory} from "./interfaces/IPlaygroundFactory.sol";

/// @title Playground
/// @notice Shared project registry and ETH revenue accounting for a community of members.
/// @dev Each deposit credits 50% to its project's creator, 30% to the other current members equally,
///      and sends 20% to the fixed Tokenworks splitter. With no other members, the creator gets 80%.
///      Recipients withdraw independently. Creating a project here
///      registers a revenue receiver; it does not attest that an external protocol deployed it.
contract Playground is Ownable, ReentrancyGuard {
    uint256 public constant MEMBER_SCALE = 1e36;

    struct Project {
        address creator;
        address receiver;
    }

    struct Metadata {
        string name;
        string description;
        string image;
        string banner;
        string website;
        string twitter;
    }

    Metadata public metadata;

    address public intake;
    /// @notice Fixed factory whose live launch policy applies to this Playground.
    address public immutable factory;
    /// @notice Fixed Tokenworks revenue destination shared by factory-created playgrounds.
    address public immutable tokenworksSplitter;
    /// @notice Fixed receiver implementation shared by this hub's minimal proxies.
    address public immutable projectImplementation;
    uint256 public memberCount;
    uint256 public projectCount;
    mapping(address member => bool active) public isMember;
    /// @notice Pending invitations confer no membership rights until accepted by that wallet.
    mapping(address wallet => bool pending) public isInvited;
    /// @notice Explicit swap operators in addition to the currently active members.
    mapping(address caller => bool allowed) public swapCallers;
    mapping(uint256 projectId => Project project) public projects;
    mapping(address requestIntake => mapping(bytes32 requestId => uint256 projectId)) public requestProjectIds;

    uint256 public totalDeposited;
    uint256 public totalClaimed;
    /// @notice ETH already forwarded to the Tokenworks splitter, excluded from hub claim liabilities.
    uint256 public totalTokenworksPaid;
    /// @notice ETH backing all unpaid credits, member fractions, and accumulator rounding dust.
    uint256 public accountedETH;
    uint256 public accETHPerMember;
    mapping(address account => uint256 amount) private _credit;
    mapping(address member => uint256 index) private _memberIndex;
    mapping(address member => uint256 fraction) private _memberFraction;

    event IntakeUpdated(address indexed previousIntake, address indexed newIntake);
    event MemberAdded(address indexed member, uint256 memberCount);
    event MemberRemoved(address indexed member, uint256 memberCount);
    event MemberInvited(address indexed member);
    event MemberInvitationRevoked(address indexed member);
    event SwapCallerSet(address indexed caller, bool allowed);
    event MetadataUpdated(string name, string description, string image, string banner, string website, string twitter);
    event ProjectCreated(uint256 indexed projectId, address indexed creator, address indexed receiver);
    event ProjectRequestSubmitted(
        uint256 indexed projectId,
        address indexed requestIntake,
        bytes32 indexed requestId,
        bytes32 action,
        address paymentAsset,
        uint256 amount
    );
    event RevenueDeposited(
        uint256 indexed projectId,
        address indexed sender,
        address indexed tokenworksSplitter,
        uint256 amount,
        uint256 creatorAmount,
        uint256 memberAmount,
        uint256 tokenworksAmount
    );
    event Claimed(address indexed account, address indexed recipient, uint256 amount);
    event SurplusAllocated(uint256 indexed projectId, uint256 amount);
    event TokenForwarded(uint256 indexed projectId, address indexed asset, uint256 amount);

    error InvalidAddress();
    error InvalidIntake();
    error NotMember();
    error AlreadyMember();
    error UnknownMember();
    error AlreadyInvited();
    error NotInvited();
    error UnknownProject();
    error NotProjectCreator();
    error NoRevenue();
    error NothingToClaim();
    error ProjectRequired();
    error IncorrectPayment();
    error InvalidRequest();
    error DuplicateRequest();
    error LaunchesDisabled();

    /// @param splitter_ Deployed Tokenworks splitter; its destination cannot be changed later.
    /// @param factory_ Deployed factory controlling whether new project launches are enabled.
    constructor(address initialOwner, address intake_, address splitter_, address factory_) {
        if (initialOwner == address(0) || initialOwner == address(this)) revert InvalidAddress();
        _initializeOwner(initialOwner);
        _setIntake(intake_);
        if (splitter_.code.length == 0) revert InvalidAddress();
        if (factory_.code.length == 0) revert InvalidAddress();
        tokenworksSplitter = splitter_;
        factory = factory_;
        isMember[initialOwner] = true;
        memberCount = 1;
        emit MemberAdded(initialOwner, 1);
        projectImplementation = address(new PlaygroundProject(address(this)));
    }

    /// @dev Send plain ETH to a project's receiver, or call deposit(projectId) on this hub.
    receive() external payable {
        revert ProjectRequired();
    }

    function setIntake(address newIntake) external onlyOwner {
        _setIntake(newIntake);
    }

    /// @notice Update the playground's public presentation without changing revenue destinations.
    function setMetadata(
        string calldata name,
        string calldata description,
        string calldata image,
        string calldata banner,
        string calldata website,
        string calldata twitter
    ) external onlyOwner {
        metadata = Metadata(name, description, image, banner, website, twitter);
        emit MetadataUpdated(name, description, image, banner, website, twitter);
    }

    /// @notice Authorize an additional swap operator for every project receiver.
    /// @dev Revoking this entry does not override active membership. Operators choose minOut,
    ///      so they are trusted to price each swap; this role does not grant any revenue share.
    function setSwapCaller(address caller, bool allowed) external onlyOwner {
        if (caller == address(0) || caller == address(this)) revert InvalidAddress();
        swapCallers[caller] = allowed;
        emit SwapCallerSet(caller, allowed);
    }

    /// @notice Whether an account can swap revenue held by any project receiver right now.
    function canSwap(address caller) public view returns (bool) {
        return isMember[caller] || swapCallers[caller];
    }

    /// @notice Invite a wallet to join; only that wallet can accept and activate membership.
    function inviteMember(address member) external onlyOwner {
        if (member == address(0) || member == address(this)) revert InvalidAddress();
        if (isMember[member]) revert AlreadyMember();
        if (isInvited[member]) revert AlreadyInvited();
        isInvited[member] = true;
        emit MemberInvited(member);
    }

    /// @notice Cancel a pending invitation. Active members must be removed with removeMember.
    function revokeInvitation(address member) external onlyOwner {
        if (!isInvited[member]) revert NotInvited();
        delete isInvited[member];
        emit MemberInvitationRevoked(member);
    }

    /// @notice Accept your invitation; revenue participation starts at acceptance, not invitation.
    function acceptInvitation() external {
        address member = msg.sender;
        if (!isInvited[member]) revert NotInvited();
        delete isInvited[member];
        // Preserve previous fractional earnings, but skip all income from the inactive interval.
        _memberIndex[member] = accETHPerMember;
        isMember[member] = true;
        ++memberCount;
        emit MemberAdded(member, memberCount);
    }

    function removeMember(address member) external onlyOwner {
        if (!isMember[member]) revert UnknownMember();
        _settleMember(member);
        isMember[member] = false;
        --memberCount;
        emit MemberRemoved(member, memberCount);
    }

    /// @notice Register a standalone receiver without submitting an Intake request.
    /// @dev Most callers can use the four-argument requestProject to create and submit together.
    function createProject() external nonReentrant returns (uint256 projectId, address receiver) {
        return _createProject();
    }

    /// @notice Create a minimal-proxy receiver and submit its first Intake request in one call.
    /// @dev Approve this hub for the ERC20 payment first. A failed submission rolls back the
    ///      receiver deployment, registration, and payment. The new receiver is the Intake payer.
    function requestProject(bytes32 action, bytes calldata body, address paymentAsset, uint256 amount)
        external
        nonReentrant
        returns (uint256 projectId, address receiver, bytes32 requestId)
    {
        (projectId, receiver) = _createProject();
        requestId = _requestProject(projectId, receiver, action, body, paymentAsset, amount);
    }

    function _createProject() private returns (uint256 projectId, address receiver) {
        if (!isMember[msg.sender]) revert NotMember();
        _requireLaunchesEnabled();
        projectId = ++projectCount;
        receiver = LibClone.clone(projectImplementation);
        PlaygroundProject(payable(receiver)).initialize(projectId);
        projects[projectId] = Project({creator: msg.sender, receiver: receiver});
        emit ProjectCreated(projectId, msg.sender, receiver);
    }

    /// @notice Pay for an Intake request from this project's receiver, preserving payer identity.
    /// @dev The active creator supplies the payment separately from revenue. The Intake ABI is
    ///      generic; only actions actually enabled by that Intake can succeed. No callback is used.
    function requestProject(
        uint256 projectId,
        bytes32 action,
        bytes calldata body,
        address paymentAsset,
        uint256 amount
    ) external nonReentrant returns (bytes32 requestId) {
        Project memory project = _project(projectId);
        if (msg.sender != project.creator) revert NotProjectCreator();
        if (!isMember[msg.sender]) revert NotMember();
        return _requestProject(projectId, project.receiver, action, body, paymentAsset, amount);
    }

    function _requestProject(
        uint256 projectId,
        address receiver,
        bytes32 action,
        bytes calldata body,
        address paymentAsset,
        uint256 amount
    ) private returns (bytes32 requestId) {
        _requireLaunchesEnabled();
        if (paymentAsset.code.length == 0) revert InvalidAddress();
        if (amount == 0) revert IncorrectPayment();

        address requestIntake = intake;
        uint256 balanceBefore = SafeTransferLib.balanceOf(paymentAsset, receiver);
        SafeTransferLib.safeTransferFrom(paymentAsset, msg.sender, receiver, amount);
        if (SafeTransferLib.balanceOf(paymentAsset, receiver) != balanceBefore + amount) {
            revert IncorrectPayment();
        }

        requestId = PlaygroundProject(payable(receiver)).request(requestIntake, action, body, paymentAsset, amount);
        if (requestId == bytes32(0)) revert InvalidRequest();
        if (requestProjectIds[requestIntake][requestId] != 0) revert DuplicateRequest();
        requestProjectIds[requestIntake][requestId] = projectId;
        emit ProjectRequestSubmitted(projectId, requestIntake, requestId, action, paymentAsset, amount);
    }

    function _requireLaunchesEnabled() private view {
        if (!IPlaygroundFactory(factory).launchesEnabled()) revert LaunchesDisabled();
    }

    /// @notice Anyone may deposit ETH for an existing project, including its receiver.
    /// @dev Revenue is shared among other members present NOW, rather than when a receiver got paid.
    function deposit(uint256 projectId) external payable nonReentrant {
        _distribute(projectId, msg.value);
    }

    function claimable(address account) public view returns (uint256 amount) {
        amount = _credit[account];
        if (isMember[account]) {
            amount += (accETHPerMember - _memberIndex[account] + _memberFraction[account]) / MEMBER_SCALE;
        }
    }

    function claim() external nonReentrant returns (uint256 amount) {
        return _claim(msg.sender, msg.sender);
    }

    /// @notice Withdraw your own earnings to another address, including from a rejecting wallet.
    function claimTo(address recipient) external nonReentrant returns (uint256 amount) {
        return _claim(msg.sender, recipient);
    }

    /// @notice Anyone can trigger a payout, but cannot change its beneficiary.
    function claimFor(address account) external nonReentrant returns (uint256 amount) {
        return _claim(account, account);
    }

    /// @notice Attribute forced/unaccounted ETH to a project using the normal split.
    /// @dev Cannot touch existing liabilities or rounding reserves. Ownership is needed because
    ///      forced ETH has no trustworthy project identifier; attribution is an admin decision.
    function allocateSurplus(uint256 projectId) external onlyOwner nonReentrant returns (uint256 amount) {
        amount = address(this).balance - accountedETH;
        _distribute(projectId, amount);
        emit SurplusAllocated(projectId, amount);
    }

    /// @notice Route accidentally received tokens into a project's conversion receiver.
    /// @dev The hub never holds ERC20 claim liabilities or Intake payment reserves.
    function forwardTokenToProject(uint256 projectId, address asset, uint256 amount) external onlyOwner nonReentrant {
        Project memory project = _project(projectId);
        if (asset.code.length == 0) revert InvalidAddress();
        if (amount == 0) revert NoRevenue();
        SafeTransferLib.safeTransfer(asset, project.receiver, amount);
        emit TokenForwarded(projectId, asset, amount);
    }

    function _setIntake(address newIntake) private {
        if (newIntake == address(this) || newIntake.code.length == 0) revert InvalidIntake();
        emit IntakeUpdated(intake, newIntake);
        intake = newIntake;
    }

    function _project(uint256 projectId) private view returns (Project memory project) {
        project = projects[projectId];
        if (project.creator == address(0)) revert UnknownProject();
    }

    function _distribute(uint256 projectId, uint256 amount) private {
        Project memory project = _project(projectId);
        if (amount == 0) revert NoRevenue();
        uint256 count = memberCount;
        bool creatorIsMember = isMember[project.creator];
        if (creatorIsMember) --count;
        uint256 memberAmount = count == 0 ? 0 : FixedPointMathLib.fullMulDiv(amount, 3, 10);
        uint256 tokenworksAmount = amount / 5;
        uint256 creatorAmount = amount - memberAmount - tokenworksAmount;
        // Settle earnings from other projects before skipping this project's member allocation.
        // Fractional earnings remain attached to the creator across every exclusion and rejoin.
        if (creatorIsMember) _settleMember(project.creator);
        _credit[project.creator] += creatorAmount;
        // Division residue stays accounted for in the hub; it is never given to future members.
        if (count != 0) accETHPerMember += FixedPointMathLib.fullMulDiv(memberAmount, MEMBER_SCALE, count);
        if (creatorIsMember) _memberIndex[project.creator] = accETHPerMember;
        totalDeposited += amount;
        totalTokenworksPaid += tokenworksAmount;
        accountedETH += amount - tokenworksAmount;
        emit RevenueDeposited(
            projectId, msg.sender, tokenworksSplitter, amount, creatorAmount, memberAmount, tokenworksAmount
        );
        if (tokenworksAmount != 0) SafeTransferLib.safeTransferETH(tokenworksSplitter, tokenworksAmount);
    }

    function _settleMember(address account) private {
        if (!isMember[account]) return;
        uint256 scaled = accETHPerMember - _memberIndex[account] + _memberFraction[account];
        _credit[account] += scaled / MEMBER_SCALE;
        _memberFraction[account] = scaled % MEMBER_SCALE;
        _memberIndex[account] = accETHPerMember;
    }

    function _claim(address account, address recipient) private returns (uint256 amount) {
        if (recipient == address(0) || recipient == address(this)) revert InvalidAddress();
        _settleMember(account);
        amount = _credit[account];
        if (amount == 0) revert NothingToClaim();
        delete _credit[account];
        totalClaimed += amount;
        accountedETH -= amount;
        SafeTransferLib.safeTransferETH(recipient, amount);
        emit Claimed(account, recipient, amount);
    }
}
