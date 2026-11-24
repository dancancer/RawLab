import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

// ============================================================================
//  RawLab 诊断报告只读拉取工具（按用户提供的诊断码 RL-YYYYMMDD-XXXXXXXX 拉取）
//  - RAM 只读凭证仅从主工作区根目录已忽略的 .env 读取，禁止经命令行参数传入
//  - 自动合并多片 breadcrumbs_jsonl，剔除服务端注入的客户端 IP 等网络字段
//  - 落盘目录结构与客户端「保存到设备」导出的 .zip 解压内容完全同构
// ============================================================================

const REPORT_ID_PATTERN = /^RL-(\d{4})(\d{2})(\d{2})-([0-9A-F]{8})$/i;
const SAFE_LOGSTORE_PATTERN = /^[a-z0-9][a-z0-9_-]{1,62}$/;
const DEFAULT_PROJECT = 'proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai';
const DEFAULT_LOGSTORE = 'logstore-diagnostics';
const DEFAULT_ENDPOINT = 'https://cn-shanghai.log.aliyuncs.com';

export function normalizeReportId(raw) {
    const trimmed = String(raw ?? '').trim().toUpperCase();
    return REPORT_ID_PATTERN.test(trimmed) ? trimmed : null;
}

export function computeQueryWindow(reportId, nowMs = Date.now(), lookbackDays = 14) {
    const normalized = normalizeReportId(reportId);
    if (!normalized) throw new Error('Invalid diagnostic report ID (expected RL-YYYYMMDD-XXXXXXXX)');
    const days = Number(lookbackDays);
    if (!Number.isFinite(days) || days < 1 || days > 30) {
        throw new Error('lookbackDays must be between 1 and 30');
    }
    const match = REPORT_ID_PATTERN.exec(normalized);
    const reportDayUtc = Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]), 0, 0, 0);
    const earliestAllowed = nowMs - days * 86_400_000;
    const fromMs = Math.max(earliestAllowed, reportDayUtc - 86_400_000);
    const toMs = nowMs + 60_000;
    return {from: new Date(Math.min(fromMs, nowMs - 60_000)), to: new Date(toMs)};
}

export function reassembleReportRows(rows, expectedReportId) {
    const targetId = normalizeReportId(expectedReportId);
    if (!targetId) throw new Error('Invalid diagnostic report ID');

    const matching = (rows ?? []).filter(
        row => String(row?.report_id ?? '').trim().toUpperCase() === targetId
    );
    if (matching.length === 0) {
        return null;
    }

    const byIndex = new Map();
    let declaredCount = 1;
    for (const row of matching) {
        const idx = Number(row.chunk_index ?? '0');
        const count = Number(row.chunk_count ?? '1');
        if (!Number.isInteger(idx) || idx < 0 || idx >= 16 || !Number.isInteger(count) || count < 1 || count > 16) {
            throw new Error(`Invalid chunk metadata on report ${targetId}`);
        }
        declaredCount = Math.max(declaredCount, count);
        if (!byIndex.has(idx)) {
            byIndex.set(idx, row);
        }
    }

    const missingChunks = [];
    const breadcrumbParts = [];
    for (let i = 0; i < declaredCount; i++) {
        const chunkRow = byIndex.get(i);
        if (!chunkRow) {
            missingChunks.push(i);
            continue;
        }
        if (typeof chunkRow.breadcrumbs_jsonl === 'string' && chunkRow.breadcrumbs_jsonl.length > 0) {
            breadcrumbParts.push(chunkRow.breadcrumbs_jsonl.replace(/\n+$/, ''));
        }
    }

    const head = byIndex.get(0) ?? matching[0];
    let manifest = null;
    try {
        manifest = head.manifest_json ? JSON.parse(head.manifest_json) : null;
    } catch {
        manifest = null;
    }
    let recentErrors = null;
    try {
        recentErrors = head.recent_errors_json ? JSON.parse(head.recent_errors_json) : null;
    } catch {
        recentErrors = null;
    }

    const breadcrumbsJsonl = breadcrumbParts.length > 0 ? breadcrumbParts.join('\n') + '\n' : '';
    const manifestJson = manifest
        ? JSON.stringify(manifest, null, 2) + '\n'
        : String(head.manifest_json ?? '{}\n');
    const recentErrorsJson = recentErrors
        ? JSON.stringify(recentErrors, null, 2) + '\n'
        : String(head.recent_errors_json ?? '{"schemaVersion":1,"events":[]}\n');

    return {
        reportId: targetId,
        platform: String(head.platform ?? manifest?.environment?.platform ?? 'unknown'),
        appVersion: String(head.app_version ?? manifest?.environment?.appVersion ?? 'unknown'),
        build: String(head.build ?? manifest?.environment?.build ?? 'unknown'),
        osVersion: String(head.os_version ?? manifest?.environment?.osVersion ?? 'unknown'),
        deviceModel: String(head.device_model ?? manifest?.environment?.deviceModel ?? 'unknown'),
        userNote: typeof head.user_note === 'string' ? head.user_note : (manifest?.userNote ?? null),
        chunkCount: declaredCount,
        receivedChunks: byIndex.size,
        missingChunks,
        manifestJson,
        breadcrumbsJsonl,
        recentErrorsJson,
    };
}

