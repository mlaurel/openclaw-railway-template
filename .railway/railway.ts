// Railway Infrastructure as Code for this template: two services, two volumes.
//
// Railway evaluates this file only when you run `railway config plan` or
// `railway config apply`; deploys never read it. See docs/DEPLOYMENT.md.
//
// Secrets never appear here. Variables marked preserve() keep whatever value
// is already set in Railway, so set them with `railway variables` (or the
// dashboard) and list every variable you add to a service in this file.
import { defineRailway, github, preserve, project, service, volume } from "railway/iac";

// The GitHub repository and branch Railway builds: your fork. Edit these, or
// export OPENCLAW_RAILWAY_REPOSITORY / OPENCLAW_RAILWAY_BRANCH before running
// the CLI. (globalThis.process may not exist in the CLI's evaluator.)
const environment = globalThis.process?.env ?? {};
const sourceRepository = environment.OPENCLAW_RAILWAY_REPOSITORY ?? "<github-owner>/<repository>";
const sourceBranch = environment.OPENCLAW_RAILWAY_BRANCH ?? "main";

// Where both services and their volumes run. Declare the volume region and size
// explicitly: Railway fills them in when it creates a volume, and an undeclared
// value shows up in every later plan as a destructive change back to "unset".
const region = environment.OPENCLAW_RAILWAY_REGION ?? "us-west2";
const volumeSizeMB = 5000;

export default defineRailway(() => {
  if (sourceRepository.startsWith("<")) {
    throw new Error(
      "Set sourceRepository in .railway/railway.ts to your fork (owner/repository), or export OPENCLAW_RAILWAY_REPOSITORY.",
    );
  }

  const openclawState = volume("openclaw-state", { region, sizeMB: volumeSizeMB });
  const tailscaleState = volume("tailscale-state", { region, sizeMB: volumeSizeMB });

  // The service name is load-bearing: tailscale/serve.json forwards to
  // openclaw.railway.internal, Railway's private DNS name for this service.
  const openclaw = service("openclaw", {
    source: github(sourceRepository, { branch: sourceBranch }),
    build: {
      builder: "DOCKERFILE",
      dockerfilePath: "Dockerfile",
      watchPatterns: ["Dockerfile", "config/**", "scripts/**"],
    },
    // OpenClaw runs one Gateway per state directory, and Railway cannot share a
    // volume between replicas: exactly one instance, in the volume's region.
    replicas: { [region]: 1 },
    deploy: {
      requiredMountPath: "/data",
      // /startupz is 200 once the Gateway admits traffic. It ignores channel
      // health, so a revoked Telegram token cannot fail every deploy.
      healthcheckPath: "/startupz",
      // Doctor runs migrations before the Gateway starts; upgrades can be slow.
      healthcheckTimeout: 600,
      // External supervisor mode restarts by exiting cleanly, so Railway must
      // restart on every exit, not only on failures.
      restartPolicyType: "ALWAYS",
      // Matches OpenClaw's own stop budget (315s drain + reserve + margin).
      drainingSeconds: 330,
    },
    volumeMounts: { "/data": openclawState },
    env: {
      PORT: "18789",
      OPENCLAW_GATEWAY_TOKEN: preserve(),
      // https://openclaw.<your-tailnet>.ts.net; set it in Railway before deploying.
      OPENCLAW_PUBLIC_ORIGIN: preserve(),
      ANTHROPIC_API_KEY: preserve(),
    },
  });

  const tailscale = service("tailscale", {
    source: github(sourceRepository, { branch: sourceBranch }),
    build: {
      builder: "DOCKERFILE",
      dockerfilePath: "tailscale/Dockerfile",
      watchPatterns: ["tailscale/**"],
    },
    replicas: { [region]: 1 },
    deploy: {
      requiredMountPath: "/var/lib/tailscale",
      // containerboot's /healthz is 200 once the node has a tailnet address.
      healthcheckPath: "/healthz",
      healthcheckTimeout: 300,
      restartPolicyType: "ALWAYS",
    },
    volumeMounts: { "/var/lib/tailscale": tailscaleState },
    env: {
      PORT: "9002",
      TS_AUTHKEY: preserve(),
    },
  });

  // Must match the project name given to `railway init --name`.
  return project("openclaw", {
    resources: [openclaw, openclawState, tailscale, tailscaleState],
  });
});
