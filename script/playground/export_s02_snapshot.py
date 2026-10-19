#!/usr/bin/env python3
"""Freeze S02 wallet weights at one finalized Ethereum block for Robinhood deployment."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import urllib.request

COLLECTION = '0xb33d806a94b6770c9d309e0842a75f8e6edcd5a6'


class RPC:
    def __init__(self, url):
        self.url = url

    def batch(self, calls):
        payload = [dict(jsonrpc='2.0', id=i, method=m, params=p) for i, (m, p) in enumerate(calls)]
        request = urllib.request.Request(self.url, json.dumps(payload).encode(), {'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                rows = json.load(response)
        except Exception:
            raise RuntimeError('RPC request failed; check endpoint access and batch support') from None
        if not isinstance(rows, list) or len(rows) != len(calls):
            raise RuntimeError('RPC returned an incomplete batch')
        by_id = {row.get('id'): row for row in rows}
        if set(by_id) != set(range(len(calls))):
            raise RuntimeError('RPC returned invalid response IDs')
        return [by_id[i] for i in range(len(calls))]

    def call(self, method, params):
        row = self.batch([(method, params)])[0]
        if 'error' in row or 'result' not in row:
            raise RuntimeError(f'RPC {method} failed')
        return row['result']


def allocation_hash(packed):
    result = subprocess.run(['cast', 'keccak', '0x' + packed.hex()], capture_output=True, text=True, check=True)
    digest = result.stdout.strip()
    if len(digest) != 66 or not digest.startswith('0x'):
        raise RuntimeError('cast returned an invalid allocation hash')
    return digest


def snapshot(rpc, block='finalized', batch_size=50, hasher=allocation_hash):
    if int(rpc.call('eth_chainId', []), 16) != 1:
        raise RuntimeError('Snapshot RPC must be Ethereum mainnet')
    finalized = rpc.call('eth_getBlockByNumber', ['finalized', False])
    if not finalized:
        raise RuntimeError('RPC does not provide a finalized block')
    chosen = finalized if block == 'finalized' else rpc.call('eth_getBlockByNumber', [hex(int(block, 0)), False])
    if not chosen or int(chosen['number'], 16) > int(finalized['number'], 16):
        raise RuntimeError('Snapshot block must be finalized')
    tag, block_hash = chosen['number'], chosen['hash']
    def read(selector):
        return int(rpc.call('eth_call', [{'to': COLLECTION, 'data': selector}, tag]), 16)
    supply = read('0x4f3e1efc')
    burned = read('0xe32a748f')
    maximum = supply + burned
    if supply <= 0:
        raise RuntimeError('S02 snapshot has no active supply')
    holders = Counter()
    missing = 0
    for start in range(1, maximum + 1, batch_size):
        calls = [('eth_call', [{'to': COLLECTION, 'data': '0x6352211e' + f'{token:064x}'}, tag])
                 for token in range(start, min(start + batch_size, maximum + 1))]
        for row in rpc.batch(calls):
            if 'error' in row:
                # Only an explicit EVM revert can represent a burned token; never skip RPC failures.
                if 'execution reverted' not in str(row['error'].get('message', '')).lower():
                    raise RuntimeError('ownerOf RPC failure (not an execution revert)')
                missing += 1
                continue
            value = row.get('result', '')
            if not isinstance(value, str) or len(value) != 66 or not value.startswith('0x'):
                raise RuntimeError('Invalid ownerOf result')
            numeric = int(value, 16)
            if not 0 < numeric < 2 ** 160:
                raise RuntimeError('Invalid ownerOf address')
            holders[f'0x{numeric:040x}'] += 1
    if sum(holders.values()) != supply or missing != burned:
        raise RuntimeError('Owner enumeration does not match active supply and burned count')
    if rpc.call('eth_getBlockByNumber', [tag, False])['hash'] != block_hash:
        raise RuntimeError('Snapshot block hash changed during enumeration')
    addresses = sorted(holders)
    if any(holders[a] >= 2 ** 32 for a in addresses):
        raise RuntimeError('NFT count exceeds packed uint32 capacity')
    packed = b''.join(bytes.fromhex(a[2:]) + holders[a].to_bytes(4, 'big') for a in addresses)
    return dict(schemaVersion=1, sourceChainId=1, collection=COLLECTION,
                blockNumber=int(tag, 16), blockHash=block_hash, supply=supply, maxTokenId=maximum,
                holders=addresses, counts=[holders[a] for a in addresses], allocationHash=hasher(packed))


def configured_rpc():
    if os.environ.get('MAINNET_RPC_URL'):
        return os.environ['MAINNET_RPC_URL']
    # Read a literal value only; never source .env or execute substitutions.
    env = Path('.env')
    if env.exists():
        for line in env.read_text().splitlines():
            key, separator, value = line.removeprefix('export ').partition('=')
            if separator and key.strip() == 'MAINNET_RPC_URL':
                parts = shlex.split(value, comments=True)
                if len(parts) == 1 and '$' not in parts[0] and '`' not in parts[0]:
                    return parts[0]
    raise RuntimeError('Set MAINNET_RPC_URL in the environment or .env')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--block', default='finalized', help='Finalized block number (decimal or 0x), default: finalized')
    parser.add_argument('--output', type=Path, default=Path('output/playground/s02-snapshot.json'))
    args = parser.parse_args()
    if args.output.exists():
        raise RuntimeError('Output already exists; choose a new --output to preserve the frozen snapshot')
    data = snapshot(RPC(configured_rpc()), args.block)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as output:
        output.write(json.dumps(data, indent=2) + '\n')
    print(f"Saved {len(data['holders'])} holders / {data['supply']} NFTs at Ethereum block {data['blockNumber']} to {args.output}")
    print(f"Allocation hash: {data['allocationHash']}")


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as error:
        # No transport exception details or endpoint URLs are printed.
        print(f'Snapshot export failed: {error}', file=sys.stderr)
        sys.exit(1)
