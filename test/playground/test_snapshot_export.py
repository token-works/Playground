import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('snapshot_export', Path(__file__).resolve().parents[2] / 'script/playground/export_s02_snapshot.py')
export = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(export)


class FakeRPC:
    def __init__(self):
        self.chain = '0x1'
        self.hash = '0x' + '12' * 32
        self.reorg = False
        self.error = 'execution reverted'
        self.supply = 3
        self.calls = []

    def call(self, method, params):
        self.calls.append((method, params))
        if method == 'eth_chainId':
            return self.chain
        if method == 'eth_getBlockByNumber':
            return dict(number='0x64', hash=('0x' + '34' * 32) if self.reorg and params[0] == '0x64' else self.hash)
        if method == 'eth_call':
            return hex(self.supply if params[0]['data'] == '0x4f3e1efc' else 1)
        raise AssertionError(method)

    def batch(self, calls):
        self.calls.extend(calls)
        result = []
        for _, params in calls:
            token = int(params[0]['data'][10:], 16)
            if token == 2:
                result.append({'error': {'message': self.error}})
            else:
                result.append({'result': '0x' + f'{512 if token == 3 else 256:064x}'})
        return result


class SnapshotExportTest(unittest.TestCase):
    def test_burn_aware_sorted_counts_and_pinned_calls(self):
        rpc = FakeRPC()
        packed = []
        result = export.snapshot(rpc, batch_size=2, hasher=lambda data: packed.append(data) or 'hash')
        self.assertEqual(result['counts'], [2, 1])
        self.assertEqual(result['supply'], 3)
        self.assertEqual(result['maxTokenId'], 4)
        self.assertEqual(result['blockHash'], rpc.hash)
        self.assertEqual(len(packed[0]), 48)
        self.assertEqual(int.from_bytes(packed[0][20:24], 'big'), 2)
        for method, params in rpc.calls:
            if method == 'eth_call':
                self.assertEqual(params[1], '0x64')

    def test_refuses_foreign_chain(self):
        rpc = FakeRPC(); rpc.chain = '0x1237'
        with self.assertRaisesRegex(RuntimeError, 'Ethereum'):
            export.snapshot(rpc)

    def test_rpc_failure_is_not_treated_as_burn(self):
        rpc = FakeRPC(); rpc.error = 'rate limit exceeded'
        with self.assertRaisesRegex(RuntimeError, 'not an execution revert'):
            export.snapshot(rpc)

    def test_refuses_reorganized_block(self):
        rpc = FakeRPC(); rpc.reorg = True
        with self.assertRaisesRegex(RuntimeError, 'hash changed'):
            export.snapshot(rpc)

    def test_export_matches_solidity_fixture_hash(self):
        fixture = __import__('json').loads((Path(__file__).resolve().parents[1] / 'fixtures/playground/s02-snapshot.json').read_text())
        result = export.snapshot(FakeRPC())
        self.assertEqual(result['allocationHash'], fixture['allocationHash'])
        self.assertEqual(result['holders'], fixture['holders'])


if __name__ == '__main__':
    unittest.main()
