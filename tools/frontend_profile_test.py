"""Independent known histograms check category accounting and overlap reporting."""
import unittest
from run_frontend_profile import parse_profile, check_saved_configuration


def fixture():
    # Hand-selected ten samples: 5 hit, 1 miss, 3 backend, 1 redirect.
    # Redirect-first attribution instead gives 5 hit, 1 miss, 1 backend, 3 redirect.
    samples={0:3,8:2,4:1,9:1,3:1,6:1,15:1}
    lines=['schema 1','iterations 2']
    for s,factor in enumerate([4,3,1,1]):
        lines.append(f'scope {s} {100*factor} {20*factor} {10*factor}')
        for k,count in enumerate([5,1,3,1]):
            lines.append(f'category {s} {k} {count*factor}')
        for mask in range(16):
            lines.append(f'joint {s} {mask} {samples.get(mask,0)*factor}')
        lines.extend([f'backend {s} 0 0 0',f'redirects {s} 0 0'])
    lines.extend(['requests 100 90 5 5','latencies 270 100 20'])
    for k in range(65):
        lines.extend([f'gap {k} {50 if k==4 else 0}',f'hit_latency {k} {90 if k==3 else 0}'])
    return '\n'.join(lines)+'\n'


class FrontendProfileTests(unittest.TestCase):
    def test_cannot_relabel_another_rtl_or_firmware_configuration(self):
        current={'variant':'current_worktree','sha256':'a'*64}
        historical={'variant':'historical_reference','sha256':'b'*64,'git_commit':'c'*40}
        saved={'multiplier':current,'runs':[{'iterations':3}]}
        check_saved_configuration(saved,current,3)
        with self.assertRaises(ValueError):check_saved_configuration(saved,historical,3)
        with self.assertRaises(ValueError):check_saved_configuration(saved,current,5)

    def test_exact_partition_and_two_denominators(self):
        r=parse_profile(fixture())
        s=r['scopes'][2]
        self.assertEqual(s['counts'],dict(hit_lookup_handoff=5,miss=1,backend=3,redirect=1))
        self.assertEqual(s['percent_of_frontend']['backend'],30)
        self.assertEqual(s['percent_of_cycles']['backend'],3)
        self.assertEqual(s['frontend_percent_of_cycles'],10)
        self.assertEqual(s['hit_without_response'],3)
        self.assertEqual(s['hit_ready_handoff'],2)

    def test_overlap_and_priority_sensitivity(self):
        s=parse_profile(fixture())['scopes'][2]
        self.assertEqual(s['overlaps']['backend_and_redirect'],2)
        self.assertEqual(s['overlaps']['backend_and_miss'],1)
        self.assertEqual(s['overlaps']['redirect_and_miss'],2)
        self.assertEqual(s['overlaps']['all_three'],1)
        self.assertEqual(s['overlaps']['backend_with_available_response'],2)
        self.assertEqual(s['redirect_first_counts'],dict(hit_lookup_handoff=5,miss=1,backend=1,redirect=3))

    def test_invalid_or_incomplete_accounting_is_rejected(self):
        original=fixture()
        for bad in [original.replace('category 0 0 20','category 0 0 21'),
                    original.replace('joint 0 0 12\n',''),
                    original+'schema 1\n',
                    original.replace('joint 0 0 12','joint 0 0 -1'),
                    original.replace('scope 1 300 60 30','scope 1 500 60 30'),
                    original.replace('latencies 270 100 20\n','')]:
            with self.subTest(bad=bad[:50]):
                with self.assertRaises(ValueError):parse_profile(bad)


if __name__=='__main__':
    unittest.main()
