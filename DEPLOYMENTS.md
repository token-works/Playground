# Deployments

These are the successfully deployed Playground contracts on Ethereum and Robinhood. Every deployment transaction listed below has a successful receipt. Owners and individual fee-recipient wallets are intentionally omitted.

`PlaygroundFactory` deploys each `Playground` directly. There is no separate Playground implementation contract or upgradeable Playground proxy. Each Playground creates its own fixed `PlaygroundProject` implementation; the implementations below belong to the initial Playground on each chain. Individual project receivers are minimal clones of that implementation.

## Ethereum — chain ID 1

| Contract | Address | Deployment block |
| --- | --- | --- |
| PlaygroundFactory | [0xccfe5edce3dccb14d1f84e7e907a84a47f7737a7](https://etherscan.io/address/0xccfe5edce3dccb14d1f84e7e907a84a47f7737a7) | 26,192,620 |
| Initial Playground | [0xdd4a83daf532778c55f8806c9adf9a0f0ebb62de](https://etherscan.io/address/0xdd4a83daf532778c55f8806c9adf9a0f0ebb62de) | 26,192,622 |
| PlaygroundProject implementation | [0x7786b4af4a7d5e2f23e5c0dcefcad1c001d7ccea](https://etherscan.io/address/0x7786b4af4a7d5e2f23e5c0dcefcad1c001d7ccea) | 26,192,622 |
| PlaygroundHolderSplitter | [0xbdf989658c6774dc9a388cdd32bcfa91cb8649b0](https://etherscan.io/address/0xbdf989658c6774dc9a388cdd32bcfa91cb8649b0) | 26,192,613 |
| TokenworksSplitter | [0x13189f137c147128ba21603917ee111cc152e8bd](https://etherscan.io/address/0x13189f137c147128ba21603917ee111cc152e8bd) | 26,192,616 |

The [factory deployment](https://etherscan.io/tx/0x9df26c8fa973c3d82b470d2b20463060c5096ea98b77794ae4adaf9b084b57f2) was followed by the [initial Playground and project implementation deployment](https://etherscan.io/tx/0x51a7ca112399ec79a7dbc3f0d61180b3fd6d7adab8d73d30d31d50e4d440e2b0).

## Robinhood — chain ID 4663

| Contract | Address | Deployment block |
| --- | --- | --- |
| PlaygroundFactory | [0xa0cbb9faafb4241d57392223eca8799f299ed060](https://robin.etherscan.io/address/0xa0cbb9faafb4241d57392223eca8799f299ed060) | 88,601,289 |
| Initial Playground | [0xe7db06c9726a69fdaa4020e7bc07a1c08328035e](https://robin.etherscan.io/address/0xe7db06c9726a69fdaa4020e7bc07a1c08328035e) | 88,601,335 |
| PlaygroundProject implementation | [0xadb5a1a296ebcd0d72120c2adc9db7419cd617a0](https://robin.etherscan.io/address/0xadb5a1a296ebcd0d72120c2adc9db7419cd617a0) | 88,601,335 |
| PlaygroundHolderSplitter | [0xa20ccd62b33142fc357b6449422dd53c0d5ae6af](https://robin.etherscan.io/address/0xa20ccd62b33142fc357b6449422dd53c0d5ae6af) | 88,601,187 |
| TokenworksSplitter | [0xa4cde76aaca6148ea52715cdd3f460f7fe091783](https://robin.etherscan.io/address/0xa4cde76aaca6148ea52715cdd3f460f7fe091783) | 88,601,235 |

The [factory deployment](https://robin.etherscan.io/tx/0x34b10fd1c5db854e3628645dcd8c408bf7e55780ab52a21f3ba0d644d4801384) was followed by the [initial Playground and project implementation deployment](https://robin.etherscan.io/tx/0xc7c10000eff40d5aa3c8dc06fc098e0e681490536fbe253046ad2dfa53374542).
