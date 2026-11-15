import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mifu_server import SDK_VERSION, build_question
from test_mifu_service import make_checkpoint, request
from training import train_model


class FormalInputAuditTests(unittest.TestCase):
    def test_hidden_option_truncation_stops_before_finetune_and_output_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / 'base'
            make_checkpoint(base)
            for name, duration in (('train', 10), ('eval', 20)):
                state, questions, _ = build_question(request(name, duration))
                row = {'state': state, 'questions': questions, 'expected': {'printer': 'candidate_00'}}
                (root / f'{name}.jsonl').write_text(json.dumps(row) + '\n', encoding='utf-8')
            finetune = Mock(side_effect=AssertionError('No optimization is permitted before input audit passes'))
            modules = {'torch': types.SimpleNamespace(cuda=types.SimpleNamespace(is_available=lambda: True)),
                       'transformers': types.SimpleNamespace(AutoTokenizer=types.SimpleNamespace(from_pretrained=lambda *a, **k: object())),
                       'laya.train': types.SimpleNamespace(TrainConfig=lambda **kw: kw, finetune=finetune)}
            with patch.dict(sys.modules, modules), patch('training.importlib.metadata.version', return_value=SDK_VERSION), \
                    patch('audit_token_budget.inspect_question', return_value={'errors': ['option_description_truncated']}):
                with self.assertRaisesRegex(ValueError, 'truncated'):
                    train_model(root / 'train.jsonl', root / 'eval.jsonl', base, root / 'out', 'test')
            finetune.assert_not_called()
            self.assertFalse((root / 'out').exists())


if __name__ == '__main__':
    unittest.main()
