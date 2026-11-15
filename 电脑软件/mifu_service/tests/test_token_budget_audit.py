import importlib.util
import json
from pathlib import Path
import sys
import unittest
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from audit_token_budget import audit, inspect_question


class EmptyAuditTests(unittest.TestCase):
    def test_empty_manifest_is_not_reported_as_success(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / 'manifest.json').write_text(json.dumps({'splits': {}}))
            with self.assertRaisesRegex(ValueError, 'empty corpus'):
                audit(root, root / 'unused-tokenizer')


class CharacterTokenizer:
    """Deterministic boundary fixture; production reports use the real tokenizer."""
    mask_token, mask_token_id, cls_token_id, sep_token_id = '[MASK]', 1, 2, 3

    def __call__(self, text, **kwargs):
        ids = [ord(char) + 10 for char in text]
        if kwargs.get('truncation'):
            ids = ids[:kwargs['max_length']]
        return {'input_ids': ids}


@unittest.skipUnless(importlib.util.find_spec('laya'), 'Requires isolated Laya audit environment')
class TokenBudgetAuditTests(unittest.TestCase):
    def test_short_labels_preserve_complete_state(self):
        question = {'type': 'choice', 'instructions': 'Choose', 'criteria': {'a': 'a', 'b': 'b'}}
        result = inspect_question(CharacterTokenizer(), {'nozzle': .2, 'ams': 'ams_ht'}, question)
        self.assertEqual([], result['errors'])
        self.assertEqual(0, result['state_tokens_dropped'])

    def test_long_option_is_detected_even_when_sdk_options_remain_distinct(self):
        question = {'type': 'choice', 'instructions': 'Choose', 'criteria': {'a': 'x' * 100, 'b': 'y' * 100}}
        result = inspect_question(CharacterTokenizer(), {}, question)
        self.assertIn('option_description_truncated', result['errors'])
        self.assertNotIn('option_collision', result['errors'])

    def test_lost_state_and_lost_instruction_are_detected(self):
        question = {'type': 'choice', 'instructions': 'Choose ' * 80, 'criteria': {'a': 'a', 'b': 'b'}}
        result = inspect_question(CharacterTokenizer(), {'hardware': 'z' * 2000}, question)
        self.assertIn('state_truncated', result['errors'])
        self.assertIn('instruction_truncated', result['errors'])


if __name__ == '__main__':
    unittest.main()
