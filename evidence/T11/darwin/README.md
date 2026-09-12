# T11 Darwin publication continuation

Source commit `d8e7ac519f3eca4b282840c8bc4c072a0d591739`, tree `a047bd09308d1fb46764a09970bc0fad7ec06d0c`, base `11b2fdc4953e3a27089c4c4b51cda1b0433b14a8`. Source is frozen. Public exports and the production write gate are unchanged.

The macOS implementation reads native `std.c.Stat` through `std.c.fstat`, using Zig's Intel `fstat$INODE64` binding and the policy module's exact device conversion. It refuses non-regular files, multiple links, special mode bits, negative lengths, nonzero flags, xattrs (including compression attributes), and native extended ACLs. A null ACL is accepted only with `ENOENT`; any allocated ACL is freed and conservatively refused. Supported mode/owner/group remain required. Create uses descriptor-relative `renameatx_np(RENAME_EXCL)` and the existing identity reconciliation after syscall errors. `fchmod` now uses the target's mode width.

The portable 41-test suite retains real replace/create, exclusive-create races, cancellation/fence/version, quarantine and lifecycle assertions. The metadata fixture now creates a real Darwin extended ACL through native ACL APIs; no Linux ACL xattr or ABI is used on macOS. Metadata refusal is also asserted through the editor before journal preparation. The ordinary-mode test checks the published file's mode/owner/group and identity. The uncertain-rename test retries the operation and asserts the same receipt ID and generation.

| Check | Result |
|---|---|
| Linux x86_64 Debug | 41/41 executed, zero skips, exit 0 |
| Linux x86_64 ReleaseSafe | 41/41 executed, zero skips, exit 0 |
| aarch64-macos.11.0 Debug / ReleaseSafe | Semantic cross-compile checks, exit 0; no binary emitted |
| x86_64-macos.11.0 Debug / ReleaseSafe | Semantic cross-compile checks, exit 0; no binary emitted |
| Current source on native macOS | NOT_RUN |

`results.json` records complete compiler/run argv, environment, cwd, exits, source/tree, corpus/config/contract hashes, compiler and Linux binary hashes, and all scratch artifact hashes. The T11 root was compiled directly with the same module graph as `build.zig`, then its binary executed from the isolated task temp directory. This runs all 41 T11 tests without filtering; this base's missing T12 source prevents using the aggregate write group. It does not establish any T12 gate.

Historical native RED is preserved in `native-red-Debug.log` and `native-red-ReleaseSafe.log`. Run `34692959158`, Apple Silicon job `103551374482`, artifact `10297447481` failed compiling T11 because `fchmod` expected `u16` and received `u32`. The archive SHA-256 was rechecked as `b8990f3ed500ec69f93e3313f3442fb5d1d5f3c9b8991e62e1e4da86d6267300`. The archive's report binds that run to source `b6475a041b9cbee8263eb2d91138f544d3c04862`, tree `1c7fbe5048241cc82d0bc8b1170f7f8ab20d48bd`; the integrator's checkpoint `9d6d8e55` is distinct. This was compile RED, not an executed publication refusal. A local pre-change Apple Silicon semantic check reproduced the same mode-width failure; its supplementary logs remain in the task state.

Actual Apple Silicon and Intel Debug/ReleaseSafe execution must run all 41 tests without skips, including native ACL/xattr refusal with original bytes retained, plain/durable replace and create, existing-create refusal, mode/owner/group preservation, simultaneous same-directory no-replace publication, unsupported strongest durability, postcommit sync failure, and original receipt replay after uncertain rename. Filesystems lacking directory sync or no-replace support must independently establish precommit refusal. macOS 11 runtime, APFS power-loss testing, strongest/F_FULLFSYNC support and T12 persistent-journal recovery remain separate NOT_RUN gates. `fsync` is not `F_FULLFSYNC`, and these fake-journal tests do not prove crash recovery or power-loss durability.

API facts came from the integrator's downloaded Apple OSS references in `state/darwin-api`, checked against the pinned Zig 0.16.0 declarations:

- [XNU stdio.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/stdio.h): descriptor-relative `renameatx_np`, `RENAME_EXCL=0x4`.
- [XNU rename manual](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/rename.2): exclusive rename semantics and unsupported filesystem behavior.
- [XNU xattr.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/xattr.h): four-argument `flistxattr`, six-argument `fsetxattr`, `XATTR_SHOWCOMPRESSION=0x20`.
- [Libc ACL header](https://github.com/apple-oss-distributions/Libc/blob/main/include/sys/acl.h), [ACL file operations](https://github.com/apple-oss-distributions/Libc/blob/main/posix1e/acl_file.c), and [filesec properties](https://github.com/apple-oss-distributions/Libc/blob/main/gen/filesec.c): extended ACL ownership and absent-ACL errno.

No push, merge, build/core change, runtime gate activation, or production write was performed.
