const { execSync } = require("child_process");

// Function to download the package
exports.downloadPackage = async ({ context, core }) => {
  const {
    PACKAGE_NAME,
    PACKAGE_EXT,
    PACKAGE_SUFFIX,
    PACKAGE_VERSION,
    GITHUB_TOKEN,
  } = process.env;

  const finalVersion = PACKAGE_NAME
    ? `${PACKAGE_VERSION}.${PACKAGE_SUFFIX}`
    : PACKAGE_VERSION;

  // Fetch package metadata
  const response = await fetch(
    `https://npm.pkg.github.com/@${context.repo.owner}/${PACKAGE_NAME}`,
    {
      headers: {
        Authorization: `token ${GITHUB_TOKEN}`,
        Accept: "application/json",
      },
    }
  );

  if (!response.ok) {
    core.setFailed(`Failed to fetch package metadata: ${response.statusText}`);
    return undefined;
  }

  const data = await response.json();

  // Get the tarball URL for the specified version
  const url = data.versions[finalVersion]?.dist?.tarball;

  if (!url) {
    core.setFailed(`Package version not found: ${finalVersion}`);
    return undefined;
  }

  // Download the package tarball
  const packageResponse = await fetch(url, {
    headers: {
      Authorization: `token ${GITHUB_TOKEN}`,
    },
  });

  if (!packageResponse.ok) {
    core.setFailed(`Failed to download package: ${packageResponse.statusText}`);
    return undefined;
  }

  const fs = require("fs");
  const { pipeline } = require("stream");

  const fileName = `${PACKAGE_NAME}-${finalVersion}.${PACKAGE_EXT}`;
  const fileStream = fs.createWriteStream(fileName);

  await new Promise((resolve, reject) => {
    pipeline(packageResponse.body, fileStream, (err) => {
      if (err) {
        reject(err);
      } else {
        resolve();
      }
    });
  });

  core.info(`Package downloaded as ${fileName}`);
  return fileName;
};
