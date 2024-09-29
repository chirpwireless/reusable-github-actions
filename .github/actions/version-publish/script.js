exports.publishVersion = async ({ github, context, core }) => {
    const { COMMIT_SHA, BUILD_VERSION, CHECK_NAME } = process.env;
    core.info(`Publishing version '${BUILD_VERSION}' for git sha '${COMMIT_SHA}' ('${CHECK_NAME}') ...`);
    const conclusion = 'success';
    let res;
    try {
        res = await github.rest.repos.createCommitStatus({
            owner: context.repo.owner,
            repo: context.repo.repo,
            sha: COMMIT_SHA,
            state: conclusion,
            description: BUILD_VERSION,
            context: CHECK_NAME,
        })
    } catch (e) {
        core.warning(`Fallback to create check run: ${e.message}`);
        res = await github.rest.checks.create({
            owner: context.repo.owner,
            repo: context.repo.repo,
            name: CHECK_NAME,
            head_sha: COMMIT_SHA,
            status: 'completed',
            conclusion: 'success',
            output: {
                title: BUILD_VERSION,
                summary: `version = ${BUILD_VERSION}`,
            },
        });
    }

    core.info(`VERSION: ${BUILD_VERSION}`);
    core.info(`VERSION object: ${JSON.stringify(res.data)}`);
};