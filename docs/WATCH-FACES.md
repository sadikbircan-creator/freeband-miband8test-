# Watch-face protocol and device profiles

Developer-only protocol notes. This guidance must not be exposed in the app UI or copied into runtime/localized strings.

## Evidence notation

Use one evidence label consistently for every technical claim and test result:

- **[SOURCE]** — protocol or implementation fact supported by a direct source link. Link the exact source file (and relevant lines when available) beside the claim.
- **[MEASURED]** — behavior measured on a physical device and supported by application diagnostic output. Use this label for the physical-device evidence requested in PR review; include model, firmware and relevant result details.
- **[DIAGNOSTIC]** — file structure or behavior confirmed by offline BIN inspection, Freeband diagnostic output or recorded application logs when it is not itself a physical-device measurement. Summarize the relevant evidence; never include authentication payloads, keys, MAC addresses or other secrets.
- **[TESTED]** — a test directly observed and reported by the user where no retained diagnostic record is available. This can cover a physical-device check or a local file-validation test.
- **[NOT TESTED]** — a behavior or assumption that has not yet been verified. Do not present it as supported or successful.

A physical-device test backed by application logs should use **[MEASURED]** (and may also identify the diagnostic evidence in the description). Use **[DIAGNOSTIC]** for diagnostic-backed results that are not physical-device measurements. Use **[TESTED]** when the result is based on the user's observation or report without retained diagnostic evidence.

## Current support boundary

- **Watch-face support is currently limited to the Xiaomi Smart Band 8.** The watch-face workflow has been tested on a physical Band 8; its commands, file validation and FE95/0055 upload channel belong to the Band 8 profile.
- **[NOT TESTED] Other Xiaomi devices:** sharing a Xiaomi protobuf envelope, FE95 service, or 0055 characteristic does not prove that the same watch-face file format, transport, chunk rules or install-result behavior is supported.
- **Current import scope:** the Freeband picker accepts `.bin` files only. AstroBox's `.mwz` package extraction is documented as a research reference; `.mwz` parsing/extraction is not implemented in this fork.
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
7. Reject nonzero `resumePosition` and stop the current attempt without sending partial file data. Freeband does not try an undocumented same-session reset. A new user-initiated install starts again at `Command{4,4}` and repeats upload negotiation from the start; if the band reports a nonzero offset again, the attempt is stopped again.
8. Wait for `Command{4,5}`; validate the returned ID and result code. Only `INSTALL_SUCCESS = 2` permits activation. Codes 0 (verification failed), 1 (install failed), 3 (already installed/in use), malformed replies and timeouts are failures.
9. After activation, require its acknowledgement and refresh the installed list before reporting completion.

