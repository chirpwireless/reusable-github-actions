exports.generateVersion = async ({github, context, core}) => {
    try {
        const now = new Date();
        const year = now.getUTCFullYear();
        const monthDay = `${now.getUTCMonth() + 1}${now.getUTCDate()}`.padStart(4, '0');
        const time = `${now.getUTCHours()}${now.getUTCMinutes()}${now.getUTCSeconds()}`.padStart(6, '0');

        let coreVersion = `${year}.${monthDay}.${time}`;

        // Determine the SHA to use
        let sha;
        if (github.context.eventName === 'pull_request' && !/^(refs\/heads\/)?(master|main)$/.test(github.context.ref)) {
            sha = github.context.payload.pull_request.head.sha;
        } else {
            sha = github.context.sha;
        }

        if (!sha) {
            core.setFailed(`Unable to find the SHA for event ${github.context.eventName}`);
            return;
        }

        coreVersion += `-${sha.substring(0, 7)}`;

        // Append branch name for non-main branches
        if (!/^(refs\/heads\/)?(master|main)$/.test(github.context.ref)) {
            const ref = github.context.ref.replace('refs/heads/', '');
            const sanitizedRef = ref.replace(/[^a-zA-Z0-9]/g, '-');
            coreVersion += `-${sanitizedRef}`;
        }

        // Trim version to 63 characters and ensure it ends with an alphanumeric character
        if (coreVersion.length > 63) {
            coreVersion = coreVersion.substring(0, 63).replace(/[^a-zA-Z0-9]*$/, '');
            core.warning('Version was trimmed to comply with Kubernetes label restrictions.');
        }

        core.setOutput('new_version', coreVersion);
    } catch (error) {
        core.setFailed(error.message);
    }
}
