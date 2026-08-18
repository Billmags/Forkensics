/**
 * R2 single-key cleanup helper for integration-runner.sh (Amendment D: T-AMD-6).
 *
 * Replaces `aws s3api head-object` / `aws s3 rm` in _r2_cleanup so that the
 * AWS CLI is not a prerequisite for running the integration suite.
 *
 * Usage (called by integration-runner.sh — do NOT invoke directly):
 *   deno run --allow-net --allow-env --allow-sys tools/r2-cleanup-helper.ts <key>
 *
 * Environment variables (exported by _r2_cleanup before calling):
 *   R2_ENDPOINT          Cloudflare R2 S3-compatible endpoint URL
 *   AWS_ACCESS_KEY_ID    R2 access key ID   (mapped from R2_ACCESS_KEY_ID)
 *   AWS_SECRET_ACCESS_KEY R2 secret key     (mapped from R2_SECRET_ACCESS_KEY)
 *   R2_BUCKET            R2 bucket name (default: forkensics-dev-media)
 *
 * Exit codes:
 *   0  — key confirmed present before delete, deleted, confirmed absent after
 *   1  — key not present in R2 (PUT was rejected / object absent); skip
 *   2  — error (any other HEAD / DELETE failure)
 *
 * NEVER logs credential values.  All output goes to stdout and is captured in
 * the integration log; T-AMD-7 and T-AMD-8 verify it contains no secrets.
 */
import {
  DeleteObjectCommand,
  HeadObjectCommand,
  S3Client,
} from "npm:@aws-sdk/client-s3@3.1109.0";

const key = Deno.args[0];
if (!key) {
  console.error("r2-cleanup-helper: <key> argument is required");
  Deno.exit(2);
}

const endpoint = Deno.env.get("R2_ENDPOINT");
const accessKeyId = Deno.env.get("AWS_ACCESS_KEY_ID");
const secretAccessKey = Deno.env.get("AWS_SECRET_ACCESS_KEY");
const bucket = Deno.env.get("R2_BUCKET") ?? "forkensics-dev-media";

if (!endpoint || !accessKeyId || !secretAccessKey) {
  console.error(
    "r2-cleanup-helper: R2_ENDPOINT, AWS_ACCESS_KEY_ID, and " +
      "AWS_SECRET_ACCESS_KEY must be set",
  );
  Deno.exit(2);
}

const client = new S3Client({
  region: "auto",
  endpoint,
  forcePathStyle: true,
  credentials: { accessKeyId, secretAccessKey },
  // Match buildR2Client() in s3.ts: prevent checksum headers from being added.
  requestChecksumCalculation: "WHEN_REQUIRED",
});

/** Returns true when the error is a 404 / NoSuchKey from the SDK. */
function is404(e: unknown): boolean {
  if (!e || typeof e !== "object") return false;
  const err = e as Record<string, unknown>;
  if (
    err.$metadata && typeof err.$metadata === "object" &&
    (err.$metadata as { httpStatusCode?: number }).httpStatusCode === 404
  ) return true;
  const name = (err as { name?: string }).name;
  return name === "NoSuchKey" || name === "NotFound";
}

// ── HEAD before delete ────────────────────────────────────────────────────────
try {
  await client.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
  console.log(`T-AMD-5/T-AMD-6: key=${key} confirmed present before delete`);
} catch (e) {
  if (is404(e)) {
    console.log(
      `T-AMD-6: key=${key} not present in R2 (PUT was rejected); skipping`,
    );
    Deno.exit(1);
  }
  // Log error name + message only (never a response body that could contain credentials).
  const errDesc = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
  console.error(`T-AMD-6: pre-delete HEAD error for key=${key} — ${errDesc}`);
  Deno.exit(2);
}

// ── DELETE ────────────────────────────────────────────────────────────────────
try {
  await client.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }));
  console.log(`T-AMD-6: delete succeeded for key=${key}`);
} catch (e) {
  console.error(`T-AMD-6: delete failed for key=${key}: ${String(e)}`);
  Deno.exit(2);
}

// ── HEAD after delete ─────────────────────────────────────────────────────────
try {
  await client.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
  console.error(`T-AMD-6: key=${key} still present after delete`);
  Deno.exit(2);
} catch (e) {
  if (is404(e)) {
    console.log(`T-AMD-6: key=${key} absent after delete (PASS)`);
    Deno.exit(0);
  }
  console.error(`T-AMD-6: post-delete HEAD failed for key=${key}`);
  Deno.exit(2);
}
