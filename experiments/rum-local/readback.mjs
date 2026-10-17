import {readFileSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

// 两种用法：
//   <验证 UUID> <平台> [local|prod]   五条合成事件逐项核对（默认 local）
//   --launches <平台> <分钟>           正式环境里该平台最近的真实启动：只输出设备标识的短哈希，核对标识跨启动不变

// RAM 凭证只留在操作者进程；输出严格投影，避免打印 IP、设备名或原始日志。
// 凭证与接口库都在主工作区（worktree 里经 git 找到它）
const repo = fileURLToPath(new URL('../../', import.meta.url));
const main = dirname(execFileSync('git', ['-C', repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
    {encoding: 'utf8'}).trim());
const req = createRequire(join(main, '.cache/shared/aliyun-sls-api/1.2.6/package.json'));
const SLS = req('@alicloud/log');
const environment = parseEnv(readFileSync(join(main, '.env'), 'utf8'));
const launches = process.argv[2] === '--launches';
const [marker, platform, expectedEnv = 'local'] = launches ? [null, process.argv[3], 'prod'] : process.argv.slice(2);
const minutes = launches ? Number(process.argv[4] ?? 30) : 60;
const appIDs = {
    macos: 'chrtja4hrt@50261ae2de76a14',
    windows: 'chrtja4hrt@353d8439b5164b1',
    ios: 'chrtja4hrt@36e8041402b0036',
    android: 'chrtja4hrt@cbf30393cecba6c',
};
const validMarker = launches || /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(marker ?? '');
if (!validMarker || !Object.hasOwn(appIDs, platform) || !['local', 'prod'].includes(expectedEnv) ||
    !(minutes > 0 && minutes <= 60)) {
    console.error('Usage: node experiments/rum-local/readback.mjs <validation UUID> <platform> [local|prod]\n' +
        '       node experiments/rum-local/readback.mjs --launches <platform> <minutes<=60>');
    process.exit(2);
}
const client = new SLS({
    accessKeyId: environment.ALIBABA_CLOUD_ACCESS_KEY_ID,
    accessKeySecret: environment.ALIBABA_CLOUD_ACCESS_KEY_SECRET,
    endpoint: 'https://cn-shanghai.log.aliyuncs.com', use_https: true,
});
try {
    const rows = await client.getLogs('proj-xtrace-42c95262f4613e908c825603fb2a93e-cn-shanghai', 'logstore-rum',
        new Date(Date.now() - minutes * 60_000), new Date(Date.now() + 60_000),
        {query: 'event_type:custom and "custom.group":"usage"', topic: '', line: 100, offset: 0,
            reverse: true, powersql: false}, {timeout: 15000});
    if (launches) {
        const short = id => createHash('sha256').update(String(id ?? '')).digest('hex').slice(0, 8);
        const started = rows.filter(row => row['custom.name'] === 'app_started' && row['app.id'] === appIDs[platform] &&
            (row.env ?? row['app.env']) === 'prod');
        const summary = started.map(row => ({time: row.__time__, device: short(row['device.id']),
            version: row['app.version'], noMarker: !JSON.parse(row.properties ?? '{}').validation_run}));
        console.log(JSON.stringify({platform, minutes, boundedRead: rows.length < 100, launches: summary}, null, 2));
        process.exit(started.length ? 0 : 1);
    }
    const matches = [];
    for (const row of rows) {
        let properties;
        try { properties = JSON.parse(row.properties ?? '{}'); } catch { continue; }
        if (typeof properties.validation_run !== 'string' || properties.validation_run.toLowerCase() !== marker.toLowerCase()) continue;
        const safeKeys = ['validation_run', 'platform', 'schema_version', 'kind', 'outcome',
            'succeeded_count', 'failed_count'];
        matches.push({
            time: row.__time__, name: row['custom.name'], group: row['custom.group'], value: row['custom.value'],
            platform: properties.platform, schema: properties.schema_version, kind: properties.kind,
            outcome: properties.outcome, succeeded: properties.succeeded_count, failed: properties.failed_count,
            country: row['geo.country'], isp: row['isp.name'], appType: row['app.type'], appID: row['app.id'],
            environment: row.env ?? row['app.env'],
            safeFields: Object.keys(properties).every(key => safeKeys.includes(key)),
        });
    }
    const names = ['app_started', 'photo_imported', 'film_selected', 'export_completed', 'batch_export_completed'];
    const boundedRead = rows.length < 100;
    const ingestionPassed = boundedRead && matches.length === 5 &&
        names.every(name => matches.filter(row => row.name === name).length === 1) &&
        matches.every(row => row.platform === platform && String(row.schema) === '1' &&
            row.appID === appIDs[platform] && row.environment === expectedEnv && row.group === 'usage' &&
            row.safeFields &&
            (row.name === 'batch_export_completed' ?
                Number.isInteger(Number(row.succeeded)) && Number(row.succeeded) >= 0 && Number(row.succeeded) <= 100000 &&
                Number.isInteger(Number(row.failed)) && Number(row.failed) >= 0 && Number(row.failed) <= 100000 &&
                Number(row.value) === Number(row.succeeded) && ['completed','partial','cancelled','interrupted'].includes(row.outcome) :
                Number(row.value) === 1)) &&
        matches.find(row => row.name === 'film_selected')?.kind === 'built_in';
    const mainlandGeoVerified = matches.length === 5 && matches.every(row => row.country === '中国');
    // 移动 SDK 在关闭网络采集后可能没有地理字段；入库和地理证明分别报告。
    console.log(JSON.stringify({marker, platform, expectedEnv, ingestionPassed, mainlandGeoVerified, boundedRead, matches}, null, 2));
    if (!ingestionPassed) process.exitCode = 1;
} catch (error) {
    console.error(JSON.stringify({code: String(error.code ?? 'UNKNOWN').slice(0, 100), status: error.statusCode}));
    process.exitCode = 1;
}
