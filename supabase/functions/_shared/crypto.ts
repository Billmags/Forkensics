/**
 * Generates a 32-byte cryptographically random upload token encoded as
 * base64url (43 chars, ~256 bits of entropy).
 */
export function generateUploadToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64url(bytes);
}

/**
 * Returns the SHA-256 digest of `data` as a lowercase 64-character hex string.
 */
export async function sha256Hex(data: Uint8Array): Promise<string> {
  // Deno 2.x types Uint8Array as Uint8Array<ArrayBufferLike>; subtle.digest
  // requires BufferSource (ArrayBufferView<ArrayBuffer>). Cast is safe: every
  // Uint8Array created by TextEncoder.encode() and new Uint8Array() is backed
  // by a plain ArrayBuffer, never a SharedArrayBuffer.
  const digest = await crypto.subtle.digest(
    "SHA-256",
    data as unknown as Uint8Array<ArrayBuffer>,
  );
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}
