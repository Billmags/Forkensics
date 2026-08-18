// tools/stubs/upload-authorize/index.ts
// 503 stub. Deploy as upload-authorize during forward cutover and rollback.
Deno.serve((_req: Request): Response =>
  new Response(
    JSON.stringify({ error: "Service temporarily unavailable" }),
    {
      status: 503,
      headers: { "Content-Type": "application/json" },
    },
  )
);
