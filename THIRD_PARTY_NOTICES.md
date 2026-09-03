# Third-Party Notices

MeetMemo Interview links the sherpa-onnx speech-recognition stack and ONNX Runtime,
and it can download several local speech models on the user's request. The complete
license texts, upstream notices, exact versions, immutable source links, conversion
attributions, and model hashes are in [`ThirdPartyLicenses/`](ThirdPartyLicenses/README.md).

The application archive contains the same directory at
`MeetMemo Interview.app/Contents/Resources/ThirdPartyLicenses`.

Important distinctions:

- SenseVoiceSmall is governed by the FunASR Model Open Source License Agreement
  v1.1; it is not described here as MIT or Apache-2.0.
- The linked sherpa-onnx v1.13.2 library is assembled only from the official
  static-no-TTS libraries. It excludes Piper/eSpeak implementation objects.
- ONNX Runtime's full upstream `ThirdPartyNotices.txt` is included verbatim.
- Model weights are downloaded separately at runtime and are not embedded in the
  source archive or the application archive.
- This notice is an index, not a replacement for the license files themselves.

MeetMemo itself remains subject to the PolyForm Noncommercial License 1.0.0 and
the upstream Required Notice in `LICENSE` and `NOTICE.md`.
