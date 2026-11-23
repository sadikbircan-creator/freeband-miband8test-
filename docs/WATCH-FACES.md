# Watch-face protocol and device profiles

Developer-only protocol notes. This guidance must not be exposed in the app UI or copied into runtime/localized strings.

## Evidence notation

Use one evidence label consistently for every technical claim and test result:

- **[SOURCE]** — protocol or implementation fact supported by a direct source link. Link the exact source file (and relevant lines when available) beside the claim.
- **[MEASURED]** — behavior measured on a physical device and supported by application diagnostic output. Use this label for the physical-device evidence requested in PR review; include model, firmware and relevant result details.
- **[DIAGNOSTIC]** — behavior confirmed by Freeband diagnostic output or recorded application logs when it is not itself a physical-device measurement. Summarize the relevant evidence; never include authentication payloads, keys, MAC addresses or other secrets.
- **[TESTED]** — a physical-device test personally observed and reported, where no retained diagnostic record or external source link is available.
- **[NOT TESTED]** — a behavior or assumption that has not yet been verified. Do not present it as supported or successful.

A physical-device test backed by application logs should use **[MEASURED]** (and may also identify the diagnostic evidence in the description). Use **[DIAGNOSTIC]** for diagnostic-backed results that are not physical-device measurements. Use **[TESTED]** only when the result is based on the observed test report without diagnostic evidence.

## Current support boundary

