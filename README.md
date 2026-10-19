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
