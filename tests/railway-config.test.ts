// Evaluates .railway/railway.ts with the Railway SDK and checks the settings
// the template depends on. This runs offline; it does not replace
// `railway config plan` against a real project.
import assert from "node:assert/strict";
import { test } from "node:test";
import { createRailwayContext, project } from "railway/iac";

process.env.OPENCLAW_RAILWAY_REPOSITORY = "example/openclaw-railway";
const { default: program } = await import("../.railway/railway.ts");

type Resource = {
  type: string;
  name: string;
  build?: Record<string, unknown>;
  deploy?: Record<string, unknown>;
  variables?: Record<string, { type: string; value?: string }>;
  volumeAttachments?: Record<string, { mountPath: string }>;
  [key: string]: unknown;
};

const definition = await program(createRailwayContext({ environment: "production" }), project);
const resources = JSON.parse(JSON.stringify(definition)).resources as Resource[];

function findService(name: string): Resource {
  const service = resources.find((resource) => resource.type === "service" && resource.name === name);
  assert.ok(service, `service ${name} is defined`);
  return service;
}

function mountPaths(service: Resource): string[] {
  return Object.values(service.volumeAttachments ?? {}).map((attachment) => attachment.mountPath);
}

test("defines exactly two services and two volumes", () => {
  const summary = resources.map((resource) => `${resource.type}:${resource.name}`).sort();
  assert.deepEqual(summary, [
    "service:openclaw",
    "service:tailscale",
    "volume:openclaw-state",
    "volume:tailscale-state",
  ]);
});

test("openclaw runs one volume-backed, health-checked Gateway", () => {
  const openclaw = findService("openclaw");
  assert.equal(openclaw.build?.dockerfilePath, "Dockerfile");
  assert.equal(openclaw.deploy?.numReplicas, 1);
  assert.equal(openclaw.deploy?.requiredMountPath, "/data");
  assert.equal(openclaw.deploy?.healthcheckPath, "/startupz");
  assert.equal(openclaw.deploy?.restartPolicyType, "ALWAYS");
  assert.deepEqual(openclaw.variables?.PORT, { type: "literal", value: "18789" });
  assert.deepEqual(mountPaths(openclaw), ["/data"]);
});

test("tailscale keeps its node identity on a volume", () => {
  const tailscale = findService("tailscale");
  assert.equal(tailscale.build?.dockerfilePath, "tailscale/Dockerfile");
  assert.equal(tailscale.deploy?.numReplicas, 1);
  assert.equal(tailscale.deploy?.requiredMountPath, "/var/lib/tailscale");
  assert.equal(tailscale.deploy?.healthcheckPath, "/healthz");
  assert.deepEqual(tailscale.variables?.PORT, { type: "literal", value: "9002" });
  assert.deepEqual(mountPaths(tailscale), ["/var/lib/tailscale"]);
});

test("no service is exposed publicly", () => {
  for (const name of ["openclaw", "tailscale"]) {
    const service = findService(name);
    for (const key of ["domains", "networking", "tcp", "tcpProxies"]) {
      assert.equal(service[key], undefined, `${name} must not set ${key}`);
    }
  }
});

test("secrets come from Railway and are never written in the file", () => {
  assert.deepEqual(findService("openclaw").variables?.OPENCLAW_GATEWAY_TOKEN, { type: "preserve" });
  assert.deepEqual(findService("tailscale").variables?.TS_AUTHKEY, { type: "preserve" });
});
