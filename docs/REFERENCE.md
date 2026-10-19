# Playground reference

[Repository overview](../README.md) · [Deployments](../DEPLOYMENTS.md) · [Contracts](../src/playground) · [Tests](../test/playground)

Commands run from the repository root using the default Foundry profile. Network scripts retain project-specific ownership, recipient and Intake defaults; inspect or override those values for a different deployment. External service examples below are historical integration examples, not a guarantee of current availability or pricing.

A factory open to anyone while creation is enabled launches independent, ownable communities. The caller of
`factory.createPlayground()` becomes that Playground's owner and first member. Every factory-created
Playground has the same immutable Tokenworks splitter; its owner cannot redirect that share.

## Revenue

For each project's ETH deposited into its Playground:

| Recipient | Share of total revenue |
| --- | --- |
| Project creator (the member who called requestProject/createProject) | 50% |
| Other currently active Playground members, equally | 30% |
| Tokenworks | 15% |
| Frozen S02 holder snapshot | 5% |

The hub sends 20% to `TokenworksSplitter`, which reserves 75% of that receipt for Tokenworks and
forwards 25% to the holder splitter. The table's 15% and 5% are shares of total project revenue.
Playground ownership itself earns no separate cut. A Playground founder can earn a creator share
on their own projects and member shares on other members' projects while active.

A project's creator is excluded from that project's 30% pool, including when they remain a member.
A removed creator keeps its creator entitlement; all remaining active members share the 30%.
When there are no other active members, the creator receives the otherwise unallocated 30%:
80% creator and 20% Tokenworks splitter. No revenue is blocked by empty membership.

Token sales first pay the authorized swap caller 0.5% of newly produced ETH. The remaining 99.5%
uses the split above. Existing ETH and permissionless `depositETH()` forwarding earn no caller fee.
Creator/member credits remain in the hub for claims; the 20% is sent to the router immediately.

## Contracts and flow

Each chain uses the same contracts and the same frozen holder manifest:

- [PlaygroundFactory](../src/playground/PlaygroundFactory.sol): immutable default Intake and Tokenworks splitter; owner-controlled global
  availability flags, public community creation, and a registry (`playgrounds(index)`,
  `isPlayground(address)`, `playgroundCount()`).
- [TokenworksSplitter](../src/playground/TokenworksSplitter.sol): immutable Tokenworks recipient and holder splitter; cumulative 75/25
  accounting on its receipts, Tokenworks claims, and permissionless surplus allocation.
- [PlaygroundHolderSplitter](../src/playground/PlaygroundHolderSplitter.sol): immutable address/NFT-count weights, independent holder claims,
  and the existing one-year owner sweep policy.
- [Playground](../src/playground/Playground.sol): each community's members, project registry, owner-controlled metadata and Intake,
  shared swap-operator allowlist, and creator/member ETH accounting.
- [PlaygroundProject](../src/playground/PlaygroundProject.sol): one receiver implementation per Playground and a small clone per project.

```text
anyone -> factory.createPlayground() -> Playground (caller is owner + first member)
member -> Playground.requestProject(...) -> project receiver clone -> IMD Intake
project revenue -> receiver -> Playground.deposit(projectId)
                                  | 50% creator credits
                                  | 30% other-member credits
                                  + 20% TokenworksSplitter
                                           | 75% Tokenworks credits (15% of gross)
                                           + 25% holder splitter (5% of gross)
```

The system deployment creates three shared contracts: holder splitter, Tokenworks splitter, and
factory. Each new Playground adds a hub and its receiver implementation. Each project adds one
44-byte Solady `LibClone` receiver. The hubs are directly deployed contracts; only project receivers use clones. Each clone has a fixed implementation, with no upgrade administrator.
The factory does not charge a launch fee beyond transaction gas. Each chain has separate balances,
claims, and deployed addresses; sharing a manifest does not bridge funds or claims.

## Launching and metadata

After the factory is deployed, any wallet can call while creation is enabled:

```solidity
Playground playground = factory.createPlayground();
// These calls must come from the founding wallet, which already owns the Playground:
playground.setMetadata(
    "My Playground",
    "A description of our community",
    "ipfs://image-cid",
    "ipfs://banner-cid",
    "https://example.com",
    "https://x.com/example"
);
playground.inviteMember(otherMember);
// The invited wallet must send its own transaction to activate membership:
playground.acceptInvitation();
```

