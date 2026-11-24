import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';

import {
    computeQueryWindow,
    normalizeReportId,
    reassembleReportRows,
    writeReassembledReport,
} from './fetch-report.mjs';

test('normalizeReportId validates strict RL-YYYYMMDD-XXXXXXXX format', () => {
    assert.equal(normalizeReportId('rl-20261124-8f3a92c1'), 'RL-20261124-8F3A92C1');
    assert.equal(normalizeReportId('RL-20261124-8F3A92C1'), 'RL-20261124-8F3A92C1');
    assert.equal(normalizeReportId('../etc/passwd'), null);
    assert.equal(normalizeReportId('RL-20261124-ZZZZZZZZ'), null);
    assert.equal(normalizeReportId(''), null);
});

test('computeQueryWindow bounds query range around report date', () => {
    const now = Date.UTC(2026, 10, 25, 12, 0, 0);
    const {from, to} = computeQueryWindow('RL-20261124-8F3A92C1', now, 14);
    assert.ok(from.getTime() < now);
    assert.ok(to.getTime() > now);
    assert.throws(() => computeQueryWindow('RL-20261124-8F3A92C1', now, 0));
    assert.throws(() => computeQueryWindow('RL-20261124-8F3A92C1', now, 60));
});

test('reassembleReportRows merges out-of-order chunks and strips client IP metadata', () => {
    const rows = [
        {
            report_id: 'RL-20261124-8F3A92C1',
            chunk_index: '1',
            chunk_count: '2',
            breadcrumbs_jsonl: '{"seq":2,"stage":"exportCompleted"}\n',
            __source__: '203.0.113.42',
            __client_ip__: '203.0.113.42',
        },
        {
            report_id: 'RL-20261124-8F3A92C1',
            chunk_index: '0',
            chunk_count: '2',
            platform: 'macos',
            app_version: '0.12.1',
            build: '24',
            os_version: '15.1.0',
            device_model: 'arm64',
            user_note: 'ARW export issue',
            manifest_json: JSON.stringify({schemaVersion: 1, reportID: 'RL-20261124-8F3A92C1'}),
            recent_errors_json: JSON.stringify({schemaVersion: 1, events: []}),
            breadcrumbs_jsonl: '{"seq":1,"stage":"recordingStarted"}\n',
            __client_ip__: '203.0.113.42',
        },
    ];

    const assembled = reassembleReportRows(rows, 'rl-20261124-8f3a92c1');
    assert.ok(assembled);
    assert.equal(assembled.reportId, 'RL-20261124-8F3A92C1');
    assert.equal(assembled.platform, 'macos');
    assert.deepEqual(assembled.missingChunks, []);
    assert.equal(
        assembled.breadcrumbsJsonl,
        '{"seq":1,"stage":"recordingStarted"}\n{"seq":2,"stage":"exportCompleted"}\n'
    );
    assert.ok(!JSON.stringify(assembled).includes('203.0.113.42'));

    const temp = mkdtempSync(join(tmpdir(), 'rawlab-fetch-test-'));
    try {
        const out = writeReassembledReport(temp, assembled);
        assert.ok(readFileSync(join(out, 'manifest.json'), 'utf8').includes('RL-20261124-8F3A92C1'));
        assert.ok(readFileSync(join(out, 'breadcrumbs.jsonl'), 'utf8').includes('exportCompleted'));
        assert.ok(readFileSync(join(out, 'recent-errors.json'), 'utf8').includes('"schemaVersion": 1'));
    } finally {
        rmSync(temp, {recursive: true, force: true});
    }
});
