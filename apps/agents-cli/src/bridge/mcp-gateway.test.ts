import assert from "node:assert/strict";
import test from "node:test";

import { RequestMcpGateway } from "./mcp-gateway.js";

const directTool = {
  name: "tapcanvas_flow_get",
  description: "Read a flow",
  execution: { sideEffect: "none" },
  parameters: { type: "object", properties: {} },
};

const deferredTool = {
  name: "tapcanvas_video_generate_to_canvas",
  description: "Generate a video",
  parameters: { type: "object", additionalProperties: true },
  schemaDeferred: true,
};

test("proxies direct MCP tools with request-scoped authorization", async (context) => {
  const originalFetch = globalThis.fetch;
  context.after(() => {
    globalThis.fetch = originalFetch;
  });
  let receivedBody: unknown;
  globalThis.fetch = async (_input, init) => {
    receivedBody = JSON.parse(String(init?.body)) as unknown;
    return new Response(JSON.stringify({ content: "flow loaded", flowId: "flow-1" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };

  const gateway = new RequestMcpGateway();
  const token = gateway.register([directTool], [], {
    endpoint: "https://api.example/agents/tools/execute",
    projectId: "project-1",
		parentAgentExecution: { model: "gpt-5.6-luna", apiStyle: "responses" },
  });
  const result = await gateway.handle(token, `Bearer ${token}`, {
    jsonrpc: "2.0",
    id: 1,
    method: "tools/call",
    params: { name: directTool.name, arguments: {} },
  });

  assert.equal(result.status, 200);
  assert.deepEqual(receivedBody, {
    toolName: directTool.name,
    providerKind: "remote",
    args: {},
    canvasProjectId: "project-1",
		parentAgentExecution: { model: "gpt-5.6-luna", apiStyle: "responses" },
  });
  assert.equal(gateway.executions(token)[0]?.status, "succeeded");
});

test("requires schema disclosure before a deferred tool can execute", async (context) => {
  const originalFetch = globalThis.fetch;
  context.after(() => {
    globalThis.fetch = originalFetch;
  });
  const wireNames: string[] = [];
  globalThis.fetch = async (_input, init) => {
    const body = JSON.parse(String(init?.body)) as { toolName?: unknown };
    wireNames.push(String(body.toolName ?? ""));
    return new Response(JSON.stringify({ content: "ok" }), { status: 200 });
  };

  const gateway = new RequestMcpGateway();
  const token = gateway.register([], [deferredTool], {
    endpoint: "https://api.example/agents/tools/execute",
  }, null, { contractHash: 'frozen-test-contract' });
  const call = (name: string, args: Record<string, unknown>) => gateway.handle(
    token,
    `Bearer ${token}`,
    { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } },
  );

  const blocked = await call(deferredTool.name, {});
  assert.match(JSON.stringify(blocked.body), /schema 尚未加载/u);
  await call("tapcanvas_get_tool_schema", { name: deferredTool.name });
  const executed = await call(deferredTool.name, { prompt: "animate" });

  assert.doesNotMatch(JSON.stringify(executed.body), /schema 尚未加载/u);
  assert.deepEqual(wireNames, ["tapcanvas_tool_schema_get", deferredTool.name]);
});

test("records transport failures instead of silently returning an untraced MCP error", async (context) => {
  const originalFetch = globalThis.fetch;
  context.after(() => {
    globalThis.fetch = originalFetch;
  });
  globalThis.fetch = async () => {
    throw new Error("connection refused");
  };

  const gateway = new RequestMcpGateway();
  const token = gateway.register([directTool], [], {
    endpoint: "https://api.example/agents/tools/execute",
  });
  await gateway.handle(token, `Bearer ${token}`, {
    jsonrpc: "2.0",
    id: 1,
    method: "tools/call",
    params: { name: directTool.name, arguments: {} },
  });

  assert.equal(gateway.executions(token)[0]?.status, "failed");
  assert.match(gateway.executions(token)[0]?.outputText ?? "", /connection refused/u);
});

test("freezes the root agent's response delivery report without calling Hono", async (context) => {
  const originalFetch = globalThis.fetch;
  context.after(() => {
    globalThis.fetch = originalFetch;
  });
  globalThis.fetch = async () => {
    throw new Error("report_delivery must remain local");
  };
  const gateway = new RequestMcpGateway();
  const token = gateway.register([], [], null);
  const result = await gateway.handle(token, `Bearer ${token}`, {
    jsonrpc: "2.0",
    id: 1,
    method: "tools/call",
    params: {
      name: "report_delivery",
      arguments: {
        taskGoal: "介绍助手身份",
        requestedOutput: "直接回答用户",
        taskKind: "identity_answer",
        delivery: {
          mode: "response",
          mediaType: null,
          kind: "answer",
          output: "助手身份说明",
        },
        requirements: [{ id: "must:identity", statement: "说明助手身份" }],
        rationale: "计划中的最终回答直接说明身份。",
      },
    },
  });

  assert.equal(result.status, 200);
  assert.match(String(gateway.deliveryReport(token)?.expectedDelivery.contractHash), /^sha256:[a-f0-9]{64}$/u);
  assert.equal(gateway.executions(token)[0]?.status, "succeeded");
});


test("advertises structured delivery arguments at the root and rejects encoded strings", async () => {
  const gateway = new RequestMcpGateway();
  const token = gateway.register([], [], null);
  const listed = await gateway.handle(token, `Bearer ${token}`, {
    jsonrpc: "2.0", id: 1, method: "tools/list",
  });
  const body = listed.body as { result: { tools: Array<{ name: string; inputSchema: {
    properties: Record<string, { type: string }>; anyOf: unknown[];
  } }> } };
  const schema = body.result.tools.find(tool => tool.name === "report_delivery")?.inputSchema;
  assert.equal(schema?.properties.delivery?.type, "object");
  assert.equal(schema?.properties.requirements?.type, "array");
  assert.equal(schema?.properties.expectedDelivery?.type, "object");
  assert.equal(schema?.properties.criteria?.type, "array");
  assert.equal(schema?.anyOf.length, 2);
  await gateway.handle(token, `Bearer ${token}`, {
    jsonrpc: "2.0", id: 2, method: "tools/call", params: {
      name: "report_delivery", arguments: {
        taskGoal: "Read canvas", requestedOutput: "Node count", taskKind: "verification",
        delivery: JSON.stringify({ mode: "response", mediaType: null, kind: "answer", output: "1 node" }),
        requirements: JSON.stringify([{ id: "read", statement: "Read the canvas" }]),
        rationale: "Read completed",
      },
    },
  });
  assert.equal(gateway.deliveryReport(token), null);
  assert.equal(gateway.executions(token)[0]?.status, "failed");
});
