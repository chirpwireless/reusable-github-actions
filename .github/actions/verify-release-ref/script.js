const RELEASE_BRANCHES = ['main', 'master'];

const isProduction = (environment) => environment === 'prod' || environment.endsWith('-prod');

async function findReleaseBranch({github, context}) {
    for (const branch of RELEASE_BRANCHES) {
        try {
            await github.rest.git.getRef({owner: context.repo.owner, repo: context.repo.repo, ref: `heads/${branch}`});
            return branch;
        } catch (error) {
            if (error.status !== 404) {
                throw error;
            }
        }
    }
    return undefined;
}

async function resolveCommit({github, context, ref}) {
    const res = await github.rest.repos.getCommit({owner: context.repo.owner, repo: context.repo.repo, ref});
    return res.data.sha;
}

async function isContainedIn({github, context, sha, branch}) {
    const res = await github.rest.repos.compareCommitsWithBasehead({
        owner: context.repo.owner,
        repo: context.repo.repo,
        basehead: `${sha}...refs/heads/${branch}`,
        per_page: 1,
    });
    return res.data.status === 'identical' || res.data.status === 'ahead';
}

exports.verifyReleaseRef = async ({github, context, core}) => {
    const {GIT_REF, ENVIRONMENT} = process.env;

    if (!isProduction(ENVIRONMENT)) {
        core.info(`'${ENVIRONMENT}' is not a production environment; any ref may be deployed.`);
        return;
    }

    const ref = GIT_REF || context.sha;
    try {
        // master counts only in repositories without main, so a newly created master cannot widen the check
        const branch = await findReleaseBranch({github, context});
        if (!branch) {
            core.setFailed(`Neither main nor master exists; refusing to deploy '${ref}' to ${ENVIRONMENT}.`);
            return;
        }

        const sha = await resolveCommit({github, context, ref});
        if (!(await isContainedIn({github, context, sha, branch}))) {
            core.setFailed(`'${ref}' (${sha}) is not merged into ${branch}. Only commits that are part of ${branch} can be deployed to ${ENVIRONMENT}.`);
            return;
        }

        core.info(`'${ref}' (${sha}) is part of ${branch}; deploying to ${ENVIRONMENT} is allowed.`);
        core.setOutput('sha', sha);
    } catch (error) {
        core.setFailed(`Cannot verify '${ref}' for ${ENVIRONMENT}: ${error.message}`);
    }
};

exports.isProduction = isProduction;
