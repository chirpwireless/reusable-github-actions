exports.generateVersion = async ({github, context, core}) => {
    try {
        // Generate base version using current UTC date
        let coreVersion = new Date().toISOString()
            .replace(/[-:]/g, '')
            .replace(/T/, '.')
            .replace(/\..+/, '');

        // Determine SHA
        let sha;
        if (github.context.eventName === 'pull_request' &&
            !github.context.ref.match(/.*(master|main)/)) {
            sha = github.context.payload.pull_request.head.sha;
        } else {
            sha = github.context.sha;
            if (!sha) {
                throw new Error(`Unable to find the sha for event ${github.context.eventName}`);
            }
        }

        // Append SHA to version
        if (sha) {
            coreVersion += `-${sha.substring(0, 7)}`;
        }

        // Add branch name for non-main branches
        if (!github.context.ref.match(/.*(master|main)/)) {
            let headRef = github.context.headRef || github.context.ref;
            headRef = headRef.replace('refs/heads/', '');
            headRef = headRef.replace(/[^a-zA-Z0-9]/g, '-');

            if (headRef) {
                coreVersion += `-${headRef}`;
            }
        }

        // Trim version according to kubernetes label restrictions
        if (coreVersion.length > 63) {
            coreVersion = coreVersion.substring(0, 63);
            coreVersion = coreVersion.replace(/[^a-zA-Z0-9]*$/, '');
            core.warning('tag was trimmed because of limitation of kubernetes labels');
        }

        return coreVersion;

    } catch (error) {
        core.setFailed(error.message);
    }
}