Only the owner can `inviteMember(wallet)`. The invited wallet then calls `acceptInvitation()`
itself; there is no direct owner-only member addition. `isInvited(wallet)` exposes pending status.
Until acceptance, the invitation adds nothing to `memberCount`, earns no member share, and grants
no project-creation or membership-based swap permission. Revenue participation starts at acceptance,
not at invitation. Explicit swap-operator grants remain a separate permission.

The owner can cancel a pending invitation with `revokeInvitation(wallet)` and remove an active
member with `removeMember(wallet)`. Acceptance consumes the invitation. A removed member needs a
new invitation and must accept again; its previous earnings and fractional carry are preserved,
with no earnings for the inactive interval. Pending invitations survive ownership transfer and can
be revoked by the new owner. The founder is the exception to this two-step flow: creating the
Playground already expresses consent, so the factory caller starts as its first member.

`setMetadata(name, description, image, banner, website, twitter)` replaces all six fields and emits
`MetadataUpdated`. `metadata()` returns all six strings. Empty fields clear optional values; there
is no on-chain URL validation or external fetching. Only the current owner can change metadata.

The factory emits `PlaygroundCreated(index, playground, creator)`; indices start at 1. Ownership
transfer uses ordinary inherited Solady behavior. It does not automatically add the new owner or
remove the old owner from membership. The current owner manages members and may update its own
Intake with `setIntake`. The factory's default Intake and every hub's Tokenworks destination stay fixed.
Plain ETH sent directly to a hub is rejected because a project ID is required. Send it to a project
receiver, or call `deposit(projectId)` with ETH. Receivers need `call` with enough gas when sent ETH;
Solidity's fixed 2,300-gas `transfer`/`send` stipend can be insufficient for their delegatecall.

## Global availability controls

The factory owner controls two independent flags, both initially `true`:

```solidity
factory.setPlaygroundCreationEnabled(false); // Prevent new communities.
factory.setLaunchesEnabled(false);           // Prevent new receivers and Intake requests in every community.
// Re-enable either independently by passing true.
```

`playgroundCreationEnabled()` gates only `factory.createPlayground()`. Existing Playgrounds can
still launch projects while creation is disabled, provided `launchesEnabled()` remains true.
Conversely, communities can be created while launches are disabled if creation remains enabled.

Every Playground stores its immutable `factory()` and reads the live launch flag before
`createProject()` or either `requestProject(...)` overload can proceed. This includes requests
through pre-created receivers, continuations, and all other Intake actions: no new Intake payment
is taken while launches are disabled. The flag affects both existing and future communities from
that factory. A hub owner cannot bypass it by changing Intake or transferring hub ownership.
If the factory cannot return its policy, launch calls revert rather than silently permitting them.

Disabling either flag leaves revenue reception, forwarding, swaps, claims, invitations, metadata,
and other administrative functions available. It does not cancel previously submitted Intake jobs
or stop already deployed projects. The factory owner is independent of individual Playground owners
and follows standard Solady ownership transfer/handover behavior. These are per-factory, per-chain
controls; changing Ethereum's factory does not change Robinhood's factory.

## Holder snapshot and claims

Both Ethereum and Robinhood use `PlaygroundHolderSplitter`. There are no live NFT ownership checks
on either chain. The saved manifest [`output/playground/s02-snapshot.json`](../output/playground/s02-snapshot.json) contains **240 addresses /
283 active S02 NFTs** at finalized Ethereum block **26,192,292**, with highest token ID **371**.
The exporter enumerates IDs 1 through `getCurrentSupply() + burnedTokenCount()` at that block,
excludes burned tokens, verifies the active count, sorts wallets, and combines each wallet's holdings.
Allocations are packed as a 20-byte address plus a 4-byte count. The constructor fixes their weights.

The script validates source chain, collection, ordering, counts and allocation hash; the contract
stores the source block number/hash, supply, maximum ID and allocation hash. This is a deployer-loaded
snapshot, not an on-chain proof of Ethereum ownership. Later NFT transfers, burns or mints do not
change either chain's weights. Recorded holders must control those addresses on the relevant chain,
including any contract wallets. The same holder can claim its independent share on both chains.

The holder splitter distributes all normally received ETH, including direct donations. Its cumulative
entitlement is `floor(totalReceived * nftCounts(holder) / SNAPSHOT_SUPPLY) - claimed(holder)`.
Use `pending(holder)`, `claim()`, `claimTo(recipient)`, or permissionless `claimFor(holder)`.
Playground's creator/member claims remain separate: `claim()`, `claimTo`, `claimFor`, and `claimable`.
On the Tokenworks router, anyone may call `claimTokenworks()` to pay the fixed recipient; only that
recipient may use `claimTokenworksTo(recipient)` to redirect its own credit.

