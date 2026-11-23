# Watch-face protocol and device profiles

Developer-only protocol notes. This guidance must not be exposed in the app UI or copied into runtime/localized strings.

## Current support boundary

- **[MEASURED] Xiaomi Smart Band 8:** the existing watch-face work is tested against the Band 8. Its commands, file validation and FE95/0055 upload channel belong to the Band 8 profile.
- **[UNVERIFIED] Other Xiaomi devices:** sharing a Xiaomi protobuf envelope, FE95 service, or 0055 characteristic does not prove that the same watch-face file format, transport, chunk rules or install-result behavior is supported.
- Future devices must get their own profile. No other profile may fall back to Band 8 commands or file validation.

## Device profile routing in Freeband

The runtime registry is `ios/Freeband/Band/WatchFaceProfiles.swift`.

- The registry currently resolves only the Xiaomi Smart Band 8 family.
- `BandLink` resolves the profile again after authentication, using the actual CoreBluetooth peripheral name (the saved band name is only a fallback), and refuses watch-face operations if the authenticated device has no profile.
- List, activate, delete, install preparation, upload negotiation, payload chunking, result parsing, BIN validation and preview decoding are dispatched through the selected profile.
- The UI keeps the existing Band 8 flow. Devices without a profile see a WIP/unsupported state and do not start a watch-face session.
- A future profile must be added explicitly to the registry with its own protocol/transport and file rules. Never add a generic fallback to the Band 8 implementation.

The profile matcher is intentionally conservative: it recognizes a name containing `Band 8`, while excluding names containing `Pro` or `Active`. It does not infer compatibility from a shared Xiaomi protobuf transport.

## Band 8 command sequence

1. `Command{4,0}`: request the installed watch-face list.
2. `Command{4,1}`: activate a face by ID; require a positive acknowledgement.
3. `Command{4,2}`: delete a face by ID; require a positive acknowledgement and refresh the list.
4. `Command{4,4}`: prepare installation with face ID and file size; require a present status equal to zero.
5. `Command{22,0}`: request data upload with type 16, full-file MD5 and size; require a present zero errno.
6. Send data through the Band 8 profile's FE95/0055 channel. Each part must be acknowledged before the next part.
7. Reject nonzero `resumePosition`. Gadgetbridge and AstroBox describe different resume semantics; do not guess.
8. Wait for `Command{4,5}`; validate the returned ID and result code. Only `INSTALL_SUCCESS = 2` permits activation. Codes 0 (verification failed), 1 (install failed), 3 (already installed/in use), malformed replies and timeouts are failures.
9. After activation, require its acknowledgement and refresh the installed list before reporting completion.

Protocol sources:
- [CODE] Gadgetbridge: `XiaomiWatchfaceService.java:44-49,72-262`; `XiaomiDataUploadService.java:83-87,106-165`.
- [CODE] AstroBox protocol definitions: `protos/xiaomi/wear_watch_face.proto` (WatchFace command IDs, PrepareInfo, PrepareReply, InstallResult; result ID field 1 and code field 2; VERIFY_FAILED=0, INSTALL_FAILED=1, INSTALL_SUCCESS=2, INSTALL_USED=3).
- [CODE] AstroBox upload definitions: `protos/xiaomi/wear_mass.proto` (prepare request/response and upload acknowledgement).
- Additional byte layouts and source snapshots: `docs/CAPABILITIES.md` §§13.1–13.2 and `docs/SOURCES-2026-11-13.md`.

## Band 8 file validation

- [CODE] Gadgetbridge `XiaomiFWHelper.java:388-440` reads the ID from offset `0x28` and name from `0x68`. The ID is NUL-terminated; it must not be truncated to a fixed nine-byte window.
- [CODE] AstroBox `resutils.rs:75-167` documents the modern `5A A5 34 12` header and scans for 9- or 12-digit IDs; `resutils.rs:1191-1194` documents MWZ handling.
- Freeband reads the decimal ID up to its NUL terminator, bounded to the ID/name header region. A 12-digit ID is covered by a synthetic protocol vector.
- **[UNVERIFIED] Two-style requirement:** the current Band 8 validator requires `faceCount == 2`, treating the two styles as normal and always-on. A public watch-face builder shows the format can encode one style without AOD or two with AOD (`Mi8WfBinTool.java`, `faceCount = hasAod ? 2 : 1`). This does not prove what every Band 8 firmware accepts. Keep the restriction inside the Band 8 profile; revisit only with a known-good one-style Band 8 file and a real-device test.
- **[UNVERIFIED] Preview decoding:** `MiWatchFacePreview.swift` reads the embedded preview offset and supports raw, palette and two RLE paths. Gadgetbridge's reference is `XiaomiBitmapUtils.java:39-44,75-148`. Freeband's RLE handling is not claimed to be byte-for-byte equivalent. Preview decoding is optional: failure to decode must never modify or reject the original BIN. Add real-file fixtures and compare against an independent decoder before widening format support.

## Research references for future, currently unimplemented profiles

These are research references, not implemented support claims:

| Candidate family / transport | Source evidence | What remains unverified in Freeband |
|---|---|---|
| Xiaomi protobuf devices using BLE V1 | `docs/BLE-V1.md`; Gadgetbridge `XiaomiBleProtocolV1.java` and `XiaomiSppProtocolV1.java` | Whether the model exposes the needed V1 characteristics and whether its watch-face upload channel matches Band 8 |
| Xiaomi protobuf devices using BLE V2 | Gadgetbridge `XiaomiBleProtocolV2.java`; `docs/CAPABILITIES.md` §13.1 | Whether watch-face commands, type 16, acknowledgements and payload framing work on that model/firmware |
| Xiaomi devices using Bluetooth Classic / SPP | Gadgetbridge device coordinators and `XiaomiSppPacketV1.java` / `XiaomiSppPacketV2.java`; AstroBox `packet/v2/layer2.rs` and `packet/mass.rs` | Discovery, authentication, command framing, upload ACK behavior and actual watch-face compatibility |
| Zepp OS-era devices (for example Mi Band 7) | Gadgetbridge device coordinators distinguish these from Xiaomi protobuf devices | Separate protocol and file-format investigation required; do not reuse this profile |

For every future profile:
1. Identify the exact model and firmware from authenticated device info.
2. Record its FE95 characteristics/properties (or SPP transport) from a real connection.
3. Write byte-level protocol notes and cite exact source files/lines before implementation.
4. Implement list, activate, delete, file validation, upload and result parsing in that profile only.
5. Add synthetic protocol vectors and an independent reference checker.
6. Keep the profile disabled until real-device list, activate, delete and upload tests pass; record model, firmware and date as [MEASURED].

Do not copy or translate AGPL-licensed Gadgetbridge implementation code into Freeband. Use source code as protocol evidence, then implement independently from these notes.
