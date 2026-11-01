const test = require('node:test');
const assert = require('node:assert');
const { fetchVersion } = require('./script.js');

const run = (title, summary) => ({ output: { title, summary } });

async function fetch(checkRuns) {
    process.env.GIT_REF = 'abc';
    process.env.CHECK_NAME = 'chirp:version';
    const github = { rest: { checks: { listForRef: async () => ({ data: { total_count: checkRuns.length, check_runs: checkRuns } }) } } };
    const core = { info() {}, setFailed() {} };
    return fetchVersion({ github, context: { repo: { owner: 'o', repo: 'r' } }, core });
}

test('a push build wins over a newer pull request build of the same commit', async () => {
    const version = await fetch([
        run('2026.111.2-abc1234-develop', 'version = x\nevent = pull_request'),
        run('2026.111.1-abc1234-develop', 'version = y\nevent = push'),
    ]);
    assert.strictEqual(version, '2026.111.1-abc1234-develop');
});

test('a main build still wins over everything', async () => {
    const version = await fetch([
        run('2026.111.3-abc1234-develop', 'version = x\nevent = push'),
        run('2026.111.1-abc1234', 'version = y\nevent = push'),
    ]);
    assert.strictEqual(version, '2026.111.1-abc1234');
});

test('a commit built only by a pull request keeps its version', async () => {
    const version = await fetch([run('2026.111.2-abc1234-feature', 'version = x\nevent = pull_request')]);
    assert.strictEqual(version, '2026.111.2-abc1234-feature');
});

test('checks published before the event line keep the newest-first rule', async () => {
    const version = await fetch([run('2026.111.2-abc1234-develop', 'version = x'), run('2026.111.1-abc1234-develop', 'version = y')]);
    assert.strictEqual(version, '2026.111.2-abc1234-develop');
});
