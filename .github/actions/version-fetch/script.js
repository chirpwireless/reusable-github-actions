exports.fetchRelease = async ({ github, context, core }) => {
    const { REPO } = process.env;
    const repo = REPO || context.repo.repo;
    core.info(`Fetching version from latest release in ${repo}...`);

    const res = await github.rest.repos.getLatestRelease({
        owner: context.repo.owner,
        repo,
    });
    core.info(`RELEASE: ${JSON.stringify(res.data)}`);

    return res.data.tag_name;
};

async function fetchVersionFromCommitStatus({ github, context, core }) {
    try {
        const { REPO, GIT_REF, CHECK_NAME } = process.env;
        const repo = REPO || context.repo.repo;

        const commitStatuses = await github.rest.repos.listCommitStatusesForRef({
            owner: context.repo.owner,
            repo,
            ref: GIT_REF,
            per_page: 100
        });
        core.debug(`STATUSES: ${JSON.stringify(commitStatuses.data)}`);

        for (const status of commitStatuses.data) {
            if (status.context === CHECK_NAME) {
                core.info(`VERSION: ${status.description}`);
                return status.description;
            }
        }

        return undefined
    } catch (e) {
        core.warning(`Failed to fetch commit statuses: ${e.message}, falling back to the checks API. If the error says 'Resource not accessible by integration', Please add statuses: write permission to the workflow to remove this warning.`);
        return undefined
    }
}


async function fetchVersionFromCheck({ github, context, core }) {
    const { REPO, GIT_REF, CHECK_NAME } = process.env;
    const repo = REPO || context.repo.repo;

    const res = await github.rest.checks.listForRef({
        owner: context.repo.owner,
        repo,
        ref: GIT_REF,
        status: 'completed',
        check_name: CHECK_NAME,
    });

    if (res.data.total_count === 0) {
        core.info(`No published \`${CHECK_NAME}\` check found in ref '${GIT_REF}'.`);
        return undefined;
    }

    const versionCheck = res.data.check_runs[0];
    core.info(`VERSION CHECK: ${JSON.stringify(versionCheck)}`);

    const version = versionCheck.output.title;
    if (!version) {
        core.info(`Version check is incorrectly formatted.`);
        return undefined;
    }

    return version;
}

exports.fetchVersion = async ({ github, context, core }) => {
    const { GIT_REF, CHECK_NAME, DEFAULT_VALUE } = process.env;
    core.info(`Fetching version for git sha '${GIT_REF}' ('${CHECK_NAME}') ...`);

    const versionFromStatus = await fetchVersionFromCommitStatus({ github, context, core });
    if (versionFromStatus) {
        return versionFromStatus;
    }
    core.warning(`No version found in commit statuses, falling back to checks`);

    const versionFromCheck = await fetchVersionFromCheck({ github, context, core });
    if (versionFromCheck) {
        return versionFromCheck;
    }

    core.setFailed(`No version found for git sha '${GIT_REF}' ('${CHECK_NAME}') in either commit statuses or checks.`);
    return DEFAULT_VALUE;
};