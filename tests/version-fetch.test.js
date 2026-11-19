// node --test tests/: version-fetch parsing and the trust rules for additional versions.
const test = require('node:test');
const assert = require('node:assert');
const vf = require('../.github/actions/version-fetch/script.js');

const run = (title, slug = 'github-actions') => ({output: {title}, app: {slug}});
const core = () => {
    const c = {warnings: [], failed: null};
    c.info = () => {};
    c.warning = (m) => c.warnings.push(m);
    c.setFailed = (m) => { c.failed = m; };
    return c;
};
const github = (byName) => ({rest: {checks: {listForRef: async ({check_name}) => {
    const runs = byName[check_name] || [];
    return {data: {total_count: runs.total ?? runs.length, check_runs: runs}};
}}, repos: {getLatestRelease: async () => ({data: {tag_name: byName.release}})}}});
const context = {repo: {owner: 'o', repo: 'r'}};

test('parseExtraVersions accepts names and skips blank lines', () => {
    assert.deepStrictEqual(vf.parseExtraVersions('VERSION_BRIDGE=chirp:version-bridge\n\nVERSION_A_2=x-y_z\n'),
        [{name: 'VERSION_BRIDGE', checkName: 'chirp:version-bridge'}, {name: 'VERSION_A_2', checkName: 'x-y_z'}]);
    assert.deepStrictEqual(vf.parseExtraVersions(''), []);
});

for (const bad of ['VERSION_A=x\r', 'PATH=x', 'VERSION_=x', 'version_a=x', 'VERSION_A=X', 'VERSION_A=a b',
                   'VERSION_A<<EOF', 'VERSION_A=x\nVERSION_A=y', ' VERSION_A=x']) {
    test(`parseExtraVersions refuses ${JSON.stringify(bad)}`, () => {
        assert.throws(() => vf.parseExtraVersions(bad));
    });
}

test('extraValue: no check means not set', () => {
    assert.strictEqual(vf.extraValue([], {checkName: 'c', production: true}), undefined);
});
test('extraValue: repeated runs with one value pass', () => {
    assert.strictEqual(vf.extraValue([run('c-0123456789abcdef'), run('c-0123456789abcdef')], {checkName: 'c', production: true}),
        'c-0123456789abcdef');
});
test('extraValue: two different values are refused', () => {
    assert.throws(() => vf.extraValue([run('c-0123456789abcdef'), run('c-fedcba9876543210')], {checkName: 'c', production: false}),
        /2 different versions/);
});
test('extraValue: a check from another app is refused', () => {
    assert.throws(() => vf.extraValue([run('c-0123456789abcdef'), run('c-0123456789abcdef', 'someone')], {checkName: 'c'}),
        /not created by GitHub Actions/);
});
for (const v of ['a\nGITHUB_PATH=/tmp', 'a\rb', 'x=y', '$(id)', ' a', '.a', '-a', 'a ', 'é', '', 'a'.repeat(129)]) {
    test(`extraValue refuses the value ${JSON.stringify(v)}`, () => {
        assert.throws(() => vf.extraValue([run(v)], {checkName: 'c', production: false}));
    });
}
test('extraValue: on production only content tags pass', () => {
    assert.throws(() => vf.extraValue([run('2026.1119.10949-42fe263')], {checkName: 'c', production: true}), /not a content tag/);
    assert.throws(() => vf.extraValue([run('latest')], {checkName: 'c', production: true}), /not a content tag/);
    assert.strictEqual(vf.extraValue([run('latest')], {checkName: 'c', production: false}), 'latest');
});

const withEnv = async (env, fn) => {
    const saved = {...process.env};
    Object.assign(process.env, env);
    try { return await fn(); } finally { process.env = saved; }
};

test('fetchExtra joins the values and warns for a missing check', async () => {
    const c = core();
    const out = await withEnv({GIT_REF: 'sha', EXTRA_VERSIONS: 'VERSION_B=chirp:b\nVERSION_C=chirp:c', PRODUCTION: 'true'},
        () => vf.fetchExtra({github: github({'chirp:b': [run('c-0123456789abcdef')]}), context, core: c}));
    assert.strictEqual(out, 'VERSION_B=c-0123456789abcdef');
    assert.strictEqual(c.warnings.length, 1);
});
test('fetchExtra refuses more checks than one page', async () => {
    const runs = [run('c-0123456789abcdef')]; runs.total = 101;
    await assert.rejects(withEnv({GIT_REF: 'sha', EXTRA_VERSIONS: 'VERSION_B=chirp:b', PRODUCTION: 'false'},
        () => vf.fetchExtra({github: github({'chirp:b': runs}), context, core: core()})), /more/);
});
test('fetchVersion refuses a title that is not an image tag', async () => {
    const c = core();
    const out = await withEnv({GIT_REF: 'sha', CHECK_NAME: 'chirp:version'},
        () => vf.fetchVersion({github: github({'chirp:version': [run('$(id)')]}), context, core: c}));
    assert.strictEqual(out, '');
    assert.match(c.failed, /not a valid image tag/);
});
test('fetchVersion prefers the main build version and keeps branch versions', async () => {
    const c = core();
    assert.strictEqual(await withEnv({GIT_REF: 'sha', CHECK_NAME: 'chirp:version'},
        () => vf.fetchVersion({github: github({'chirp:version': [run('2026.1.1-abc1234-pr'), run('2026.1.1-abc1234')]}), context, core: c})),
        '2026.1.1-abc1234');
    assert.strictEqual(await withEnv({GIT_REF: 'sha', CHECK_NAME: 'chirp:version'},
        () => vf.fetchVersion({github: github({'chirp:version': [run('2026.1119.94533-17c59cf-hotfix-devops-x')]}), context, core: c})),
        '2026.1119.94533-17c59cf-hotfix-devops-x');
    assert.strictEqual(c.failed, null);
});
