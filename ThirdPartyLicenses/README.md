# Third-party license manifest

This directory is shipped with MeetMemo Interview. It contains the exact license
and notice material for the native speech stack linked into the app, plus the
models that the app can download at runtime. Model weights are not part of the
source repository or application archive.

## Linked native components

| Component | Exact source used by the pinned build | License material |
| --- | --- | --- |
| sherpa-onnx v1.13.2 (`13d0ae6c539d2809d32f5eaa3ef1db0c459d0b24`) | [immutable source](https://github.com/k2-fsa/sherpa-onnx/tree/13d0ae6c539d2809d32f5eaa3ef1db0c459d0b24) | `sherpa-onnx/LICENSE` (Apache-2.0) |
| ONNX Runtime v1.24.4 (`2d924974ef147392ced8409d36bd6d2e7fcc8a74`) | [immutable source](https://github.com/microsoft/onnxruntime/tree/2d924974ef147392ced8409d36bd6d2e7fcc8a74) | `onnxruntime/LICENSE`, full `onnxruntime/ThirdPartyNotices.txt` |
| kaldi-native-fbank v1.22.3 (`b09e686fe2084732ddd30d1ef80acfc0f13eaf01`) | [immutable source](https://github.com/csukuangfj/kaldi-native-fbank/tree/b09e686fe2084732ddd30d1ef80acfc0f13eaf01) | `kaldi-native-fbank/LICENSE` |
| kaldi-decoder v0.3.0 (`62fda2d74246a90db9570e46fb16b012f813fae7`) | [immutable source](https://github.com/k2-fsa/kaldi-decoder/tree/62fda2d74246a90db9570e46fb16b012f813fae7) | `kaldi-decoder/LICENSE` |
| kaldifst v1.8.0 (`ab5bdd013bdf13921e6aeee77db5722ebf9955fb`) | [immutable source](https://github.com/k2-fsa/kaldifst/tree/ab5bdd013bdf13921e6aeee77db5722ebf9955fb) | `kaldifst/LICENSE`, `kaldifst/basic-filebuf.h.notice` |
| OpenFST v1.8.5-2026-04-11 (`dbe9dcc03a1206b9350853d4b12e8b7c33186993`) | [immutable source](https://github.com/csukuangfj/openfst/tree/dbe9dcc03a1206b9350853d4b12e8b7c33186993) | `openfst/COPYING` |
| simple-sentencepiece v0.7 (`62dd423df1d51da5ea06f1c3a046fc04f01b4f39`) | [immutable source](https://github.com/pkufool/simple-sentencepiece/tree/62dd423df1d51da5ea06f1c3a046fc04f01b4f39) | `simple-sentencepiece/LICENSE`, plus the complete embedded Darts and ThreadPool notice-bearing files |
| KISS FFT (`febd4caeed32e33ad8b2e0bb5ea77542c40f18ec`) | [source](https://github.com/mborgerding/kissfft/tree/febd4caeed32e33ad8b2e0bb5ea77542c40f18ec) | `kissfft/COPYING`, `kissfft/BSD-3-Clause.txt` |
| nlohmann/json v3.12.0 (`55f93686c01528224f448c19128836e7df245f72`) | [immutable source](https://github.com/nlohmann/json/tree/55f93686c01528224f448c19128836e7df245f72) | `nlohmann-json/LICENSE.MIT` |
| hclust-cpp 2026-02-25 (`db76039198979ce8d03632ab6ef14fe6accb127c`) | [immutable source](https://github.com/csukuangfj/hclust-cpp/tree/db76039198979ce8d03632ab6ef14fe6accb127c) | `hclust-cpp/LICENSE` |
| Eigen 5.0.1 (`bc3b39870ecb690a623a3f49149a358b95c5781d`) | [immutable source](https://gitlab.com/libeigen/eigen/-/tree/bc3b39870ecb690a623a3f49149a358b95c5781d) | all six upstream license files and `eigen-5.0.1-source.tar.gz` (archive SHA-256 `e9c326dc8c05cd1e044c71f30f1b2e34a6161a3b6ecf445d56b53ff1669e3dec`) |

The sherpa library is assembled from the official
`sherpa-onnx-v1.13.2-osx-universal2-static-no-tts-lib.tar.bz2` asset (SHA-256
`da84dc0d6c7c09de1030caea2a2abadd1504bd66887100cf3af357df178c10ce`).
It deliberately omits the Piper/eSpeak TTS libraries, PortAudio, the C++ API
wrapper, and static ONNX Runtime. ONNX Runtime is bundled as a separate v1.24.4
dynamic library.

## Runtime-downloadable models

| Model | Provenance | License material |
| --- | --- | --- |
| SenseVoiceSmall | Alibaba Group / FunASR; ONNX conversion repository revision `2365baeacb507f821a0c8120fcee3d484dba7a07` | `models/SenseVoiceSmall-MODEL_LICENSE` (FunASR Model Open Source License Agreement v1.1) |
| Silero VAD v4 | snakers4/silero-vad; k2-fsa 16 kHz ONNX export; model SHA-256 `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6` | `models/Silero-VAD-LICENSE` (MIT) |
| CAM++ speaker embedding | 3D-Speaker / `iic/speech_campplus_sv_zh-cn_16k-common`; k2-fsa ONNX export; model SHA-256 `f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11` | `models/3D-Speaker-LICENSE` (Apache-2.0) |
| Fun-ASR-Nano-2512 INT8 | FunAudioLLM/Tongyi Lab; Wasser1462/zengshuishui conversion; k2-fsa mirror revision `6f16bd378457e13f36ccf3910df9017f96c346fb` | `models/Fun-ASR-LICENSE` and `models/Qwen3-0.6B-LICENSE` (Apache-2.0) |
| Qwen3-ASR-0.6B INT8 | QwenLM; converter revisions `68818b2313fe77bd06f6a7c5068ff3ef59d02b8a` (Hugging Face) and `9c182309f7bb075f241424441add9e16c5086dfb` (ModelScope) | `models/Qwen3-ASR-LICENSE` (Apache-2.0) |

SenseVoiceSmall attribution: SenseVoiceSmall © 2023–2028 Alibaba Group / FunASR.
ONNX conversion provided by csukuangfj. Used under the FunASR Model Open Source
License Agreement v1.1. The model license says later revisions may apply, so its
official terms must be checked again before each public release or model mirror.

## Integrity

`SHA256SUMS` is the canonical, complete file manifest for this directory. The
build scripts reject missing files, extra files, symbolic links, or checksum
mismatches both before packaging and after copying the directory into the App.

The application code pins every downloaded model file by immutable revision,
exact byte size, and SHA-256. `scripts/fetch_sherpa_frameworks.sh` likewise pins
all native release assets and refuses a checksum mismatch. The release checklist
also verifies that this directory is present in the final application bundle.
