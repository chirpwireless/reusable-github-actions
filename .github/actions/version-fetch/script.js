const MAIN_BUILD_VERSION = /^[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{7}$/;
const CONTENT_TAG = /^c-[0-9a-f]{16}$/;
// The value ends up in the job environment and in image tags: the character set of a Docker tag, one line.
const VERSION_VALUE = /^[A-Za-z0-9._-]{1,128}$/;
const EXTRA_LINE = /^(VERSION_[A-Z0-9_]+)=([a-z0-9:_-]+)$/;

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

async function listChecks({github, context, ref, checkName}) {
    return github.rest.checks.listForRef({
        owner: context.repo.owner,
        repo: context.repo.repo,
        ref,
        status: 'completed',
        check_name: checkName,
        filter: 'all',
        per_page: 100,
    });
}

async function fetchVersionFromCheck({github, context, core}) {
    const {GIT_REF, CHECK_NAME} = process.env;

    const res = await listChecks({github, context, ref: GIT_REF, checkName: CHECK_NAME});

    if (res.data.total_count === 0) {
        core.info(`No published \`${CHECK_NAME}\` check found in ref '${GIT_REF}'.`);
        return undefined;
    }

    // A pull request build publishes its merge-ref image on the PR head commit, so a main commit can carry both.
    const mainBuild = res.data.check_runs.find((run) => MAIN_BUILD_VERSION.test(run.output?.title || ''));
    const versionCheck = mainBuild || res.data.check_runs[0];
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

    const version = await fetchVersionFromCheck({github, context, core}) || await fetchRelease({github, context, core});
    if (!version) {
        core.setFailed(`No version found for git sha '${GIT_REF}' ('${CHECK_NAME}') in either checks or releases.`);
        return '';
    }
    if (!VERSION_VALUE.test(version)) {
        core.setFailed(`The version found for git sha '${GIT_REF}' ('${CHECK_NAME}') is not a valid image tag.`);
        return '';
    }
    return version;
};

exports.parseExtraVersions = (text) => {
    const seen = new Set();
    const extras = [];
    for (const line of (text || '').split('\n')) {
        if (line.trim() === '') {
            continue;
        }
        const match = EXTRA_LINE.exec(line);
        if (!match) {
            throw new Error(`Invalid extra-versions line ${JSON.stringify(line)}: expected VERSION_NAME=check-name`);
        }
        const [, name, checkName] = match;
        if (seen.has(name)) {
            throw new Error(`Invalid extra-versions line ${JSON.stringify(line)}: the name ${name} is repeated`);
        }
        seen.add(name);
        extras.push({name, checkName});
    }
    return extras;
};

// Returns the single value of the check, undefined when the ref has none; throws on anything a deploy must not trust.
exports.extraValue = (runs, {checkName, production}) => {
    if (runs.length === 0) {
        return undefined;
    }
    if (runs.some((run) => run.app?.slug !== 'github-actions')) {
        throw new Error(`a \`${checkName}\` check was not created by GitHub Actions`);
    }
    const values = [...new Set(runs.map((run) => run.output?.title || ''))];
    if (values.length > 1) {
        throw new Error(`the \`${checkName}\` checks carry ${values.length} different versions`);
    }
    const [value] = values;
    if (!VERSION_VALUE.test(value)) {
        throw new Error(`the \`${checkName}\` check carries an invalid version`);
    }
    if (production && !CONTENT_TAG.test(value) && !MAIN_BUILD_VERSION.test(value)) {
        throw new Error(`the \`${checkName}\` check carries ${value}, which is not a main build version`);
    }
    return value;
};

exports.fetchExtra = async ({github, context, core}) => {
    const {GIT_REF, EXTRA_VERSIONS, PRODUCTION} = process.env;
    const production = PRODUCTION === 'true';
    const lines = [];

    for (const {name, checkName} of exports.parseExtraVersions(EXTRA_VERSIONS)) {
        const res = await listChecks({github, context, ref: GIT_REF, checkName});
        if (res.data.total_count > res.data.check_runs.length) {
            throw new Error(`ref '${GIT_REF}' has more \`${checkName}\` checks than one page`);
        }
        const value = exports.extraValue(res.data.check_runs, {checkName, production});
        if (value === undefined) {
            // A commit made before the image existed deploys without it; one whose helmfile needs it fails there.
            core.warning(`No published \`${checkName}\` check found in ref '${GIT_REF}': ${name} is not set.`);
            continue;
        }
        lines.push(`${name}=${value}`);
    }

    return lines.join('\n');
};