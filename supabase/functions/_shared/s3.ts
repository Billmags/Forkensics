import { PutObjectCommand, S3Client } from "npm:@aws-sdk/client-s3@3.1109.0";
import { getSignedUrl } from "npm:@aws-sdk/s3-request-presigner@3.1109.0";

// ---------------------------------------------------------------------------
// parseAmzExpiry
// ---------------------------------------------------------------------------

/**
 * Pure fail-closed parser. Exported for direct unit testing.
 *
 * Algorithm:
 *   1. Extract X-Amz-Date and X-Amz-Expires from the signed URL query string.
 *   2. Verify both are present; throw if either is absent.
 *   3. Parse X-Amz-Expires as an integer; throw if !== 300.
 *   4. Match X-Amz-Date against /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/;
 *      throw if pattern does not match.
 *   5. Construct Date via Date.UTC(year, month-1, day, hour, minute, second).
 *   6. Round-trip check: verify each UTC component exactly matches the parsed
 *      value — guards against normalised-but-invalid calendar values
 *      (non-leap Feb 29, Apr 31, hour 25, minute 60, second 60, etc.).
 *   7. Return new Date(date.getTime() + 300_000).
 *
 * Throws on any malformed, missing, non-300, or calendar-invalid input.
 */
export function parseAmzExpiry(signedUrl: string): Date {
  const u = new URL(signedUrl);
  const amzDate = u.searchParams.get("X-Amz-Date");
  const amzExpires = u.searchParams.get("X-Amz-Expires");

  if (!amzDate) {
    throw new Error("parseAmzExpiry: X-Amz-Date absent from signed URL");
  }
  if (!amzExpires) {
    throw new Error("parseAmzExpiry: X-Amz-Expires absent from signed URL");
  }

  const expiresNum = Number(amzExpires);
  if (!Number.isInteger(expiresNum) || expiresNum !== 300) {
    throw new Error(
      `parseAmzExpiry: X-Amz-Expires must be exactly 300, got: ${amzExpires}`,
    );
  }

  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(amzDate);
  if (!m) {
    throw new Error(
      `parseAmzExpiry: malformed X-Amz-Date (expected YYYYMMDDTHHmmssZ): ${amzDate}`,
    );
  }

  const [, y, mo, d, h, mi, s] = m.map(Number);
  const constructed = new Date(Date.UTC(y, mo - 1, d, h, mi, s));

  // Component round-trip: rejects normalization of calendar-invalid values.
  if (
    constructed.getUTCFullYear() !== y ||
    constructed.getUTCMonth() + 1 !== mo ||
    constructed.getUTCDate() !== d ||
    constructed.getUTCHours() !== h ||
    constructed.getUTCMinutes() !== mi ||
    constructed.getUTCSeconds() !== s
  ) {
    throw new Error(
      `parseAmzExpiry: calendar-invalid date in X-Amz-Date: ${amzDate}`,
    );
  }

  return new Date(constructed.getTime() + 300_000);
}

// ---------------------------------------------------------------------------
// presignPutUrl
// ---------------------------------------------------------------------------

function buildR2Client(): S3Client {
  const endpoint = Deno.env.get("R2_ENDPOINT");
  const accessKeyId = Deno.env.get("R2_ACCESS_KEY_ID");
  const secretAccessKey = Deno.env.get("R2_SECRET_ACCESS_KEY");

  if (!endpoint || !accessKeyId || !secretAccessKey) {
    throw new Error(
      "presignPutUrl: R2_ENDPOINT, R2_ACCESS_KEY_ID, and R2_SECRET_ACCESS_KEY must be set",
    );
  }

  return new S3Client({
    region: "auto",
    endpoint,
    forcePathStyle: true,
    credentials: { accessKeyId, secretAccessKey },
    // "WHEN_REQUIRED": prevents the flexibleChecksumsMiddleware from adding
    // x-amz-sdk-checksum-algorithm to the signed headers of presigned PUT URLs.
    // Without this, the SDK (v3.x "WHEN_SUPPORTED" default) injects that header
    // into X-Amz-SignedHeaders, and R2 returns 400 when the client PUT omits it.
    requestChecksumCalculation: "WHEN_REQUIRED",
  });
}

/**
 * Signs a presigned PUT URL for R2.
 *
 * - contentType MUST be provided; it is baked into the signature.
 *   R2 rejects PUT requests whose Content-Type header does not match (403).
 * - ExpiresIn MUST be 300 (literal type).
 * - region: "auto" (R2 requirement).
 * - forcePathStyle: true (R2 requirement).
 * - Returns the URL and the expiry parsed from X-Amz-Date + X-Amz-Expires
 *   (authoritative; never from local clock).
 * - Throws on signing or parse failure (caller compensates).
 */
export async function presignPutUrl(
  objectPath: string,
  expiresIn: 300,
  contentType: string,
): Promise<{ url: string; expiresAt: Date }> {
  const bucket = Deno.env.get("R2_BUCKET");
  if (!bucket) {
    throw new Error("presignPutUrl: R2_BUCKET must be set");
  }
  const client = buildR2Client();

  const command = new PutObjectCommand({
    Bucket: bucket,
    Key: objectPath,
    ContentType: contentType,
  });

  // signableHeaders forces content-type into X-Amz-SignedHeaders so R2
  // rejects any PUT whose Content-Type header does not match exactly.
  const url = await getSignedUrl(client, command, {
    expiresIn,
    signableHeaders: new Set(["content-type"]),
  });
  const expiresAt = parseAmzExpiry(url);
  return { url, expiresAt };
}
