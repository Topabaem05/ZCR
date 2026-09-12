Public platform references used for the adapter design:

- [Apple FSEvents lifecycle guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html): watch before scan; start/stop/invalidate/release and reconciliation.
- [Apple FSEvents callback](https://developer.apple.com/documentation/coreservices/fseventstreamcallback): callback ABI and borrowed event arrays.
- [Apple FSEvents API index](https://developer.apple.com/documentation/coreservices/file_system_events): public run-loop scheduling API and deprecation.
- [Apple FlushSync](https://developer.apple.com/documentation/coreservices/1445629-fseventstreamflushsync): empty run-loop pump is not a delivery barrier.
- [Linux inotify manual](https://man7.org/linux/man-pages/man7/inotify.7.html): nonrecursive watches, rename mapping, overflow and event structure.

Manual Darwin C ABI declarations and constants still require SDK/native validation before a platform support claim.
