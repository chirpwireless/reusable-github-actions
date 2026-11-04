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
        run('2026.111.2-abc1234-develop', 'version = x\nevent = pull_request\nref = refs/pull/7/merge'),
        run('2026.111.1-abc1234-develop', 'version = y\nevent = push\nref = refs/heads/develop'),
    ]);
    assert.strictEqual(version, '2026.111.1-abc1234-develop');
});

test('a main build still wins over everything', async () => {
    const version = await fetch([
        run('2026.111.3-abc1234-develop', 'version = x\nevent = push\nref = refs/heads/develop'),
        run('2026.111.1-abc1234', 'version = y\nevent = push\nref = refs/heads/main'),
    ]);
    assert.strictEqual(version, '2026.111.1-abc1234');
});

test('a commit built only by a pull request keeps its version', async () => {
    const version = await fetch([run('2026.111.2-abc1234-feature', 'version = x\nevent = pull_request\nref = refs/pull/7/merge')]);
    assert.strictEqual(version, '2026.111.2-abc1234-feature');
});

test('a hand build on a branch the copy skips does not win over the branch build', async () => {
    const version = await fetch([
        run('2026.111.3-abc1234-feature-x', 'version = x\nevent = workflow_dispatch\nref = refs/heads/feature/x'),
        run('2026.111.1-abc1234-develop', 'version = y\nevent = push\nref = refs/heads/develop'),
    ]);
    assert.strictEqual(version, '2026.111.1-abc1234-develop');
});

test('a branch that gets a main-form tag does not win as a main build', async () => {
    const version = await fetch([
        run('2026.111.3-abc1234', 'version = x\nevent = workflow_dispatch\nref = refs/heads/fix/domain-x'),
        run('2026.111.1-abc1235', 'version = y\nevent = push\nref = refs/heads/main'),
    ]);
    assert.strictEqual(version, '2026.111.1-abc1235');
});

test('a main-form check from before the ref line still wins', async () => {
    const version = await fetch([
        run('2026.111.3-abc1234-develop', 'version = x\nevent = push\nref = refs/heads/develop'),
        run('2026.111.1-abc1234', 'version = y'),
    ]);
    assert.strictEqual(version, '2026.111.1-abc1234');
});

test('a commit built only on an unlisted branch keeps its version', async () => {
    const version = await fetch([run('2026.111.2-abc1234-feature-x', 'version = x\nevent = push\nref = refs/heads/feature/x')]);
    assert.strictEqual(version, '2026.111.2-abc1234-feature-x');
});

test('checks published before the event line keep the newest-first rule', async () => {
    const version = await fetch([run('2026.111.2-abc1234-develop', 'version = x'), run('2026.111.1-abc1234-develop', 'version = y')]);
    assert.strictEqual(version, '2026.111.2-abc1234-develop');
});
