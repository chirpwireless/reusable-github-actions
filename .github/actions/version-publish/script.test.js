const test = require('node:test');
const assert = require('node:assert');
const { publishVersion } = require('./script.js');

test('the summary carries the event and the ref that version-fetch reads', async () => {
    process.env.COMMIT_SHA = 'abc';
    process.env.BUILD_VERSION = '2026.111.1-abc1234-develop';
    process.env.CHECK_NAME = 'chirp:version';
    let created;
    const github = { rest: { checks: { create: async (args) => { created = args; return { data: {} }; } } } };
    await publishVersion({
        github,
        context: { repo: { owner: 'o', repo: 'r' }, eventName: 'push', ref: 'refs/heads/develop' },
        core: { info() {} },
    });
    assert.strictEqual(created.output.title, '2026.111.1-abc1234-develop');
    assert.match(created.output.summary, /^event = push$/m);
    assert.match(created.output.summary, /^ref = refs\/heads\/develop$/m);
});