Protocol sources:
- [SOURCE] Gadgetbridge watch-face command handling and install-result flow: [XiaomiWatchfaceService.java](https://codeberg.org/Freeyourgadget/Gadgetbridge/src/commit/83b2efe915631b484f5c0b15b0cd1b52ebea3580/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/services/XiaomiWatchfaceService.java#L44-L262).
- [SOURCE] Gadgetbridge upload negotiation explicitly fails the current transfer when `resumePosition` is nonzero, rather than continuing at an offset: [XiaomiDataUploadService.java, lines 61–68](https://github.com/Freeyourgadget/Gadgetbridge/blob/a0948ee1cbc2a870f91d313f8e37df5f524465f7/app/src/main/java/nodomain/gadgetbridge/service/devices/xiaomi/services/XiaomiDataUploadService.java#L61-L68). The upload request and part-transfer implementation are in [lines 94–174](https://github.com/Freeyourgadget/Gadgetbridge/blob/a0948ee1cbc2a870f91d313f8e37df5f524465f7/app/src/main/java/nodomain/gadgetbridge/service/devices/xiaomi/services/XiaomiDataUploadService.java#L94-L174).
- [SOURCE] AstroBox watch-face command IDs, prepare messages and install-result codes: [wear_watch_face.proto](https://github.com/AstralSightStudios/AstroBox-NG-Module-Pb/blob/03a92010056dd41af114f6f46fd612104b27bd7b/protos/xiaomi/wear_watch_face.proto).
- [SOURCE] AstroBox upload preparation and acknowledgement definitions: [wear_mass.proto](https://github.com/AstralSightStudios/AstroBox-NG-Module-Pb/blob/03a92010056dd41af114f6f46fd612104b27bd7b/protos/xiaomi/wear_mass.proto).
- Additional protocol analysis and source snapshots maintained in this fork: [CAPABILITIES.md](CAPABILITIES.md) §§13.1–13.2 and [SOURCES-2026-11-13.md](SOURCES-2026-11-13.md).

## Band 8 file validation

- [SOURCE] Gadgetbridge's [XiaomiFWHelper.java, lines 320–335](https://github.com/Freeyourgadget/Gadgetbridge/blob/a0948ee1cbc2a870f91d313f8e37df5f524465f7/app/src/main/java/nodomain/gadgetbridge/devices/xiaomi/XiaomiFWHelper.java#L320-L335) reads the ID at offset `0x28` up to its NUL terminator and rejects IDs that are not decimal digits. Its name reader starts at `0x68` ([lines 338–355](https://github.com/Freeyourgadget/Gadgetbridge/blob/a0948ee1cbc2a870f91d313f8e37df5f524465f7/app/src/main/java/nodomain/gadgetbridge/devices/xiaomi/XiaomiFWHelper.java#L338-L355)).
- [SOURCE] AstroBox's [resutils.rs, lines 75–105](https://github.com/AstralSightStudios/AstroBox-NG-Module-Core/blob/6b9b82ddc875212a4ec4dd1deb68f39016460f61/src/device/xiaomi/resutils.rs#L75-L105) locates 9- or 12-character ASCII alphanumeric IDs in the configured BIN field. Its `.mwz` ID reader checks package metadata and falls back to the embedded BIN ([lines 107–149](https://github.com/AstralSightStudios/AstroBox-NG-Module-Core/blob/6b9b82ddc875212a4ec4dd1deb68f39016460f61/src/device/xiaomi/resutils.rs#L107-L149)). Freeband intentionally follows Gadgetbridge's decimal-only BIN ID rule.
- Freeband reads the decimal ID up to its NUL terminator, bounded to the ID/name header region. A 12-digit ID is covered by a synthetic protocol vector.
- [SOURCE] The [Mi Band 8 Watch Face Maker](https://www.mibandwatchfaces.com/mi_band8_watchface_maker/) Info section specifies a 122×310 `previewImg`. The [Mi8WfBinTool packer, lines 929–962](https://github.com/zhy8388608/Mi8WfBinTool/blob/5e4195ce91b9d8810a7a2233c96b4cba44184adc/Mi8WfBinTool.java#L929-L962) reads that asset, encodes it and stores its offset in the BIN header; a [Band 8 watch-face tutorial, section 5.1](https://www.bandbbs.cn/threads/7188/page-17) independently gives the same 122×310 dimension. This is a warning-only profile reference, not a universal format rule.
- [SOURCE] The same packer sets `faceCount = hasAod ? 2 : 1` ([Mi8WfBinTool.java, lines 919–934](https://github.com/zhy8388608/Mi8WfBinTool/blob/5e4195ce91b9d8810a7a2233c96b4cba44184adc/Mi8WfBinTool.java#L919-L934)). Therefore, two styles are not a universal file-format requirement: a package without AOD can declare one style.
- Freeband's parser now requires at least one declared style. A count different from the Band 8 profile's two-style normal+AOD reference is reported as a compatibility warning and does not block import.
- [NOT TESTED] Whether the tested Band 8 firmware accepts and renders a one-style/no-AOD package has not yet been verified on a physical band.
- [SOURCE] The packer reads the embedded preview header and selects the raw/palette/LVGL RLE decode path in [Mi8WfBinTool.java, lines 763–779](https://github.com/zhy8388608/Mi8WfBinTool/blob/5e4195ce91b9d8810a7a2233c96b4cba44184adc/Mi8WfBinTool.java#L763-L779).
- [SOURCE] The packer’s RLE v1 decoder (`Rle.decV10`, lines 330–353) uses a clear high bit for repeating the next pixel `n` times and a set high bit for `n` literal pixels. Its RLE v2 decoder (`Rle.decV20`, lines 379–394) uses byte-level runs: set high bit for `n` literal bytes, clear high bit for repeating the next byte `n` times ([Mi8WfBinTool.java](https://github.com/zhy8388608/Mi8WfBinTool/blob/5e4195ce91b9d8810a7a2233c96b4cba44184adc/Mi8WfBinTool.java#L330-L394)).
- [SOURCE] Gadgetbridge’s `XiaomiBitmapUtils.java` is a separate implementation. In the archived GitHub mirror, its RLE v1 decoder uses the opposite control-bit polarity and `n+1` chunk counts; its RLE v2 decoder uses `n` chunks and supports a configurable chunk size ([XiaomiBitmapUtils.java, lines 177–295](https://github.com/Freeyourgadget/Gadgetbridge/blob/a0948ee1cbc2a870f91d313f8e37df5f524465f7/app/src/main/java/nodomain/freeyourgadget/gadgetbridge/service/devices/xiaomi/XiaomiBitmapUtils.java#L177-L295)). Freeband intentionally follows the cited packer’s RLE representation, not Gadgetbridge’s v1 decoder. No Gadgetbridge decoder code was copied or translated.
- Freeband’s RLE v1 implementation applies strict input bounds and exact decoded-length checks; its RLE v2 implementation handles the byte-oriented form used by the selected preview branch. Protocol fixtures cover both repeat and literal records for RLE v1 and RLE v2. Pixel-by-pixel parity with Gadgetbridge has not been established.
- A nonzero `resumePosition` fails the active install attempt with a specific UI message. The user can retry the install from the beginning; that retry repeats preparation and upload negotiation rather than continuing the saved offset. Freeband does not automatically loop or assume that a second request resets a band-side partial transfer.
- Preview decoding is optional: missing metadata, unsupported encoding or a dimension mismatch generates an advisory warning. It must never alter or reject an otherwise parseable BIN by itself.


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
6. Keep the profile disabled until real-device list, activate, delete and upload tests pass; record model, firmware and date as [MEASURED], with sanitized application diagnostic evidence.

Do not copy or translate AGPL-licensed Gadgetbridge implementation code into Freeband. Use source code as protocol evidence, then implement independently from these notes.

## Shared watch-face compatibility analysis

The shared, read-only analyzer is `ios/Freeband/Band/WatchFaceCompatibility.swift`. It reads the embedded preview dimensions, attempts to decode the preview and returns only the values consumed by the import UI: preview size, decoded preview (if supported) and advisory warnings. It never changes the BIN and never blocks installation. The profile supplies device-specific reference values; shared parsing and decoding logic is not duplicated per device.

The shared analyzer consumes the Band 8 profile references documented once in **Band 8 file validation** above: 122×310 for the embedded preview and a two-style normal+AOD comparison. The latter is advisory because the cited packer writes one style when AOD is absent. A zero-style file is structurally rejected; one-style files remain importable.

The profile checks are advisory: a dimension mismatch, decode failure or style-count difference warns but does not block installation. These checks do not establish widget, data-source or on-band AOD compatibility. Physical observations and the separate offline header comparison are recorded below; they are not interchangeable evidence.
- [DIAGNOSTIC] Static header comparison of the two uploaded reference samples (offline byte inspection, not a device-compatibility result):

  | Sample | Size | Header signature | ID | Face count | Embedded preview offset |
  |---|---:|---|---|---:|---:|
  | Atatürk (Band 8 reference) | 379,168 bytes | `5A A5 34 12` | `167210065` | 2 | `0x00051EE4` (335,588) |
  | CascadeDigitsConv (user-identified Band 10 test) | 2,572,224 bytes | `5A A5 34 12` | `167210065` | 2 | `0x00208534` (2,131,252) |

  SHA-256: Atatürk `f7d2a60b47c4bc1eaa3b1f9cc4ad16cd2b52fa7e26ab514eacbecfed38a88a06`; Band 10 test `96c765a0a73eaa04ac789bc65820876e1a77681d929854f31526a5a07b2a6279`.
- The two samples therefore share the same signature, reported ID and style count. None of those header values can distinguish their device origin. Their preview offsets differ, but an offset is only a location pointer, not a preview dimension.
- The uploaded `band10_test3.bin` sample is **2,572,224 bytes**. The earlier physical diagnostic Case C records a **2,577,286-byte** payload; these are not the same byte-for-byte sample based on size alone and must remain separate test records unless their hashes are compared.
- The earlier offline comparison above did not measure embedded width/height or pixel decoding. The later user-observed batch result is recorded separately below and must not be retroactively attributed to these two exact files without matching filenames or hashes.
- A preview-size match or successful preview decode is not proof that the full face layout, widget coordinates, data sources or AOD are compatible. Those require separate structural analysis and physical-device validation.
- Future device profiles supply their own optional reference values to the same analyzer. The metadata reader, image decoder and warning/report mechanism are shared rather than copied into each profile.


## Latest compatibility-analysis check — Xiaomi Smart Band 8

**[TESTED] User-observed physical-device test — 2026-11-23 (later test batch)**

The user imported several different watch-face BIN files and checked the compatibility report and preview in the app.

- Band 8-origin files tested in this batch: no compatibility warnings; embedded previews decoded and displayed.
- Band 10-origin files tested in this batch: the report warned that the normal+AOD style reference was not met and that the embedded preview did not match the 122×310 reference.
- These warnings did not block import, upload or activation. The user confirmed that the files could still be uploaded and activated.
- This is evidence about the files tested in this batch only. It does not establish universal Band 8/Band 10 classification accuracy or guarantee correct on-band rendering.
- The exact filenames, individual dimensions and file hashes for this later batch were not retained in the report. Do not merge these observations with the earlier named NewModLand, CascadeDigitsConv or 2.58 MB test records unless the samples are positively matched.

**Status of older records:** The earlier diagnostic-backed transfer/install records below remain valid historical evidence for those specific test files and firmware. They describe upload, install and activation behavior, not the later compatibility analyzer's warning accuracy. Where older preliminary notes said preview dimensions had not been inspected, the later batch result supersedes that general statement, but does not supply exact measurements for the older named files.

## Real-device validation — Xiaomi Smart Band 8

**[MEASURED] Physical-device test record — 2026-11-23**

Device and connection context:
- Device: Xiaomi Smart Band 8
- Model identifier reported by the device: `M2239B1`
- Firmware reported by the device: `2.3.14`
- Transport: FE95 BLE V1
- Authentication completed successfully.
- BLE writes were reported as 244-byte writes. Application-level upload chunks were 2,048 bytes.

The following core operations were completed on the physical band using the profile-routed implementation:
- Installed watch-face list request and parsing completed.
- Activation of an installed face received a positive device acknowledgement.
- Deletion of an inactive removable face received a positive device acknowledgement; the refreshed list decreased from seven entries to six.
- The separate file-by-file install and rendering outcomes are recorded in Cases A–E below.

**What this establishes**
- The tested Band 8 profile can list, activate and delete faces on firmware 2.3.14.
- The upload/install evidence is separated by source file in the comparative records below. A successful transfer or install response is not treated as proof of visual compatibility.
- New device families remain unsupported until they have their own independently verified profile.

**[NOT TESTED] Not yet verified**
- Profile rejection and unsupported-state behavior on a different physical device.
- Malformed or truncated BIN handling on-device.
- Preview decoding accuracy against an independent decoder.
- Whether a one-style/no-AOD Band 8 BIN is accepted and rendered by the tested firmware.
- The cause of the duplicate face ID observed in the Atatürk and NewModLand diagnostic records.

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


## Comparative physical-device file tests — Xiaomi Smart Band 8

The following cases are deliberately separated. A successful transfer/install response from the Band 8 does not mean that a file originating from another band family is visually compatible with the Band 8, nor does it establish support for that source device.

### Case A — Native Band 8 watch-face file (positive compatibility control)

**[MEASURED] Physical-device test — 2026-11-23**

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

**[MEASURED] Physical-device test — 2026-11-23**

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

**Open observation — duplicate face ID**
- The Atatürk Band 8 reference log and this NewModLand Band 10-origin log both report face ID `167210065`.
- This ID must not be used as a device-family detector. The reason the two files share the reported ID has not been established.
- A direct BIN/header comparison is still pending; no change to ID parsing is justified by this observation alone.

### Case C — Additional approximately 2.58 MB Band 10-origin file (large-file stress test)

**[MEASURED] Physical-device test — 2026-11-23**

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