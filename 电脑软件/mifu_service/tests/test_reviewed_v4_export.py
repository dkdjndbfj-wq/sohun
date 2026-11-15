"""Offline export tests. Token audit doubles are fixtures, not tokenizer evidence."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from decision_contract import SCHEMA, ContractError, build_decision_input, normalize_request
from outcome_collection import digest
from reviewed_v4_export import (SPLITS, export_reviewed_v4, prepare_review_template, review_binding)
from test_decision_contract import live_request
from test_mifu_service import make_checkpoint
from training import export_dataset, train_model


def fixture(index, count=2):
    request = live_request(count)
    request['requestId'] = f'request-{index}'
    request['decision_context']['snapshot_id'] = f'snapshot-{index}'
    request['plate'].update(id=f'plate-{index}', taskId=f'task-{index}', estimated_seconds=3600 + index)
    for candidate in request['candidates']:
        candidate['admission']['snapshot_id'] = f'snapshot-{index}'
    record = {'recordId': f'record-{index}', 'createdAt': '1970-01-01T00:18:20Z',
              'request': request, 'feedback': 'observed', 'selectedCandidateId': 'device-0',
              'source': 'client_feedback_unverified', 'trainingEligible': False}
    seal(record)
    return record, label_for(record, f'episode-{index}')


def seal(record):
    record['submissionSha256'] = digest({key: record[key] for key in
        ('request', 'decision', 'feedback', 'selectedCandidateId', 'outcome', 'observation') if key in record})


def label_for(record, episode):
    return {**review_binding(record), 'episodeId': episode, 'selectedCandidateId': 'device-0',
            'reviewSource': 'expert_review', 'reviewer': 'fixture-person-not-real-review',
            'rationale': 'Unit test label only; not quality evidence', 'reviewedAt': '1970-01-01T00:20:00Z'}


class ReviewedV4ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.records_path = self.root / 'feedback.jsonl'
        self.labels_path = self.root / 'reviews.jsonl'
        pairs = [fixture(index) for index in range(8)]
        self.records = [pair[0] for pair in pairs]
        self.labels = [pair[1] for pair in pairs]

    def tearDown(self):
        self.temp.cleanup()

    def inputs(self):
        for path, rows in ((self.records_path, self.records), (self.labels_path, self.labels)):
            path.write_text(''.join(json.dumps(row) + '\n' for row in rows), encoding='utf-8')

    def export(self, name='bundle', **kwargs):
        self.inputs()
        return export_reviewed_v4(self.records_path, self.labels_path, self.root / name, now_epoch_s=2000, **kwargs)

    def rebind(self, index):
        seal(self.records[index])
        self.labels[index].update(review_binding(self.records[index]))

    def source_rows(self, name='bundle'):
        return [json.loads(line) for line in (self.root / name / 'sources.jsonl').read_text(encoding='utf-8').splitlines()]

    def tokenizer(self):
        directory = self.root / 'fixture-tokenizer'
        directory.mkdir()
        (directory / 'tokenizer.json').write_text('{"fixture":"not_a_real_tokenizer"}', encoding='utf-8')
        return directory

    def audit_stubs(self, result=None):
        return patch('reviewed_v4_export._load_local_tokenizer', return_value=(object(), {'laya': 'test-double-not-real-audit'})), \
            patch('audit_token_budget.inspect_question', return_value=result or {
                'errors': [], 'sequence_tokens': 200, 'max_option_tokens': 24})

    def test_no_tokenizer_produces_only_pending_previews_and_no_training_or_ready(self):
        with patch.dict(sys.modules, {'torch': None, 'laya': None, 'transformers': None}):
            report = self.export()
        self.assertEqual('pending_token_audit', report['status'])
        self.assertEqual('pending', report['tokenAudit']['status'])
        self.assertFalse(report['tokenAudit']['allRowsAudited'])
        for field in ('trainingFilesWritten', 'trainingStarted', 'modelReady', 'deployable', 'automaticExecutionAuthorized'):
            self.assertFalse(report[field])
        self.assertEqual(8, report['exportedRows'])
        self.assertEqual(8, report['groupCount'])
        for split in SPLITS:
            self.assertGreater(report['splitRows'][split], 0)
            self.assertFalse((self.root / 'bundle' / f'{split}.jsonl').exists())
            row = json.loads((self.root / 'bundle' / f'pending_{split}.jsonl').read_text(encoding='utf-8').splitlines()[0])
            self.assertNotIn('state', row)
            self.assertEqual(SCHEMA, row['inputContract'])
            self.assertEqual(SCHEMA, row['model_input_preview']['state']['schema'])
        self.assertFalse((self.root / 'bundle/mifu_manifest.json').exists())
        self.assertIn('unverified', report['sourceNotice'])
        self.assertEqual('not_performed', report['sourceAuthentication'])

    def test_all_rows_use_shared_audited_builder_and_label_mapping(self):
        self.records[0]['request']['candidates'].reverse()
        self.rebind(0)
        directory = self.tokenizer()
        loader, audit = self.audit_stubs()
        with loader, audit, patch('reviewed_v4_export.build_decision_input', wraps=build_decision_input) as shared:
            report = self.export(tokenizer_dir=directory)
        self.assertEqual(8, shared.call_count)
        self.assertEqual({1000}, {call.kwargs['now_epoch_s'] for call in shared.call_args_list})
        self.assertEqual('passed_all_rows', report['tokenAudit']['status'])
        self.assertTrue(report['trainingFilesWritten'])
        self.assertFalse(report['modelReady'])
        row = next(row for split in SPLITS for row in
                   [json.loads(line) for line in (self.root / 'bundle' / f'{split}.jsonl').read_text(encoding='utf-8').splitlines()]
                   if row['mifu_provenance']['recordId'] == 'record-0')
        self.assertEqual('candidate_01', row['expected']['printer'])
        self.assertEqual(SCHEMA, row['state']['schema'])
        self.assertNotIn('device-0', json.dumps({'state': row['state'], 'questions': row['questions']}))

    def test_original_timestamps_are_preserved_and_do_not_gain_live_freshness(self):
        before = copy.deepcopy(self.records)
        self.export()
        sources = self.source_rows()
        self.assertEqual(before, [row['record'] for row in sources])
        self.assertTrue(all(row['offlineValidationEpochS'] == 1000 and row['liveFreshnessGranted'] is False for row in sources))
        with self.assertRaises(ContractError):
            normalize_request(sources[0]['record']['request'], now_epoch_s=2000)

    def test_task_episode_and_snapshot_links_are_transitively_isolated(self):
        self.records[1]['request']['plate']['taskId'] = 'task-0'
        self.labels[2]['episodeId'] = 'episode-1'
        self.records[3]['request']['decision_context']['snapshot_id'] = 'snapshot-2'
        for candidate in self.records[3]['request']['candidates']:
            candidate['admission']['snapshot_id'] = 'snapshot-2'
        for index in (1, 3):
            self.rebind(index)
        report = self.export()
        sources = {row['record']['recordId']: row['binding'] for row in self.source_rows()}
        self.assertEqual(5, report['groupCount'])
        self.assertEqual(1, len({sources[f'record-{i}']['groupId'] for i in range(4)}))
        self.assertEqual(1, len({sources[f'record-{i}']['split'] for i in range(4)}))

    def test_identical_and_permuted_inputs_cannot_leak_between_splits(self):
        for index in (1, 2):
            self.records[index]['request']['plate']['estimated_seconds'] = 3600
        self.records[2]['request']['candidates'].reverse()
        for index in (1, 2):
            self.rebind(index)
        report = self.export()
        sources = self.source_rows()
        self.assertEqual(6, report['groupCount'])
        self.assertEqual(1, len({row['binding']['groupId'] for row in sources[:3]}))
        self.assertEqual(1, len({row['binding']['inputPermutationInvariantSha256'] for row in sources[:3]}))

    def test_splits_are_reproducible_independent_of_input_order_and_hashes_match(self):
        first = self.export('first')
        self.records.reverse()
        self.labels.reverse()
        second = self.export('second')
        self.assertEqual(first['splitGroups'], second['splitGroups'])
        self.assertEqual(first['files'], second['files'])
        for entry in first['files'].values():
            actual = hashlib.sha256((self.root / 'first' / entry['path']).read_bytes()).hexdigest()
            self.assertEqual(entry['sha256'], actual)
        self.assertNotEqual(first['sources']['recordsSha256'], second['sources']['recordsSha256'])

    def test_review_and_ledger_hash_binding_rejects_modified_or_foreign_content(self):
        for field, value in (('recordSha256', '0' * 64), ('requestSha256', '1' * 64),
                             ('candidateIds', ['foreign']), ('recordId', 'missing'), ('selectedCandidateId', 'foreign')):
            original = self.labels[0][field]
            self.labels[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.export(field)
            self.assertFalse((self.root / field).exists())
            self.labels[0][field] = original
        self.records[0]['request']['plate']['estimated_seconds'] += 1
        self.labels[0].update(review_binding(self.records[0]))
        with self.assertRaisesRegex(ValueError, 'submission hash'):
            self.export('tampered')

    def test_accepted_feedback_is_not_an_independent_review(self):
        self.records[0]['feedback'] = 'accepted'
        self.rebind(0)
        for key in ('reviewer', 'rationale', 'reviewedAt', 'episodeId'):
            original = self.labels[0][key]
            self.labels[0][key] = ''
            with self.subTest(field=key), self.assertRaises(ValueError):
                self.export(key)
            self.labels[0][key] = original
        self.labels[0]['reviewSource'] = 'accepted'
        with self.assertRaisesRegex(ValueError, 'separate'):
            self.export('no-review')

    def test_declared_synthetic_sources_markers_and_reserved_namespaces_are_rejected(self):
        original = copy.deepcopy(self.records[0])
        mutations = [lambda r: r.update(source='synthetic_pipeline_only'),
                     lambda r: r['request']['decision_context'].update(source='synthetic_pipeline_only'),
                     lambda r: r['request']['candidates'][0]['features']['hardware'].update(source='synthetic_pipeline_only'),
                     lambda r: r['request'].update(requestId='synthetic-12'),
                     lambda r: r['request']['plate'].update(taskId='sim-task')]
        for index, mutate in enumerate(mutations):
            self.records[0] = copy.deepcopy(original)
            mutate(self.records[0])
            self.rebind(0)
            with self.subTest(case=index), self.assertRaises(ValueError):
                self.export(f'synthetic-{index}')
        self.records[0] = original
        self.rebind(0)
        self.labels[0]['episodeId'] = 'synthetic-episode'
        with self.assertRaisesRegex(ValueError, 'namespace'):
            self.export('synthetic-episode')

    def test_future_missing_and_internally_conflicting_times_are_not_rebased(self):
        original = copy.deepcopy(self.records[0])
        mutations = [lambda r: r.update(createdAt='1970-01-01T00:35:00Z'),
                     lambda r: r['request']['decision_context'].update(observed_at_epoch_s=1101),
                     lambda r: r['request']['candidates'][0]['admission'].update(observed_at_epoch_s=879),
                     lambda r: r['request']['candidates'][0]['features']['timing_evidence']['setup'].pop('observed_at_epoch_s'),
                     lambda r: r['request']['decision_context'].update(observed_at_epoch_s=True)]
        for index, mutate in enumerate(mutations):
            self.records[0] = copy.deepcopy(original)
            mutate(self.records[0])
            self.rebind(0)
            with self.subTest(case=index), self.assertRaises(ValueError):
                self.export(f'time-{index}')
            self.assertFalse((self.root / f'time-{index}').exists())

    def test_review_cannot_precede_record_or_be_future(self):
        for value in ('1970-01-01T00:16:40Z', '1970-01-01T00:35:00Z', '1970-01-01T00:20:00'):
            self.labels[0]['reviewedAt'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.export('bad-review-time')

    def test_single_candidate_record_is_bound_then_excluded(self):
        record, label = fixture(20, 1)
        self.records.append(record)
        self.labels.append(label)
        report = self.export()
        self.assertEqual(8, report['exportedRows'])
        self.assertEqual(9, report['reviewedRecords'])
        self.assertEqual('record-20', report['excludedSingleCandidateRecords'][0]['recordId'])
        self.assertNotIn('record-20', {row['record']['recordId'] for row in self.source_rows()})
        self.labels[-1]['selectedCandidateId'] = 'device-1'
        with self.assertRaisesRegex(ValueError, 'eligible candidate'):
            self.export('invalid-single')

    def test_excluded_single_candidate_still_preserves_transitive_episode_isolation(self):
        # Task 0 was observed in episode 1 with one possible device; this links
        # its multi-candidate work to task 1 even though the observation is not
        # itself a ranking example.
        record, label = fixture(20, 1)
        record['request']['plate']['taskId'] = 'task-0'
        seal(record)
        label = label_for(record, 'episode-1')
        self.records.append(record)
        self.labels.append(label)
        report = self.export()
        sources = {row['record']['recordId']: row['binding'] for row in self.source_rows()}
        self.assertEqual(8, report['exportedRows'])
        self.assertEqual(7, report['groupCount'])
        self.assertEqual(sources['record-0']['groupId'], sources['record-1']['groupId'])
        self.assertEqual(sources['record-0']['split'], sources['record-1']['split'])
        self.assertNotIn('record-20', sources)
        self.assertTrue(report['excludedSingleCandidateRecords'][0]['isolationGroupKeysSha256'])

    def test_only_single_candidate_groups_cannot_pad_four_split_minimum(self):
        self.records, self.labels = self.records[:3], self.labels[:3]
        for index in range(20, 25):
            record, label = fixture(index, 1)
            self.records.append(record)
            self.labels.append(label)
        with self.assertRaisesRegex(ValueError, 'four independent'):
            self.export()
        self.assertFalse((self.root / 'bundle').exists())

    def test_fewer_than_four_independent_groups_is_not_padded_or_ready(self):
        self.records, self.labels = self.records[:3], self.labels[:3]
        with self.assertRaisesRegex(ValueError, 'four independent'):
            self.export()
        self.assertFalse((self.root / 'bundle').exists())

    def test_duplicate_records_reviews_and_conflicting_request_labels_are_rejected(self):
        self.records.append(copy.deepcopy(self.records[0]))
        with self.assertRaisesRegex(ValueError, 'Duplicate recordId'):
            self.export('duplicate-record')
        self.records.pop()
        self.labels.append(copy.deepcopy(self.labels[0]))
        with self.assertRaisesRegex(ValueError, 'duplicate recordId'):
            self.export('duplicate-label')
        self.labels.pop()
        self.records[1]['request'] = copy.deepcopy(self.records[0]['request'])
        self.rebind(1)
        self.labels[1]['selectedCandidateId'] = 'device-1'
        with self.assertRaisesRegex(ValueError, 'Conflicting reviews'):
            self.export('conflict')

    def test_token_truncation_and_tokenizer_mutation_stop_before_output(self):
        directory = self.tokenizer()
        loader, audit = self.audit_stubs({'errors': ['option_description_truncated']})
        with loader, audit, self.assertRaisesRegex(ContractError, 'truncated'):
            self.export('truncated', tokenizer_dir=directory)
        self.assertFalse((self.root / 'truncated').exists())
        def changed(*args, **kwargs):
            (directory / 'tokenizer.json').write_text('changed')
            return {'errors': [], 'sequence_tokens': 200, 'max_option_tokens': 24}
        loader, _ = self.audit_stubs()
        with loader, patch('audit_token_budget.inspect_question', side_effect=changed), self.assertRaisesRegex(ValueError, 'changed during audit'):
            self.export('changed', tokenizer_dir=directory)
        self.assertFalse((self.root / 'changed').exists())

    def test_existing_output_and_inputs_are_never_overwritten(self):
        self.inputs()
        record_bytes, label_bytes = self.records_path.read_bytes(), self.labels_path.read_bytes()
        self.export()
        before = {path.name: path.read_bytes() for path in (self.root / 'bundle').iterdir()}
        with self.assertRaisesRegex(ValueError, 'already exists'):
            self.export()
        self.assertEqual(before, {path.name: path.read_bytes() for path in (self.root / 'bundle').iterdir()})
        self.assertEqual(record_bytes, self.records_path.read_bytes())
        self.assertEqual(label_bytes, self.labels_path.read_bytes())

    def test_blank_review_template_never_copies_accepted_candidate_as_label(self):
        self.inputs()
        report = prepare_review_template(self.records_path, self.root / 'template.jsonl', now_epoch_s=2000)
        self.assertEqual('review_required', report['status'])
        labels = [json.loads(line) for line in (self.root / 'template.jsonl').read_text(encoding='utf-8').splitlines()]
        self.assertTrue(all(label['selectedCandidateId'] == label['reviewer'] == label['episodeId'] == '' for label in labels))
        self.assertEqual(review_binding(self.records[0]), {key: labels[0][key] for key in review_binding(self.records[0])})
        with self.assertRaisesRegex(ValueError, 'already exists'):
            prepare_review_template(self.records_path, self.root / 'template.jsonl', now_epoch_s=2000)
        with self.assertRaises(ValueError):
            export_reviewed_v4(self.records_path, self.root / 'template.jsonl', self.root / 'invalid-template', now_epoch_s=2000)

    def test_legacy_export_and_training_still_reject_v4_including_pending_preview(self):
        self.export()
        with self.assertRaisesRegex(ValueError, 'v4 observations'):
            export_dataset(self.records_path, self.labels_path, self.root / 'legacy')
        make_checkpoint(self.root / 'base')
        with self.assertRaisesRegex(ValueError, 'mifu-decision-v4'):
            train_model(self.root / 'bundle/pending_train.jsonl', self.root / 'bundle/pending_validation.jsonl',
                        self.root / 'base', self.root / 'training', 'unit-test', dry_run=True)
        self.assertFalse((self.root / 'training').exists())

    def test_duplicate_json_keys_and_invalid_observation_do_not_export(self):
        self.inputs()
        self.labels_path.write_text('{"recordId":"a","recordId":"b"}\n')
        with self.assertRaisesRegex(ValueError, 'Duplicate JSON'):
            export_reviewed_v4(self.records_path, self.labels_path, self.root / 'duplicate-json', now_epoch_s=2000)
        self.records[0]['observation'] = {'schema': 'mifu-observation-v1', 'source': 'synthetic_pipeline_only'}
        self.rebind(0)
        with self.assertRaises(ValueError):
            self.export('bad-observation')

    def test_observation_preserves_unknowns_but_rejects_foreign_or_future_times(self):
        request = self.records[0]['request']
        observation = {'schema': 'mifu-observation-v1', 'source': 'desktop_observation',
                       'requestId': request['requestId'], 'plate_id': request['plate']['id'],
                       'candidate_ids': ['device-0', 'device-1'], 'snapshot_at': '1970-01-01T00:16:40Z',
                       'artifact_sha256': 'a' * 64, 'plate_index': 1, 'geometry': {'status': 'not_measured'},
                       'devices': [{'candidate_id': key, 'ams_observed': False, 'telemetry_at': None,
                                    'ams_telemetry_at': None} for key in ('device-0', 'device-1')],
                       'ams_units': [], 'feed_slots': [], 'training_eligible': False}
        self.records[0]['observation'] = observation
        self.rebind(0)
        self.export('with-observation')
        self.assertEqual(observation, self.source_rows('with-observation')[0]['record']['observation'])
        observation['snapshot_at'] = '1970-01-01T00:16:41Z'
        self.rebind(0)
        with self.assertRaisesRegex(ValueError, 'does not bind'):
            self.export('foreign-observation')
        observation['snapshot_at'] = '1970-01-01T00:16:40Z'
        observation['devices'][0]['telemetry_at'] = '1970-01-01T00:18:21Z'
        self.rebind(0)
        with self.assertRaisesRegex(ValueError, 'cannot be future'):
            self.export('future-observation')

    def test_malformed_typed_fields_and_envelope_fail_with_validation_error(self):
        for target, field, value in ((self.records[0], 'feedback', []),
                                     (self.labels[0], 'reviewSource', {})):
            original = target[field]
            target[field] = value
            self.rebind(0)
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.export('bad-' + field)
            target[field] = original
        self.records[0]['request'].pop('requestId')
        self.rebind(0)
        with self.assertRaisesRegex(ValueError, 'exact v4 request envelope'):
            self.export('bad-envelope')

    def test_cli_pending_export_works_without_training_dependencies(self):
        self.inputs()
        completed = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / 'reviewed_v4_export.py'),
                                    'export', '--records', str(self.records_path), '--labels', str(self.labels_path),
                                    '--out', str(self.root / 'cli')], capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual('pending_token_audit', json.loads(completed.stdout)['status'])


if __name__ == '__main__':
    unittest.main()
