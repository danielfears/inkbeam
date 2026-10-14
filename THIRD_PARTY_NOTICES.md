# Third-party notices

## UxPlay

InkBeam downloads and runs
[UxPlay](https://github.com/FDH2/UxPlay) through the
[uxplay-windows](https://github.com/leapbtw/uxplay-windows) packaging project.
Both are licensed under the GNU General Public License version 3 or later.

The runtime is not committed to this repository. The reproducible build uses
the pinned `uxplay-windows` 2.0.0.1736 release and
[libuxplay commit 437f375](https://github.com/leapbtw/libuxplay/commit/437f37514257d9cb513ac7fbdee743b4da85852e).
It applies the
[random-PIN attempt-count patch](https://github.com/danielfears/inkbeam/blob/main/patches/uxplay-random-password-attempt-count.patch),
which increments the retry counter only after failed credential verification.
The resulting x64 runtime is published as the
[InkBeam UxPlay 2.0.0.1736-authfix1 prerelease](https://github.com/danielfears/inkbeam/releases/tag/uxplay-2.0.0.1736-authfix1).
The installer verifies its published SHA-256 digest before use.

`scripts/Start-ReceiverHost.ps1` includes digit-glyph data derived from
UxPlay's `create_pin_display` implementation so that UxPlay's ephemeral PIN can
be shown in the desktop widget. This project is therefore distributed under
GPL-3.0-or-later.

## Apple trademarks and protocols

AirPlay, iPad and Apple are trademarks of Apple Inc. This project is
unofficial, is not endorsed by Apple, and does not claim AirPlay
certification. It supports ordinary screen mirroring and does not decrypt
FairPlay-protected video.