- **[MEASURED] Xiaomi Smart Band 8:** the existing watch-face work is tested against the Band 8. Its commands, file validation and FE95/0055 upload channel belong to the Band 8 profile.
- **[NOT TESTED] Other Xiaomi devices:** sharing a Xiaomi protobuf envelope, FE95 service, or 0055 characteristic does not prove that the same watch-face file format, transport, chunk rules or install-result behavior is supported.
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
- [SOURCE] Gadgetbridge watch-face command handling and install-result flow: [XiaomiWatchfaceService.java](https://codeberg.org/Freeyourgadget/Gadgetbridge/src/commit/83b2efe915631b484f5c0b15b0cd1b52ebea3580/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/services/XiaomiWatchfaceService.java#L44-L262).
- [SOURCE] Gadgetbridge upload negotiation and chunk-transfer handling: [XiaomiDataUploadService.java](https://codeberg.org/Freeyourgadget/Gadgetbridge/src/commit/83b2efe915631b484f5c0b15b0cd1b52ebea3580/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/services/XiaomiDataUploadService.java#L83-L165).
- [SOURCE] AstroBox watch-face command IDs, prepare messages and install-result codes: [wear_watch_face.proto](https://github.com/AstralSightStudios/AstroBox-NG-Module-Pb/blob/03a92010056dd41af114f6f46fd612104b27bd7b/protos/xiaomi/wear_watch_face.proto).
- [SOURCE] AstroBox upload preparation and acknowledgement definitions: [wear_mass.proto](https://github.com/AstralSightStudios/AstroBox-NG-Module-Pb/blob/03a92010056dd41af114f6f46fd612104b27bd7b/protos/xiaomi/wear_mass.proto).
- Additional protocol analysis and source snapshots maintained in this fork: [CAPABILITIES.md](CAPABILITIES.md) §§13.1–13.2 and [SOURCES-2026-11-13.md](SOURCES-2026-11-13.md).

## Band 8 file validation

- [SOURCE] Gadgetbridge's [XiaomiFWHelper.java](https://codeberg.org/Freeyourgadget/Gadgetbridge/src/commit/83b2efe915631b484f5c0b15b0cd1b52ebea3580/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/XiaomiFWHelper.java) reads the ID from offset `0x28` and name from `0x68` (source snapshot line range 388–440). The ID is NUL-terminated; it must not be truncated to a fixed nine-byte window.
- [SOURCE] AstroBox's [resutils.rs](https://github.com/AstralSightStudios/AstroBox-NG-Module-Core/tree/6b9b82ddc875212a4ec4dd1deb68f39016460f61/src) documents the modern `5A A5 34 12` header and scans for 9- or 12-digit IDs (source snapshot line range 75–167); the same source documents MWZ handling (lines 1191–1194).
- Freeband reads the decimal ID up to its NUL terminator, bounded to the ID/name header region. A 12-digit ID is covered by a synthetic protocol vector.
- **[NOT TESTED] Two-style requirement:** the current Band 8 validator requires `faceCount == 2`, treating the two styles as normal and always-on. A public watch-face builder shows the format can encode one style without AOD or two with AOD (`Mi8WfBinTool.java`, `faceCount = hasAod ? 2 : 1`). This does not prove what every Band 8 firmware accepts. Keep the restriction inside the Band 8 profile; revisit only with a known-good one-style Band 8 file and a real-device test.
- **[NOT TESTED] Preview decoding:** `MiWatchFacePreview.swift` reads the embedded preview offset and supports raw, palette and two RLE paths. Gadgetbridge's reference is `XiaomiBitmapUtils.java:39-44,75-148`. Freeband's RLE handling is not claimed to be byte-for-byte equivalent. Preview decoding is optional: failure to decode must never modify or reject the original BIN. Add real-file fixtures and compare against an independent decoder before widening format support.

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
6. Keep the profile disabled until real-device list, activate, delete and upload tests pass; record model, firmware and date as [DIAGNOSTIC].

Do not copy or translate AGPL-licensed Gadgetbridge implementation code into Freeband. Use source code as protocol evidence, then implement independently from these notes.

## Real-device validation — Xiaomi Smart Band 8

**[MEASURED] [DIAGNOSTIC] Physical-device test record — 2026-11-23**

Device and connection context:
- Device: Xiaomi Smart Band 8
- Model identifier reported by the device: `M2239B1`
- Firmware reported by the device: `2.3.14`
- Transport: FE95 BLE V1
- Authentication completed successfully.
- BLE writes were reported as 244-byte writes. The application-level upload chunks were 2,048 bytes.

The following operations were completed on the physical band using the profile-routed implementation. Results below are supported by the application's diagnostic records:

| Operation | Observed result |
|---|---|
| Read installed watch-face list | Completed; list contained 7 entries in the initial activation test |
| Activate an installed face | Positive device acknowledgement; operation completed |
| Delete an installed face | Positive device acknowledgement; refreshed list contained 6 entries |
| Install Atatürk BIN (user-identified Band 8 face; 379,168 bytes) | Prepare status 0; upload accepted with resume position 0; all 186 chunks acknowledged; final `Command{4,5}` result reported success for the requested ID; automatic activation acknowledged; refreshed list contained 7 entries |
| Activate and delete additional installed faces | Completed with positive acknowledgements |
| Install NewModLand BIN (user-identified Band 10-origin face; 361,181 bytes) | Prepare status 0; upload accepted with resume position 0; all 177 chunks acknowledged; final install result reported success; automatic activation acknowledged; refreshed list contained 7 entries |

**What this establishes**
- The Band 8 profile routing works on the tested Band 8 firmware for list, activate, delete, install preparation, upload negotiation, chunk transfer, per-chunk acknowledgements, final install-result handling, automatic activation and list refresh.
- The upload implementation waited for the device's final install result; completion was not inferred from a fixed delay.
- The NewModLand result is a regression-compatibility observation: the user had previously installed this Band 10-origin face on the Band 8, and it continued to install. It does **not** establish that the file was designed for Band 8 or that Band 10 devices are supported by Freeband.

**Open observation — duplicate embedded face ID**
- Both the Atatürk and NewModLand test files were reported with the same face ID (`167210065`) in the diagnostic output.
- This is consistent with the previously observed duplicate-ID behavior, but the available logs alone do not establish whether the ID is embedded identically in both files, produced by parsing, or affected by another part of the workflow.
- Keep the existing duplicate-ID warning/guard. Do not infer source model or file identity from this ID alone. A byte-level comparison of the original BIN files is still needed.

**[NOT TESTED] Not yet verified**
- Profile rejection and unsupported-state behavior on a different physical device.
- Malformed or truncated BIN handling on-device.
- Preview decoding accuracy against an independent decoder.
- Whether a one-style/no-AOD Band 8 BIN is accepted by the tested firmware.
- The duplicate-ID cause described above.

Diagnostic records were reviewed with sensitive authentication payloads and device-specific secrets excluded from this document. Do not publish raw authentication bytes, keys, MAC addresses or unredacted device identifiers in repository logs or PR discussions.


## Reconnection and re-pairing validation — Xiaomi Smart Band 8

**[TESTED] User-observed physical-device test — 2026-11-23**

The user performed the following checks on the physical band:

- Fully closed and relaunched Freeband.
- Removed the band's pairing from Freeband, then introduced/paired the band again.
- Confirmed that previously installed and externally added watch faces were listed correctly.
- Confirmed that watch-face IDs and names were displayed correctly.
- Confirmed that the currently active watch face was identified and displayed correctly.

**Result:** Watch-face listing, ID/name display and active-face identification remained correct after application restart and re-pairing.

**Evidence scope:** This result is based on the user's direct observation and report. No separate diagnostic log was retained for this test, so it is classified as [TESTED], not [DIAGNOSTIC].


## Large-file upload diagnostic excerpt — Band 10-origin BIN tested on Band 8

**[MEASURED] [DIAGNOSTIC] Physical-device diagnostic excerpt — 2026-11-23**

This is a sanitized excerpt of the retained diagnostic details supplied for the approximately 2.6 MB Band 10-origin watch-face file uploaded to a Xiaomi Smart Band 8. It is intentionally an excerpt, not a claim that the complete original log has been reproduced. Event wording below is retained where available; explanatory notes are marked as such.

Device context:
- Device: Xiaomi Smart Band 8
- Model identifier: `M2239B1`
- Firmware: `2.3.14`
- Upload chunk size: 2,048 bytes
- Total parts: 1,259
- Final part: 902 bytes
- Total payload represented by the part counts: 2,577,286 bytes

Sanitized event sequence:

```text
[21:03:52] [upload] Part 1259/1259 acknowledged (902 bytes).
[21:03:52] [upload] All watch-face data parts acknowledged; waiting for Command{4,5} install result.
[21:03:52] [install] watch face install result: success (167210065); activating
[21:03:52] [activate] Activation command sent for ID 167210065.
[21:04:08] [activate] imported watch-face activation timed out
[21:04:08] [connection] Channel released.
[21:04:21] [connection] Reconnected; device M2239B1; firmware 2.3.14.
[21:04:21] [watch-face-list] List contained 7 items.
[21:04:21] [connection] Channel released.
```

Authentication data handling:
```text
[auth 1/2] request payload: *** [REDACTED]
[auth 1/2] response payload: *** [REDACTED]
[auth 2/2] request payload: *** [REDACTED]
[auth 2/2] response payload: *** [REDACTED]
```

Interpretation:
- All 1,259 upload parts were acknowledged, including the final 902-byte part.
- The device then returned a successful install result for ID `167210065`.
- The subsequent automatic activation timed out. Therefore, this log proves successful data transfer and a successful install-result response, but **does not prove that automatic activation completed**.
- The reconnect reported a seven-item watch-face list. The count alone does not prove that this specific new face was present or active.
- The install result repeated ID `167210065`, which had also appeared in earlier tests. This reinforces the duplicate-ID observation but does not identify its cause.

Security note: authentication request/response bytes are represented by explicit redaction markers above. No authentication payload, key material, MAC address or unique device address is retained in this excerpt. The model identifier is retained because it identifies the product model, not an individual band.



## Comparative physical-device file tests — Xiaomi Smart Band 8

The following cases are deliberately separated. A successful transfer/install response from the Band 8 does not mean that a file originating from another band family is visually compatible with the Band 8, nor does it establish support for that source device.

### Case A — Native Band 8 watch-face file (positive compatibility control)

**[MEASURED] [DIAGNOSTIC] Physical-device test — 2026-11-23**

Test file:
- User-identified as a Band 8 watch-face file (Atatürk face).
- File size: 379,168 bytes.
- Target device: Xiaomi Smart Band 8, model `M2239B1`, firmware `2.3.14`.

Sanitized diagnostic sequence (event summary; not a verbatim raw-log dump):
```text
[prepare] Command{4,4}: status 0
[upload-negotiation] Accepted; resumePosition = 0
[upload] 186 parts; chunk size = 2,048 bytes
[upload] Parts 1..186 acknowledged
[install] Command{4,5}: success (face ID reported by the device/parser)
[activate] Activation acknowledgement: true
[watch-face-list] Refreshed list: 7 entries
[result] Installation and automatic activation completed
```

Observed result:
- Preparation succeeded.
- All 186 upload chunks were acknowledged.
- The final install-result command reported success.
- Automatic activation received a positive acknowledgement.
- The installed list refreshed to 7 entries.
- This is the positive control: a Band 8-origin file completed the full tested upload, install, activation and list-refresh flow on the Band 8.

Evidence limitation:
- The original diagnostic record was reviewed, but a complete raw log transcript is not retained in this document. The sequence above is a sanitized event summary; it must not be mistaken for verbatim log lines.
- Authentication request/response bytes and unique device identifiers are excluded.

### Case B — NewModLand, Band 10-origin file (cross-family compatibility test)

**[MEASURED] [DIAGNOSTIC] Physical-device test — 2026-11-23**

Test file:
- Name: NewModLand.
- Origin: user-identified Band 10 watch-face file.
- File size: 361,181 bytes.
- Target device: Xiaomi Smart Band 8, model `M2239B1`, firmware `2.3.14`.

Sanitized diagnostic sequence (event summary; not a verbatim raw-log dump):
```text
[prepare] Command{4,4}: status 0
[upload-negotiation] Accepted; resumePosition = 0
[upload] 177 parts; chunk size = 2,048 bytes
[upload] Parts 1..177 acknowledged
[install] Command{4,5}: success (167210065)
[activate] Automatic activation acknowledgement: true
[watch-face-list] Refreshed list: 7 entries
[result] Transfer, install response and automatic activation completed
```

Observed on-band result:
- The Band 8 accepted the upload and returned a successful install result.
- Automatic activation was acknowledged.
- The face appeared on the Band 8, but its layout/resolution did not match the Band 8 screen correctly.
- Some data fields/widgets appeared misplaced or incorrect; the AOD presentation was also not correct.

Interpretation:
- This demonstrates that this particular Band 10-origin BIN can pass through the tested Band 8 transfer/install path.
- It is **not** evidence of proper Band 8 visual compatibility, nor evidence that Freeband supports Band 10.
- Treat it as a cross-family negative visual-compatibility test, not as a supported-file success.

### Case C — Additional approximately 2.58 MB Band 10-origin file (large-file stress test)

**[MEASURED] [DIAGNOSTIC] Physical-device test — 2026-11-23**

Test file:
- Origin: user-identified Band 10 watch-face file; distinct from NewModLand.
- Payload size calculated from the reported chunks: 2,577,286 bytes (approximately 2.58 MB / 2.46 MiB).
- Target device: Xiaomi Smart Band 8, model `M2239B1`, firmware `2.3.14`.

Sanitized diagnostic excerpt:
```text
[upload] Chunk size: 2,048 bytes; total parts: 1,259
[upload] Final part 1,259/1,259: 902 bytes; acknowledged
[21:03:52] All watch-face data parts acknowledged; waiting for Command{4,5} install result.
[21:03:52] watch face install result: success (167210065); activating
[21:03:52] Activation command sent for ID 167210065.
[21:04:08] imported watch-face activation timed out
[21:04:08] Channel released.
[21:04:21] Reconnected; device M2239B1; firmware 2.3.14.
[21:04:21] Watch-face list contained 7 items.
```

Observed on-band result reported by the user:
- The main watch-face display appeared, but the layout/resolution was mismatched for the Band 8.
- Some data fields/widgets appeared misplaced or incorrect.
- The AOD presentation was not correct.

Interpretation:
- All 1,259 data parts were acknowledged, and the device returned a successful install result.
- Automatic activation timed out. The seven-item list after reconnect does not, by itself, prove that this exact file was installed or active.
- The user's visual observation indicates that the main face was displayed, but the automatic activation timeout and list-count-only diagnostic evidence remain distinct facts.
- This is a large-file transfer stress test and a cross-family visual-compatibility failure, not a supported Band 8 file success.

Authentication payloads and their raw responses are redacted and are not reproduced. No keys, MAC addresses or unique device addresses are included.

### Case D — Band 4-origin BIN (signature rejection)

**[TESTED] User-observed file-validation test — 2026-11-23**

- Input: user-identified Band 4 BIN.
- Freeband result: `this file does not have a recognized Xiaomi watch-face signature`.
- The file was rejected by local signature validation before upload.
- No physical-band upload or compatibility result was established.

### Case E — Band 6-origin BIN (signature rejection)

**[TESTED] User-observed file-validation test — 2026-11-23**

- Input: user-identified Band 6 BIN.
- Freeband result: `this file does not have a recognized Xiaomi watch-face signature`.
- The file was rejected by local signature validation before upload.
- No physical-band upload or compatibility result was established.

### Comparative conclusion

| Test case | File origin | Band 8 transfer/install result | Automatic activation | Visual compatibility on Band 8 |
|---|---|---|---|---|
| Atatürk control | Band 8 | Successful; all 186 chunks acknowledged; install result success | Acknowledged | Positive tested control |
| NewModLand | Band 10 | Successful; all 177 chunks acknowledged; install result success | Acknowledged | Incorrect layout/fields/AOD |
| Large 2.58 MB file | Band 10 | All 1,259 chunks acknowledged; install result success | Timed out | Main face displayed per user; layout/fields/AOD incorrect |
| Band 4 BIN | Band 4 | Not attempted; rejected by signature validator | Not attempted | Not tested |
| Band 6 BIN | Band 6 | Not attempted; rejected by signature validator | Not attempted | Not tested |

These cases must not be collapsed into a single "upload supported" result. The Band 8-origin file is the positive compatibility control. The Band 10-origin files show that transport/install acceptance can occur without correct rendering. Band 4 and Band 6 samples are currently rejected before upload. No support for Band 4, Band 6 or Band 10 is claimed by these tests.