export function writeReassembledReport(outputDir, assembled) {
    const safeDir = resolve(outputDir);
    mkdirSync(safeDir, {recursive: true});
    writeFileSync(join(safeDir, 'manifest.json'), assembled.manifestJson, 'utf8');
    writeFileSync(join(safeDir, 'breadcrumbs.jsonl'), assembled.breadcrumbsJsonl, 'utf8');
    writeFileSync(join(safeDir, 'recent-errors.json'), assembled.recentErrorsJson, 'utf8');
    return safeDir;
}

async function runCli() {
    const args = process.argv.slice(2);
    let reportArg = null;
    let days = 14;
    let customOut = null;

    for (let i = 0; i < args.length; i++) {
        if (args[i] === '--days' && i + 1 < args.length) {
            days = Number(args[++i]);
        } else if (args[i] === '--out' && i + 1 < args.length) {
            customOut = args[++i];
        } else if (!args[i].startsWith('-') && !reportArg) {
            reportArg = args[i];
        } else {
            reportArg = null;
            break;
        }
    }

    const reportId = normalizeReportId(reportArg);
    if (!reportId || !(days >= 1 && days <= 30)) {
        console.error(
            'Usage: env -u DEBUG -u NODE_DEBUG node scripts/diagnostics/fetch-report.mjs <RL-YYYYMMDD-XXXXXXXX> [--days 1..30] [--out <dir>]'
        );
        process.exit(2);
    }

    const repo = fileURLToPath(new URL('../../', import.meta.url));
    const main = dirname(
        execFileSync('git', ['-C', repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'], {
            encoding: 'utf8',
        }).trim()
    );
    const envFile = join(main, '.env');
    const environment = parseEnv(readFileSync(envFile, 'utf8'));
    const project = environment.RAWLAB_SLS_DIAGNOSTIC_PROJECT ?? DEFAULT_PROJECT;
    const logstore = environment.RAWLAB_SLS_DIAGNOSTIC_LOGSTORE ?? DEFAULT_LOGSTORE;
    const endpoint = environment.RAWLAB_SLS_DIAGNOSTIC_ENDPOINT ?? DEFAULT_ENDPOINT;

    if (!SAFE_LOGSTORE_PATTERN.test(logstore)) {
        console.error('Invalid RAWLAB_SLS_DIAGNOSTIC_LOGSTORE name');
        process.exit(2);
    }

    const req = createRequire(join(main, '.cache/shared/aliyun-sls-api/1.2.6/package.json'));
    const SLS = req('@alicloud/log');
    const client = new SLS({
        accessKeyId: environment.ALIBABA_CLOUD_ACCESS_KEY_ID,
        accessKeySecret: environment.ALIBABA_CLOUD_ACCESS_KEY_SECRET,
        endpoint,
        use_https: true,
    });

    const {from, to} = computeQueryWindow(reportId, Date.now(), days);
    try {
        const rows = await client.getLogs(
            project,
            logstore,
            from,
            to,
            {
                query: `report_id:"${reportId}"`,
                topic: 'rawlab-diagnostic-v1',
                line: 20,
                offset: 0,
                reverse: false,
                powersql: false,
            },
            {timeout: 15000}
        );

        const assembled = reassembleReportRows(rows, reportId);
        if (!assembled) {
            console.error(JSON.stringify({found: false, reportId, logstore}, null, 2));
            process.exit(1);
        }

        const outDir = customOut
            ? resolve(customOut)
            : join(main, '.cache/tmp/diagnostics', reportId);
        const savedPath = writeReassembledReport(outDir, assembled);
        const lineCount = assembled.breadcrumbsJsonl
            ? assembled.breadcrumbsJsonl.trim().split('\n').length
            : 0;

        console.log(
            JSON.stringify(
                {
                    found: true,
                    reportId: assembled.reportId,
                    platform: assembled.platform,
                    appVersion: assembled.appVersion,
                    build: assembled.build,
                    osVersion: assembled.osVersion,
                    deviceModel: assembled.deviceModel,
                    userNote: assembled.userNote,
                    chunks: `${assembled.receivedChunks}/${assembled.chunkCount}`,
                    missingChunks: assembled.missingChunks,
                    breadcrumbLines: lineCount,
                    savedDirectory: savedPath,
                },
                null,
                2
            )
        );
        if (assembled.missingChunks.length > 0) {
            process.exitCode = 1;
        }
    } catch (error) {
        console.error(
            JSON.stringify({
                code: String(error?.code ?? 'UNKNOWN').slice(0, 100),
                status: error?.statusCode ?? null,
            })
        );
        process.exitCode = 1;
    }
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
    await runCli();
}
