// Function to unarchive the package
exports.unarchivePackage = async ({ core }) => {
  const { FILE_NAME, FILE_EXT } = process.env;
  core.info(`Unarchiving ${FILE_NAME}...`);

  if (FILE_EXT === "tgz" || FILE_EXT === "tar.gz") {
    const { execSync } = require("child_process");
    execSync(`tar -xzf ${FILE_NAME}`, { stdio: "inherit" });
    core.info("Package unarchived");
  } else {
    core.info(`Unrecognized extension for unarchiving: ${FILE_EXT}`);
  }
};
