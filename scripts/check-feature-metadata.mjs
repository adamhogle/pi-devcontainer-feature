// Validate devcontainer-feature.json against the invariants this feature relies on.
// CI cannot execute install.sh (no Docker-in-Docker on shared runners), so this is
// the only automated gate on the metadata.
import { readFileSync } from "node:fs";

const path = process.env.FEATURE_JSON ?? "src/pi/devcontainer-feature.json";
const errors = [];

let feature;
try {
  feature = JSON.parse(readFileSync(path, "utf8"));
} catch (error) {
  console.error(`${path}: not valid JSON -- ${error.message}`);
  process.exit(1);
}

const require = (condition, message) => {
  if (!condition) errors.push(message);
};

require(feature.id === "pi", `id must be "pi", got ${JSON.stringify(feature.id)}`);
require(
  typeof feature.version === "string" && /^\d+\.\d+\.\d+$/.test(feature.version),
  `version must be plain semver x.y.z, got ${JSON.stringify(feature.version)}`,
);
require(typeof feature.name === "string" && feature.name.length > 0, "name is required");

// dev-up passes this per invocation, pinned to the host's pi version.
require(feature.options?.version?.type === "string", "options.version must be a string option");
// Pinned, never floating: a moving runtime would change the image without changing the tag.
require(
  /^\d+\.\d+\.\d+$/.test(feature.options?.nodeVersion?.default ?? ""),
  "options.nodeVersion.default must be an exact x.y.z version",
);
// pi requires node >=22.19.0.
const [major] = (feature.options?.nodeVersion?.default ?? "0").split(".").map(Number);
require(major >= 22, `options.nodeVersion.default must be >= 22, got ${major}`);

// Same reasoning as nodeVersion: a floating tool version would change the built
// image without changing the feature version.
for (const tool of ["ripgrepVersion", "fdVersion"]) {
  require(
    /^\d+\.\d+\.\d+$/.test(feature.options?.[tool]?.default ?? ""),
    `options.${tool}.default must be an exact x.y.z version`,
  );
}

// dev-pi sets these too, but the feature must stand on its own.
require(
  feature.containerEnv?.PI_CODING_AGENT_DIR === "/opt/pi/agent",
  "containerEnv.PI_CODING_AGENT_DIR must be /opt/pi/agent (dev-up mounts ~/.pi/agent there)",
);

// The feature must never carry credentials; dev-pi injects those per session.
const secretish = /(TOKEN|SECRET|PASSWORD|API_?KEY|CREDENTIAL)/i;
for (const key of Object.keys(feature.containerEnv ?? {})) {
  require(!secretish.test(key), `containerEnv.${key} looks like a credential; the feature must not carry any`);
}

if (errors.length > 0) {
  console.error(`${path}:`);
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}

console.log(
  `${path}: ok (feature ${feature.version}, installs pi "${feature.options.version.default}", ` +
    `node ${feature.options.nodeVersion.default}, ripgrep ${feature.options.ripgrepVersion.default}, ` +
    `fd ${feature.options.fdVersion.default})`,
);