The holder splitter is initially owned by the configured Tokenworks recipient. After 365 days from
its deployment, its owner may `sweep()` the full balance and permanently close holder claims.
Claims remain open until the first successful nonempty sweep. Later receipts remain sweepable and
do not reopen claims. This deadline belongs to the shared holder splitter: launching another
Playground does not reset or extend it. Holder-splitter ownership changes affect sweep authority,
not the router's fixed Tokenworks recipient or the snapshot weights.

## System deployment

Both scripts prepare five transactions: deploy the shared holder splitter, deploy the Tokenworks
splitter, deploy the factory, create one initial Playground, then disable further Playground creation.
The initial Playground belongs to the configured factory owner, who is also its first member.
At completion, `playgroundCreationEnabled()` is **false** and `launchesEnabled()` is **true**:
projects can be launched inside that initial Playground. Defaults:

- Tokenworks recipient / initial holder-splitter sweep owner: `0x019817aD02a31B990433542097bE29D97613E8Cb`.
- Factory owner / global availability administrator: `0x019817aD02a31B990433542097bE29D97613E8Cb`.
- Intake v2: `0xa43e6F75ee006411F79Ac1C84120606C2330DE82` ([IMD documentation](https://imd.fun/docs/#intake)).
- Snapshot: `output/playground/s02-snapshot.json` on **both** chains.

Optional overrides are `PLAYGROUND_TOKENWORKS`, `PLAYGROUND_FACTORY_OWNER`, `PLAYGROUND_INTAKE`,
and `PLAYGROUND_S02_SNAPSHOT`.
`PLAYGROUND_OWNER` is no longer used: each Playground's owner is its factory caller. These scripts
broadcast from `PLAYGROUND_FACTORY_OWNER` (or its default), since that wallet must create the initial
Playground and disable subsequent creation. The eventual signing wallet must match that address;
Tokenworks can use a different recipient. Both factory flags are initially enabled by the constructor;
the script turns Playground creation off after creating the first community. The factory owner
controls the flags but cannot change the shared router or default Intake.

Ethereum broadcast and verification (`MAINNET_RPC_URL` and `ETHERSCAN_API_KEY` in environment or `.env`):

```sh
forge script script/playground/DeployPlayground.s.sol:DeployPlayground \
  --rpc-url mainnet \
  --sender 0x019817aD02a31B990433542097bE29D97613E8Cb \
  --ledger --hd-paths "m/44'/60'/4'/0/0" \
  --slow --broadcast --verify --verifier etherscan -vvv
```

Robinhood mainnet, chain 4663, using the public RPC configured in `foundry.toml` and the
[RobinScan Etherscan explorer](https://robin.etherscan.io/). Verification uses `ETHERSCAN_API_KEY`
and Etherscan's [V2 endpoint for chain 4663](https://api.etherscan.io/v2/chainlist), passed explicitly:

```sh
forge script script/playground/DeployPlaygroundRobinhood.s.sol:DeployPlaygroundRobinhood \
  --rpc-url robinhood \
  --sender 0x019817aD02a31B990433542097bE29D97613E8Cb \
  --ledger --hd-paths "m/44'/60'/4'/0/0" \
  --offline --slow --broadcast --verify --verifier etherscan \
  --verifier-url 'https://api.etherscan.io/v2/api?chainid=4663' -vvv
```

For the original Foundry 1.5.1 deployment workflow, the Robinhood `[etherscan]` entry is required to associate `ETHERSCAN_API_KEY` with
chain 4663; without it, verification reports `Missing etherscan key for chain 4663` even when
the key exists. Keep `--offline` on Robinhood commands to skip external trace lookups that
otherwise throw `Chain 4663 not supported`. This option also prevents compiler downloads, so
Solidity 0.8.26 must already be installed (run `forge build` first
if needed). It does not disable RPC calls or the explicitly requested verification submission.
The explicit `--verifier-url` bypasses the built-in chain registry for verification.

These commands broadcast the five transactions and then request source verification. Verification is
an explorer submission, not an additional on-chain transaction. Remove `--broadcast` and `--verify`
to simulate without sending transactions. Save the printed initial Playground address after an
actual deployment; the scripts also print the factory, splitters and project receiver implementation.
The initial owner/member can immediately approve Intake payment to that Playground and call
`requestProject`. No additional members or swap routes are added automatically. Concrete DEX adapters
are still required for ERC20 fee conversion.

If more Playgrounds are wanted later, the factory owner calls `setPlaygroundCreationEnabled(true)`.
Each new creator then calls `createPlayground()` and becomes owner/first member of their community.
The separate `setLaunchesEnabled(bool)` flag continues to control project launches across all of them.

To deliberately refresh the frozen snapshot, use a new file and deploy **both chains with that file**:

```sh
python3 script/playground/export_s02_snapshot.py --output output/playground/s02-snapshot-new.json
export PLAYGROUND_S02_SNAPSHOT=output/playground/s02-snapshot-new.json
```

The exporter uses Python 3 and Foundry's `cast`, reads only `MAINNET_RPC_URL` from the environment
or a literal `.env` value, supports an explicit finalized `--block`, and refuses to overwrite files.
Keep manifests under `output/playground` for Foundry's read permissions. The scripts reject snapshots
exceeding the EVM initcode limit rather than truncating holders. Preserve the deployed manifest.

## Intake requests

For the default flow, an active member approves the **hub** for the ERC20 payment, then calls:

```solidity
(uint256 projectId, address receiver, bytes32 requestId) =
    playground.requestProject(action, body, paymentAsset, amount);
```

The hub creates and initializes a receiver clone, records the caller as creator, and transfers
exactly `amount` from that creator to the receiver. The receiver gives the current Intake an exact
temporary allowance, calls
`request(bytes32,bytes,(address,bytes4),address,uint256)`, and clears the allowance. The request has
no callback. The receiver, rather than the shared hub, is the Intake payer. Existing token revenue
is preserved, and payment is separate from distributable ETH. If any step reverts, the clone,
project registration, payment, and request all roll back. Retrying the same call creates a receiver
and submits a new request atomically. Each successful call to this overload creates a new project.

The separate calls remain available when a receiver is needed before submission:

```solidity
(uint256 projectId, address receiver) = playground.createProject();
// After approving the hub, the same active creator submits for that existing receiver:
bytes32 requestId = playground.requestProject(projectId, action, body, paymentAsset, amount);
```

The existing-project overload can submit further requests using the same receiver and payer
identity. A reverted request leaves that already-created receiver intact. The founding owner starts as a member. A later owner must also be an active member to create
or request projects; ownership alone does not bypass membership checks.

`requestProjectIds(intakeAddress, requestId)` records project provenance; a replacement Intake
can reuse an ID without colliding with the previous Intake. `setIntake` affects subsequent requests
for every project. External launch verification and result callbacks are not implemented.

### Historical Intake integration example

The integration example below used `launch.open@launch-1` on Ethereum and Robinhood Chain at a price of 0.5 IMD; Sepolia was oracle-only in that configuration. Before paying, read the service's [capabilities](https://api.imd.fun/requests/capabilities) and validate the request to confirm current action support, chain, payment token and amount. These service settings are not enforced constants of Playground. The recorded Ethereum example approved Playground for `500000000000000000` units of IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, then called:

```solidity
(uint256 projectId, address receiver, bytes32 requestId) = playground.requestProject(
    bytes32("launch.open@launch-1"), body, IMD, 500000000000000000
);
```

`body` is the launch's compact UTF-8 JSON, with an `onchain` kind and `chainId: 1` on Ethereum
or `chainId: 4663` on Robinhood. Use the same chain as the deployed receiver. IMD is
`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` on Ethereum and
`0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` on Robinhood. Validate the body with
`POST /requests/check` before paying. Follow `/intake/<chainId>/<transactionHash>` and the returned job/launch links; submission
does not mean deployment has completed, and a later refusal does not refund the request payment.

The [payer rules](https://imd.fun/docs/#intake-examples) in the recorded integration assigned the requester trading-fee share to the proxy that calls Intake: 1% of trades, paid in both pool currencies. Confirm the current downstream fee rules before relying on them. That revenue
enters this project's existing conversion and 50/30/15/5 accounting flow when received and forwarded.
For `evm_project`, `evm_contracts`, or `univ4_hook`, explicitly set `owner` to the intended admin
wallet: otherwise it defaults to the proxy, which cannot execute arbitrary admin calls. Choose
`economics.remainderTo` deliberately; omission sends remaining launch tokens to the proxy for its
revenue pipeline. The receiver cannot redirect factory requester fees or withdraw arbitrary assets
to an external wallet.

Playground submits one request per call. Intake execution and job processing are external service behavior and should be verified against current service documentation.

## ERC20 conversion

Swaps are modular in this initial implementation. A concrete DEX adapter must implement
`IPlaygroundSwapAdapter` before live token conversion is usable. No arbitrary router/calldata
execution is exposed to callers.

The owner configures routes on each receiver and any extra operators on the shared hub:

```solidity
receiver.configureSwap(asset, adapter);
playground.setSwapCaller(operator, true);
// Active Playground members or explicitly approved operators can execute:
receiver.swapToETH(asset, amountIn, minETHOut, deadline);
```

`canSwap(account)` is true for either an active member or an explicitly approved operator. Every
receiver checks this live on the hub, so a single allowlist update applies to all projects. Removing
a member removes its automatic swap permission, unless it is also explicitly approved. Revoking an
explicit grant does not override active membership. The founding owner can swap because it starts as a member. A later owner needs active membership
or an explicit operator grant. Operator status grants no membership share or project-creation
rights. `swapCallers` and `SwapCallerSet` expose the explicit grants for inspection/indexing.

Callers are trusted to choose an appropriate `amountIn`, `minETHOut`, and deadline for each trade.
`minETHOut` must be nonzero and refers to actual ETH received **after DEX/hook fees, before the 0.5%
caller reward**. There is no independent oracle or owner-maintained price floor. All active members
and explicitly approved operators can price and execute sales for every project's configured assets.

The adapter must pull exactly `amountIn` and send native ETH back to the receiver. Approval is
limited to that input and cleared afterward. The receiver checks actual token and ETH balance
changes, ignoring the adapter's reported output. It computes:

```text
newETH = ETH balance after swap - ETH balance before swap
callerReward = floor(newETH * 50 / 10_000)
projectDeposit = preexistingETH + newETH - callerReward
```

The receiver deposits the project proceeds, then pays `msg.sender` the reward. An underpaying swap
or failed hub deposit rolls back the whole transaction, including the reward. Preexisting ETH is
forwarded without a fee; `depositETH()` remains permissionless and unrewarded. A sale producing
1 ETH pays 0.005 ETH to its caller and deposits 0.995 ETH for the 50/30/15/5 split. The reward rounds
down for very small outputs. `Swapped` records the caller, actual output, and reward.

`clearSwap(asset)` disables a route. Only the current hub owner can configure or clear routes;
swap authorization alone cannot change the adapter, project identity, or deposit destination.
Rebase/reflection or sender-tax tokens that violate exact balance checks are unsupported.

## Accounting boundaries

- Member accounting is O(1). Before each distribution, the active creator's prior member earnings
  are settled, then its index skips only its own project's member increment. Fractions survive this
  exclusion, claims, removal and rejoining. New members do not receive past earnings.
- Revenue ownership means project creator, not factory caller or current Playground owner. A
  member deploying a project earns that project's 50%; removing it does not revoke that entitlement.
- Shares are determined when ETH reaches the hub. Tokens and ETH waiting in a receiver do not
  snapshot membership. Ownership changes do not redirect the fixed Tokenworks share, and ordinary
  ownership renunciation does not block accounting or existing claims.
- Member and Tokenworks amounts round down to wei; the creator gets the remainder. Member fractions
  use `1e36` precision. Accumulator division dust stays reserved and cannot be claimed as surplus.
  Tokenworks router rounding is cumulative: holders receive `floor(totalReceived / 4)` over time.
- Rejecting claim recipients do not block deposits. Hub and Tokenworks credits can be claimed to a
  different address by their beneficiary. Holder forwarding uses a normal ETH call to execute the
  snapshot splitter's accounting.
- Forced ETH / ETH attached to payable ownership calls bypass receive accounting. Hub owners may
  attribute only surplus using `allocateSurplus(projectId)`; anyone may distribute router surplus
  with `distributeSurplus()`. Forced holder-splitter ETH remains sweepable residue.
- `totalDeposited = totalClaimed + totalTokenworksPaid + accountedETH` in each hub. The 20% sent to
  the router is no longer a hub liability. Each router and holder splitter tracks its own claims.

## Validation

```sh
forge test --offline
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test/playground -p 'test_*.py'
```

Invitation, availability, revenue and deployment-script behavior are covered by the local tests above. Unit/fuzz tests use local Intake/token/adapter mocks and snapshot fixtures; they do not exercise paid IMD launches or production DEX adapters. Deployment simulations also do not establish successful paid launches or actual downstream factory fee payouts. See [DEPLOYMENTS.md](../DEPLOYMENTS.md) for recorded addresses and transaction receipts. Concrete DEX adapters are outside this implementation.
