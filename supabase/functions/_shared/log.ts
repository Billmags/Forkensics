import type { FkErrorCode } from "./errors.ts";

interface LogFields {
  fn: string;
  status: number;
  duration_ms: number;
  error_code?: FkErrorCode;
  request_id?: string;
  user_id?: string;
  case_id?: string;
  outcome?: string;
  presign_error?: string;
}

/**
 * Structured log emitter.
 *
 * NEVER logged: paths, tokens, presigned URLs, secrets, keys, JWTs,
 *               raw DB messages, content_type, declared_size_bytes.
 * user_id: only after auth confirmed.
 * case_id: only after body validated.
 * status is always a real HTTP status code (never 0).
 */
export function safeLog(fields: LogFields): void {
  try {
    console.log(JSON.stringify(fields));
  } catch {
    // Logging must never throw.
  }
}
