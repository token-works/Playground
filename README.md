# Playground

Solidity contracts for independent communities that launch projects through an Intake service and share project revenue. Anyone can create a Playground while factory creation is enabled; the creator becomes its owner and first member. This repository contains the contracts, deployment scripts, tests and frozen holder manifest.

## Architecture

| Contract | Purpose |
| --- | --- |
| [PlaygroundFactory](src/playground/PlaygroundFactory.sol) | Creates communities, records them and controls factory-wide availability flags |
| [Playground](src/playground/Playground.sol) | Community membership, project registration, Intake requests and creator/member ETH claims |
| [PlaygroundProject](src/playground/PlaygroundProject.sol) | Project-specific Intake payer and revenue receiver, with configurable token-to-ETH adapters |
| [TokenworksSplitter](src/playground/TokenworksSplitter.sol) | Routes its receipts between the fixed Tokenworks recipient and holder splitter |
| [PlaygroundHolderSplitter](src/playground/PlaygroundHolderSplitter.sol) | Frozen NFT-holder weights, ETH claims and a delayed owner sweep |

Four [interfaces](src/playground/interfaces) define hub, factory, Intake and swap-adapter integration. Each community is a directly deployed `Playground` and deploys its own receiver implementation. Its projects use immutable receiver clones with separate project IDs and balances. **The community hubs are not clones of a shared Playground implementation.** No upgrade mechanism is included.

## Revenue

ETH deposited for a project is allocated as follows, subject to integer rounding:

| Recipient | Share |
| --- | ---: |
| Project creator | 50% |
| Other active community members, equally | 30% |
| Tokenworks | 15% |
| Frozen S02 holder snapshot | 5% |

The creator is excluded from its own project's member share. If no other active members exist, the creator receives 80% and the splitters receive 20%. Removing a creator preserves its creator entitlement and previously earned credits. Membership is evaluated when ETH reaches the hub, rather than when a receiver first receives assets. Playground ownership earns no separate cut.

An authorized token conversion pays its caller **0.5% of newly produced ETH**, then applies the table to the remainder. Pre-existing ETH and permissionless `depositETH()` forwarding earn no caller reward. Creator/member and Tokenworks shares use claim accounting; holder funds are forwarded immediately to their splitter.

## Prompting projects to return revenue to Playground

Name the **project receiver clone** as the destination for project revenue. The Playground hub, factory and project implementation are different contracts. Plain ETH sent to the hub reverts; ETH sent to the receiver waits there until forwarded into the hub's accounting.

### Prepare the receiver and request

If your prompt needs an explicit receiver address, an active member should first call `playground.createProject()`. Read `ProjectCreated` or `projects(projectId)` to obtain the receiver, and verify its `playground()` and `projectId()` getters. Then the same creator, still an active member, approves the **hub** for the Intake payment and submits through the existing-project overload:

```solidity
playground.requestProject(projectId, action, body, paymentAsset, amount);
```

This preserves the receiver as the Intake payer. The four-argument overload creates a new receiver for each successful request and passes the body unchanged: it does **not** substitute receiver-address placeholders. For that flow, the prompt must tell the worker to resolve and validate the actual Intake payer before configuring revenue destinations. Merely mentioning Playground in a prompt submitted directly from a wallet does not make its receiver the payer.

