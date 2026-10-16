import {readFileSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {createRequire} from 'node:module';

const req = createRequire(new URL('../../.cache/shared/aliyun-arms-api/10.1.0/package.json', import.meta.url));
const API = req('@alicloud/arms20190808');
const Core = req('@alicloud/openapi-core');
const Dara = req('@darabonba/typescript');
const environment = parseEnv(readFileSync(new URL('../../.env', import.meta.url), 'utf8'));
const client = new API.default(new Core.$OpenApiUtil.Config({
    regionId: 'cn-shanghai', accessKeyId: environment.ALIBABA_CLOUD_ACCESS_KEY_ID,
    accessKeySecret: environment.ALIBABA_CLOUD_ACCESS_KEY_SECRET, connectTimeout: 10000, readTimeout: 15000,
}));
try {
    const result = [];
    for (const [platform, pid] of [['android', 'chrtja4hrt@cbf30393cecba6c'], ['ios', 'chrtja4hrt@36e8041402b0036']]) {
        const response = await client.getRumAppInfoWithOptions(new API.GetRumAppInfoRequest({
            regionId: 'cn-shanghai', pid,
        }), new Dara.RuntimeOptions({autoretry: false, maxAttempts: 1}));
        const data = response.body.data;
        const module = data?.bonreeSDKConfig?.moduleConfig;
        const flags = Object.fromEntries(Object.entries(module?.defaultConfig ?? {}).map(([name, value]) => [name, value.enable]));
        const required = ['network','h5','routechange','crash','view','coollaunch','hotlaunch','action','lagstuck',
            'lagfps','statechange','anr','customlog','customevent','custommetric','battery'];
        const verified = response.body.success === true && data.pid === pid && data.regionId === 'cn-shanghai' &&
            data.appType.toLowerCase() === platform && module.enable === true &&
            Object.keys(module.versionConfigs ?? {}).length === 0 && required.every(name => name in flags) &&
            Object.entries(flags).every(([name, enabled]) => enabled === (name === 'customevent'));
        result.push({platform, pid, verified, collectors: flags});
    }
    console.log(JSON.stringify(result, null, 2));
    if (result.some(item => !item.verified)) process.exitCode = 1;
} catch (error) {
    console.error(JSON.stringify({code: String(error.code ?? 'UNKNOWN').slice(0, 100), status: error.statusCode}));
    process.exitCode = 1;
}
