# Gate 2B Results — Rev 14
Date: 2026-08-15T15:59:48Z
PROJECT_REF: hkfrbdpedrxmbsawnbpr
MEM_THRESHOLD_MIB: 200  CPU_THRESHOLD_MS: 1500

## Fixture Preflight
S-5: test-S-5.jpg 4671619B 2500x2000 sha256=34b728cb30e1ace09f9a27441077469888cd394b1e07fa73fe8877d4e01b2744
S-8: test-S-8.jpg 7172815B 4000x2000 sha256=380ae75688152df3889c20668edc5a627fdca4f81e80d498f245264dec37e09e
S-10: test-S-10.jpg 9725268B 4000x2500 sha256=72f1d59b160131e6f4d088a51de3ed3be236b7e3ee6164e015ece43dbf5bdcc3
S-12: test-S-12.jpg 9075710B 4000x3000 sha256=25f78c81214a4d7d08ca99bf8987fd4971c98aeb6c9ffd9a572bbc52b04a08b3
S-15: test-S-15.jpg 9802741B 5000x3000 sha256=e57ffcc644c7f6b9f301d63c3c25485798ebcc8e834be971ea02c337938fd6de

## Hashes
magick.wasm sha256: c903248c3b66a550b74bac5ea25d359e84455b8d82aa945a16f75f6fd8be610a
index.ts (survey) sha256: f9cc074e01212463e6bb1c71ab8a6142708f93e3c181089a800c098b5b839976

## Survey Phase Results

### Phase S-5MP
Phase S-5MP bundle: 9.3 MB

### S-5
curl_exit=0  HTTP=546  wall_time_s=3.157433
x-request-id: <not found>
HTTP 546 — resource limit boundary
Phase S-5MP: 546 boundary — survey stopped

## Ceiling Selection

Survey Results:
  MP   Func  Telem    CPU ms   Mem MiB                  Reason   Viable
---------------------------------------------------------------------------
   5  false  false         —         —                     546       NO
   8  false  false         —         —                       —       NO
  10  false  false         —         —                       —       NO
  12  false  false         —         —                       —       NO
  15  false  false         —         —                       —       NO
---------------------------------------------------------------------------

RECOMMENDED_CEILING=NONE
VIABLE_LEVELS=
CEILING SELECTION: FAIL — no viable ceiling
