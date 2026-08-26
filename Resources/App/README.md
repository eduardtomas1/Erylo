# App bundle resources

`Info.plist.in`, `Erylo.entitlements`, and `ThirdPartyNotices.txt` are reviewed release inputs. They stay tracked even though assembled apps and signing output do not. Assembly copies the repository's actual Apache-2.0 `LICENSE` to `Contents/Resources/Erylo-License.txt` and the reviewed Sparkle 2.9.6 plus bundled-component notices to `Contents/Resources/ThirdPartyNotices.txt`; validation rejects a missing, modified, symlinked, or incomplete notice. No additional Erylo distribution license is invented.

No placeholder icon is shipped. Pass a reviewed `.icns` file to `Scripts/release/assemble-app.sh --icon` when final artwork exists; the assembler then copies it to `Contents/Resources/AppIcon.icns` and adds `CFBundleIconFile`. Without that option, neither a fake resource nor dangling icon metadata is emitted.

`Config/Appcast.example.plist` documents the public Sparkle metadata shape but is deliberately rejected by the assembler. A real appcast config may be committed because it contains only a canonical lowercase HTTPS feed URL and public EdDSA key. Userinfo (even empty userinfo), credentials, explicit ports, queries, and fragments are rejected consistently. Private Sparkle keys remain in approved keychain or secret storage and are never accepted by these scripts.