Keep administrative ownership separate from revenue collection. For supported IMD launch kinds (`evm_project`, `evm_contracts`, `univ4_hook`), explicitly set the request body's `owner` to your admin wallet or multisig. Where token economics apply, set `economics.remainderTo` to the receiver if the remaining launch tokens should enter this revenue flow. That field controls token allocation, not ongoing application fees. Requester trading fees follow the service's payer rules; verify the current [IMD request fields and payer rules](https://imd.fun/docs/#intake-examples) rather than assuming the prose changes them. The receiver has no arbitrary execution function for administration or external fee claims.

### Copy-pastable prompt block

Append this to your project description and replace every placeholder before submission:

```text
Playground revenue integration:
- Chain ID: <CHAIN_ID>
- Playground hub: <PLAYGROUND_ADDRESS>
- Existing project ID: <PROJECT_ID>
- Project revenue receiver clone: <RECEIVER_ADDRESS>
- Contract administrator: <ADMIN_WALLET_OR_MULTISIG>
- Revenue model: <EXACT_FEES_OR_INCOME_SOURCES,_RATES,ASSETS_AND_WHEN_PAYABLE>

Verify that the hub registers this receiver for this project and that the
receiver's playground() and projectId() getters match. Route all project-owned
revenue described above to this receiver, including each applicable fee,
royalty, treasury or withdrawal-recipient setting. Keep user deposits, escrow,
refunds and other funds owed to users separate from project revenue.

Use the admin address for administrative roles. Do not infer fee recipients
from the deployer, owner, msg.sender or tx.origin. Keep this project's receiver
as the requester when submitting through Playground's Intake flow.

Prefer native ETH revenue. Pay the receiver with a payable call and sufficient
gas, checking success. Receiving ETH alone does not distribute it: provide an
operational path for anyone to subsequently call receiver.depositETH() with
ZERO msg.value. The receiver forwards its ETH balance to the correct project.
Do not duplicate the revenue split; Playground applies its existing accounting.

If revenue is held upstream, provide permissionless release to the fixed
receiver. Do not require the receiver to make an arbitrary claim or admin call.

For ERC20 revenue, identify every expected token and supply a compatible
IPlaygroundSwapAdapter route to native ETH. Document the Playground-owner
configuration and the active member or approved operator that will call
swapToETH with appropriate minimum output and deadline. Verify token transfer
rules permit the route. Token conversion is not automatic; the receiver's
existing 0.5% caller incentive applies to newly produced ETH.

Verify an actual revenue-producing action, payout to this receiver, forwarding
or token conversion, and the resulting creator/member credits and splitter
payments. Show the configured receiver and any unfinished setup steps in the
deployment report. Document who, if anyone, can change the revenue destination.
```

ETH forwarding is permissionless but still needs a transaction; name the UI action or keeper that will trigger it. ERC20 conversion additionally needs an owner-configured adapter and an authorized caller. This repository supplies the adapter interface, not a production DEX adapter. Without that setup, received tokens remain in the project receiver. See the [conversion reference](docs/REFERENCE.md#erc20-conversion) for its exact balance checks and permissions.

## Membership and controls

- Owners invite wallets; each invited wallet must call `acceptInvitation()` before it becomes a member. Invitations alone earn no share and grant no member permissions. The founder starts active automatically.
- Active members can register/request projects and execute configured token conversions. Explicit swap operators can also convert revenue, but receive no membership rights or member share.
- A community owner manages invitations/removals, metadata, its Intake address, swap operators and each receiver's adapter routes. It can attribute surplus ETH to a project and forward accidentally received hub tokens into a project receiver. It cannot change the fixed revenue percentages or Tokenworks destination. Ownership transfer does not change membership automatically.
- The factory owner can independently disable new communities and new project creation/Intake requests across its communities. Existing revenue forwarding, swaps and claims remain available. These flags do not cancel previously submitted Intake jobs.

**Concrete DEX adapters are not included.** ERC20 conversion requires a deployed adapter implementing [IPlaygroundSwapAdapter](src/playground/interfaces/IPlaygroundSwapAdapter.sol) and an owner-configured route. Members/operators choose the amount, minimum output and deadline; there is no independent price oracle or slippage floor. These callers and configured adapters are trusted within that role.

## Frozen holder allocation

The included [S02 manifest](output/playground/s02-snapshot.json) records 240 addresses holding 283 NFTs at Ethereum block 26,192,292. Weights are fixed at deployment, not updated from live NFT ownership. Deployments on different chains have separate balances and claims.

**After 365 days from the holder splitter's deployment, its owner can sweep the full balance and permanently close holder claims.** Claims remain available until the first successful nonempty sweep; later receipts remain sweepable. Creating another community does not restart this deadline. This authority belongs to the holder-splitter owner, separately from community and factory administration.

## Build and test

Install Foundry and Python 3, then replace the repository URL below:

```sh
git clone --recurse-submodules "YOUR_REPOSITORY_URL" playground
cd playground
forge build --offline
forge test --offline
python3 -m unittest discover -s test/playground -p 'test_*.py'
```

For an existing checkout, initialize dependencies with `git submodule update --init --recursive`. Offline builds require Solidity 0.8.26 to be available locally; run `forge build` once with network access if Foundry needs to fetch it. The default [configuration](foundry.toml) uses Solidity 0.8.26, Cancun, via IR, optimizer runs 1 and no CBOR/compiler metadata hash. No custom profile is needed.

Local Solidity tests use Intake/token/adapter mocks and snapshot fixtures. Python tests cover the snapshot exporter. These tests do not establish current external service availability, paid launch success or production DEX-adapter behavior.

See [DEPLOYMENTS.md](DEPLOYMENTS.md) for deployment records and [docs/REFERENCE.md](docs/REFERENCE.md) for contract behavior, request examples and operational commands. Copy [.env.example](.env.example) to `.env` to configure deployment credentials and overrides. Scripts in [script/playground](script/playground) include project-specific owners, Intake and recipient defaults; review or override them for another deployment. Intake action support, payment prices and downstream economics must be checked with the service before submitting a paid request.

## License

Project contracts are [MIT licensed](LICENSE). Dependencies retain their respective licenses. No independent security audit is claimed.
