export type FkErrorCode =
  | "FK_UNAUTHENTICATED"
  | "FK_FORBIDDEN"
  | "FK_NOT_FOUND"
  | "FK_WRONG_STATE"
  | "FK_UPLOAD_IN_PROGRESS"
  | "FK_FILE_TOO_LARGE"
  | "FK_INVALID_CONTENT_TYPE"
  | "FK_INVALID_INPUT"
  | "FK_INVALID_TOKEN"
  | "FK_INTERNAL"
  | "FK_PROCESSING_FAILED";

const KNOWN_CODES: readonly FkErrorCode[] = [
  "FK_UNAUTHENTICATED",
  "FK_FORBIDDEN",
  "FK_NOT_FOUND",
  "FK_WRONG_STATE",
  "FK_UPLOAD_IN_PROGRESS",
  "FK_FILE_TOO_LARGE",
  "FK_INVALID_CONTENT_TYPE",
  "FK_INVALID_INPUT",
  "FK_INVALID_TOKEN",
  "FK_INTERNAL",
  "FK_PROCESSING_FAILED",
];

export function errorEnvelope(
  code: FkErrorCode,
  message: string,
  status: number,
): Response {
  return new Response(
    JSON.stringify({ error: { code, message } }),
    {
      status,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      },
    },
  );
}

/**
 * Extracts a FK_* error code from a DB error object.
 * Returns null when no recognisable code is present.
 */
export function extractDbErrorCode(err: unknown): FkErrorCode | null {
  if (!err || typeof err !== "object") return null;
  const msg = (err as Record<string, unknown>)["message"];
  if (typeof msg !== "string") return null;
  const match = /\b(FK_[A-Z_]+)\b/.exec(msg);
  if (!match) return null;
  const candidate = match[1] as FkErrorCode;
  return (KNOWN_CODES as readonly string[]).includes(candidate)
    ? candidate
    : null;
}
