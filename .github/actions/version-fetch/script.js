async function fetchRelease({github, context, core}) {
    const repo = context.repo.repo;
    core.info(`Fetching version from latest release in ${repo}...`);

    const res = await github.rest.repos.getLatestRelease({
        owner: context.repo.owner,
        repo,
    });
    core.info(`RELEASE: ${JSON.stringify(res.data)}`);

    return res.data.tag_name;
}

async function fetchVersionFromCheck({github, context, core}) {
    const {GIT_REF, CHECK_NAME} = process.env;
    const repo = context.repo.repo;

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

exports.fetchRef = async ({github, context, core}) => {
    const {GIT_REF, GITHUB_REF_NAME} = process.env;

    if (GIT_REF) {
        core.info(`git ref is defined as ${GIT_REF}`)
        return GIT_REF
    }

    if (GITHUB_REF_NAME === 'main' || GITHUB_REF_NAME === 'master') {
        core.info(`Branch is main or master, but version is not defined. Defaulting to the last release`)
        return fetchRelease({github, context, core})
    }
    core.info(`Using ${GITHUB_REF_NAME} as the git ref`)
    return GITHUB_REF_NAME
};

exports.fetchVersion = async ({github, context, core}) => {
    const {GIT_REF, CHECK_NAME} = process.env;
    core.info(`Fetching version for git sha '${GIT_REF}' ('${CHECK_NAME}') ...`);

    const versionFromCheck = await fetchVersionFromCheck({github, context, core});
    if (versionFromCheck) {
        return versionFromCheck;
    }

    const versionFromRelease = await fetchRelease({github, context, core})
    if (versionFromRelease) {
        return versionFromRelease
    }

    core.setFailed(`No version found for git sha '${GIT_REF}' ('${CHECK_NAME}') in either checks or releases.`);
    return '';
};