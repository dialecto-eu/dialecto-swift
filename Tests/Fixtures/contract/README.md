# Swift live client contract fixtures

Shared by the Dialecto server and this client. The server's fixture generator writes them, and a server test
builds the release from the input through its real plan and check and fails when any file here differs by a byte.
Do not edit them by hand.

- `input/Localizable.xcstrings`: the String Catalog. Three languages (`en`, `de`, `zh-Hans`), a positional
  `%1$@ %2$lld` (reordered in `de`), a `%%`, a plural, a key marked not to translate and a stale key.
- `localizable/<locale>.json`: the payloads. Flat, keys sorted. The plural and the not-to-translate key are left out.
- `manifest.json`: the signed manifest (release `rel_swiftfixture0001`, sequence 7, committed 2026-10-09), format
  `xcstrings`.
- `test-key.json`: **TEST-ONLY key pair. It signs nothing real; never use it anywhere else.**
