exports.generateVersion = async ({github, context, core}) => {
    // Generate base version using current UTC date
    let date = new Date();
    let coreVersion = `${date.getFullYear()}.${date.getMonth()+1}${date.getDate()}.${date.getHours()}${date.getMinutes()}${date.getSeconds()}`;

    // Determine SHA
    let sha;
    if (context.eventName === 'pull_request' &&
        !context.ref?.match(/.*(master|main)/)) {
        sha = context.payload.pull_request.head.sha;
    } else {
        sha = context.sha;
        if (!sha) {
            throw new Error(`Unable to find the sha for event ${context.eventName}`);
        }
    }

    // Append SHA to version
    if (sha) {
        coreVersion += `-${sha.substring(0, 7)}`;
    }

    // Add branch name for non-main branches
    if (!context.ref?.match(/.*(master|main)/)) {
        let headRef = process.env.GITHUB_HEAD_REF || context.ref;
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
}
