# Native storage evidence capture report

Source5781b6c, RED0018842, base d011a0d. Changed only three CI Python files. Four focused unittest cases pass on committed source: raw preservation without source/Git/special files; byte cap failure; missing fixtures cannot claim execution; replaced repository parent is not followed. RED missing capture module is preserved in state/T12/native-capture-red.log at0018842.

Collector was run on the retained actual T12 source8d241f6 fixtures, without rerunning their runtime binaries: each mode21 exec-fixture directories,187 raw members. Independently read every tar member and compared size/SHA256 with the capture manifest; no repo members are included. See verification.json for exact collector source/code/command/log/archive hashes. Fixture corpus belongs to old runtime8d241f6 and is not labeled new runtime PASS. Collector preserves executed child/case records, not every in-process negative fixture.

Native runner now captures after registered tests when T12 test source exists. Missing capture or capture exceptions cause a required failed check, independently from registered-tests exit. The original command outcome remains authoritative. The native source snapshot and installed-binary archive remain in the parent report. New real platform execution is pending publish.
